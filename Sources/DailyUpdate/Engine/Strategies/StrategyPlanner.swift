import Foundation

struct StrategyPlan {
    let ownerResolution: OwnerResolution
    let currentVersion: String?
    let latestVersion: String?
    let updateCommandSpec: CommandSpec?
    let gateReasons: [GateReason]
    let blockReason: BlockReason?
    let failureMessage: String?
}

enum StrategyPlanner {
    typealias ProcessRunner = (CommandSpec) async -> ShellRunner.Result
    typealias BoundedRunner = (BoundedProcessSpec) async -> QueryOutcome

    /// P2-2: what a plan may consult besides the filesystem, injected the same way `fetchRelease`
    /// is so tests never start a real brew or npm.
    /// - `brewInfo`: the per-run Homebrew cache discovery built (§1). With it, a brew check starts
    ///   no per-item `brew info`; without it (Phase 1 callers, or a check before discovery ran),
    ///   the strategy asks brew once per plan, as before.
    /// - `runProcess`: the per-item fallback calls (`brew info <name>`, Phase 1's `npm view`).
    /// - `runBounded`: RC5's provenance `npm view`, which needs the 4 MB stdout cap.
    struct Services {
        var brewInfo: BrewInfoProvider?
        var runProcess: ProcessRunner
        var runBounded: BoundedRunner

        static let live = Services(
            brewInfo: nil,
            runProcess: { spec in await ShellRunner.run(spec, timeout: 30) },
            runBounded: { spec in await BoundedProcessRunner.run(spec) }
        )

        static func live(brewInfo: BrewInfoProvider?) -> Services {
            var services = Services.live
            services.brewInfo = brewInfo
            return services
        }
    }

    /// `/usr/bin/curl` is SIP-protected, so a `curl` planted earlier on PATH
    /// never runs. `-q` must come first to skip `~/.curlrc`, and
    /// `--proto =https` refuses every other scheme. Without `-L`, curl follows no redirects.
    static let claudeDistTagsRequest = pinnedHTTPSRequest("https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags")

    /// Same pinning as `claudeDistTagsRequest`. The body is only read as JSON.
    static let openCodeLatestReleaseRequest = pinnedHTTPSRequest("https://api.github.com/repos/anomalyco/opencode/releases/latest")

    /// Cursor publishes its current build only in its installer script. The script is only
    /// searched for the build string and never runs.
    static let cursorAgentInstallerRequest = pinnedHTTPSRequest("https://cursor.com/install")

    private static func pinnedHTTPSRequest(_ url: String) -> CommandSpec {
        CommandSpec(executablePath: "/usr/bin/curl",
            arguments: ["-q", "--proto", "=https", "--fail", "--silent", "--show-error", "--max-time", "20", url])
    }

    /// Returns the response body for a pinned request, or `nil` when it failed. A planner input,
    /// like `pathLookup`, so tests never reach the network.
    typealias ReleaseFetcher = (CommandSpec) async -> String?

    static let liveReleaseFetcher: ReleaseFetcher = { spec in await fetchBody(spec) }

    static func fetchBody(_ spec: CommandSpec, run: ProcessRunner = { spec in
        await ShellRunner.runProcess(executablePath: spec.executablePath, arguments: spec.arguments,
            environment: ["PATH": ShellRunner.defaultPath], timeout: 25)
    }) async -> String? {
        let result = await run(spec)
        return result.succeeded ? result.stdout : nil
    }

    static func isStrictSemVer(_ value: String) -> Bool {
        value.range(of: strictSemVerPattern, options: .regularExpression) != nil
    }

    static func usesTypedEngine(config: DetectorConfig) -> Bool {
        (config.source == .bundled && config.hasTypedEngineFields) ||
            (config.source == .inventory && config.inventory != nil)
    }

    /// P2-1: the inventory branch. Resolves through whatever `InventoryResolver`-backed closure
    /// the caller injects (P2-5 wires the real enumerator registry into `DetectionService` and
    /// `UpdateCheckService`; tests inject a fake), then hands off to the existing
    /// `checkPlan(config:currentVersion:resolution:layout:fetchRelease:)` the same way the
    /// bundled path already does. A row carrying the error marker (an unreadable ecosystem root,
    /// §1's "Enumerations that are partial or failed") is reported Check Failed directly from its
    /// `description`, without ever calling the resolver.
    static func checkPlan(
        config: DetectorConfig,
        currentVersion: String?,
        resolve: (InventoryIdentity) async -> InstalledPackage?,
        layout: EcosystemLayout = .live(),
        fetchRelease: @escaping ReleaseFetcher = liveReleaseFetcher,
        services: Services = .live
    ) async -> StrategyPlan? {
        guard config.source == .inventory, let identity = config.inventory else { return nil }

        if identity.isErrorMarker {
            return StrategyPlan(
                ownerResolution: OwnerResolution(commandName: "", active: nil, competing: [], resolveError: .lookupFailed(config.description ?? "Couldn't read this install")),
                currentVersion: nil, latestVersion: nil, updateCommandSpec: nil, gateReasons: [],
                blockReason: nil, failureMessage: config.description ?? "Couldn't read this install"
            )
        }

        guard let record = await resolve(identity) else {
            let message = "\(config.name): this install is no longer where it was found"
            return StrategyPlan(
                ownerResolution: OwnerResolution(commandName: identity.packageID, active: nil, competing: [], resolveError: .lookupFailed(message)),
                currentVersion: currentVersion, latestVersion: nil, updateCommandSpec: nil, gateReasons: [],
                blockReason: nil, failureMessage: message
            )
        }

        let executable = record.executables.first ?? record.packageDirectory
        let resolution = OwnerResolution(
            commandName: identity.packageID,
            active: OwnerCandidate(commandPath: executable, resolvedPath: executable, owner: record.owner),
            competing: []
        )
        // §7.2: a record under an untrusted root never gets a command.
        if record.flags.contains(.untrustedRoot) {
            return StrategyPlan(
                ownerResolution: resolution, currentVersion: record.versionRaw, latestVersion: nil, updateCommandSpec: nil,
                gateReasons: [], blockReason: .untrustedPath,
                failureMessage: "\(record.root.label) can be written by other users"
            )
        }
        // D10: an `npm link` is updated where it was linked from, never by `npm install -g`.
        if record.flags.contains(.linked) {
            let source = record.evidence.first { $0.kind == "npm-link" }?.path ?? record.packageDirectory
            return StrategyPlan(
                ownerResolution: resolution, currentVersion: record.versionRaw, latestVersion: nil, updateCommandSpec: nil,
                gateReasons: [], blockReason: .manualOnly,
                failureMessage: "Linked from \(PackageNameRules.sanitize(source))"
            )
        }
        return await checkPlan(config: config, currentVersion: currentVersion, resolution: resolution, layout: layout,
            fetchRelease: fetchRelease, services: services)
    }

