import Foundation

enum ResolvedOwner: Equatable, Hashable {
    case brewFormula(String)
    case brewCask(String)
    case npm(prefix: String, package: String)
    case nativeInstaller(NativeInstallerID)
    case pipx(package: String)
    case uvTool(name: String)
    // P2-1: the owners a discovery record can carry. None has a real update strategy yet — every
    // arm in StrategyPlanner.makeStrategy below is `.blocked` until the PR that owns that
    // ecosystem (P2-2 through P2-6b) replaces it.
    case pnpm(home: String, package: String)
    case yarnClassic(globalDir: String, package: String)
    case bun(root: String, package: String)
    case pipUser(site: String, distribution: String)
    case cargo(root: String, crate: String)
    case gem(gemDir: String, name: String, systemOwned: Bool)
    case appStore(adamID: String)
    case sparkleApp(feedURL: String)
    case selfUpdatingApp(kind: String)
    case versionManager(kind: VersionManagerKind, root: String)
    case agentSkill(lockFile: String, name: String)
    case agentPlugin(agent: String, marketplace: String, plugin: String)
    case system(provider: String)
    case unknown
}

enum NativeInstallerID: String, Equatable, Hashable {
    case claudeCode
    case opencode
    case cursorAgent
}

enum ResolveError: Error, Equatable {
    case invalidCommandName
    case lookupFailed(String)
    case unresolvedPath(String)
}

struct OwnerCandidate: Equatable {
    let commandPath: String
    let resolvedPath: String
    let owner: ResolvedOwner
}

struct OwnerResolution: Equatable {
    let commandName: String
    let active: OwnerCandidate?
    let competing: [OwnerCandidate]
    let resolveError: ResolveError?

    init(
        commandName: String,
        active: OwnerCandidate?,
        competing: [OwnerCandidate],
        resolveError: ResolveError? = nil
    ) {
        self.commandName = commandName
        self.active = active
        self.competing = competing
        self.resolveError = resolveError
    }

    var fingerprint: String? {
        guard let active else { return nil }
        return "\(active.commandPath)|\(active.resolvedPath)|\(describe(active.owner))"
    }

    private func describe(_ owner: ResolvedOwner) -> String {
        switch owner {
        case .brewFormula(let formula): return "brew:\(formula)"
        case .brewCask(let token): return "cask:\(token)"
        case .npm(let prefix, let package): return "npm:\(prefix):\(package)"
        case .nativeInstaller(let id): return "native:\(id.rawValue)"
        case .pipx(let package): return "pipx:\(package)"
        case .uvTool(let name): return "uv:\(name)"
        case .pnpm(let home, let package): return "pnpm:\(home):\(package)"
        case .yarnClassic(let globalDir, let package): return "yarn:\(globalDir):\(package)"
        case .bun(let root, let package): return "bun:\(root):\(package)"
        case .pipUser(let site, let distribution): return "pip:\(site):\(distribution)"
        case .cargo(let root, let crate): return "cargo:\(root):\(crate)"
        case .gem(let gemDir, let name, _): return "gem:\(gemDir):\(name)"
        case .appStore(let adamID): return "appStore:\(adamID)"
        case .sparkleApp(let feedURL): return "sparkle:\(feedURL)"
        case .selfUpdatingApp(let kind): return "selfUpdating:\(kind)"
        case .versionManager(let kind, let root): return "versionManager:\(kind.rawValue):\(root)"
        case .agentSkill(let lockFile, let name): return "skill:\(lockFile):\(name)"
        case .agentPlugin(let agent, let marketplace, let plugin): return "plugin:\(agent):\(marketplace):\(plugin)"
        case .system(let provider): return "system:\(provider)"
        case .unknown: return "unknown"
        }
    }
}

struct EcosystemLayout: Equatable, Sendable {
    let homeDirectory: String
    let brewPrefixes: [String]
    let brewCellars: [String]
    let brewCaskrooms: [String]
    let claudeNativeRoot: String
    let opencodeNativeRoot: String
    let cursorAgentNativeRoot: String
    let uvToolRoots: [String]
    let pipxVenvRoots: [String]
    let npmGlobalRoots: [String]
    let nvmVersionsRoot: String
    let voltaRoot: String
    let fnmRoots: [String]

