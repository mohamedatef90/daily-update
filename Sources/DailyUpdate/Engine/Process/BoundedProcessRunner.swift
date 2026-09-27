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
    /// The grace period between `SIGTERM` and `SIGKILL`, and the hard stop after that: reading
    /// never waits past `timeout + killGracePeriod` for EOF, even if a grandchild still holds a
    /// pipe open.
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

        func drainOnce(_ fd: Int32, into data: inout Data, cap: Int, exceeded: inout Bool) {
            guard !exceeded else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                    read(fd, rawBuffer.baseAddress, rawBuffer.count)
                }
                guard bytesRead > 0 else { break }
                if data.count < cap {
                    data.append(buffer, count: min(bytesRead, cap - data.count))
                }
                if data.count >= cap { exceeded = true; break }
            }
        }

        while true {
            drainOnce(stdoutFD, into: &stdoutData, cap: spec.maxStdoutBytes, exceeded: &stdoutCapExceeded)
            drainOnce(stderrFD, into: &stderrData, cap: spec.maxStderrBytes, exceeded: &stderrTruncated)

            if stdoutCapExceeded {
                if process.isRunning { process.terminate() }
                break
            }
            if !process.isRunning {
                break
            }

            let now = Date()
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

        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
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