    static func checkPlan(
        config: DetectorConfig,
        currentVersion: String?,
        pathLookup: CommandPathLookup? = nil,
        layout: EcosystemLayout = .live(),
        fetchRelease: @escaping ReleaseFetcher = liveReleaseFetcher,
        services: Services = .live
    ) async -> StrategyPlan? {
        guard usesTypedEngine(config: config) else { return nil }
        guard let commandName = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !commandName.isEmpty else {
            return StrategyPlan(
                ownerResolution: OwnerResolution(commandName: "", active: nil, competing: [], resolveError: .invalidCommandName),
                currentVersion: currentVersion,
                latestVersion: nil,
                updateCommandSpec: nil,
                gateReasons: [],
                blockReason: .unknownOwner,
                failureMessage: "Missing command name"
            )
        }

        let layout = pathLookup?.layout ?? layout
        let resolution = await OwnerResolver.resolve(commandName: commandName, lookup: pathLookup, layout: layout)
        return await checkPlan(
            config: config,
            currentVersion: currentVersion,
            resolution: resolution,
            layout: layout,
            fetchRelease: fetchRelease,
            services: services
        )
    }

    static func checkPlan(
        config: DetectorConfig,
        currentVersion: String?,
        resolution: OwnerResolution,
        layout: EcosystemLayout = .live(),
        fetchRelease: @escaping ReleaseFetcher = liveReleaseFetcher,
        services: Services = .live
    ) async -> StrategyPlan {
        switch prepare(config: config, resolution: resolution, layout: layout, fetchRelease: fetchRelease, services: services) {
        case .blocked(let reason, let message):
            return StrategyPlan(
                ownerResolution: resolution,
                currentVersion: currentVersion,
                latestVersion: nil,
                updateCommandSpec: nil,
                gateReasons: [],
                blockReason: reason,
                failureMessage: message
            )
        case .failed(let message):
            return StrategyPlan(
                ownerResolution: resolution,
                currentVersion: currentVersion,
                latestVersion: nil,
                updateCommandSpec: nil,
                gateReasons: [],
                blockReason: nil,
                failureMessage: message
            )
        case .ready(let strategy):
            guard let typedCurrent = await strategy.currentVersion() else {
                return StrategyPlan(ownerResolution: resolution, currentVersion: nil, latestVersion: nil,
                    updateCommandSpec: nil, gateReasons: [], blockReason: nil,
                    failureMessage: "Could not read installed version")
            }
            let latestOutcome = await strategy.latestVersion(currentVersion: typedCurrent)
            if let blockReason = latestOutcome.blockReason {
                return StrategyPlan(
                    ownerResolution: resolution,
                    currentVersion: typedCurrent,
                    latestVersion: latestOutcome.latestVersion,
                    updateCommandSpec: nil,
                    gateReasons: latestOutcome.gateReasons,
                    blockReason: blockReason,
                    failureMessage: latestOutcome.failureMessage
                )
            }
            if let failureMessage = latestOutcome.failureMessage {
                return StrategyPlan(
                    ownerResolution: resolution,
                    currentVersion: typedCurrent,
                    latestVersion: latestOutcome.latestVersion,
                    updateCommandSpec: nil,
                    gateReasons: latestOutcome.gateReasons,
                    blockReason: nil,
                    failureMessage: failureMessage
                )
            }

            if latestOutcome.latestVersion == nil && strategy.requiresLatestVersion {
                return StrategyPlan(
                    ownerResolution: resolution,
                    currentVersion: typedCurrent,
                    latestVersion: nil,
                    updateCommandSpec: nil,
                    gateReasons: latestOutcome.gateReasons,
                    blockReason: nil,
                    failureMessage: "Could not determine latest version"
                )
            }

            let updateSpec = makeUpdateSpec(
                from: strategy,
                targetVersion: latestOutcome.latestVersion,
                workingDirectory: config.workingDirectory
            )
            if updateSpec == nil && strategy.requiresTargetVersion {
                return StrategyPlan(
                    ownerResolution: resolution,
                    currentVersion: typedCurrent,
                    latestVersion: latestOutcome.latestVersion,
                    updateCommandSpec: nil,
                    gateReasons: latestOutcome.gateReasons,
                    blockReason: nil,
                    failureMessage: "Could not produce a pinned update command"
                )
            }

            if let updateSpec, !updateSpec.isSingle {
                return StrategyPlan(
                    ownerResolution: resolution,
                    currentVersion: typedCurrent,
                    latestVersion: latestOutcome.latestVersion,
                    updateCommandSpec: nil,
                    gateReasons: latestOutcome.gateReasons,
                    blockReason: .manualOnly,
                    failureMessage: "Blocked non-single update command"
                )
            }

            return StrategyPlan(
                ownerResolution: resolution,
                currentVersion: typedCurrent,
                latestVersion: latestOutcome.latestVersion,
                updateCommandSpec: updateSpec,
                gateReasons: latestOutcome.gateReasons,
                blockReason: nil,
                failureMessage: nil
            )
        }
    }

