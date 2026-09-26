import Foundation

enum ResolvedOwner: Equatable {
    case brewFormula(String)
    case brewCask(String)
    case npm(prefix: String, package: String)
    case nativeInstaller(NativeInstallerID)
    case pipx(package: String)
    case uvTool(name: String)
    case unknown
}

enum NativeInstallerID: String, Equatable {
    case claudeCode
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

    func candidates(for commandName: String) -> [String] {
        candidatesByName[commandName] ?? []
    }
}

enum OwnerResolver {
    private static let markerPrefix = "__DAILY_UPDATE_WHENCE__"
    private static let commandNameRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._+-]+$"#) // swiftlint:disable:this force_try
    private static let npmNameRegex = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^(?:@(?:[a-z0-9-~][a-z0-9-._~]*)/[a-z0-9-~][a-z0-9-._~]*|[a-z0-9-~][a-z0-9-._~]*)$"#
    )

    static func lookup(commandNames: [String]) async -> CommandPathLookup {
        let uniqueNames = Array(Set(commandNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
        let validNames = uniqueNames.filter { isValidCommandName($0) }
        guard !validNames.isEmpty else {
            return CommandPathLookup(candidatesByName: [:])
        }

        let script = """
        for name in "$@"; do
          printf '%s%s\\n' "\(markerPrefix)BEGIN:" "$name"
          whence -ap -- "$name" 2>/dev/null || true
          printf '%s%s\\n' "\(markerPrefix)END:" "$name"
        done
        """

        let result = await ShellRunner.runProcess(
            executablePath: "/bin/zsh",
            arguments: ["-lc", script, "--"] + validNames,
            timeout: 20
        )
        guard result.succeeded else {
            return CommandPathLookup(candidatesByName: [:], failureMessage: "Command lookup failed (exit \(result.exitCode)): \(result.stderr)")
        }

        return CommandPathLookup(candidatesByName: parseWhenceOutput(result.stdout), layout: await EcosystemLayout.discover())
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
