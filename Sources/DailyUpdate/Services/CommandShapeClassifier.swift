import Foundation

enum CommandRisk: String, Codable, CaseIterable, Hashable {
    case bulk
    case remoteScript
    case privileged
    case destructive
    case fallbackChain
    case chained
    case suppressedErrors
    case controlFlow
    case unparseable
}

struct CommandClassification: Equatable {
    let risks: Set<CommandRisk>

    var isBulk: Bool { risks.contains(.bulk) }
    var isRemoteScript: Bool { risks.contains(.remoteScript) }

    var needsReview: Bool {
        !risks.intersection([.fallbackChain, .chained, .suppressedErrors, .controlFlow, .unparseable]).isEmpty
    }
}

enum CommandShapeClassifier {
    private static let remoteScriptPatterns = [
        #"(curl|wget|fetch|http)\b[^|\n]*\|\s*(sudo\s+)?(/bin/)?(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|perl|ruby|node)\b"#,
        #"(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|perl|ruby|node)\b[^\n]*(<\([^)]*(curl|wget|fetch|http)\b[^)]*\)|\$\([^)]*(curl|wget|fetch|http)\b[^)]*\))"#,
        #"(eval|source|\.)\s+["']?\$\([^)]*(curl|wget|fetch|http)\b[^)]*\)"#
    ]

    private static let suppressedPatterns = [
        #"2>\s*/dev/null"#,
        #"&>\s*/dev/null"#,
        #">\s*/dev/null\s+2>&1"#,
        #"2>&-"#
    ]

    static func classify(_ command: String) -> CommandClassification {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CommandClassification(risks: [.unparseable]) }