    static func currentVersion(
        config: DetectorConfig, pathLookup: CommandPathLookup?, services: Services = .live
    ) async -> (version: String?, owner: OwnerCandidate?) {
        guard let name = config.command else { return (nil, nil) }
        let layout = pathLookup?.layout ?? .live()
        let resolution = await OwnerResolver.resolve(commandName: name, lookup: pathLookup, layout: layout)
        guard case .ready(let strategy) = prepare(config: config, resolution: resolution, layout: layout, services: services) else { return (nil, nil) }
        return (await strategy.currentVersion(), resolution.active)
    }

    static func ownershipFingerprint(for config: DetectorConfig, resolution: OwnerResolution) -> String? {
        guard var baseFingerprint = resolution.fingerprint else { return nil }
        if let active = resolution.active {
            let tool: String?
            switch active.owner {
            case .npm(let prefix, _): tool = "\(prefix)/bin/npm"
            case .nativeInstaller: tool = active.commandPath
            case .brewFormula, .brewCask:
                let components = active.resolvedPath.components(separatedBy: "/")
                if let marker = components.firstIndex(where: { $0 == "Cellar" || $0 == "Caskroom" }) {
                    tool = components[..<marker].joined(separator: "/") + "/bin/brew"
                } else { tool = nil }
            default: tool = nil
            }
            if let tool, let resolved = PathTrust.resolvedExecutable(tool) {
                baseFingerprint += "|executor:\(resolved)"
            }
        }
        guard let workingDirectory = config.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty else {
            return baseFingerprint
        }
        let expanded = (workingDirectory as NSString).expandingTildeInPath
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return "\(baseFingerprint)|cwd:\(normalized)"
    }

    static func plannedCommand(
        config: DetectorConfig,
        targetVersion: String?,
        pathLookup: CommandPathLookup? = nil,
        layout: EcosystemLayout = .live(),
        services: Services = .live
    ) async -> (commandSpec: CommandSpec, fingerprint: String)? {
        guard usesTypedEngine(config: config) else { return nil }
        guard let commandName = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !commandName.isEmpty else {
            return nil
        }

        let layout = pathLookup?.layout ?? layout
        let resolution = await OwnerResolver.resolve(commandName: commandName, lookup: pathLookup, layout: layout)
        switch prepare(config: config, resolution: resolution, layout: layout, services: services) {
        case .ready(let strategy):
            guard let spec = makeUpdateSpec(from: strategy, targetVersion: targetVersion, workingDirectory: config.workingDirectory),
                  spec.isSingle,
                  let fingerprint = ownershipFingerprint(for: config, resolution: resolution) else {
                return nil
            }
            return (spec, fingerprint)
        case .blocked, .failed:
            return nil
        }
    }

    static func commandForResolvedOwner(
        config: DetectorConfig,
        resolution: OwnerResolution,
        targetVersion: String?,
        layout: EcosystemLayout = .live(),
        services: Services = .live
    ) -> CommandSpec? {
        switch prepare(config: config, resolution: resolution, layout: layout, services: services) {
        case .ready(let strategy):
            let spec = makeUpdateSpec(from: strategy, targetVersion: targetVersion, workingDirectory: config.workingDirectory)
            return spec?.isSingle == true ? spec : nil
        case .blocked, .failed:
            return nil
        }
    }

    private enum PreparationOutcome {
        case ready(Strategy)
        case blocked(BlockReason, String)
        case failed(String)
    }

    private enum StrategyBuildOutcome {
        case strategy(Strategy)
        case unknownOwner(String)
        case noStrategy(String)
        /// P2-1: an owner blocked for a reason more specific than "no strategy" — system-owned,
        /// managed by a version manager, or manual-only.
        case blocked(BlockReason, String)
    }

    private static func prepare(
        config: DetectorConfig,
        resolution: OwnerResolution,
        layout: EcosystemLayout,
        fetchRelease: @escaping ReleaseFetcher = liveReleaseFetcher,
        services: Services = .live
    ) -> PreparationOutcome {
        if let error = resolution.resolveError {
            switch error {
            case .invalidCommandName:
                return .failed("Invalid command name for owner lookup")
            case .lookupFailed(let message):
                return .failed(message)
            case .unresolvedPath(let path):
                return .failed("Could not resolve command path: \(path)")
            }
        }

        guard let active = resolution.active else {
            return .blocked(.unknownOwner, "Could not resolve active command path")
        }
        if hasOwnerMismatch(config: config, owner: active.owner) {
            return .blocked(.ownerMismatch, "Resolved owner does not match catalog package identity")
        }

        switch makeStrategy(config: config, active: active, layout: layout, fetchRelease: fetchRelease, services: services) {
        case .strategy(let strategy):
            return .ready(strategy)
        case .unknownOwner(let message):
            return .blocked(.unknownOwner, message)
        case .noStrategy(let message):
            return .blocked(.noStrategy, message)
        case .blocked(let reason, let message):
            return .blocked(reason, message)
        }
    }

