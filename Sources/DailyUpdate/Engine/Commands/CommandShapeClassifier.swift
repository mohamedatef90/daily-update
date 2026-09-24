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

        for words in allSimpleCommands(check) {
            let normalized = normalizedTokens(words: words)
            if containsSubsequence(haystack: normalized, needle: updateTokens) {
                return true
            }
        }
        return false
    }

    static func containsMutatingPackageManagerVerb(_ command: String) -> Bool {
        for words in allSimpleCommands(command) {
            let normalized = stripWrappers(normalizedTokens(words: words))
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
        if tokens.contains(where: { $0.kind == .op(.and) || $0.kind == .op(.semicolon) || $0.kind == .op(.newline) || $0.kind == .op(.background) }) {
            risks.insert(.chained)
        }
        if containsSuppressedErrors(trimmed) {
            risks.insert(.suppressedErrors)
        }
        if containsControlFlow(tokens) {
            risks.insert(.controlFlow)
        }

        let simpleCommands = allSimpleCommands(trimmed)
        for words in simpleCommands {
            if startsWithDynamicExecutable(words) {
                risks.insert(.unparseable)
            }
            if containsPrivilegeEscalation(words: words) {
                risks.insert(.privileged)
            }
            if containsDestructiveOperation(words: words) {
                risks.insert(.destructive)
            }
            if isBulkOperation(words: words) {
                risks.insert(.bulk)
            }
        }

        if isRemoteScript(trimmed, tokens: tokens) {
            risks.insert(.remoteScript)
        }

        for nested in nestedCommands(in: trimmed, words: ShellLexer.words(from: tokens)) {
            risks.formUnion(classify(nested, depth: depth + 1, visited: nextVisited))
        }

        return risks
    }

    private static func allSimpleCommands(_ command: String) -> [[String]] {
        var segments: [[String]] = []
        var queue = [command]
        var visited = Set<String>()

        while let next = queue.popLast() {
            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, visited.insert(trimmed).inserted else { continue }

            let tokens = ShellLexer.lex(trimmed)
            let logical = ShellLexer.split(tokens, by: [.and, .or, .semicolon, .newline, .background])
            for segment in logical {
                let pipelineStages = ShellLexer.split(segment, by: [.pipe, .pipeAnd])
                for stage in pipelineStages {
                    let words = ShellLexer.words(from: stage)
                    guard !words.isEmpty else { continue }
                    segments.append(words)
                    queue.append(contentsOf: inlineShellCommands(in: words))
                }
            }
            queue.append(contentsOf: ShellLexer.nestedCommands(in: trimmed))
        }
        return segments
    }

    private static func containsControlFlow(_ tokens: [ShellToken]) -> Bool {
        let lowered = ShellLexer.words(from: tokens).map { $0.lowercased() }
        if lowered.contains(where: { controlFlowKeywords.contains($0) }) {
            return true
        }
        return tokens.contains(where: { $0.kind == .op(.leftBrace) || $0.kind == .op(.rightBrace) })
    }

    private static func containsPrivilegeEscalation(words: [String]) -> Bool {
        let normalizedWords = normalizedTokens(words: words)
        if normalizedWords.contains(where: { privilegeCommands.contains($0) }) {
            return true
        }
        let stripped = stripWrappers(normalizedWords)
        guard let executable = stripped.first else { return false }
        return executable == "osascript"
    }

    private static func containsDestructiveOperation(words: [String]) -> Bool {
        let normalized = stripWrappers(normalizedTokens(words: words))
        guard let executable = normalized.first else { return false }
        let args = Array(normalized.dropFirst())

        switch executable {
        case "rm":
            return hasRecursiveOrForceFlag(args)
        case "git":
            if args.count >= 2, args[0] == "reset", args[1] == "--hard" {
                return true
            }
            if args.first == "clean", args.dropFirst().contains(where: { $0.hasPrefix("-") && $0.contains("f") }) {
                return true
            }
            return false
        case "diskutil":
            guard let verb = args.first else { return false }
            return verb == "erasedisk" || verb == "partitiondisk" || verb.hasPrefix("erase")
        case "chmod", "chown":
            return args.contains("-r") || args.contains("-R") || args.contains(where: { $0.hasPrefix("-") && ($0.contains("r") || $0.contains("R")) })
        case "dd":
            return true
        default:
            if executable.hasPrefix("mkfs") || executable == "shred" || executable == "srm" {
                return true
            }
            return false
        }
    }

    private static func hasRecursiveOrForceFlag(_ args: [String]) -> Bool {
        for arg in args {
            if arg == "--" {
                break
            }
            if arg == "--recursive" || arg == "--force" {
                return true
            }
            guard arg.hasPrefix("-") else { continue }
            if arg.contains("r") || arg.contains("R") || arg.contains("f") {
                return true
            }
        }
        return false
    }

    private static func isRemoteScript(_ command: String, tokens: [ShellToken]) -> Bool {
        for words in allSimpleCommands(command) {
            if startsWithDynamicExecutable(words) {
                continue
            }

            let strippedRaw = stripWrappersRaw(words)
            guard let executableToken = strippedRaw.first else { continue }
            let executable = normalizedExecutableName(executableToken)
            let args = Array(strippedRaw.dropFirst())

            if executable == "." || executable == "source" || executable == "eval" {
                if argumentsContainFetcherSubstitution(args) {
                    return true
                }
            }

            if interpreters.contains(executable), argumentsContainFetcherSubstitution(args) {
                return true
            }
        }

        for logicalSegment in ShellLexer.split(tokens, by: [.and, .or, .semicolon, .newline, .background]) {
            let stages = ShellLexer.split(logicalSegment, by: [.pipe, .pipeAnd])
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
        if startsWithDynamicExecutable(words) {
            return true
        }

        let strippedRaw = stripWrappersRaw(words)
        guard let executableToken = strippedRaw.first else { return false }
        let executable = normalizedExecutableName(executableToken)
        let args = Array(strippedRaw.dropFirst()).map { $0.lowercased() }

        if shellExecutables.contains(executable) {
            return shellConsumesStdin(args)
        }

        if executable == "perl" || executable == "ruby" || executable == "node" {
            if containsInlineFlag(args, allowedShortOptions: ["e", "p"]) {
                return false
            }
            if hasScriptPathArgument(args) {
                return false
            }
            return true
        }

        if executable == "python" || executable == "python2" || executable == "python3" {
            if containsInlineFlag(args, allowedShortOptions: ["c", "m"]) {
                return false
            }
            if hasScriptPathArgument(args) {
                return false
            }
            return true
        }

        if interpreters.contains(executable) {
            if hasScriptPathArgument(args) {
                return false
            }
            return true
        }

        return looksLikeInterpreter(executable)
    }

    private static func shellConsumesStdin(_ arguments: [String]) -> Bool {
        if containsShortOptionCluster(arguments, containing: "c") {
            return false
        }
        if containsShortOptionCluster(arguments, containing: "s") {
            return true
        }

        guard let script = firstPositionalArgument(arguments) else {
            return true
        }
        if script == "-" || script == "/dev/stdin" {
            return true
        }
        return false
    }

    private static func containsInlineFlag(_ arguments: [String], allowedShortOptions: Set<Character>) -> Bool {
        for arg in arguments {
            if arg == "--" {
                break
            }
            guard arg.hasPrefix("-"), !arg.hasPrefix("--") else { continue }
            let letters = arg.dropFirst()
            if letters.contains(where: { allowedShortOptions.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func hasScriptPathArgument(_ arguments: [String]) -> Bool {
        guard let first = firstPositionalArgument(arguments) else { return false }
        return first != "-" && first != "/dev/stdin"
    }

    private static func firstPositionalArgument(_ arguments: [String]) -> String? {
        var index = 0
        var stopOptions = false
        while index < arguments.count {
            let arg = arguments[index]
            if stopOptions {
                return arg
            }
            if arg == "--" {
                stopOptions = true
                index += 1
                continue
            }
            if arg.hasPrefix("-"), arg != "-" {
                index += 1
                continue
            }
            return arg
        }
        return nil
    }

    private static func containsShortOptionCluster(_ arguments: [String], containing character: Character) -> Bool {
        for arg in arguments {
            if arg == "--" {
                break
            }
            guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 1 else { continue }
            if arg.dropFirst().contains(character) {
                return true
            }
        }
        return false
    }

    private static func argumentsContainFetcherSubstitution(_ args: [String]) -> Bool {
        for arg in args where arg.contains("$(") || arg.contains("<(") || arg.contains("`") {
            for nested in ShellLexer.nestedCommands(in: arg) {
                if nestedCommandStartsWithFetcher(nested) {
                    return true
                }
            }
        }
        for (index, arg) in args.enumerated() where arg == "<" || arg == "$" {
            guard index + 1 < args.count else { continue }
            let nested = args[(index + 1)...].joined(separator: " ")
            if nestedCommandStartsWithFetcher(nested) {
                return true
            }
        }
        let joined = args.joined(separator: " ")
        for nested in ShellLexer.nestedCommands(in: joined) {
            if nestedCommandStartsWithFetcher(nested) {
                return true
            }
        }
        return false
    }

    private static func nestedCommandStartsWithFetcher(_ command: String) -> Bool {
        for words in allSimpleCommands(command) {
            let normalized = stripWrappers(normalizedTokens(words: words))
            guard let executable = normalized.first else { continue }
            if fetchers.contains(executable) {
                return true
            }
        }
        return false
    }

    private static func looksLikeInterpreter(_ executable: String) -> Bool {
        if executable == "source" || executable == "." || executable == "eval" {
            return true
        }
        if executable.hasSuffix("sh") {
            return true
        }
        if executable.contains("python") || executable.contains("perl") || executable.contains("ruby") || executable.contains("node") {
            return true
        }
        return false
    }

    private static func isBulkOperation(words: [String]) -> Bool {
        let normalizedAll = normalizedTokens(words: words)
        let includesXargs = normalizedAll.contains("xargs")
        var normalized = stripWrappers(normalizedTokens(words: words))
        guard !words.isEmpty else { return false }
        guard !normalized.isEmpty else { return false }

        if normalized.first == "xargs" {
            normalized = stripWrappers(normalized)
            guard !normalized.isEmpty else { return false }
        }

        guard let executable = normalized.first else { return false }
        let args = Array(normalized.dropFirst())
        let hasSubstitution = args.contains(where: containsCommandSubstitution) || args.contains("$") || args.contains("<")

        switch executable {
        case "brew":
            guard let verb = args.first, verb == "upgrade" else { return false }
            let tail = Array(args.dropFirst())
            let positional = positionalArguments(tail)
            return positional.isEmpty || hasSubstitution
        case "npm":
            return isBulkNpm(args)
        case "pnpm":
            return isBulkPnpm(args)
        case "yarn":
            return args.count >= 2 &&
                args[0] == "global" &&
                args[1] == "upgrade" &&
                positionalArguments(Array(args.dropFirst(2))).isEmpty
        case "gem":
            if args.first == "update" {
                let tail = Array(args.dropFirst())
                return positionalArguments(tail).isEmpty && !tail.contains("--system")
            }
            return false
        case "mise":
            if let verb = args.first, (verb == "upgrade" || verb == "up") {
                return positionalArguments(Array(args.dropFirst())).isEmpty
            }
            return false
        case "mas":
            return args.first == "upgrade"
        case "pipx":
            return args.first == "upgrade-all"
        case "uv":
            return args.count >= 3 && args[0] == "tool" && args[1] == "upgrade" && args.contains("--all")
        case "cargo":
            return args.count >= 2 && args[0] == "install-update" && args.contains("-a")
        case "softwareupdate":
            return args.contains("-ia") || ((args.contains("-i") || args.contains("--install")) && (args.contains("-a") || args.contains("--all")))
        case "npx":
            return args.count >= 2 && args[0] == "skills" && args[1] == "update"
        case "pip", "pip3":
            if includesXargs && args.first == "install" && (args.contains("-u") || args.contains("--upgrade")) {
                return true
            }
            return args.first == "install" && (args.contains("-u") || args.contains("--upgrade")) && hasSubstitution
        case "python", "python3", "python2":
            if includesXargs &&
                args.count >= 3 &&
                args[0] == "-m" &&
                args[1] == "pip" &&
                args[2] == "install" &&
                (args.contains("-u") || args.contains("--upgrade")) {
                return true
            }
            return args.count >= 3 &&
                args[0] == "-m" &&
                args[1] == "pip" &&
                args[2] == "install" &&
                (args.contains("-u") || args.contains("--upgrade")) &&
                hasSubstitution
        default:
            return false
        }
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

    private static func nestedCommands(in command: String, words: [String]) -> [String] {
        var nested = ShellLexer.nestedCommands(in: command)
        nested.append(contentsOf: inlineShellCommands(in: words))
        return nested
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

    private static func inlineShellCommands(in words: [String]) -> [String] {
        let stripped = stripWrappersRaw(words)
        guard let executable = stripped.first.map(normalizedExecutableName), shellExecutables.contains(executable) else {
            return []
        }

        var nested: [String] = []
        for (index, token) in stripped.enumerated() {
            let lowered = token.lowercased()
            guard lowered.hasPrefix("-"), !lowered.hasPrefix("--"), lowered.dropFirst().contains("c") else { continue }
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
        if lower.contains("/") {
            return (lower as NSString).lastPathComponent
        }
        return lower
    }

    private static func stripWrappers(_ tokens: [String]) -> [String] {
        var working = tokens

        func removeLeadingOptions(optionValueFlags: Set<String> = [], allowAssignments: Bool = false) {
            while let first = working.first {
                if first == "--" {
                    working.removeFirst()
                    break
                }
                if optionValueFlags.contains(first), working.count > 1 {
                    working.removeFirst(2)
                    continue
                }
                if allowAssignments && first.contains("="), !first.hasPrefix("="), !first.hasSuffix("=") {
                    working.removeFirst()
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
                if first == "env" {
                    removeLeadingOptions(optionValueFlags: ["-u"], allowAssignments: true)
                }
                continue
            }
            if first == "sudo" || first == "doas" {
                working.removeFirst()
                removeLeadingOptions(optionValueFlags: ["-u", "-g", "-h", "-p", "-r", "-t", "-C", "-T"])
                continue
            }
            if first == "timeout" {
                working.removeFirst()
                removeLeadingOptions(optionValueFlags: ["--signal", "-s", "-k"])
                if let duration = working.first, !duration.hasPrefix("-") {
                    working.removeFirst()
                }
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
                if lowered == "env" {
                    while let next = working.first {
                        if next == "--" {
                            working.removeFirst()
                            break
                        }
                        if next == "-u", working.count > 1 {
                            working.removeFirst(2)
                            continue
                        }
                        if next.hasPrefix("-") {
                            working.removeFirst()
                            continue
                        }
                        if next.contains("="), !next.hasPrefix("="), !next.hasSuffix("=") {
                            working.removeFirst()
                            continue
                        }
                        break
                    }
                }
                continue
            }
            if lowered == "sudo" || lowered == "doas" {
                working.removeFirst()
                while let next = working.first, next.hasPrefix("-") {
                    let consumesValue = ["-u", "-g", "-h", "-p", "-r", "-t", "-C", "-T"].contains(next)
                    working.removeFirst()
                    if consumesValue, !working.isEmpty {
                        working.removeFirst()
                    }
                }
                continue
            }
            if lowered == "timeout" {
                working.removeFirst()
                while let next = working.first, next.hasPrefix("-") {
                    let consumesValue = next == "--signal" || next == "-s" || next == "-k"
                    working.removeFirst()
                    if consumesValue, !working.isEmpty {
                        working.removeFirst()
                    }
                }
                if let duration = working.first, !duration.hasPrefix("-") {
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

    private static func startsWithDynamicExecutable(_ words: [String]) -> Bool {
        let stripped = stripWrappers(normalizedTokens(words: words))
        guard let executable = stripped.first else { return false }
        return executable.hasPrefix("$")
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
