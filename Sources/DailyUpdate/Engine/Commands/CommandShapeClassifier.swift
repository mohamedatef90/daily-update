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
    /// interpret: an unquoted `{` or `}` at or before the executable, an
    /// unknown wrapper option, a loop or `case` header outside the modelled
    /// grammar, or a stray `)`.
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
            let normalized = stripWrappers(words: words)
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

        let inline = simpleCommands.flatMap { inlineShellCommands(in: $0) }
        // An empty body (`f()`, `$()`) runs nothing; only the top level must be non-empty.
        let nestedBodies = ShellLexer.nestedCommands(in: trimmed).filter { !$0.allSatisfy(\.isWhitespace) }
        for nested in nestedBodies + inline {
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
                if armTokens.prefix(executableIndex + 1).contains(where: \.hasUnquotedBrace) || unwrap(words).failsClosed
                    || findExecBodyHasUnquotedBrace(Array(armTokens.dropFirst(executableIndex)))
                    || shellScriptFollowsOption(words) {
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
                hasUnquotedBrace: tokens[arm].hasUnquotedBrace), at: 0)
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
        let normalized = stripWrappers(words: words)
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
            if let executable = stripWrappers(words: words).first,
               fetchers.contains(executable) { return true }
            // `find -exec curl …`, `eval curl …` and `sh -c 'curl …'` fetch too.
            if inlineShellCommands(in: words).contains(where: nestedCommandStartsWithFetcher) { return true }
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
        // `-m` runs any module on stdin (`code`, `pdb`), so only json.tool is data.
        if ["python", "python2", "python3"].contains(executable), args == ["-m", "json.tool"] { return false }
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
        let python = InlineProgramFlags(program: ["c"], noArgument: Set("BEIOPqsSub"), value: ["W", "X"])
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
            let normalized = stripWrappers(words: words)
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
        let normalized = stripWrappers(words: words)
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
        guard let executable = normalized.first else { return false }
        let args = Array(normalized.dropFirst())

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
        // `trap` runs its first argument as code; `find -exec` runs the words up to `;` or `+`.
        if executable == "trap" { return stripped.dropFirst().first { $0 != "--" }.map { [$0] } ?? [] }
        if executable == "find" { return findExecCommands(Array(stripped.dropFirst())) }
        guard shellExecutables.contains(executable) else {
            return []
        }

        if case .script(let script) = shellScript(stripped) { return [script] }
        return []
    }

    /// Fails closed when a word before the shell's script is not a modelled `-` cluster,
    /// or when the word after the script flag is an option (`sh -c -- 'x'`, `sh -c +x 'x'`).
    private static func shellScriptFollowsOption(_ words: [String]) -> Bool {
        let stripped = stripWrappersRaw(words)
        guard let executable = stripped.first.map(normalizedExecutableName),
              shellExecutables.contains(executable) else { return false }
        if case .unparseable = shellScript(stripped) { return true }
        return false
    }

    private enum ShellScript {
        case none
        case script(String)
        case unparseable
    }

    /// Clusters that take no value, so the script is the word right after the cluster.
    private static let shellScriptFlagLetters = Set("cefilnuvx")
    /// fish reads `-f` as `--features`, which takes a value.
    private static let fishScriptFlagLetters = Set("ceilnuvx")

    /// zsh can expand a word with these into a different option: `-$x`, `$(echo -c)`, `{-c,-e}`.
    private static let shellOptionExpansionCharacters = Set("$`{*?[")

    /// The script `sh`/`bash`/`zsh`/`fish` would run. One walk over the words after the
    /// shell: a word that could expand, or an option that is not a `-` cluster of
    /// `c e f i l n u v x` (`--wordexp`, `--command`, `+c`, `-o name`, `-C`), fails closed.
    /// A cluster with `c` takes the next word as the script; the first operand is a file.
    private static func shellScript(_ stripped: [String]) -> ShellScript {
        guard let executable = stripped.first.map(normalizedExecutableName) else { return .none }
        let isFish = executable == "fish"
        let letters = isFish ? fishScriptFlagLetters : shellScriptFlagLetters
        let isOption = { (word: String) in word.hasPrefix("-") || word.hasPrefix("+") }
        var index = 1
        while index < stripped.count {
            let word = stripped[index]
            if word.contains(where: shellOptionExpansionCharacters.contains) { return .unparseable }
            guard isOption(word) else { return .none }
            guard word.count > 1, word.hasPrefix("-"), word.dropFirst().allSatisfy(letters.contains) else {
                return .unparseable
            }
            if word.contains("c") {
                guard index + 1 < stripped.count else { return .none }
                let script = stripped[index + 1]
                if isOption(script) { return .unparseable }
                // fish keeps reading options after the script: `fish -c 'x' -C 'y'`.
                if isFish, stripped.dropFirst(index + 2).contains(where: isOption) { return .unparseable }
                return .script(script)
            }
            index += 1
        }
        return .none
    }

    /// `find -exec` re-quotes its body word by word, so a brace list inside it is not modelled.
    private static func findExecBodyHasUnquotedBrace(_ tokens: [ShellToken]) -> Bool {
        guard let first = tokens.first, normalizedExecutableName(first.value) == "find" else { return false }
        var inBody = false
        var previous = ""
        for token in tokens.dropFirst() {
            defer { previous = token.value }
            if inBody, token.value == ";" || (token.value == "+" && previous == "{}") { inBody = false; continue }
            if inBody, token.hasUnquotedBrace { return true }
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(token.value) { inBody = true }
        }
        return false
    }

    private static func findExecCommands(_ args: [String]) -> [String] {
        var commands: [String] = []
        var index = 0
        while index < args.count {
            defer { index += 1 }
            guard ["-exec", "-execdir", "-ok", "-okdir"].contains(args[index]) else { continue }
            // `+` ends the body only right after `{}`; elsewhere it is an argument.
            var end = index + 1
            while end < args.count, args[end] != ";", !(args[end] == "+" && args[end - 1] == "{}") { end += 1 }
            commands.append(args[(index + 1)..<end].map(ShellEscaping.quote).joined(separator: " "))
            index = end
        }
        return commands
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

    /// getopt-style options for one wrapper. Short letters may be clustered
    /// (`-iv`) and a value letter takes the rest of its word or the next word.
    /// Any option not listed fails closed.
    private struct WrapperOptions {
        var flags: Set<Character> = []
        var values: Set<Character> = []
        var longFlags: Set<String> = []
        var longValues: Set<String> = []
        /// Whole-word options, for wrappers that do not cluster (`arch`).
        var words: Set<String> = []
        var valueWords: Set<String> = []
        /// Options that turn a string into a new command line (`env -S`).
        var refused: Set<String> = []
        var numeric = false
        var assignments = false
        var operands = 0
    }

    private static let wrapperOptions: [String: WrapperOptions] = [
        "env": WrapperOptions(flags: Set("0iv"), values: Set("uPLU"), words: ["-"],
            refused: ["-S", "--split-string"], assignments: true),
        "sudo": WrapperOptions(flags: Set("ABbEeHiKklNnPSsVv"), values: Set("CDghpRrTtUu"),
            longFlags: ["--askpass", "--background", "--bell", "--edit", "--login", "--non-interactive",
                "--preserve-env", "--preserve-groups", "--remove-timestamp", "--reset-timestamp", "--set-home",
                "--shell", "--stdin"],
            longValues: ["--chdir", "--chroot", "--close-from", "--command-timeout", "--group", "--host",
                "--other-user", "--prompt", "--role", "--type", "--user"]),
        "doas": WrapperOptions(flags: Set("Lns"), values: Set("Cu")),
        "nice": WrapperOptions(values: ["n"], longValues: ["--adjustment"], numeric: true),
        "timeout": WrapperOptions(flags: Set("fpv"), values: Set("ks"),
            longFlags: ["--foreground", "--preserve-status", "--verbose"], longValues: ["--kill-after", "--signal"],
            operands: 1),
        "exec": WrapperOptions(flags: Set("cl"), values: ["a"]),
        "command": WrapperOptions(flags: Set("pvV")),
        "time": WrapperOptions(flags: Set("alp"), values: ["o"]),
        "nohup": WrapperOptions(),
        "caffeinate": WrapperOptions(flags: Set("disum"), values: Set("tw")),
        "arch": WrapperOptions(words: ["-32", "-64", "-arm64", "-arm64e", "-x86_64", "-i386", "-c", "arm64", "x86_64"],
            valueWords: ["-arch", "-d", "-e"]),
        "xargs": WrapperOptions(flags: Set("0oprtx"), values: Set("EIJLnPRSs")),
    ]

    /// Removes leading wrappers (`sudo -u root`, `env A=1`, `if`, `then` …)
    /// and returns the words from the executable on. `failsClosed` is set
    /// when a wrapper option is unknown or re-parses a string as a command.
    private static func unwrap(_ tokens: [String], preservePrivilege: Bool = false) -> (words: [String], failsClosed: Bool) {
        var working = ArraySlice(tokens)
        while let first = working.first {
            let lowered = normalizedExecutableName(first)
            if lowered == "repeat" {
                working = working.dropFirst(2); continue
            }
            if ["if", "while", "until", "coproc", "then", "do", "else", "elif", "!", "noglob", "nocorrect", "builtin", "-"].contains(lowered) {
                working = working.dropFirst(); continue
            }
            if let options = wrapperOptions[lowered] {
                if preservePrivilege, lowered == "sudo" || lowered == "doas" { return (Array(working), false) }
                working = working.dropFirst()
                guard skipOptions(&working, options) else { return (Array(working), true) }
                continue
            }
            if isAssignment(first) {
                working = working.dropFirst(); continue
            }
            break
        }
        return (Array(working), false)
    }

    private static func skipOptions(_ working: inout ArraySlice<String>, _ options: WrapperOptions) -> Bool {
        while let arg = working.first {
            if options.refused.contains(where: { arg.hasPrefix($0) }) { return false }
            if arg == "--" { working = working.dropFirst(); break }
            if options.words.contains(arg) { working = working.dropFirst(); continue }
            if options.valueWords.contains(arg) { working = working.dropFirst(2); continue }
            if options.assignments, !arg.hasPrefix("-"), isAssignment(arg) { working = working.dropFirst(); continue }
            guard arg.hasPrefix("-"), arg != "-" else { break }
            if arg.hasPrefix("--") {
                let name = String(arg.prefix { $0 != "=" })
                if options.longFlags.contains(name) {
                    working = working.dropFirst(); continue
                }
                guard options.longValues.contains(name) else { return false }
                working = working.dropFirst(name == arg ? 2 : 1); continue
            }
            let letters = Array(arg.dropFirst())
            if options.numeric, letters.allSatisfy(\.isNumber) { working = working.dropFirst(); continue }
            var consumed = 1
            for (offset, letter) in letters.enumerated() {
                if options.flags.contains(letter) { continue }
                guard options.values.contains(letter) else { return false }
                if offset == letters.count - 1 { consumed = 2 }
                break
            }
            working = working.dropFirst(consumed)
        }
        for _ in 0..<options.operands {
            guard let operand = working.first, !operand.hasPrefix("-") else { break }
            working = working.dropFirst()
        }
        return true
    }

    /// `NAME=value` or `NAME+=value`, `NAME` a shell identifier; `NAME=` is empty, not a command.
    /// Non-ASCII counts as a name character, because zsh takes `é=1` as a name in a UTF-8 locale.
    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "=") else { return false }
        var name = word[..<equals]
        if name.hasSuffix("+") { name = name.dropLast() }
        guard let first = name.first, !(first.isASCII && first.isNumber) else { return false }
        return name.allSatisfy { $0 == "_" || !$0.isASCII || $0.isLetter || $0.isNumber }
    }

    private static func stripWrappersRaw(_ tokens: [String], preservePrivilege: Bool = false) -> [String] {
        unwrap(tokens, preservePrivilege: preservePrivilege).words
    }

    /// The executable and its arguments, normalized (lowercased basenames).
    private static func stripWrappers(words: [String]) -> [String] {
        normalizedTokens(words: stripWrappersRaw(words))
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