    private static func makeStrategy(
        config: DetectorConfig,
        active: OwnerCandidate,
        layout: EcosystemLayout,
        fetchRelease: @escaping ReleaseFetcher,
        services: Services
    ) -> StrategyBuildOutcome {
        switch active.owner {
        case .brewFormula(let formula):
            let resolvedFormula = config.packages?.brew ?? formula
            guard let brewExecutable = brewExecutable(
                for: active.resolvedPath,
                roots: layout.brewCellars,
                suffix: "/Cellar"
            ) else {
                return .unknownOwner("Could not derive brew executable path")
            }
            guard PathTrust.isTrustedExecutable(brewExecutable) else {
                return .unknownOwner("Untrusted brew executable path")
            }
            // F7: the discovery snapshot knows the tap; a formula outside homebrew/core upgrades by
            // its full name. Either name must pass §7.4 before it can reach argv.
            let provided = services.brewInfo?.formula(resolvedFormula, brewExecutable: brewExecutable)
            guard let upgradeToken = provided?.upgradeToken ??
                    (PackageNameRules.isValidBrewFormulaName(resolvedFormula) ? resolvedFormula : nil) else {
                return .unknownOwner("Formula name isn't a valid Homebrew name")
            }
            return .strategy(BrewFormulaStrategy(
                formula: resolvedFormula,
                upgradeToken: upgradeToken,
                brewExecutable: brewExecutable,
                provided: provided,
                runProcess: services.runProcess
            ))
        case .brewCask(let token):
            let resolvedToken = config.packages?.brewCask ?? token
            guard let brewExecutable = brewExecutable(
                for: active.resolvedPath,
                roots: layout.brewCaskrooms,
                suffix: "/Caskroom"
            ) else {
                return .unknownOwner("Could not derive brew executable path")
            }
            guard PathTrust.isTrustedExecutable(brewExecutable) else {
                return .unknownOwner("Untrusted brew executable path")
            }
            let provided = services.brewInfo?.cask(resolvedToken, brewExecutable: brewExecutable)
            guard let upgradeToken = provided?.upgradeToken ??
                    (PackageNameRules.isValidCaskToken(resolvedToken) ? resolvedToken : nil) else {
                return .unknownOwner("Cask token isn't a valid Homebrew token")
            }
            return .strategy(BrewCaskStrategy(
                token: resolvedToken,
                upgradeToken: upgradeToken,
                brewExecutable: brewExecutable,
                resolvedAppPath: active.resolvedPath,
                provided: provided,
                runProcess: services.runProcess
            ))
        case .npm(let prefix, let package):
            let resolvedPackage = config.packages?.npm ?? package
            let npmExecutable = "\(prefix)/bin/npm"
            guard PathTrust.isTrustedExecutable(npmExecutable) else {
                return .unknownOwner("Untrusted npm executable path")
            }
            // RC5: a discovered package the catalog doesn't vouch for (no `packages.npm`) must
            // prove it came from the registry before it may be updated from it.
            return .strategy(NpmPackageStrategy(
                package: resolvedPackage,
                prefix: prefix,
                npmExecutable: npmExecutable,
                checksProvenance: config.source == .inventory && config.packages?.npm == nil,
                runProcess: services.runProcess,
                runBounded: services.runBounded
            ))
        case .nativeInstaller(let installer):
            // The catalog names the one self-updater it trusts for this item.
            guard config.selfUpdater == installer.rawValue else {
                return .noStrategy("Unsupported native self-updater")
            }
            switch installer {
            case .claudeCode:
                guard PathTrust.isTrustedExecutable(active.commandPath) else {
                    return .unknownOwner("Untrusted Claude executable path")
                }
                return .strategy(ClaudeNativeStrategy(executable: active.commandPath, resolvedPath: active.resolvedPath,
                    fetchDistTags: { await fetchRelease(claudeDistTagsRequest) }))
            case .opencode:
                guard PathTrust.isTrustedExecutable(active.commandPath) else {
                    return .unknownOwner("Untrusted OpenCode executable path")
                }
                return .strategy(OpenCodeNativeStrategy(executable: active.commandPath, fetchRelease: fetchRelease))
            case .cursorAgent:
                guard PathTrust.isTrustedExecutable(active.commandPath) else {
                    return .unknownOwner("Untrusted Cursor Agent executable path")
                }
                return .strategy(CursorAgentNativeStrategy(executable: active.commandPath, resolvedPath: active.resolvedPath,
                    nativeRoot: layout.cursorAgentNativeRoot, fetchRelease: fetchRelease))
            }
        case .pipx, .uvTool:
            return .noStrategy("Strategy deferred to PR-B2")
        // P2-1: discovery owners. Each is Blocked until the PR that owns its ecosystem (noted
        // per case) wires a real strategy; D7 lists exactly which owners ever get one.
        case .pnpm, .yarnClassic, .bun, .pipUser:
            return .noStrategy("Listed only")
        case .cargo:
            return .noStrategy("Listed only") // P2-3: a git/path source becomes .manualOnly instead.
        case .gem(_, _, let systemOwned):
            return systemOwned ? .blocked(.systemOwned, "Managed by system Ruby") : .noStrategy("Listed only")
        case .appStore:
            return .noStrategy("App Store handoff lands in P2-6a")
        case .sparkleApp:
            return .noStrategy("Sparkle strategy lands in P2-6b")
        case .selfUpdatingApp:
            return .noStrategy("Self-updating app handoff lands in P2-6a")
        case .versionManager(let kind, _):
            return .blocked(.managedByVersionManager, "Managed by \(kind.rawValue)")
        case .agentSkill:
            return .blocked(.manualOnly, "Managed by `npx skills`")
        case .agentPlugin(let agent, _, _):
            return .blocked(.manualOnly, "Managed by \(agent)")
        case .system(let provider):
            return .blocked(.systemOwned, "Managed by \(provider)")
        case .unknown:
            return .noStrategy("No strategy for resolved owner")
        }
    }

