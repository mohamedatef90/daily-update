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
    private static let fetchers: Set<String> = ["curl", "wget", "fetch", "http"]
    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish",
        "python", "python3", "python2", "perl", "ruby", "node"
    ]
    private static let shellExecutables: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    private static let privilegeCommands: Set<String> = ["sudo", "doas", "pkexec", "su"]
    private static let controlFlowKeywords: Set<String> = [
        "if", "then", "fi", "for", "while", "case", "do", "done", "function", "else", "elif", "until"
    ]

    static func classify(_ command: String) -> CommandClassification {
        let risks = classify(command, depth: 0, visited: Set())
        return CommandClassification(risks: risks)
    }

    static func checkRunsUpdate(check: String, update: String) -> Bool {
        let updateTokens = normalizedTokens(update)
        guard !updateTokens.isEmpty else { return false }

        var queue = [check]
        var visited = Set<String>()
        while let command = queue.popLast() {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, visited.insert(trimmed).inserted else { continue }

            let tokens = ShellLexer.lex(trimmed)
            for segment in ShellLexer.split(tokens, by: [.and, .or, .semicolon, .newline]) {
                let words = ShellLexer.words(from: segment)
                let normalized = normalizedTokens(words: words)
                if containsSubsequence(haystack: normalized, needle: updateTokens) {
                    return true
                }
                queue.append(contentsOf: inlineShellCommands(in: words))
            }
        }
        return false
    }

    static func containsMutatingPackageManagerVerb(_ command: String) -> Bool {
        let segments = allCommandSegments(command)
        for words in segments {
            let normalized = normalizedTokens(words: words)
            if isMutatingPackageManagerInvocation(normalized) {
                return true
            }
        }
        return false
    }

    private static func classify(_ command: String, depth: Int, visited: Set<String>) -> Set<CommandRisk> {
        guard depth < 4 else { return [] }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [.unparseable] }
        guard !visited.contains(trimmed) else { return [] }

        var nextVisited = visited
        nextVisited.insert(trimmed)

        var risks = Set<CommandRisk>()
        let tokens = ShellLexer.lex(trimmed)

        if ShellLexer.hasUnbalancedQuotes(trimmed) {
            risks.insert(.unparseable)
        }
        if tokens.contains(where: { $0.kind == .op(.or) }) {
            risks.insert(.fallbackChain)
        }
        if tokens.contains(where: { $0.kind == .op(.and) || $0.kind == .op(.semicolon) || $0.kind == .op(.newline) }) {
            risks.insert(.chained)
        }
        if containsSuppressedErrors(trimmed) {
            risks.insert(.suppressedErrors)
        }
        if containsControlFlow(tokens) {
            risks.insert(.controlFlow)
        }
        if containsPrivilegeEscalation(trimmed, tokens: tokens) {
            risks.insert(.privileged)
        }
        if containsDestructiveOperation(tokens: tokens) {
            risks.insert(.destructive)
        }
        if isRemoteScript(trimmed, tokens: tokens) {
            risks.insert(.remoteScript)
        }
        if isBulkOperation(trimmed, tokens: tokens) {
            risks.insert(.bulk)
        }

        for nested in inlineShellCommands(in: ShellLexer.words(from: tokens)) {
            risks.formUnion(classify(nested, depth: depth + 1, visited: nextVisited))
        }

        return risks
    }

    private static func allCommandSegments(_ command: String) -> [[String]] {
        var segments: [[String]] = []
        var queue = [command]
        var visited = Set<String>()

        while let next = queue.popLast() {
            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, visited.insert(trimmed).inserted else { continue }

            let tokens = ShellLexer.lex(trimmed)
            let logical = ShellLexer.split(tokens, by: [.and, .or, .semicolon, .newline])
            for segment in logical {
                let words = ShellLexer.words(from: segment)
                guard !words.isEmpty else { continue }
                segments.append(words)
                queue.append(contentsOf: inlineShellCommands(in: words))
            }
        }
        return segments
    }

    private static func containsControlFlow(_ tokens: [ShellToken]) -> Bool {
        let lowered = ShellLexer.words(from: tokens).map { $0.lowercased() }
        if lowered.contains(where: { controlFlowKeywords.contains($0) }) {
            return true
        }
        return lowered.contains("{") || lowered.contains("}")
    }

    private static func containsPrivilegeEscalation(_ command: String, tokens: [ShellToken]) -> Bool {
        let lowered = ShellLexer.words(from: tokens).map(normalizedExecutableName)
        if lowered.contains(where: { privilegeCommands.contains($0) }) {
            return true
        }
        return lowered.contains("osascript") && command.lowercased().contains("administrator privileges")
    }

    private static func containsDestructiveOperation(tokens: [ShellToken]) -> Bool {
        let words = normalizedTokens(words: ShellLexer.words(from: tokens))
        guard !words.isEmpty else { return false }

        for (index, token) in words.enumerated() {
            if token == "rm", index + 1 < words.count {
                let flags = words[index + 1]
                if flags.hasPrefix("-"), flags.contains("r"), flags.contains("f") {
                    return true
                }
            }
            if token == "git", index + 2 < words.count, words[index + 1] == "reset", words[index + 2] == "--hard" {
                return true
            }
            if token == "git", index + 2 < words.count, words[index + 1] == "clean", words[index + 2].contains("f") {
                return true
            }
            if token == "diskutil", index + 1 < words.count {
                let verb = words[index + 1]
                if verb == "erasedisk" || verb == "partitiondisk" || verb.hasPrefix("erase") {
                    return true
                }
            }
            if token == "chmod" || token == "chown" {
                if words.dropFirst(index + 1).contains("-r") || words.dropFirst(index + 1).contains(where: { $0.contains("r") && $0.hasPrefix("-") }) {
                    return true
                }
            }
        }

        return words.contains(where: {
            $0 == "dd" ||
                $0.hasPrefix("mkfs") ||
                $0 == "shred" ||
                $0 == "srm"
        })
    }

    private static func isRemoteScript(_ command: String, tokens: [ShellToken]) -> Bool {
        if matches(#"(?:^|[;&]\s*)(?:eval|source|\.|bash|sh|zsh|dash|ksh|fish|python[0-9.]*|perl|ruby|node)\b[^\n]*(?:<\(|\$\()[^)]*(?:curl|wget|fetch|http)\b[^)]*\)"#, in: command) {
            return true
        }

        for logicalSegment in ShellLexer.split(tokens, by: [.and, .or, .semicolon, .newline]) {
            let stages = ShellLexer.split(logicalSegment, by: [.pipe])
            let stageWords = stages.map { ShellLexer.words(from: $0) }

            for (index, words) in stageWords.enumerated() where isFetcherStage(words) {
                guard index + 1 < stageWords.count else { continue }
                if stageWords[(index + 1)...].contains(where: executesPipelineInput) {
                    return true
                }
            }
        }
        return false
    }

    private static func isFetcherStage(_ words: [String]) -> Bool {
        let normalized = stripWrappers(normalizedTokens(words: words))
        guard let executable = normalized.first else { return false }
        return fetchers.contains(executable)
    }

    private static func executesPipelineInput(_ words: [String]) -> Bool {
        let normalized = stripWrappers(normalizedTokens(words: words))
        guard let executable = normalized.first else { return false }
        guard interpreters.contains(executable) else { return false }
        return interpreterConsumesStdin(executable: executable, arguments: Array(normalized.dropFirst()))
    }

    private static func interpreterConsumesStdin(executable: String, arguments: [String]) -> Bool {
        if arguments.contains("-c") || arguments.contains("-lc") || arguments.contains("-e") {
            return false
        }
        if let firstPositional = firstPositionalArgument(arguments) {
            return firstPositional == "-"
        }
        if executable == "node" {
            return !arguments.contains("-p")
        }
        return true
    }

    private static func firstPositionalArgument(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--" {
                return index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            return arg
        }
        return nil
    }

    private static func isBulkOperation(_ command: String, tokens: [ShellToken]) -> Bool {
        if matches(#"xargs[^\n]*(pip|pip3|python3?\s+-m\s+pip)\s+install\s+-U(\s|$)"#, in: command) {
            return true
        }
        if matches(#"xargs[^\n]*brew\s+upgrade(\s|$)"#, in: command) {
            return true
        }

        let segments = allCommandSegments(command)
        for words in segments {
            var normalized = stripWrappers(normalizedTokens(words: words))
            guard !normalized.isEmpty else { continue }

            if normalized.first == "xargs" {
                normalized = stripWrappers(normalized)
                guard !normalized.isEmpty else { continue }
            }

            guard let executable = normalized.first else { continue }
            let args = Array(normalized.dropFirst())
            let hasSubstitution = args.contains(where: containsCommandSubstitution)

            switch executable {
            case "brew":
                guard let verb = args.first, verb == "upgrade" else { continue }
                let tail = Array(args.dropFirst())
                let positional = positionalArguments(tail)
                if positional.isEmpty || hasSubstitution {
                    return true
                }
            case "npm":
                if isBulkNpm(args) { return true }
            case "pnpm":
                if isBulkPnpm(args) { return true }
            case "yarn":
                if args.count >= 2, args[0] == "global", args[1] == "upgrade", positionalArguments(Array(args.dropFirst(2))).isEmpty {
                    return true
                }
            case "gem":
                if args.first == "update" {
                    let tail = Array(args.dropFirst())
                    if positionalArguments(tail).isEmpty && !tail.contains("--system") {
                        return true
                    }
                }
            case "mise":
                if let verb = args.first, (verb == "upgrade" || verb == "up"), positionalArguments(Array(args.dropFirst())).isEmpty {
                    return true
                }
            case "mas":
                if args.first == "upgrade" {
                    return true
                }
            case "pipx":
                if args.first == "upgrade-all" {
                    return true
                }
            case "uv":
                if args.count >= 3, args[0] == "tool", args[1] == "upgrade", args.contains("--all") {
                    return true
                }
            case "cargo":
                if args.count >= 2, args[0] == "install-update", args.contains("-a") {
                    return true
                }
            case "softwareupdate":
                if args.contains("-ia") || ((args.contains("-i") || args.contains("--install")) && (args.contains("-a") || args.contains("--all"))) {
                    return true
                }
            case "npx":
                if args.count >= 2, args[0] == "skills", args[1] == "update" {
                    return true
                }
            case "pip", "pip3":
                if args.first == "install", args.contains("-u") || args.contains("--upgrade"), hasSubstitution {
                    return true
                }
            case "python", "python3", "python2":
                if args.count >= 3, args[0] == "-m", args[1] == "pip", args[2] == "install", (args.contains("-u") || args.contains("--upgrade")), hasSubstitution {
                    return true
                }
            default:
                continue
            }
        }

        return false
    }

    private static func isBulkNpm(_ args: [String]) -> Bool {
        guard let commandIndex = args.firstIndex(where: { ["update", "up", "upgrade"].contains($0) }) else {
            return false
        }
        let before = Array(args[..<commandIndex])
        let after = Array(args.dropFirst(commandIndex + 1))
        let hasGlobal = hasGlobalFlag(before + after)
        let positional = positionalArguments(after, valueOptions: ["--location"])
        return hasGlobal && positional.isEmpty
    }

    private static func isBulkPnpm(_ args: [String]) -> Bool {
        guard let verb = args.first, verb == "update" || verb == "up" else { return false }
        let tail = Array(args.dropFirst())
        let hasGlobal = tail.contains("-g") || tail.contains("--global")
        return hasGlobal && positionalArguments(tail).isEmpty
    }

    private static func isMutatingPackageManagerInvocation(_ normalized: [String]) -> Bool {
        guard !normalized.isEmpty else { return false }
        let words = stripWrappers(normalized)
        guard let executable = words.first else { return false }
        let args = Array(words.dropFirst())

        switch executable {
        case "brew":
            return args.first.map { ["upgrade", "update", "install", "reinstall", "uninstall", "tap", "untap"].contains($0) } ?? false
        case "npm", "pnpm":
            return args.contains(where: { ["update", "up", "upgrade", "install", "i", "add", "remove", "uninstall"].contains($0) })
        case "yarn":
            return args.contains(where: { ["upgrade", "add", "remove", "install", "up"].contains($0) })
        case "pip", "pip3":
            return args.contains(where: { ["install", "uninstall"].contains($0) })
        case "python", "python3", "python2":
            return args.count >= 3 && args[0] == "-m" && args[1] == "pip" && ["install", "uninstall"].contains(args[2])
        case "gem":
            return args.first.map { ["update", "install", "uninstall"].contains($0) } ?? false
        case "pipx":
            return args.first.map { ["upgrade", "upgrade-all", "install", "uninstall", "reinstall"].contains($0) } ?? false
        case "uv":
            return args.count >= 3 && args[0] == "tool" && ["install", "upgrade", "uninstall"].contains(args[1])
        case "cargo":
            return args.first.map { ["install", "uninstall", "install-update"].contains($0) } ?? false
        case "rustup":
            return args.first.map { ["update", "install"].contains($0) } ?? false
        case "mas":
            return args.first.map { ["upgrade", "install"].contains($0) } ?? false
        case "softwareupdate":
            return args.contains("-ia") || args.contains("-i") || args.contains("--install")
        default:
            return false
        }
    }

    private static func inlineShellCommands(in words: [String]) -> [String] {
        let stripped = stripWrappersRaw(words)
        guard let executable = stripped.first.map(normalizedExecutableName), shellExecutables.contains(executable) else {
            return []
        }

        var nested: [String] = []
        for (index, token) in stripped.enumerated() where token.lowercased() == "-c" || token.lowercased() == "-lc" {
            guard index + 1 < stripped.count else { continue }
            nested.append(stripped[index + 1])
        }
        return nested
    }

    private static func containsSuppressedErrors(_ command: String) -> Bool {
        matches(#"2>\s*/dev/null|&>\s*/dev/null|>\s*/dev/null\s+2>&1|2>&-"#, in: command)
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

    private static func normalizedTokens(_ command: String) -> [String] {
        normalizedTokens(words: ShellLexer.words(from: ShellLexer.lex(command)))
    }

    private static func normalizedTokens(words: [String]) -> [String] {
        words
            .map(normalizedExecutableName)
            .filter { !$0.isEmpty }
    }

    private static func normalizedExecutableName(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("/") {
            return (lower as NSString).lastPathComponent
        }
        return lower
    }

    private static func stripWrappers(_ tokens: [String]) -> [String] {
        var working = tokens

        func removeLeadingOptions(optionValueFlags: Set<String> = []) {
            while let first = working.first {
                if optionValueFlags.contains(first), working.count > 1 {
                    working.removeFirst(2)
                    continue
                }
                if first.hasPrefix("-") {
                    working.removeFirst()
                    continue
                }
                break
            }
        }

        while let first = working.first {
            if ["env", "command", "exec", "nohup", "time"].contains(first) {
                working.removeFirst()
                continue
            }
            if first == "sudo" || first == "doas" {
                working.removeFirst()
                removeLeadingOptions()
                continue
            }
            if first == "arch" {
                working.removeFirst()
                if let architecture = working.first, architecture.hasPrefix("-") || architecture == "arm64" || architecture == "x86_64" {
                    working.removeFirst()
                }
                continue
            }
            if first == "nice" {
                working.removeFirst()
                removeLeadingOptions(optionValueFlags: ["-n"])
                continue
            }
            if first == "caffeinate" {
                working.removeFirst()
                removeLeadingOptions()
                continue
            }
            if first == "xargs" {
                working.removeFirst()
                removeLeadingOptions(optionValueFlags: ["-n", "-p", "-i", "-l", "-s", "-e", "-I", "-L", "-P", "-E"])
                continue
            }
            if first.contains("="), !first.hasPrefix("="), !first.hasSuffix("=") {
                working.removeFirst()
                continue
            }
            break
        }

        return working
    }

    private static func hasGlobalFlag(_ args: [String]) -> Bool {
        if args.contains("-g") || args.contains("--global") {
            return true
        }
        if args.contains("--location=global") {
            return true
        }
        guard args.count >= 2 else { return false }
        for index in 0..<(args.count - 1) where args[index] == "--location" {
            if args[index + 1] == "global" {
                return true
            }
        }
        return false
    }

    private static func stripWrappersRaw(_ tokens: [String]) -> [String] {
        var working = tokens
        while let first = working.first {
            let lowered = normalizedExecutableName(first)
            if ["env", "command", "exec", "nohup", "time"].contains(lowered) {
                working.removeFirst()
                continue
            }
            if lowered == "sudo" || lowered == "doas" {
                working.removeFirst()
                while let next = working.first, next.hasPrefix("-") {
                    working.removeFirst()
                }
                continue
            }
            if lowered == "arch" {
                working.removeFirst()
                if let next = working.first, next.hasPrefix("-") || next == "arm64" || next == "x86_64" {
                    working.removeFirst()
                }
                continue
            }
            if lowered == "nice" {
                working.removeFirst()
                while let next = working.first, next.hasPrefix("-") {
                    let consumesValue = next == "-n"
                    working.removeFirst()
                    if consumesValue, !working.isEmpty {
                        working.removeFirst()
                    }
                }
                continue
            }
            if lowered == "caffeinate" {
                working.removeFirst()
                while let next = working.first, next.hasPrefix("-") {
                    working.removeFirst()
                }
                continue
            }
            if lowered == "xargs" {
                working.removeFirst()
                while let next = working.first, next.hasPrefix("-") {
                    let consumesValue = ["-n", "-p", "-i", "-l", "-s", "-e", "-I", "-L", "-P", "-E"].contains(next)
                    working.removeFirst()
                    if consumesValue, !working.isEmpty {
                        working.removeFirst()
                    }
                }
                continue
            }
            if first.contains("="), !first.hasPrefix("="), !first.hasSuffix("=") {
                working.removeFirst()
                continue
            }
            break
        }
        return working
    }

    private static func positionalArguments(
        _ args: [String],
        valueOptions: Set<String> = []
    ) -> [String] {
        var positional: [String] = []
        var skipNext = false

        for arg in args {
            if skipNext {
                skipNext = false
                continue
            }
            if valueOptions.contains(arg) {
                skipNext = true
                continue
            }
            if arg.hasPrefix("-") {
                continue
            }
            positional.append(arg)
        }

        return positional
    }

    private static func containsCommandSubstitution(_ token: String) -> Bool {
        token.contains("$(") || token.contains("<(") || token.contains("`")
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
