import Foundation

enum ActionCommandPolicy {
    private static let remoteScriptPattern = #"(curl|wget)\b[^|\n]*\|\s*(sh|bash)\b"#
    private static let stderrSuppressionPattern = #"2>\s*/dev/null"#

    private static let bulkPatterns: [String] = [
        #"^\s*npm\s+update\s+-g\s*$"#,
        #"^\s*pnpm\s+update\s+-g\s*$"#,
        #"^\s*yarn\s+global\s+upgrade\s*$"#,
        #"^\s*brew\s+upgrade\s*$"#,
        #"^\s*gem\s+update\s*$"#,
        #"^\s*mise\s+upgrade\s*$"#,
        #"xargs[^|\n]*\s+install\s+-U(\s|$)"#
    ]

    static func hasFallbackChain(_ command: String) -> Bool {
        command.contains("||")
    }

    static func hasSuppressedStderr(_ command: String) -> Bool {
        matches(pattern: stderrSuppressionPattern, in: command)
    }

    static func hasCommandSeparator(_ command: String) -> Bool {
        command.contains(";")
    }

    static func isRemoteScriptInstaller(_ command: String) -> Bool {
        matches(pattern: remoteScriptPattern, in: command)
    }

    static func matchesBulkPattern(_ command: String) -> Bool {
        bulkPatterns.contains { pattern in
            matches(pattern: pattern, in: command)
        }
    }

    private static func matches(pattern: String, in command: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }
}
