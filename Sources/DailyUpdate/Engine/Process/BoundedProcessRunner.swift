import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Amendment 1 RC1: the enricher process contract. Only `ReadOnlyQueries.swift` may reference
/// this type (the discovery lint enforces that); everything else in the engine still uses the
/// legacy runner. Every enricher process this runner starts is bounded on every axis a hostile or
/// broken child could exploit: its environment, its output size, its stderr size and its runtime.
enum ProcessEnvironment: Sendable, Equatable {
    /// Built from scratch; nothing is copied from the parent process. Every enricher must use
    /// this case — a test asserts it.
    case exactly([String: String])
    /// Only `whence` uses this (RC2): it deliberately sources the user's login shell profile, but
    /// `PATH` is always the given override, never the raw `ProcessInfo` value — matching Phase
    /// 1's `ShellRunner` behavior, so owner resolution describes what actually runs (S1).
    case inherited(overridingPATH: String)
}

struct BoundedProcessSpec: Sendable {
    let executable: String
    let arguments: [String]
    let environment: ProcessEnvironment
    let timeout: TimeInterval
    let maxStdoutBytes: Int
    let maxStderrBytes: Int

    init(
        executable: String,
        arguments: [String],
        environment: ProcessEnvironment,
        timeout: TimeInterval,
        maxStdoutBytes: Int,
        maxStderrBytes: Int = 16 * 1024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
    }
}

enum BoundedProcessRunner {
    /// The hard stop after a `SIGTERM`: reading never waits past `timeout + killGracePeriod` for
    /// EOF, even if a grandchild still holds a pipe open.
    ///
    /// P2-2 (CR FU2): `SIGKILL` goes out halfway through this window — at `timeout + 1 s`, not the
    /// amendment's `+ 2 s` — so the kill has a full second to land before reading stops at `+ 2 s`.
    /// The same schedule applies after the stdout cap: `SIGTERM` at the cap, `SIGKILL` 1 s later,
    /// reading stops 2 s later.
    static let killGracePeriod: TimeInterval = 2