    static func fixture(home: String) -> EcosystemLayout {
        let brewPrefixes = ["\(home)/opt/homebrew", "\(home)/usr/local"]
        return EcosystemLayout(
            homeDirectory: home,
            brewPrefixes: brewPrefixes,
            brewCellars: brewPrefixes.map { "\($0)/Cellar" },
            brewCaskrooms: brewPrefixes.map { "\($0)/Caskroom" },
            claudeNativeRoot: "\(home)/.local/share/claude/versions",
            opencodeNativeRoot: "\(home)/.opencode/bin",
            cursorAgentNativeRoot: "\(home)/.local/share/cursor-agent/versions",
            uvToolRoots: ["\(home)/.local/share/uv/tools"],
            pipxVenvRoots: ["\(home)/.local/pipx/venvs", "\(home)/.local/share/pipx/venvs"],
            npmGlobalRoots: ["\(home)/.npm-global", "\(home)/.local"],
            nvmVersionsRoot: "\(home)/.nvm/versions/node",
            voltaRoot: "\(home)/.volta",
            fnmRoots: ["\(home)/.fnm", "\(home)/.local/share/fnm"]
        )
    }

    static let defaultBrewPrefixes = ["/opt/homebrew", "/usr/local"]

    static func discover() async -> EcosystemLayout {
        if ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] != nil { return .live() }
        return live(brewPrefix: await BrewPrefixDiscovery.shared.prefix(probe: BrewPrefixDiscovery.runBrewPrefix))
    }

    /// A discovered or configured prefix is added to the defaults, so formulas under a second
    /// (Rosetta) brew keep their owner.
    static func live(home: String = NSHomeDirectory(), brewPrefix: String? = nil) -> EcosystemLayout {
        let configured = brewPrefix ?? ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"]
        var brewPrefixes: [String] = []
        for prefix in [configured].compactMap({ $0 }) + defaultBrewPrefixes where !brewPrefixes.contains(prefix) {
            brewPrefixes.append(prefix)
        }
        return EcosystemLayout(
            homeDirectory: home,
            brewPrefixes: brewPrefixes,
            brewCellars: brewPrefixes.map { "\($0)/Cellar" },
            brewCaskrooms: brewPrefixes.map { "\($0)/Caskroom" },
            claudeNativeRoot: "\(home)/.local/share/claude/versions",
            opencodeNativeRoot: "\(home)/.opencode/bin",
            cursorAgentNativeRoot: "\(home)/.local/share/cursor-agent/versions",
            uvToolRoots: ["\(home)/.local/share/uv/tools"],
            pipxVenvRoots: ["\(home)/.local/pipx/venvs", "\(home)/.local/share/pipx/venvs"],
            npmGlobalRoots: ["\(home)/.npm-global", "\(home)/.local"],
            nvmVersionsRoot: "\(home)/.nvm/versions/node",
            voltaRoot: "\(home)/.volta",
            fnmRoots: ["\(home)/.fnm", "\(home)/.local/share/fnm"]
        )
    }
}

/// Runs `brew --prefix` at most once per process; every lookup reuses the answer.
actor BrewPrefixDiscovery {
    static let shared = BrewPrefixDiscovery()

    private var cached: String??

    func prefix(probe: @Sendable () async -> String?) async -> String? {
        if let cached { return cached }
        let value = await probe()
        cached = .some(value)
        return value
    }

    static let runBrewPrefix: @Sendable () async -> String? = {
        let result = await ShellRunner.run("brew --prefix", timeout: 10)
        let prefix = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, prefix.hasPrefix("/"), !prefix.contains("\n") else { return nil }
        return prefix
    }
}

struct CommandPathLookup: Equatable, Sendable {
    let candidatesByName: [String: [String]]
    var failureMessage: String? = nil
    var layout: EcosystemLayout? = nil
    /// RC2: the login PATH this batch saw, in its three states. Discovery's D5 activity and R2/R3
    /// grouping key off this; Phase 1 callers that don't care can ignore it.
    var loginPath: LoginPath = .unknown("Not queried")
    /// F4: the `*_HOME`/`*_DIR` override snapshot (plus `HOMEBREW_PREFIX`, `HOMEBREW_CACHE`,
    /// `PYENV_VERSION` and the `UV_*INDEX*` variables), read from the same login shell — never
    /// from this process's own environment — so the GUI and the CLI see the same roots.
    var environmentSnapshot: [String: String] = [:]

    func candidates(for commandName: String) -> [String] {
        candidatesByName[commandName] ?? []
    }
}

