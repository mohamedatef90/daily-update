import Foundation

enum ShellRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { exitCode == 0 }
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

                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        process.terminate()
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: Result(
                        exitCode: 127,
                        stdout: "",
                        stderr: error.localizedDescription
                    ))
                    return
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }
        }
    }

    private static var defaultPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "\(home)/.pyenv/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/.bun/bin",
            "\(home)/Library/pnpm",
            "\(home)/.yarn/bin",
            "\(home)/.asdf/shims"
        ]
        .joined(separator: ":")
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