    private static func makeUpdateSpec(
        from strategy: Strategy,
        targetVersion: String?,
        workingDirectory: String?
    ) -> CommandSpec? {
        guard var spec = strategy.updateCommand(targetVersion: targetVersion) else { return nil }
        spec.workingDirectory = workingDirectory?.nilIfEmpty
        return spec
    }

    private static func hasOwnerMismatch(config: DetectorConfig, owner: ResolvedOwner) -> Bool {
        guard let packages = config.packages else { return false }
        switch owner {
        case .brewFormula(let formula):
            return packages.brew != formula
        case .brewCask(let token):
            return packages.brewCask != token
        case .npm(_, let package):
            return packages.npm != package
        case .pipx(let package):
            return packages.pipx != package
        case .uvTool(let name):
            return packages.uv != name
        case .cargo(_, let crate):
            return packages.cargo != crate
        case .gem(_, let name, _):
            return packages.gem != name
        case .appStore(let adamID):
            return packages.masAdamID != adamID
        case .nativeInstaller:
            return false
        // P2-1: the catalog schema has no field for these ecosystems yet, so there's nothing a
        // catalog entry could declare that would conflict (D6: "a missing key isn't a mismatch").
        case .pnpm, .yarnClassic, .bun, .pipUser, .sparkleApp, .selfUpdatingApp, .versionManager, .agentSkill, .agentPlugin, .system:
            return false
        case .unknown:
            return true
        }
    }

    private static func brewExecutable(for path: String, roots: [String], suffix: String) -> String? {
        for root in roots {
            let expandedRoot = (root as NSString).expandingTildeInPath
            let normalizedRoot = URL(fileURLWithPath: expandedRoot).standardizedFileURL.path
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard normalizedPath.hasPrefix("\(normalizedRoot)/") || normalizedPath == normalizedRoot else {
                continue
            }
            guard normalizedRoot.hasSuffix(suffix) else { continue }
            let prefix = String(normalizedRoot.dropLast(suffix.count))
            return "\(prefix)/bin/brew"
        }
        return nil
    }

    static func parseBrewFormulaInfo(from output: String, cellar: String = "/opt/homebrew/Cellar") -> BrewFormulaInfo? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulas = root["formulae"] as? [[String: Any]],
              let first = formulas.first else {
            return nil
        }

        guard let versions = first["versions"] as? [String: Any],
              let stable = versions["stable"] as? String,
              !stable.isEmpty else {
            return nil
        }

        let revision = (first["revision"] as? Int) ?? 0
        let pinned = (first["pinned"] as? Bool) ?? false

        let linkedVersion = (first["linked_keg"] as? String)?.nilIfEmpty
        let linkedCellarPath: String?
        if let version = linkedVersion, let name = first["name"] as? String {
            linkedCellarPath = "\(cellar)/\(name)/\(version)"
        } else { linkedCellarPath = nil }

        let latestVersion = revision > 0 ? "\(stable)_\(revision)" : stable
        return BrewFormulaInfo(
            latestVersion: latestVersion,
            linkedVersion: linkedVersion,
            linkedCellarPath: linkedCellarPath,
            pinned: pinned
        )
    }

    static func parseBrewCaskVersion(from output: String) -> String? {
        parseBrewCaskInfo(from: output)?.version
    }

    /// `version` (without its `,build` suffix) and `auto_updates` from `brew info --json=v2 --cask`.
    static func parseBrewCaskInfo(from output: String) -> BrewCaskInfo? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let first = casks.first,
              let version = (first["version"] as? String)?.components(separatedBy: ",").first?.nilIfEmpty else {
            return nil
        }
        return BrewCaskInfo(version: version, autoUpdates: (first["auto_updates"] as? Bool) ?? false)
    }

    static func parseClaudeDistTags(from output: String) -> [String: String]? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["dist-tags"] as? [String: String]) ?? (root as? [String: String])
    }
}

private struct LatestVersionOutcome {
    var latestVersion: String?
    var gateReasons: [GateReason] = []
    var blockReason: BlockReason?
    var failureMessage: String?
}

private protocol Strategy {
    var requiresLatestVersion: Bool { get }
    var requiresTargetVersion: Bool { get }
    func currentVersion() async -> String?
    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome
    func updateCommand(targetVersion: String?) -> CommandSpec?
}

struct BrewFormulaInfo {
    let latestVersion: String
    let linkedVersion: String?
    let linkedCellarPath: String?
    let pinned: Bool
}

private final class BrewFormulaStrategy: Strategy {
    private var cachedInfo: BrewFormulaInfo?
    private var loadedInfo = false

    init(formula: String, upgradeToken: String, brewExecutable: String, provided: BrewFormulaRecord?,
         runProcess: @escaping StrategyPlanner.ProcessRunner) {
        self.formula = formula
        self.upgradeToken = upgradeToken
        self.brewExecutable = brewExecutable
        self.provided = provided
        self.runProcess = runProcess
    }
    let formula: String
    /// F7: `formula`, or the tap-qualified `full_name` for a formula outside homebrew/core.
    let upgradeToken: String
    let brewExecutable: String
    /// P2-2: this formula's entry in the discovery snapshot, when one was taken.
    let provided: BrewFormulaRecord?
    let runProcess: StrategyPlanner.ProcessRunner
    let requiresLatestVersion = true
    let requiresTargetVersion = false

