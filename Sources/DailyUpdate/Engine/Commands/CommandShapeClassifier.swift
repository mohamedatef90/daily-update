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
    private static let fetchers: Set<String> = ["curl", "wget", "fetch", "http", "lwp-request", "lwp-download", "get", "nscurl", "aria2c", "https", "xh"]
    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish",
        "python", "python3", "python2", "perl", "ruby", "node"
    ]
    private static let shellExecutables: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    private static let privilegeCommands: Set<String> = ["sudo", "doas", "pkexec", "su"]
    private static let controlFlowKeywords: Set<String> = [
        "if", "then", "fi", "for", "while", "case", "do", "done", "function", "else", "elif", "until", "coproc", "repeat",
        "foreach", "select", "end", "esac"
    ]
    private static let groupOperators: Set<ShellOperator> = [.leftParen, .rightParen, .leftBrace, .rightBrace]
    private static let commandSeparators: Set<ShellOperator> = [.and, .or, .semicolon, .newline, .background, .pipe, .pipeAnd]

    /// One simple command. `failsClosed` marks shapes this model does not
    /// interpret: brace expansion at or before the executable, a loop or
    /// `case` header outside the modelled grammar, or a stray `)`.
    private struct SimpleCommand {
        var words: [String]
        var failsClosed: Bool
    }

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

        let parsedCommands = simpleCommands(trimmed)
        let simpleCommands = parsedCommands.map(\.words)
        if parsedCommands.contains(where: \.failsClosed) {
            risks.insert(.unparseable)
        }
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

        for nested in ShellLexer.nestedCommands(in: trimmed) + simpleCommands.flatMap({ inlineShellCommands(in: $0) }) {
            risks.formUnion(classify(nested, depth: depth + 1, visited: nextVisited))
        }

        return risks
    }

    private static func allSimpleCommands(_ command: String) -> [[String]] {
        simpleCommands(command).map(\.words)
    }

    private static func simpleCommands(_ command: String) -> [SimpleCommand] {
        var segments: [SimpleCommand] = []
        var queue = [command]
        var visited = Set<String>()

        while let next = queue.popLast() {
            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, visited.insert(trimmed).inserted else { continue }

            // Group delimiters end a simple command, like any separator: in
            // `for x (1) sudo …` and `case a in (a) sudo …` the words after
            // `)` are a new command, not arguments of the header.
            for (stage, terminator) in splitSimpleCommands(ShellLexer.lex(trimmed)) {
                let wordTokens = stage.filter(\.isWord)
                let raw = wordTokens.map(\.value)
                var failsClosed = headerFailsClosed(raw, terminator: terminator)
                let armTokens = commandTokens(wordTokens)
                if let arm = wordTokens.firstIndex(where: \.hasUnquotedCaseTerminator), arm != 0,
                   !(arm == 3 && isCaseHeader(raw)) {
                    failsClosed = true
                }
                var words = armTokens.map(\.value)
                let executableIndex = words.count - stripWrappersRaw(words).count
                if armTokens.prefix(executableIndex + 1).contains(where: \.hasUnquotedBraceExpansion) {
                    failsClosed = true
                }
                if executableIndex < words.count, words[executableIndex] != "[",
                   armTokens[executableIndex].hasUnquotedGlob {
                    words[executableIndex] = "$glob"
                }
                guard !words.isEmpty || failsClosed else { continue }
                segments.append(SimpleCommand(words: words, failsClosed: failsClosed))
                queue.append(contentsOf: inlineShellCommands(in: words))
            }
            queue.append(contentsOf: ShellLexer.nestedCommands(in: trimmed))
        }
        return segments
    }

    private static func splitSimpleCommands(_ tokens: [ShellToken]) -> [([ShellToken], ShellOperator?)] {
        var stages: [([ShellToken], ShellOperator?)] = []
        var current: [ShellToken] = []
        for token in tokens {
            if case .op(let op) = token.kind {
                if !current.isEmpty { stages.append((current, op)) }
                current = []
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { stages.append((current, nil)) }
        return stages
    }

    /// After wrapper stripping, `for`/`foreach`/`select` must be exactly
    /// `NAME [in WORDS…]` and `case` exactly `case WORD in`. zsh short loops
    /// (`for x (1) cmd`, `for ((…)) cmd`) and anything else fail closed.
    private static func headerFailsClosed(_ words: [String], terminator: ShellOperator?) -> Bool {
        let stripped = stripWrappersRaw(words)
        guard let keyword = stripped.first.map(normalizedExecutableName) else { return false }
        switch keyword {
        case "for", "foreach", "select":
            if let terminator, groupOperators.contains(terminator) { return true }
            guard stripped.count >= 2, matches(#"^[A-Za-z_][A-Za-z0-9_]*$"#, in: stripped[1]) else { return true }
            return stripped.count > 2 && stripped[2] != "in"
        case "case":
            guard isCaseHeader(stripped) else { return true }
            // Words after `in` must open an arm: `pat)`, `pat)cmd`, or the
            // first alternative of `pat|pat)`.
            guard stripped.count > 3, !stripped[3].contains(")") else { return false }
            return !(stripped.count == 4 && terminator == .pipe)
        default:
            return false
        }
    }

    private static func isCaseHeader(_ words: [String]) -> Bool {
        let stripped = stripWrappersRaw(words)
        return stripped.count >= 3 && normalizedExecutableName(stripped[0]) == "case" && stripped[2] == "in"
    }

    private static func commandTokens(_ tokens: [ShellToken]) -> [ShellToken] {
        // A case arm's unquoted closing parenthesis introduces a new command.
        // Text attached after it (`a)curl`) is that command's first word.
        // Quoted parentheses remain ordinary arguments.
        guard let arm = tokens.firstIndex(where: { $0.hasUnquotedCaseTerminator }),
              let end = tokens[arm].caseTerminatorEnd else { return tokens }
        var rest = Array(tokens.dropFirst(arm + 1))
        let attached = String(tokens[arm].value.dropFirst(end))
        if !attached.isEmpty {
            rest.insert(ShellToken(value: attached, kind: .word, hasUnquotedGlob: tokens[arm].hasUnquotedGlob,
                hasUnquotedBraceExpansion: tokens[arm].hasUnquotedBraceExpansion), at: 0)
        }
        return rest
    }

    private static func commandWords(_ tokens: [ShellToken]) -> [String] {
        commandTokens(tokens.filter(\.isWord)).map(\.value)
    }

    private static func containsControlFlow(_ tokens: [ShellToken]) -> Bool {
        let lowered = ShellLexer.words(from: tokens).map { $0.lowercased() }
        if lowered.contains(where: { controlFlowKeywords.contains($0) }) {
            return true
        }
        return tokens.contains(where: { $0.kind == .op(.leftBrace) || $0.kind == .op(.rightBrace) })
    }

    private static func containsPrivilegeEscalation(words: [String]) -> Bool {
        guard let executable = stripWrappersRaw(words, preservePrivilege: true).first.map(normalizedExecutableName) else { return false }
        return privilegeCommands.contains(executable) || executable == "osascript"
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
            guard arg.hasPrefix("-"), !arg.hasPrefix("--") else { continue }
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

            if argumentsContainFetcherSubstitution(args) {
                // awk and sed treat an operand as a program, so a fetched
                // argument is code for them, not data.
                let dataCommands: Set<String> = ["grep", "head", "tail", "jq", "cut", "tr", "sort", "uniq", "wc", "shasum", "echo", "printf", "test", "["]
                if !dataCommands.contains(executable) { return true }
            }
        }

        for logicalSegment in ShellLexer.split(tokens, by: [.and, .or, .semicolon, .newline, .background]) {
            let stages = ShellLexer.split(logicalSegment, by: [.pipe, .pipeAnd])
            var downloadFed = false
            for stage in stages {
                let words = commandWords(stage)
                if downloadFed {
                    let grouped = stage.contains { $0.kind == .op(.leftBrace) || $0.kind == .op(.leftParen) }
                    if grouped || executesPipelineInput(words) { return true }
                }
                if stageContainsFetcher(stage) {
                    downloadFed = true
                    for word in words where word.hasPrefix(">(") {
                        for nested in ShellLexer.nestedCommands(in: word) {
                            if allSimpleCommands(nested).contains(where: executesPipelineInput) { return true }
                        }
                    }
                }
            }
        }
        return false
    }

    private static func stageContainsFetcher(_ tokens: [ShellToken]) -> Bool {
        // Groups remain intact until the surrounding pipeline has been split.
        for (command, _) in splitSimpleCommands(tokens) {
            let words = commandWords(command)
            if let executable = stripWrappers(normalizedTokens(words: words)).first,
               fetchers.contains(executable) { return true }
            for word in words {
                for nested in ShellLexer.nestedCommands(in: word) {
                    if nestedCommandStartsWithFetcher(nested) { return true }
                }
            }
        }
        return false
    }

    private static func executesPipelineInput(_ words: [String]) -> Bool {
        let stripped = stripWrappersRaw(words)
        guard let executable = stripped.first.map(normalizedExecutableName) else { return true }
        let args = Array(stripped.dropFirst())
        let filters: Set<String> = ["grep", "sed", "awk", "head", "tail", "jq", "cut", "tr", "sort", "uniq", "wc", "shasum"]
        if filters.contains(executable) { return false }
        guard let flags = inlineProgramFlags[executable] else { return true }
        return !containsInlineProgram(args, flags: flags)
    }

    private struct InlineProgramFlags {
        /// Letters that introduce an inline program argument.
        let program: Set<Character>
        /// Letters known to take no argument. Anything unlisted fails closed.
        let noArgument: Set<Character>
        /// Letters that take a value, attached or as the next argument.
        let value: Set<Character>
    }

    // `-i` is excluded everywhere: python and node read stdin interactively
    // after the inline program, and perl/ruby `-i` takes an attached suffix.
    private static let inlineProgramFlags: [String: InlineProgramFlags] = {
        let python = InlineProgramFlags(program: ["c", "m"], noArgument: Set("BEIOPqsSub"), value: ["W", "X"])
        return [
            "python": python, "python2": python, "python3": python,
            "perl": InlineProgramFlags(program: ["e"], noArgument: Set("anlpstTwWX"), value: ["I", "M", "m"]),
            "ruby": InlineProgramFlags(program: ["e"], noArgument: Set("anlpsvw"), value: ["I", "r", "C", "E"]),
            "node": InlineProgramFlags(program: ["e"], noArgument: [], value: ["r"]),
        ]
    }()

    /// True only for an allow-listed option prefix that ends in a cluster
    /// whose last letter is the program flag, followed by a program argument.
    /// A `-`, `--`, long option or script operand before that is not inline.
    private static func containsInlineProgram(_ arguments: [String], flags: InlineProgramFlags) -> Bool {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            guard arg != "-", !arg.hasPrefix("--"), arg.hasPrefix("-") else { return false }
            let letters = Array(arg.dropFirst())
            guard let first = letters.first else { return false }
            if flags.value.contains(first) {
                // `-W ignore` consumes the next argument; `-Wignore` is attached.
                index += letters.count == 1 ? 2 : 1
                continue
            }
            guard let last = letters.last, flags.program.contains(last),
                  letters.dropLast().allSatisfy(flags.noArgument.contains) else {
                guard letters.allSatisfy(flags.noArgument.contains) else { return false }
                index += 1
                continue
            }
            return index + 1 < arguments.count
        }
        return false
    }

    private static func argumentsContainFetcherSubstitution(_ args: [String]) -> Bool {
        for arg in args where arg.contains("$(") || arg.contains("<(") || arg.contains("=(") || arg.contains("`") {
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
        let hasSubstitution = stripWrappersRaw(words).dropFirst().contains(where: containsCommandSubstitution) || args.contains("$") || args.contains("<")

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
        guard let executable = stripped.first.map(normalizedExecutableName) else { return [] }
        if executable == "eval" { return [stripped.dropFirst().joined(separator: " ")] }
        guard shellExecutables.contains(executable) else {
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

        let lower = (trimmed.hasPrefix("=") ? String(trimmed.dropFirst()) : trimmed).lowercased()
        if matches(#"^[a-z_][a-z0-9_]*="#, in: lower) { return lower }
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
            if first == "repeat" {
                working.removeFirst(min(2, working.count)); continue
            }
            if ["if", "while", "until", "coproc", "then", "do", "else", "elif", "!", "noglob", "nocorrect", "builtin", "-"].contains(first) {
                working.removeFirst(); continue
            }
            if ["env", "command", "exec", "nohup", "time"].contains(first) {
                working.removeFirst()
                if first == "env" {
                    removeLeadingOptions(optionValueFlags: ["-u"], allowAssignments: true)
                } else if first == "exec" || first == "command" {
                    removeLeadingOptions(optionValueFlags: ["-a"])
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

    private static func stripWrappersRaw(_ tokens: [String], preservePrivilege: Bool = false) -> [String] {
        var working = tokens
        while let first = working.first {
            let lowered = normalizedExecutableName(first)
            if lowered == "repeat" {
                working.removeFirst(min(2, working.count)); continue
            }
            if ["if", "while", "until", "coproc", "then", "do", "else", "elif", "!", "noglob", "nocorrect", "builtin", "-"].contains(lowered) {
                working.removeFirst(); continue
            }
            if ["env", "command", "exec", "nohup", "time"].contains(lowered) {
                working.removeFirst()
                if ["env", "exec", "command"].contains(lowered) {
                    while let next = working.first {
                        if next == "--" {
                            working.removeFirst()
                            break
                        }
                        if (next == "-u" || next == "-a"), working.count > 1 {
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
                if preservePrivilege { return working }
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
        token.contains("$(") || token.contains("<(") || token.contains("=(") || token.contains("`")
    }

    private static func startsWithDynamicExecutable(_ words: [String]) -> Bool {
        let stripped = stripWrappersRaw(words)
        guard let executable = stripped.first else { return false }
        return executable.hasPrefix("$") || executable.hasPrefix("`")
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
