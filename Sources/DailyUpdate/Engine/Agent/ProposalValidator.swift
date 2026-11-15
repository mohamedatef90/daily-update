import Foundation

/// The engine's verdict on an agent proposal. Nothing is executed to reach it.
enum ProposalVerdict: Equatable {
    /// Passed every check. It is still only a candidate: a user reviews it and the engine would run
    /// it through the normal dry-run and verification path. The spike never executes it.
    case acceptedCandidate
    case gated([String])
    case blocked([String])
    case invalid(String)

    var name: String {
        switch self {
        case .acceptedCandidate: return "acceptedCandidate"
        case .gated: return "gated"
        case .blocked: return "blocked"
        case .invalid: return "invalid"
        }
    }

    var reasons: [String] {
        switch self {
        case .acceptedCandidate: return []
        case .gated(let reasons), .blocked(let reasons): return reasons
        case .invalid(let reason): return [reason]
        }
    }
}

struct CommandAssessment: Equatable {
    var role: String
    var argv: [String]
    var spec: CommandSpec?
    var display: String
    var risks: [String]
}

struct ProposalEvaluation {
    var proposal: AgentProposal?
    var verdict: ProposalVerdict
    var version: CommandAssessment?
    var update: CommandAssessment?
    var ownerCheck: String
    var taint: [TaintCheck.Finding] = []
    /// Set only for `suggestRemoval`; built by the engine, never by the agent.
    var removalSuggestion: RemovalSuggestion?
}

/// Everything the validator needs from the machine, injectable so tests need no real tools.
struct ProposalEnvironment {
    /// A bare name or absolute path -> the absolute executable path, or nil if there is none.
    var resolveExecutable: (String) -> String?
    var isTrustedExecutable: (String) -> Bool
    /// The owner the engine itself resolves for a command name (nil: unknown or no name given).
    var resolveOwner: (String) async -> ResolvedOwner?
    var homeDirectory: String

    static func live() -> ProposalEnvironment {
        ProposalEnvironment(
            resolveExecutable: { name in
                if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
                var entries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
                entries += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                return PathSearch.candidates(for: name, pathEntries: entries, fileSystem: LiveFileSystem()).first
            },
            isTrustedExecutable: { PathTrust.isTrustedExecutable($0) },
            resolveOwner: { name in
                let resolution = await OwnerResolver.resolve(commandName: name)
                return resolution.active?.owner
            },
            homeDirectory: NSHomeDirectory())
    }
}