    func currentVersion() async -> String? {
        await info()?.linkedVersion
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        guard let info = await info() else {
            return LatestVersionOutcome(latestVersion: nil)
        }
        if info.pinned {
            return LatestVersionOutcome(
                latestVersion: info.latestVersion,
                gateReasons: [.pinned]
            )
        }
        if let linkedCellarPath = info.linkedCellarPath,
           !FileManager.default.isWritableFile(atPath: linkedCellarPath) {
            return LatestVersionOutcome(
                latestVersion: info.latestVersion,
                blockReason: .needsPrivilege,
                failureMessage: "Linked Cellar is not writable"
            )
        }
        return LatestVersionOutcome(latestVersion: info.latestVersion)
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: brewExecutable, arguments: ["upgrade", "--formula", upgradeToken])
    }

    /// §1: the snapshot already holds `versions.stable`, `revision`, `pinned` and `linked_keg`, so
    /// with one this starts no process. The filesystem fallback has no latest version; then, as
    /// in Phase 1, brew is asked once per plan.
    private func info() async -> BrewFormulaInfo? {
        if loadedInfo { return cachedInfo }
        loadedInfo = true
        let prefix = URL(fileURLWithPath: brewExecutable).deletingLastPathComponent().deletingLastPathComponent().path
        if let provided, let latest = provided.latestVersion {
            cachedInfo = BrewFormulaInfo(
                latestVersion: latest,
                linkedVersion: provided.linkedVersion,
                linkedCellarPath: provided.linkedVersion.map { "\(prefix)/Cellar/\(provided.name)/\($0)" },
                pinned: provided.pinned
            )
            return cachedInfo
        }
        let result = await runProcess(CommandSpec(executablePath: brewExecutable, arguments: ["info", "--json=v2", formula]))
        guard result.succeeded else { return nil }
        cachedInfo = StrategyPlanner.parseBrewFormulaInfo(from: result.stdout, cellar: "\(prefix)/Cellar")
        return cachedInfo
    }
}

struct BrewCaskInfo: Equatable {
    let version: String
    let autoUpdates: Bool
}

/// G3: a cask with `auto_updates` updates itself, so `brew outdated` hides it without `--greedy`.
/// The check compares what runs (the app bundle) with the cask's version, so a self-updating cask
/// that is behind shows like `--greedy` would. The plan is a named `brew upgrade --cask <token>`,
/// which Homebrew always evaluates greedily, so `--greedy` is not passed.
private final class BrewCaskStrategy: Strategy {
    private var cachedInfo: BrewCaskInfo?
    private var loadedInfo = false

    init(token: String, upgradeToken: String, brewExecutable: String, resolvedAppPath: String,
         provided: BrewCaskRecord?, runProcess: @escaping StrategyPlanner.ProcessRunner) {
        self.token = token
        self.upgradeToken = upgradeToken
        self.brewExecutable = brewExecutable
        self.resolvedAppPath = resolvedAppPath
        self.provided = provided
        self.runProcess = runProcess
    }
    let token: String
    /// F7: `token`, or the `full_token` for a cask outside homebrew/cask.
    let upgradeToken: String
    let brewExecutable: String
    let resolvedAppPath: String
    let provided: BrewCaskRecord?
    let runProcess: StrategyPlanner.ProcessRunner
    let requiresLatestVersion = true
    let requiresTargetVersion = false

    func currentVersion() async -> String? {
        if let bundle = bundleVersion(from: resolvedAppPath) { return bundle }
        // For a self-updating cask the Caskroom directory is what brew installed, not what runs.
        guard let info = await info(), !info.autoUpdates else { return nil }
        let parts = resolvedAppPath.components(separatedBy: "/")
        guard let index = parts.firstIndex(of: "Caskroom"), parts.count > index + 2 else { return nil }
        return parts[index + 2].nilIfEmpty
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        guard let latest = await info()?.version else {
            return LatestVersionOutcome(latestVersion: nil)
        }
        if latest.lowercased() == "latest" {
            return LatestVersionOutcome(
                latestVersion: nil,
                failureMessage: "Cask does not publish a concrete version"
            )
        }
        return LatestVersionOutcome(latestVersion: latest)
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: brewExecutable, arguments: ["upgrade", "--cask", upgradeToken])
    }

    private func info() async -> BrewCaskInfo? {
        if loadedInfo { return cachedInfo }
        loadedInfo = true
        if let provided, let latest = provided.latestVersion {
            cachedInfo = BrewCaskInfo(version: latest, autoUpdates: provided.autoUpdates)
            return cachedInfo
        }
        let result = await runProcess(CommandSpec(executablePath: brewExecutable, arguments: ["info", "--json=v2", "--cask", token]))
        guard result.succeeded else { return nil }
        cachedInfo = StrategyPlanner.parseBrewCaskInfo(from: result.stdout)
        return cachedInfo
    }

    private func bundleVersion(from binaryPath: String) -> String? {
        guard let appRange = binaryPath.range(of: ".app/") else { return nil }
        let bundlePath = String(binaryPath[..<appRange.lowerBound]) + ".app"
        let infoPath = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist").path
        guard let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else { return nil }
        return (info["CFBundleShortVersionString"] as? String)?.nilIfEmpty ??
            (info["CFBundleVersion"] as? String)?.nilIfEmpty
    }
}

/// RC5's pure pieces, internal so `NpmProvenanceTests` can check them directly.
enum NpmPackageStrategyShape {
    /// Amendment 1 RC5: exactly `<P>/bin/npm view --json --global --prefix <P> <name> versions
    /// dist-tags`. `--global` makes npm skip a project `.npmrc` in the working directory, the way
    /// `install -g` does. The name already passed the npm regex, so it can't be read as a flag.
    static func provenanceArguments(prefix: String, package: String) -> [String] {
        ["view", "--json", "--global", "--prefix", prefix, package, "versions", "dist-tags"]
    }