    static func run(_ spec: BoundedProcessSpec) async -> QueryOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runSynchronously(spec))
            }
        }
    }

    private static func runSynchronously(_ spec: BoundedProcessSpec) -> QueryOutcome {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        switch spec.environment {
        case .exactly(let dictionary):
            process.environment = dictionary
        case .inherited(let overridingPATH):
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = overridingPATH
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        setNonBlocking(stdoutFD)
        setNonBlocking(stderrFD)

        do {
            try process.run()
        } catch {
            return QueryOutcome(
                evidence: ProcessEvidence(
                    executable: spec.executable,
                    arguments: spec.arguments,
                    termination: .launchFailed(PackageNameRules.sanitize("\(error)", maxLength: 500)),
                    stderr: "",
                    stderrTruncated: false,
                    elapsedMs: 0
                ),
                stdout: Data()
            )
        }

        var stdoutData = Data()
        var stderrData = Data()
        var stdoutCapExceeded = false
        var stderrTruncated = false
        let timeoutDeadline = start.addingTimeInterval(spec.timeout)
        let hardStopDeadline = timeoutDeadline.addingTimeInterval(killGracePeriod)
        var sentTerm = false
        var sentKill = false
        var timedOut = false

        // S2: once a stream hits its cap, this keeps reading and discarding — it never stops
        // draining the pipe. A child that keeps writing past the cap (stdout's terminate-on-cap
        // path aside) must never see a full pipe buffer and block on write(2); that would hide
        // its real exit status behind a timeout instead of reporting it.
        //
        // P2-2 (Security re-review FU3, CR FU2): `exceeded` means bytes were actually dropped. A
        // stream of exactly `cap` bytes is kept whole and isn't reported as truncated.
        func drainOnce(_ fd: Int32, into data: inout Data, cap: Int, exceeded: inout Bool) {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                    read(fd, rawBuffer.baseAddress, rawBuffer.count)
                }
                guard bytesRead > 0 else { break }
                let room = max(0, cap - data.count)
                if room > 0 { data.append(buffer, count: min(bytesRead, room)) }
                if bytesRead > room { exceeded = true }
            }
        }

        var capKillDeadline: Date?

        while true {
            drainOnce(stdoutFD, into: &stdoutData, cap: spec.maxStdoutBytes, exceeded: &stdoutCapExceeded)
            drainOnce(stderrFD, into: &stderrData, cap: spec.maxStderrBytes, exceeded: &stderrTruncated)

            let now = Date()
            // Security FU5 / CR FU2: past the stdout cap the output is never parsed, and the child
            // gets the same SIGTERM → SIGKILL escalation as a timeout, so one that ignores SIGTERM
            // doesn't linger. The pipes keep draining meanwhile so it can't block on a write.
            if stdoutCapExceeded {
                if capKillDeadline == nil {
                    capKillDeadline = now.addingTimeInterval(killGracePeriod)
                    kill(process.processIdentifier, SIGTERM)
                }
                if !process.isRunning { break }
                if let capKillDeadline {
                    if now >= capKillDeadline { break }
                    if !sentKill, now >= capKillDeadline.addingTimeInterval(-killGracePeriod / 2) {
                        sentKill = true
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                usleep(2000)
                continue
            }
            if !process.isRunning {
                break
            }

            if now >= hardStopDeadline {
                timedOut = true
                break
            }
            if now >= timeoutDeadline, !sentTerm {
                sentTerm = true
                timedOut = true
                kill(process.processIdentifier, SIGTERM)
            }
            if timedOut, !sentKill, now >= timeoutDeadline.addingTimeInterval(killGracePeriod / 2) {
                sentKill = true
                kill(process.processIdentifier, SIGKILL)
            }
            usleep(2000)
        }

        // One last non-blocking drain: a process that exited normally may still have buffered
        // output sitting in the pipe.
        drainOnce(stdoutFD, into: &stdoutData, cap: spec.maxStdoutBytes, exceeded: &stdoutCapExceeded)
        drainOnce(stderrFD, into: &stderrData, cap: spec.maxStderrBytes, exceeded: &stderrTruncated)
        // `Pipe`/`FileHandle` owns these descriptors; closing through it (not a raw `close(2)`)
        // keeps its bookkeeping consistent so it never later closes a descriptor number the
        // kernel has since handed to an unrelated pipe on another thread.
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        let termination: Termination
        if stdoutCapExceeded {
            termination = .outputCapExceeded
        } else if timedOut {
            // Once discovery's own ceiling fires, the outcome is "it didn't finish in time" even
            // if the SIGKILL that followed reaped the process before this returns.
            termination = .timedOut(afterMs: elapsedMs)
        } else {
            reapIfNeeded(process)
            switch process.terminationReason {
            case .uncaughtSignal:
                termination = .signaled(process.terminationStatus)
            default:
                termination = .exited(process.terminationStatus)
            }
        }

        // S2: `String(decoding:as:)` never fails — it replaces invalid byte sequences instead of
        // dropping the whole string, which mattered once the 16 KB cap could split a multi-byte
        // character mid-sequence.
        let stderrText = String(decoding: stderrData, as: UTF8.self)
        let sanitizedStderr = PackageNameRules.sanitize(homeRedacted(stderrText), maxLength: spec.maxStderrBytes)

        return QueryOutcome(
            evidence: ProcessEvidence(
                executable: spec.executable,
                arguments: spec.arguments,
                termination: termination,
                stderr: sanitizedStderr,
                stderrTruncated: stderrTruncated,
                elapsedMs: elapsedMs
            ),
            stdout: stdoutData
        )
    }

    /// A dying child can leave `waitpid` collectible without `Process.isRunning` having noticed
    /// yet; this nudges Foundation's bookkeeping without ever blocking past what the caller above
    /// already waited.
    private static func reapIfNeeded(_ process: Process) {
        guard process.isRunning else { return }
        var status: Int32 = 0
        _ = waitpid(process.processIdentifier, &status, WNOHANG)
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// §7.4: stderr is sanitized before it's kept, with `$HOME` shown as `~`.
    private static func homeRedacted(_ text: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}