        var risks = Set<CommandRisk>()
        if hasUnbalancedQuotes(trimmed) { risks.insert(.unparseable) }
        if trimmed.contains("||") { risks.insert(.fallbackChain) }
        if matches(#"(;|&&|\n)"#, in: trimmed) { risks.insert(.chained) }
        if suppressedPatterns.contains(where: { matches($0, in: trimmed) }) { risks.insert(.suppressedErrors) }
        if matches(#"\b(if|for|while|case|function)\b|(\{\s*.*\s*\})"#, in: trimmed) { risks.insert(.controlFlow) }
        if matches(#"\b(sudo|doas|pkexec)\b|\bsu\b"#, in: trimmed) { risks.insert(.privileged) }
        if matches(#"\b(rm\s+-[A-Za-z]*[rf]|dd\b|mkfs\w*|diskutil\s+erase|diskutil\s+partitionDisk|git\s+reset\s+--hard|git\s+clean\s+-f|shred\b|srm\b|chmod\s+-R|chown\s+-R)\b"#, in: trimmed) {
            risks.insert(.destructive)
        }
        if remoteScriptPatterns.contains(where: { matches($0, in: trimmed) }) { risks.insert(.remoteScript) }
        if isBulkOperation(trimmed) { risks.insert(.bulk) }

        return CommandClassification(risks: risks)
    }

    static func checkRunsUpdate(check: String, update: String) -> Bool {
        let updateTokens = normalizedTokens(update)
        guard !updateTokens.isEmpty else { return false }

        for segment in splitSegments(check) {
            let checkTokens = normalizedTokens(segment)
            if checkTokens.isEmpty { continue }
            if containsSubsequence(haystack: checkTokens, needle: updateTokens) {
                return true
            }
        }
        return false
    }

    private static func isBulkOperation(_ command: String) -> Bool {
        if matches(#"xargs[^\n]*(pip|pip3|python3?\s+-m\s+pip)\s+install\s+-U(\s|$)"#, in: command) {
            return true
        }
        if matches(#"\bpip3?\b[^\n]*\binstall\b[^\n]*\s-U\s+[^\n]*\$\("#, in: command) {
            return true
        }

        for segment in splitSegments(command) {
            var tokens = normalizedTokens(segment)
            guard !tokens.isEmpty else { continue }
            tokens = stripWrappers(tokens)
            guard let executable = tokens.first else { continue }

            switch executable {
            case "brew":
                if isBulkBrew(tokens) { return true }
            case "npm":
                if isBulkNpm(tokens) { return true }
            case "pnpm":
                if isBulkPnpm(tokens) { return true }
            case "yarn":
                if tokens.count >= 3, tokens[1] == "global", tokens[2] == "upgrade", tokenTail(tokens, from: 3).isEmpty {
                    return true
                }
            case "gem":
                if tokens.count >= 2, tokens[1] == "update" {
                    let args = tokenTail(tokens, from: 2)
                    if args.isEmpty || (args.allSatisfy { $0.hasPrefix("-") } && !args.contains("--system")) {
                        return true
                    }
                }
            case "mise":
                if tokens.count >= 2, ["upgrade", "up"].contains(tokens[1]), tokenTail(tokens, from: 2).isEmpty {
                    return true
                }
            case "mas":
                if tokens.count == 2, tokens[1] == "upgrade" { return true }
            case "pipx":
                if tokens.count >= 2, tokens[1] == "upgrade-all" { return true }
            case "uv":
                if tokens.count >= 4, tokens[1] == "tool", tokens[2] == "upgrade", tokens.contains("--all") { return true }
            case "cargo":
                if tokens.count >= 3, tokens[1] == "install-update", tokens.contains("-a") { return true }
            case "softwareupdate":
                if tokens.contains("-ia") || (tokens.contains("-i") && tokens.contains("-a")) { return true }
            case "npx":
                if tokens.count >= 3, tokens[1] == "skills", tokens[2] == "update" { return true }
            default:
                break
            }
        }
        return false
    }

    private static func isBulkBrew(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2, tokens[1] == "upgrade" else { return false }
        let args = tokenTail(tokens, from: 2)
        let nonFlags = args.filter { !$0.hasPrefix("-") }
        return nonFlags.isEmpty
    }

    private static func isBulkNpm(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        let args = Array(tokens.dropFirst())
        if let commandIndex = args.firstIndex(where: { ["update", "up", "upgrade"].contains($0) }) {
            let before = args[..<commandIndex]
            let after = Array(args[(commandIndex + 1)...])
            let hasGlobal = before.contains("-g") || before.contains("--global") || after.contains("-g") || after.contains("--global")
            let positional = after.filter { !$0.hasPrefix("-") }
            return hasGlobal && positional.isEmpty
        }
        return false
    }

    private static func isBulkPnpm(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2, ["update", "up"].contains(tokens[1]) else { return false }
        let args = tokenTail(tokens, from: 2)
        let hasGlobal = args.contains("-g") || args.contains("--global")
        let positional = args.filter { !$0.hasPrefix("-") }
        return hasGlobal && positional.isEmpty
    }

    private static func splitSegments(_ command: String) -> [String] {
        command.components(separatedBy: CharacterSet(charactersIn: "\n;|&"))
    }

    private static func normalizedTokens(_ command: String) -> [String] {
        tokenize(command).map { normalizeToken($0) }
    }

    private static func normalizeToken(_ token: String) -> String {
        let raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return raw }
        if raw == "/bin/bash" || raw == "/usr/bin/bash" || raw == "/bin/sh" {
            return (raw as NSString).lastPathComponent.lowercased()
        }
        if raw.hasPrefix("/") {
            return (raw as NSString).lastPathComponent.lowercased()
        }
        return raw.lowercased()
    }

    private static func stripWrappers(_ tokens: [String]) -> [String] {
        var tokens = tokens
        while let first = tokens.first {
            if first == "env" || first == "command" || first == "exec" || first == "nohup" || first == "time" {
                tokens.removeFirst()
                continue
            }
            if first == "sudo" || first == "doas" {
                tokens.removeFirst()
                continue
            }
            if first.contains("="), !first.hasPrefix("="), !first.hasSuffix("=") {
                tokens.removeFirst()
                continue
            }
            break
        }
        return tokens
    }

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        for scalar in command.unicodeScalars {
            let char = Character(scalar)
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if char == "'" && !inDouble {
                inSingle.toggle()
                continue
            }
            if char == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }
            if !inSingle && !inDouble && char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(char)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func containsSubsequence(haystack: [String], needle: [String]) -> Bool {
        guard !needle.isEmpty else { return false }
        var needleIndex = 0
        for token in haystack {
            if token == needle[needleIndex] {
                needleIndex += 1
                if needleIndex == needle.count {
                    return true
                }
            }
        }
        return false
    }

    private static func tokenTail(_ tokens: [String], from index: Int) -> [String] {
        guard tokens.count > index else { return [] }
        return Array(tokens[index...]).filter { !$0.isEmpty }
    }

    private static func hasUnbalancedQuotes(_ command: String) -> Bool {
        var single = false
        var double = false
        var escaped = false

        for scalar in command.unicodeScalars {
            let char = Character(scalar)
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if char == "'" && !double { single.toggle() }
            if char == "\"" && !single { double.toggle() }
        }

        return single || double || escaped
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