    /// `https://<host>/<name>/-/<basename>-<version>.tgz`, where `<basename>` drops the scope.
    static func isRegistryTarball(_ resolved: String, package: String, version: String) -> Bool {
        let basename = package.split(separator: "/").last.map(String.init) ?? package
        let suffix = "/\(package)/-/\(basename)-\(version).tgz"
        guard resolved.hasPrefix("https://"), resolved.hasSuffix(suffix) else { return false }
        let host = resolved.dropFirst("https://".count).dropLast(suffix.count)
        return !host.isEmpty && host.range(of: #"^[A-Za-z0-9.-]+(:[0-9]{1,5})?$"#, options: .regularExpression) != nil
    }

}

private struct NpmPackageStrategy: Strategy {
    let package: String
    let prefix: String
    let npmExecutable: String
    /// RC5: on for inventory rows not joined to a catalog `packages.npm`.
    let checksProvenance: Bool
    let runProcess: StrategyPlanner.ProcessRunner
    let runBounded: StrategyPlanner.BoundedRunner
    let requiresLatestVersion = true
    let requiresTargetVersion = true

    static let notOnRegistryMessage = "Installed version isn't on the registry (git or tarball install?)"
    static let provenanceStdoutCap = 4 * 1024 * 1024

    /// The update's own environment: `ShellRunner` starts from this process's environment with
    /// `PATH=<P>/bin:<default>`, so the provenance check sees the same npmrc and registry.
    private var environmentPATH: String { "\(prefix)/bin:\(ShellRunner.defaultPath)" }

    private var manifest: [String: Any]? {
        let packageJSON = "\(prefix)/lib/node_modules/\(package)/package.json"
        guard let data = FileManager.default.contents(atPath: packageJSON) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func currentVersion() async -> String? {
        (manifest?["version"] as? String)?.nilIfEmpty
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        checksProvenance ? await provenanceCheckedLatest(installed: currentVersion) : await catalogLatest()
    }

    /// Phase 1, unchanged, for catalog-joined packages (`codex-cli`, `gemini-cli`, …; N6).
    private func catalogLatest() async -> LatestVersionOutcome {
        let result = await runProcess(
            CommandSpec(
                executablePath: npmExecutable,
                arguments: ["view", "\(package)@latest", "version", "--json"],
                environment: ["PATH": environmentPATH]
            )
        )
        guard result.succeeded else { return LatestVersionOutcome(latestVersion: nil) }

        let rawValue = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if rawValue.first == "\"",
           let data = rawValue.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            candidate = decoded
        } else {
            candidate = rawValue
        }

        guard StrategyPlanner.isStrictSemVer(candidate) else {
            return LatestVersionOutcome(
                latestVersion: nil,
                failureMessage: "Latest npm version is not strict semver: \(candidate)"
            )
        }
        return LatestVersionOutcome(latestVersion: candidate)
    }

    /// RC5 (N1–N5). Update Available needs all of: `_resolved` absent (with no `_from`) or
    /// registry-shaped; the installed version published under this name; and a strict-semver
    /// `dist-tags.latest`. A failed call is Check Failed, never Current or Update Available.
    private func provenanceCheckedLatest(installed: String?) async -> LatestVersionOutcome {
        guard let installed else { return LatestVersionOutcome(latestVersion: nil) }
        let manifest = self.manifest ?? [:]
        let resolved = manifest["_resolved"] as? String
        if let resolved {
            guard NpmPackageStrategyShape.isRegistryTarball(resolved, package: package, version: installed) else {
                return LatestVersionOutcome(latestVersion: nil, blockReason: .manualOnly, failureMessage: Self.notOnRegistryMessage)
            }
        } else if manifest["_from"] != nil {
            return LatestVersionOutcome(latestVersion: nil, blockReason: .manualOnly, failureMessage: Self.notOnRegistryMessage)
        }

        let outcome = await runBounded(BoundedProcessSpec(
            executable: npmExecutable,
            arguments: NpmPackageStrategyShape.provenanceArguments(prefix: prefix, package: package),
            environment: .inherited(overridingPATH: environmentPATH),
            timeout: 30,
            maxStdoutBytes: Self.provenanceStdoutCap
        ))
        guard case .exited(0) = outcome.evidence.termination else {
            return LatestVersionOutcome(latestVersion: nil, failureMessage: "npm view failed: \(Self.describe(outcome.evidence))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: outcome.stdout) as? [String: Any] else {
            return LatestVersionOutcome(latestVersion: nil, failureMessage: "npm view returned JSON that couldn't be read")
        }
        // N5: a package with one published version returns `versions` as a string.
        let versions: [String] = (root["versions"] as? [String]) ?? ((root["versions"] as? String).map { [$0] } ?? [])
        guard versions.contains(installed) else {
            return LatestVersionOutcome(latestVersion: nil, blockReason: .manualOnly, failureMessage: Self.notOnRegistryMessage)
        }
        guard let latest = (root["dist-tags"] as? [String: Any])?["latest"] as? String, StrategyPlanner.isStrictSemVer(latest) else {
            return LatestVersionOutcome(latestVersion: nil, failureMessage: "npm's latest dist-tag is missing or isn't strict semver")
        }
        return LatestVersionOutcome(latestVersion: latest)
    }

    private static func describe(_ evidence: ProcessEvidence) -> String {
        switch evidence.termination {
        case .exited(let code):
            let detail = evidence.stderr.split(separator: "?").first.map(String.init) ?? ""
            return detail.isEmpty ? "exit \(code)" : "exit \(code): \(PackageNameRules.sanitize(detail, maxLength: 160))"
        case .signaled(let signal): return "killed by signal \(signal)"
        case .timedOut: return "timed out"
        case .outputCapExceeded: return "output too large"
        case .launchFailed(let reason): return reason
        }
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        guard let targetVersion = targetVersion?.nilIfEmpty, StrategyPlanner.isStrictSemVer(targetVersion) else {
            return nil
        }
        return CommandSpec(
            executablePath: npmExecutable,
            arguments: ["install", "-g", "--prefix", prefix, "\(package)@\(targetVersion)"],
            environment: ["PATH": environmentPATH]
        )
    }
}

private struct ClaudeNativeStrategy: Strategy {
    let executable: String
    let resolvedPath: String
    let fetchDistTags: () async -> String?
    let requiresLatestVersion = true
    let requiresTargetVersion = false