enum ProposalValidator {
    private static let privilegeExecutables: Set<String> = ["sudo", "doas", "pkexec", "su", "osascript", "launchctl"]
    private static let shellsAndInterpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "python", "python3", "python2",
        "perl", "ruby", "node", "osascript", "php", "lua",
    ]
    private static let inlineScriptFlags: Set<String> = ["-c", "-lc", "-ic", "-e", "-E", "--eval", "-p", "-pe", "-ep", "--print", "-r", "-S", "--command"]
    private static let fetchers: Set<String> = ["curl", "wget", "fetch", "nscurl", "aria2c", "http", "https", "xh", "lwp-request"]
    private static let destructiveExecutables: Set<String> = [
        "rm", "rmdir", "unlink", "mv", "cp", "dd", "diskutil", "chmod", "chown", "ln", "tee", "truncate",
        "shred", "srm", "kill", "killall", "pkill", "launchctl", "crontab",
    ]
    /// Executables an update command may start with. Anything else is gated for a human, not blocked.
    private static let knownUpdaters: Set<String> = [
        "brew", "npm", "pnpm", "yarn", "pipx", "uv", "pip", "pip3", "cargo", "gem", "bun", "rustup", "mas", "mise",
        "corepack",
    ]
    private static let mutatingVerbs: Set<String> = [
        "install", "uninstall", "remove", "rm", "update", "upgrade", "delete", "add", "link", "unlink",
        "self-update", "publish", "login", "logout", "cleanup", "prune", "reinstall", "run", "exec", "x", "dlx",
    ]
    private static let protectedPathFragments: [String] = [
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".profile", ".gitconfig",
        "/.ssh", "/.aws", "/.gnupg", "/.config/gh", "/.netrc", "/.npmrc", "/.codex", "/.claude", "/.hermes",
        "/etc/", "/private/etc", "/System/", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/usr/bin", "/usr/sbin",
        "/var/root", "/Library/Keychains",
    ]

    static func evaluate(
        raw: Data, context: AgentItemContext, evidence: EvidenceBundle = EvidenceBundle(items: [], notes: []),
        environment: ProposalEnvironment
    ) async -> ProposalEvaluation {
        let proposal: AgentProposal
        do {
            proposal = try ProposalParser.parse(raw)
        } catch {
            return ProposalEvaluation(proposal: nil, verdict: .invalid("\(error)"), version: nil, update: nil, ownerCheck: "not run")
        }
        return await evaluate(proposal: proposal, context: context, evidence: evidence, environment: environment)
    }

    static func evaluate(
        proposal: AgentProposal, context: AgentItemContext,
        evidence: EvidenceBundle = EvidenceBundle(items: [], notes: []), environment: ProposalEnvironment
    ) async -> ProposalEvaluation {
        var blocked: [String] = []
        var gated: [String] = []

        let version = assess(role: "version", argv: proposal.versionCommand, environment: environment, blocked: &blocked, gated: &gated)
        var update: CommandAssessment?
        if let argv = proposal.updateCommand {
            update = assess(role: "update", argv: argv, environment: environment, blocked: &blocked, gated: &gated)
        }

        // Owner check against what the engine itself resolves for the command.
        var ownerCheck = "skipped (no command name)"
        if let name = context.commandName, !name.isEmpty {
            if let owner = await environment.resolveOwner(name) {
                let engineKind = kind(of: owner)
                ownerCheck = "engine owner \(engineKind.rawValue), proposal owner \(proposal.ownerKind.rawValue)"
                if engineKind != .unknown, proposal.ownerKind != .unknown, proposal.ownerKind != .manual, engineKind != proposal.ownerKind {
                    gated.append("owner mismatch: the engine resolves \(engineKind.rawValue), the proposal says \(proposal.ownerKind.rawValue)")
                }
            } else {
                ownerCheck = "engine could not resolve an owner for \(name)"
            }
        }

        if let argv = proposal.updateCommand, let first = argv.first {
            let base = basename(first)
            if let expected = expectedUpdater(for: proposal.ownerKind), knownUpdaters.contains(base), !expected.contains(base) {
                gated.append("update command uses \(base) but the proposal owner is \(proposal.ownerKind.rawValue)")
            }
        }
        if proposal.latestSource == .none, proposal.verify == .versionMatchesLatest {
            gated.append("verify needs a latest version but latestSource is none")
        }
        if proposal.confidence < 0.4 {
            gated.append("low confidence (\(proposal.confidence))")
        }

        // Taint: a token, URL or domain that is only in the untrusted text is never accepted.
        let taint = TaintCheck.findings(proposal: proposal, context: context, evidence: evidence)
        for finding in taint {
            gated.append("taint: \(finding.kind) \(finding.token.prefix(80)) appears only in untrusted text")
        }

        // Recommendation paths.
        var removal: RemovalSuggestion?
        switch proposal.recommendation {
        case .update:
            if proposal.updateCommand == nil { gated.append("recommendation is update but no update command was proposed") }
        case .suggestRemoval:
            // No command from the agent. The engine builds the text, and it is always a person's decision.
            removal = RemovalSuggestion.make(for: context)
            gated.append("removal suggestion: destructive, needs a person")
        case .ignore, .investigate:
            break
        }

        let verdict: ProposalVerdict
        if !blocked.isEmpty {
            verdict = .blocked(unique(blocked))
        } else if !gated.isEmpty {
            verdict = .gated(unique(gated))
        } else {
            verdict = .acceptedCandidate
        }
        return ProposalEvaluation(
            proposal: proposal, verdict: verdict, version: version, update: update, ownerCheck: ownerCheck,
            taint: taint, removalSuggestion: removal)
    }

    // MARK: - One command

    private static func assess(
        role: String, argv: [String], environment: ProposalEnvironment,
        blocked: inout [String], gated: inout [String]
    ) -> CommandAssessment {
        let executableName = argv[0]
        let base = basename(executableName)
        let arguments = Array(argv.dropFirst())
        let expandedArguments = arguments.map { expandTilde($0, home: environment.homeDirectory) }
        var risks: [String] = []
        func block(_ reason: String) { risks.append(reason); blocked.append("\(role) command: \(reason)") }

        if privilegeExecutables.contains(base) { block("privileged executable \(base)") }
        if shellsAndInterpreters.contains(base), arguments.contains(where: { inlineScriptFlags.contains($0) }) {
            block("inline script through \(base)")
        } else if shellsAndInterpreters.contains(base) {
            gated.append("\(role) command runs an interpreter (\(base))")
            risks.append("interpreter \(base)")
        }
        if fetchers.contains(base) { block("network fetcher \(base)") }
        if destructiveExecutables.contains(base) { block("destructive or file-writing executable \(base)") }
        // `defaults` and `plutil` read app versions from Info.plist; only their read forms are allowed.
        if base == "defaults", arguments.first != "read" { block("defaults is allowed only as `defaults read`") }
        if base == "plutil", arguments.first != "-p", arguments.first != "-extract" {
            block("plutil is allowed only for printing (-p) or extracting (-extract) a value")
        }
        if role == "version", let verb = arguments.first(where: { mutatingVerbs.contains($0) }) {
            block("a version command may not use the verb \(verb)")
        }
        for argument in expandedArguments {
            if let fragment = protectedPathFragments.first(where: { argument.contains($0) }) {
                block("touches a protected path (\(fragment))")
                break
            }
        }

        // Resolve the executable and check trust.
        let expandedExecutable = expandTilde(executableName, home: environment.homeDirectory)
        var spec: CommandSpec?
        if executableName.contains("/") && !expandedExecutable.hasPrefix("/") {
            block("relative executable path")
        } else if let resolved = environment.resolveExecutable(expandedExecutable) {
            if environment.isTrustedExecutable(resolved) {
                spec = CommandSpec(executablePath: resolved, arguments: expandedArguments)
            } else {
                block("executable is not in a trusted location (\(basename(resolved)))")
            }
        } else {
            block("executable not found: \(base)")
        }

        // The existing classifier looks at the command exactly as the engine would display and run it.
        let display = spec?.displayString ?? ([executableName] + arguments).map(ShellEscaping.quote).joined(separator: " ")
        let classification = CommandShapeClassifier.classify(display)
        for risk in classification.risks.sorted(by: { $0.rawValue < $1.rawValue }) {
            risks.append("classifier: \(risk.rawValue)")
            switch risk {
            case .privileged, .destructive, .remoteScript:
                blocked.append("\(role) command: classifier flags \(risk.rawValue)")
            case .bulk, .fallbackChain, .chained, .suppressedErrors, .controlFlow, .unparseable:
                gated.append("\(role) command: classifier flags \(risk.rawValue)")
            }
        }

        if role == "update", !knownUpdaters.contains(base), !risks.contains(where: { $0.hasPrefix("privileged") }) {
            gated.append("update command does not start with a known package manager (\(base))")
        }
        return CommandAssessment(role: role, argv: argv, spec: spec, display: display, risks: risks)
    }

    // MARK: - Helpers

    static func kind(of owner: ResolvedOwner) -> ProposalOwnerKind {
        switch owner {
        case .brewFormula: return .brewFormula
        case .brewCask: return .brewCask
        case .npm: return .npm
        case .pnpm: return .pnpm
        case .yarnClassic: return .yarn
        case .pipx: return .pipx
        case .uvTool: return .uvTool
        case .pipUser: return .pip
        case .cargo: return .cargo
        case .gem: return .gem
        case .nativeInstaller, .selfUpdatingApp, .sparkleApp: return .nativeInstaller
        case .appStore: return .appBundle
        case .system: return .system
        case .bun, .versionManager, .agentSkill, .agentPlugin, .unknown: return .unknown
        }
    }

    private static func expectedUpdater(for owner: ProposalOwnerKind) -> Set<String>? {
        switch owner {
        case .brewFormula, .brewCask: return ["brew"]
        case .npm: return ["npm", "corepack"]
        case .pnpm: return ["pnpm"]
        case .yarn: return ["yarn"]
        case .pipx: return ["pipx"]
        case .uvTool: return ["uv"]
        case .pip: return ["pip", "pip3"]
        case .cargo: return ["cargo", "rustup"]
        case .gem: return ["gem"]
        case .nativeInstaller, .appBundle, .system, .manual, .unknown: return nil
        }
    }

    private static func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func expandTilde(_ value: String, home: String) -> String {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home + value.dropFirst(1) }
        return value
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
