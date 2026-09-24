import Foundation

enum TerminalCommandLauncher {
    static func openInTerminal(command: String) async -> ShellRunner.Result {
        await ShellRunner.runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: arguments(for: command),
            timeout: 30
        )
    }

    static func arguments(for command: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script (item 1 of argv)",
            "-e", "end run",
            "--",
            command
        ]
    }
}