    func currentVersion() async -> String? {
        let marker = "/versions/"
        guard let markerRange = resolvedPath.range(of: marker) else { return nil }
        let suffix = resolvedPath[markerRange.upperBound...]
        guard let versionComponent = suffix.split(separator: "/").first else { return nil }
        return String(versionComponent)
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        guard let channel = claudeChannel() else {
            return LatestVersionOutcome(
                latestVersion: nil,
                failureMessage: "Claude channel must be latest or stable"
            )
        }

        guard let payload = await fetchDistTags(),
              let distTags = StrategyPlanner.parseClaudeDistTags(from: payload),
              let latest = distTags[channel]?.nilIfEmpty else {
            return LatestVersionOutcome(latestVersion: nil)
        }

        guard latest.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil else {
            return LatestVersionOutcome(
                latestVersion: nil,
                failureMessage: "Claude dist-tag is not strict semver: \(latest)"
            )
        }
        return LatestVersionOutcome(latestVersion: latest)
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: executable, arguments: ["update"])
    }

    private func claudeChannel() -> String? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let settingsPath = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/settings.json").path
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "latest"
        }
        let channel = (root["autoUpdatesChannel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "latest"
        guard ["latest", "stable"].contains(channel) else { return nil }
        return channel
    }
}

/// `\A`/`\z` so a trailing newline can never pass. ICU's `$` also matches just before one.
private let strictSemVerPattern = #"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z"#

/// `~/.opencode/bin/opencode`: its own `upgrade <version>` command, pinned to the latest GitHub release.
private struct OpenCodeNativeStrategy: Strategy {
    let executable: String
    let fetchRelease: StrategyPlanner.ReleaseFetcher
    let requiresLatestVersion = true
    let requiresTargetVersion = true

    func currentVersion() async -> String? {
        let result = await ShellRunner.run(CommandSpec(executablePath: executable, arguments: ["--version"]), timeout: 15)
        guard result.succeeded else { return nil }
        let version = Self.withoutV(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        return StrategyPlanner.isStrictSemVer(version) ? version : nil
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        guard let body = await fetchRelease(StrategyPlanner.openCodeLatestReleaseRequest),
              let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = (root["tag_name"] as? String)?.nilIfEmpty else {
            return LatestVersionOutcome(latestVersion: nil)
        }
        let version = Self.withoutV(tag)
        guard StrategyPlanner.isStrictSemVer(version) else {
            // Scalars, not graphemes, bound the text; anything but printable ASCII shows as `?`.
            let printable = tag.unicodeScalars.prefix(32).map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" }
            let shown = String(printable) + (tag.unicodeScalars.count > 32 ? "…" : "")
            return LatestVersionOutcome(latestVersion: nil, failureMessage: "OpenCode release tag is not strict semver: \(shown)")
        }
        return LatestVersionOutcome(latestVersion: version)
    }

    /// `--method curl` keeps the upgrade on the native installer that owns this binary.
    func updateCommand(targetVersion: String?) -> CommandSpec? {
        guard let targetVersion = targetVersion?.nilIfEmpty,
              StrategyPlanner.isStrictSemVer(targetVersion) else { return nil }
        return CommandSpec(executablePath: executable, arguments: ["upgrade", targetVersion, "--method", "curl"])
    }

    private static func withoutV(_ value: String) -> String {
        value.hasPrefix("v") ? String(value.dropFirst()) : value
    }
}

/// `~/.local/bin/cursor-agent` → `~/.local/share/cursor-agent/versions/<YYYY.MM.DD-hash>/`: the
/// build comes from the path, the latest build from Cursor's installer, and the update is its own
/// `update` command.
private struct CursorAgentNativeStrategy: Strategy {
    let executable: String
    let resolvedPath: String
    let nativeRoot: String
    let fetchRelease: StrategyPlanner.ReleaseFetcher
    let requiresLatestVersion = true
    let requiresTargetVersion = false

    private static let buildPattern = #"\A[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7,40}\z"#

    func currentVersion() async -> String? {
        let prefix = nativeRoot.hasSuffix("/") ? nativeRoot : nativeRoot + "/"
        guard resolvedPath.hasPrefix(prefix),
              let build = resolvedPath.dropFirst(prefix.count).split(separator: "/").first.map(String.init),
              build.range(of: Self.buildPattern, options: .regularExpression) != nil else { return nil }
        return build
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        guard let body = await fetchRelease(StrategyPlanner.cursorAgentInstallerRequest),
              let regex = try? NSRegularExpression(pattern: #"downloads\.cursor\.com/lab/([0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7,40})/"#),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else {
            return LatestVersionOutcome(latestVersion: nil)
        }
        let latest = String(body[range])
        // Builds on the same date differ only by hash, which has no order.
        if let currentVersion, currentVersion != latest,
           currentVersion.prefix(10) == latest.prefix(10) {
            return LatestVersionOutcome(latestVersion: nil,
                failureMessage: "Cursor Agent build \(latest) can't be ordered against \(currentVersion)")
        }
        return LatestVersionOutcome(latestVersion: latest)
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: executable, arguments: ["update"])
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
