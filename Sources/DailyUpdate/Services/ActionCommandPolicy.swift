import Foundation

enum ActionCommandPolicy {
    enum PackageManager: String, CaseIterable {
        case brew
        case npm
        case pnpm
        case yarn
        case gem
        case pip
        case flutter
        case mise
        case bun
        case nvm
        case fnm
        case rustup
        case cargo
        case mas
    }

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

    private static let packageManagerPatterns: [(PackageManager, String)] = [
        (.brew, #"\bbrew\b"#),
        (.npm, #"\bnpm\b"#),
        (.pnpm, #"\bpnpm\b"#),
        (.yarn, #"\byarn\b"#),
        (.gem, #"\bgem\b"#),
        (.pip, #"\bpip3?\b|\bpython3?\s+-m\s+pip\b"#),
        (.flutter, #"\bflutter\b"#),
        (.mise, #"\bmise\b"#),
        (.bun, #"\bbun\b"#),
        (.nvm, #"\bnvm\b"#),
        (.fnm, #"\bfnm\b"#),
        (.rustup, #"\brustup\b"#),
        (.cargo, #"\bcargo\b"#),
        (.mas, #"\bmas\b"#)
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

    static func shouldAutoSelectForInstall(_ item: UpdateItem) -> Bool {
        item.canInstall && !item.isSnoozed && !isRemoteScriptInstaller(item.installCommand)
    }

    static func packageManagers(in command: String) -> Set<PackageManager> {
        var managers = Set<PackageManager>()
        for (manager, pattern) in packageManagerPatterns where matches(pattern: pattern, in: command) {
            managers.insert(manager)
        }
        return managers
    }

    static func checkAndUpdateSharePackageManager(checkCommand: String, updateCommand: String) -> Bool {
        let checkManagers = packageManagers(in: checkCommand)
        let updateManagers = packageManagers(in: updateCommand)
        guard !checkManagers.isEmpty, !updateManagers.isEmpty else { return true }
        return !checkManagers.isDisjoint(with: updateManagers)
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