/// F4: the fixed list the whence script also captures. Absolute-path variables are validated as
/// paths (dropped otherwise); `PYENV_VERSION` and the `UV_*INDEX*` variables are plain values, so
/// they're only checked for shape (no newline, within the size cap).
enum LoginEnvironmentOverrides {
    static let pathVariableNames = [
        "HOMEBREW_PREFIX", "HOMEBREW_CACHE", "NPM_CONFIG_PREFIX", "PNPM_HOME", "BUN_INSTALL",
        "PIPX_HOME", "UV_TOOL_DIR", "CARGO_INSTALL_ROOT", "CARGO_HOME", "GEM_HOME", "NVM_DIR",
        "FNM_DIR", "MISE_DATA_DIR", "ASDF_DATA_DIR", "PYENV_ROOT", "RUSTUP_HOME", "VOLTA_HOME",
        "XDG_DATA_HOME", "PYTHONUSERBASE",
    ]
    static let valueVariableNames = ["PYENV_VERSION", "UV_INDEX_URL", "UV_DEFAULT_INDEX", "UV_INDEX", "UV_EXTRA_INDEX_URL"]
    static let allVariableNames = pathVariableNames + valueVariableNames
    static let maxValueBytes = 1024

    static func isValid(name: String, value: String) -> Bool {
        guard !value.isEmpty, !value.contains("\n"), value.utf8.count <= maxValueBytes else { return false }
        guard pathVariableNames.contains(name) else { return true }
        return value.hasPrefix("/")
    }
}

enum OwnerResolver {
    /// S1 (regression fix): `whence` starts from `ProcessInfo`'s environment like Phase 1 did, but
    /// `PATH` is always `ShellRunner.defaultPath`, never the raw parent value. When the app is
    /// launched from Finder, launchd's own PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) has none of the
    /// native-installer or user-local directories `whence` needs to find `claude`, `opencode`,
    /// `cursor-agent`, or a `~/.local/bin` copy of `node`/`npm`. Exposed so a test can assert this
    /// without spawning a real shell.
    static var whenceEnvironment: ProcessEnvironment {
        .inherited(overridingPATH: ShellRunner.defaultPath)
    }

