import AppKit
import Foundation

enum AdminCommandRunner {
    /// Shows macOS's standard administrator authentication dialog without changing
    /// the machine. macOS controls whether Touch ID is available in that dialog.
    static func requestAuthorization() async -> ShellRunner.Result {
        await run("/usr/bin/true")
    }

    static func run(
        _ command: String,
        workingDirectory: String? = nil,
        timeout _: TimeInterval = 600
    ) async -> ShellRunner.Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let source = appleScriptSource(for: command, workingDirectory: workingDirectory)
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: ShellRunner.Result(
                        exitCode: 1,
                        stdout: "",
                        stderr: "Could not prepare the administrator command."
                    ))
                    return
                }

                var error: NSDictionary?
                let output = script.executeAndReturnError(&error)
                if let error {
                    let message = error[NSAppleScript.errorMessage] as? String
                        ?? "Administrator authorization was cancelled or failed."
                    let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? 1
                    continuation.resume(returning: ShellRunner.Result(
                        exitCode: code,
                        stdout: "",
                        stderr: message
                    ))
                    return
                }

                continuation.resume(returning: ShellRunner.Result(
                    exitCode: 0,
                    stdout: output.stringValue ?? "",
                    stderr: ""
                ))
            }
        }
    }

    static func appleScriptSource(for command: String, workingDirectory: String?) -> String {
        let resolvedCommand = ConfigLoader.resolveCommand(command)
        let directoryPrefix = workingDirectory.map {
            "cd \(ShellEscaping.quote(($0 as NSString).expandingTildeInPath)) && "
        } ?? ""
        let shellCommand = "/bin/zsh -lc \(ShellEscaping.quote(directoryPrefix + resolvedCommand))"
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}
