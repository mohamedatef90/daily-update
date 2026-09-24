import Darwin
import Foundation

enum ShellRunner {
    private static let timeoutQueue = DispatchQueue(
        label: "DailyUpdate.ShellRunner.timeout",
        qos: .userInitiated
    )

    enum Termination: String, Equatable {
        case exited
        case timedOut
        case launchFailed
        case signalled
    }

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let termination: Termination
        let processIdentifier: Int32?
        let duration: TimeInterval

        var timedOut: Bool { termination == .timedOut }
        var succeeded: Bool { termination == .exited && exitCode == 0 }
    }

    static func run(
        _ command: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) async -> Result {
        let resolvedCommand = ConfigLoader.resolveCommand(command)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let startedAt = Date()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", resolvedCommand]

                if let workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory.expandingTilde)
                }

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = Self.defaultPath
                environment?.forEach { env[$0.key] = $0.value }
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(
                        exitCode: 127,
                        stdout: "",
                        stderr: error.localizedDescription,
                        termination: .launchFailed,
                        processIdentifier: nil,
                        duration: Date().timeIntervalSince(startedAt)
                    ))
                    return
                }

                let pid = process.processIdentifier
                _ = setpgid(pid, pid)
                let outputGroup = DispatchGroup()
                var stdoutData = Data()
                var stderrData = Data()
                let outputLock = NSLock()
                let stateLock = NSLock()
                var didTimeOut = false
                var didFinish = false
                var stopOutputDrain = false
                let shouldStopOutputDrain = {
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    return stopOutputDrain
                }

                outputGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = readToEndSafely(
                        stdoutPipe.fileHandleForReading,
                        shouldStop: shouldStopOutputDrain
                    )
                    outputLock.lock(); stdoutData = data; outputLock.unlock()
                    outputGroup.leave()
                }
                outputGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = readToEndSafely(
                        stderrPipe.fileHandleForReading,
                        shouldStop: shouldStopOutputDrain
                    )
                    outputLock.lock(); stderrData = data; outputLock.unlock()
                    outputGroup.leave()
                }

                let timeoutWork = DispatchWorkItem {
                    stateLock.lock()
                    guard !didFinish else { stateLock.unlock(); return }
                    didTimeOut = true
                    stateLock.unlock()
                    terminateProcessTree(pid: pid, signal: SIGTERM)
                    Self.timeoutQueue.asyncAfter(deadline: .now() + 1) {
                        terminateProcessTree(pid: pid, signal: SIGKILL)
                        stateLock.lock()
                        stopOutputDrain = true
                        stateLock.unlock()
                    }
                }
                Self.timeoutQueue.asyncAfter(deadline: .now() + max(0.01, timeout), execute: timeoutWork)

                process.waitUntilExit()
                outputGroup.wait()
                stateLock.lock()
                didFinish = true
                let timedOut = didTimeOut
                stateLock.unlock()
                timeoutWork.cancel()

                outputLock.lock(); let out = stdoutData; let err = stderrData; outputLock.unlock()
                let stdout = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let termination: Termination
                if timedOut {
                    termination = .timedOut
                } else if process.terminationReason == .uncaughtSignal {
                    termination = .signalled
                } else {
                    termination = .exited
                }

                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr,
                    termination: termination,
                    processIdentifier: pid,
                    duration: Date().timeIntervalSince(startedAt)
                ))
            }
        }
    }

    private static func readToEndSafely(
        _ handle: FileHandle,
        shouldStop: () -> Bool
    ) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if shouldStop() { return data }
                usleep(10_000)
                continue
            }
            return data
        }
    }

    private static func terminateProcessTree(pid: Int32, signal: Int32) {
        if kill(-pid, signal) != 0 { _ = kill(pid, signal) }
    }

    static var defaultPath: String {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        return effectivePath(
            inheritedPath: environment["PATH"],
            home: home,
            userManagedDirectories: userManagedBinDirectories(home: home)
        )
    }

    static func effectivePath(
        inheritedPath: String?,
        home: String,
        userManagedDirectories: [String]
    ) -> String {
        let inherited = inheritedPath?.split(separator: ":").map(String.init) ?? []
        let fallbacks = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin",
            "/usr/sbin", "/sbin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin", "\(home)/.nvm/versions/node/current/bin", "\(home)/.pyenv/shims",
            "\(home)/.local/share/mise/shims", "\(home)/.bun/bin", "\(home)/Library/pnpm",
            "\(home)/.yarn/bin", "\(home)/.asdf/shims"
        ] + userManagedDirectories

        var seen = Set<String>()
        return (inherited + fallbacks)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func userManagedBinDirectories(home: String) -> [String] {
        let fileManager = FileManager.default
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        var candidates = [
            homeURL.appendingPathComponent("bin").path,
            homeURL.appendingPathComponent(".local/bin").path,
            homeURL.appendingPathComponent(".npm-global/bin").path,
            homeURL.appendingPathComponent(".opencode/bin").path
        ]
        if let entries = try? fileManager.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) {
            for entry in entries {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    candidates.append(entry.appendingPathComponent("bin").path)
                }
            }
        }
        var seen = Set<String>()
        return candidates.filter { fileManager.fileExists(atPath: $0) && seen.insert($0).inserted }
    }
}

private extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