    private static let markerPrefix = "__DAILY_UPDATE_WHENCE__"
    private static let commandNameRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._+-]+$"#) // swiftlint:disable:this force_try
    private static let npmNameRegex = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^(?:@(?:[a-z0-9-~][a-z0-9-._~]*)/[a-z0-9-~][a-z0-9-._~]*|[a-z0-9-~][a-z0-9-._~]*)$"#
    )

    static func lookup(commandNames: [String], layout: EcosystemLayout = .live()) async -> CommandPathLookup {
        let uniqueNames = Array(Set(commandNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
        let validNames = uniqueNames.filter { isValidCommandName($0) }
        guard !validNames.isEmpty else {
            return CommandPathLookup(candidatesByName: [:], layout: layout)
        }

        let overrideNameList = LoginEnvironmentOverrides.allVariableNames.joined(separator: " ")
        let script = """
        for name in "$@"; do
          printf '%s%s\\n' "\(markerPrefix)BEGIN:" "$name"
          whence -ap -- "$name" 2>/dev/null || true
          printf '%s%s\\n' "\(markerPrefix)END:" "$name"
        done
        printf '%s\\n' "\(markerPrefix)PATH_BEGIN"
        printf '%s\\n' "$PATH"
        printf '%s\\n' "\(markerPrefix)PATH_END"
        printf '%s\\n' "\(markerPrefix)ENV_BEGIN"
        for name in \(overrideNameList); do
          eval "value=\\${$name}"
          printf '%s=%s\\n' "$name" "$value"
        done
        printf '%s\\n' "\(markerPrefix)ENV_END"
        """

        // RC2: only `whence` uses the inherited (login-profile) environment; every enricher under
        // Engine/Discovery/ builds its own from scratch instead.
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: "/bin/zsh",
            arguments: ["-lc", script, "--"] + validNames,
            environment: Self.whenceEnvironment,
            timeout: 20,
            maxStdoutBytes: 1024 * 1024
        ))

        guard case .exited(0) = outcome.evidence.termination else {
            let reason = failureReason(for: outcome.evidence.termination, stderr: outcome.evidence.stderr)
            return CommandPathLookup(
                candidatesByName: [:],
                failureMessage: "Command lookup failed: \(reason)",
                layout: layout,
                loginPath: .unknown(reason)
            )
        }

        let output = String(data: outcome.stdout, encoding: .utf8) ?? ""
        return CommandPathLookup(
            candidatesByName: parseWhenceOutput(output),
            layout: layout,
            loginPath: parseLoginPath(output),
            environmentSnapshot: parseEnvironmentSnapshot(output)
        )
    }

    private static func failureReason(for termination: Termination, stderr: String) -> String {
        switch termination {
        case .exited(let code): return "exit \(code): \(stderr)"
        case .signaled(let signal): return "killed by signal \(signal)"
        case .timedOut: return "timed out"
        case .outputCapExceeded: return "output too large"
        case .launchFailed(let reason): return reason
        }
    }

    private static func parseLoginPath(_ output: String) -> LoginPath {
        guard let block = markedBlock(in: output, prefix: "PATH_BEGIN", suffix: "PATH_END") else {
            return .unknown("missing PATH marker")
        }
        // CR#3: `block` is `"$PATH\n"` (the script's own trailing `printf '%s\n'`). Trimming
        // before splitting keeps that newline off the last PATH entry — split(separator: ":")
        // only breaks on colons, so an untrimmed block turned a clean ".../bin" into ".../bin\n",
        // and no ranking or lookup ever matched that root's bin directory again.
        let entries = block
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        return entries.isEmpty ? .empty : .known(entries)
    }

    private static func parseEnvironmentSnapshot(_ output: String) -> [String: String] {
        guard let block = markedBlock(in: output, prefix: "ENV_BEGIN", suffix: "ENV_END") else { return [:] }
        var snapshot: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            guard LoginEnvironmentOverrides.allVariableNames.contains(name),
                  LoginEnvironmentOverrides.isValid(name: name, value: value) else { continue }
            snapshot[name] = value
        }
        return snapshot
    }

    /// Both marker lines carry the shared `markerPrefix`, so the content between them is
    /// whatever the shell printed for that block, one line per printed value.
    private static func markedBlock(in output: String, prefix: String, suffix: String) -> String? {
        guard let beginRange = output.range(of: "\(markerPrefix)\(prefix)\n"),
              let endRange = output.range(of: "\(markerPrefix)\(suffix)", range: beginRange.upperBound..<output.endIndex) else {
            return nil
        }
        return String(output[beginRange.upperBound..<endRange.lowerBound])
    }

    static func resolve(
        commandName: String,
        lookup: CommandPathLookup? = nil,
        layout: EcosystemLayout = .live()
    ) async -> OwnerResolution {
        let trimmedName = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidCommandName(trimmedName) else {
            return OwnerResolution(commandName: trimmedName, active: nil, competing: [], resolveError: .invalidCommandName)
        }

        if let lookup {
            if let failure = lookup.failureMessage {
                return OwnerResolution(commandName: trimmedName, active: nil, competing: [], resolveError: .lookupFailed(failure))
            }
            let candidates = lookup.candidates(for: trimmedName)
            return resolve(commandName: trimmedName, candidatePaths: candidates, layout: layout)
        }

        let oneShotLookup = await Self.lookup(commandNames: [trimmedName])
        return await resolve(commandName: trimmedName, lookup: oneShotLookup, layout: layout)
    }

    static func resolve(
        commandName: String,
        candidatePaths: [String],
        layout: EcosystemLayout = .live()
    ) -> OwnerResolution {
        let trimmedName = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidCommandName(trimmedName) else {
            return OwnerResolution(commandName: trimmedName, active: nil, competing: [], resolveError: .invalidCommandName)
        }

        var seenResolved = Set<String>()
        var resolvedCandidates: [OwnerCandidate] = []
        var firstResolveError: ResolveError?

        for candidate in candidatePaths {
            guard let absoluteCommandPath = normalizedAbsolutePath(for: candidate) else { continue }
            switch resolveRealPath(absoluteCommandPath) {
            case .success(let resolvedPath):
                guard seenResolved.insert(resolvedPath).inserted else { continue }
                let owner = classify(resolvedPath: resolvedPath, layout: layout)
                resolvedCandidates.append(
                    OwnerCandidate(
                        commandPath: absoluteCommandPath,
                        resolvedPath: resolvedPath,
                        owner: owner
                    )
                )
            case .failure:
                if firstResolveError == nil {
                    firstResolveError = .unresolvedPath(absoluteCommandPath)
                }
            }
        }

        if resolvedCandidates.isEmpty, let firstResolveError {
            return OwnerResolution(commandName: trimmedName, active: nil, competing: [], resolveError: firstResolveError)
        }

        let active = resolvedCandidates.first
        let competing = Array(resolvedCandidates.dropFirst())
        return OwnerResolution(commandName: trimmedName, active: active, competing: competing, resolveError: nil)
    }

    private static func parseWhenceOutput(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var currentName: String?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("\(markerPrefix)BEGIN:") {
                let name = String(line.dropFirst("\(markerPrefix)BEGIN:".count))
                currentName = name
                result[name, default: []] = []
                continue
            }

            if line.hasPrefix("\(markerPrefix)END:") {
                currentName = nil
                continue
            }

            guard let currentName else { continue }
            result[currentName, default: []].append(line)
        }

        return result
    }

    private static func classify(resolvedPath: String, layout: EcosystemLayout) -> ResolvedOwner {
        if let npmOwner = npmOwner(for: resolvedPath, layout: layout) {
            return npmOwner
        }
        if let formula = capture(path: resolvedPath, roots: layout.brewCellars) {
            return .brewFormula(formula)
        }
        if let cask = capture(path: resolvedPath, roots: layout.brewCaskrooms) {
            return .brewCask(cask)
        }
        if isPath(resolvedPath, within: layout.claudeNativeRoot) {
            return .nativeInstaller(.claudeCode)
        }
        // `curl https://opencode.ai/install | bash` puts the binary in `~/.opencode/bin`.
        if isPath(resolvedPath, within: layout.opencodeNativeRoot) {
            return .nativeInstaller(.opencode)
        }
        // `curl https://cursor.com/install | bash` links `agent` and `cursor-agent` to `versions/<build>/`.
        if isPath(resolvedPath, within: layout.cursorAgentNativeRoot) {
            return .nativeInstaller(.cursorAgent)
        }
        if let name = capture(path: resolvedPath, roots: layout.uvToolRoots) {
            return .uvTool(name: name)
        }
        if let package = capture(path: resolvedPath, roots: layout.pipxVenvRoots) {
            return .pipx(package: package)
        }
        return .unknown
    }

    private static func npmOwner(for path: String, layout: EcosystemLayout) -> ResolvedOwner? {
        let marker = "/lib/node_modules/"
        guard let range = path.range(of: marker) else { return nil }

        let prefix = String(path[..<range.lowerBound])
        guard isAllowedNpmPrefix(prefix, layout: layout) else { return nil }

        let nodePath = "\(prefix)/bin/node"
        guard FileManager.default.fileExists(atPath: nodePath) else { return nil }

        let remainder = String(path[range.upperBound...])
        let components = remainder.split(separator: "/").map(String.init)
        let package: String

        guard let first = components.first else { return nil }
        if first.hasPrefix("@") {
            guard components.count >= 2 else { return nil }
            package = "\(first)/\(components[1])"
        } else {
            package = first
        }

        guard isValidNpmName(package), !package.hasPrefix("-") else { return nil }

        let packageJSON = "\(prefix)/lib/node_modules/\(package)/package.json"
        guard let data = FileManager.default.contents(atPath: packageJSON),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let declaredName = payload["name"] as? String,
              declaredName == package,
              isValidNpmName(declaredName),
              !declaredName.hasPrefix("-") else {
            return nil
        }

        return .npm(prefix: prefix, package: package)
    }

    private static func isAllowedNpmPrefix(_ prefix: String, layout: EcosystemLayout) -> Bool {
        if layout.brewPrefixes.contains(where: { isPath(prefix, within: $0) }) {
            return true
        }
        if isPath(prefix, within: layout.nvmVersionsRoot) {
            return true
        }
        if layout.npmGlobalRoots.contains(where: { isPath(prefix, within: $0) }) {
            return true
        }
        if isPath(prefix, within: layout.voltaRoot) {
            return true
        }
        if layout.fnmRoots.contains(where: { isPath(prefix, within: $0) }) {
            return true
        }
        return false
    }

    private static func capture(path: String, roots: [String]) -> String? {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        for root in roots {
            let normalizedRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path
            guard normalizedPath == normalizedRoot || normalizedPath.hasPrefix("\(normalizedRoot)/") else { continue }
            let relative = String(normalizedPath.dropFirst(normalizedRoot.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let firstComponent = relative.components(separatedBy: "/").first, !firstComponent.isEmpty else {
                continue
            }
            return firstComponent
        }
        return nil
    }

    private static func isPath(_ path: String, within root: String) -> Bool {
        let normalizedRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix("\(normalizedRoot)/")
    }

    private static func resolveRealPath(_ path: String) -> Result<String, ResolveError> {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else {
            return .failure(.unresolvedPath(path))
        }
        return .success(String(cString: buffer))
    }

    private static func normalizedAbsolutePath(for path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
    }

    private static func isValidCommandName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let range = NSRange(location: 0, length: name.utf16.count)
        return commandNameRegex.firstMatch(in: name, options: [], range: range) != nil
    }

    private static func isValidNpmName(_ name: String) -> Bool {
        let range = NSRange(location: 0, length: name.utf16.count)
        return npmNameRegex.firstMatch(in: name, options: [], range: range) != nil
    }
}
