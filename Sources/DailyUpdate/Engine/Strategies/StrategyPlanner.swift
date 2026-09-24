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
    static func usesTypedEngine(config: DetectorConfig) -> Bool {
        config.source == .bundled && config.hasTypedEngineFields
    }

    static func checkPlan(
        config: DetectorConfig,
        currentVersion: String?,
        pathLookup: CommandPathLookup? = nil,
        layout: EcosystemLayout = .live()
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

        let resolution = await OwnerResolver.resolve(commandName: commandName, lookup: pathLookup, layout: layout)
        return await checkPlan(
            config: config,
            currentVersion: currentVersion,
            resolution: resolution,
            layout: layout
        )
    }

    static func checkPlan(
        config: DetectorConfig,
        currentVersion: String?,
        resolution: OwnerResolution,
        layout: EcosystemLayout = .live()
    ) async -> StrategyPlan {
        switch prepare(config: config, resolution: resolution, layout: layout) {
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
            let typedCurrent = await strategy.currentVersion() ?? currentVersion
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

    static func ownershipFingerprint(for config: DetectorConfig, resolution: OwnerResolution) -> String? {
        guard let baseFingerprint = resolution.fingerprint else { return nil }
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
        layout: EcosystemLayout = .live()
    ) async -> (commandSpec: CommandSpec, fingerprint: String)? {
        guard usesTypedEngine(config: config) else { return nil }
        guard let commandName = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !commandName.isEmpty else {
            return nil
        }

        let resolution = await OwnerResolver.resolve(commandName: commandName, lookup: pathLookup, layout: layout)
        switch prepare(config: config, resolution: resolution, layout: layout) {
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
        layout: EcosystemLayout = .live()
    ) -> CommandSpec? {
        switch prepare(config: config, resolution: resolution, layout: layout) {
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
    }

    private static func prepare(
        config: DetectorConfig,
        resolution: OwnerResolution,
        layout: EcosystemLayout
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

        switch makeStrategy(config: config, active: active, layout: layout) {
        case .strategy(let strategy):
            return .ready(strategy)
        case .unknownOwner(let message):
            return .blocked(.unknownOwner, message)
        case .noStrategy(let message):
            return .blocked(.noStrategy, message)
        }
    }

    private static func makeStrategy(
        config: DetectorConfig,
        active: OwnerCandidate,
        layout: EcosystemLayout
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
            return .strategy(BrewFormulaStrategy(
                formula: resolvedFormula,
                brewExecutable: brewExecutable
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
            return .strategy(BrewCaskStrategy(
                token: resolvedToken,
                brewExecutable: brewExecutable,
                resolvedAppPath: active.resolvedPath
            ))
        case .npm(let prefix, let package):
            let resolvedPackage = config.packages?.npm ?? package
            let npmExecutable = "\(prefix)/bin/npm"
            guard PathTrust.isTrustedExecutable(npmExecutable) else {
                return .unknownOwner("Untrusted npm executable path")
            }
            return .strategy(NpmPackageStrategy(
                package: resolvedPackage,
                prefix: prefix,
                npmExecutable: npmExecutable
            ))
        case .nativeInstaller(let installer):
            guard installer == .claudeCode, config.selfUpdater == "claudeCode" else {
                return .noStrategy("Unsupported native self-updater")
            }
            return .strategy(ClaudeNativeStrategy(executable: active.commandPath))
        case .pipx, .uvTool:
            return .noStrategy("Strategy deferred to PR-B2")
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
        case .nativeInstaller:
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

    static func parseBrewFormulaInfo(from output: String) -> BrewFormulaInfo? {
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

        var linkedVersion: String?
        var linkedCellarPath: String?
        if let installed = first["installed"] as? [[String: Any]] {
            if let linked = installed.first(where: { ($0["linked_keg"] as? String)?.isEmpty == false }) ?? installed.first {
                linkedVersion = linked["version"] as? String
                linkedCellarPath = linked["path"] as? String
            }
        }

        let latestVersion = revision > 0 ? "\(stable)_\(revision)" : stable
        return BrewFormulaInfo(
            latestVersion: latestVersion,
            linkedVersion: linkedVersion,
            linkedCellarPath: linkedCellarPath,
            pinned: pinned
        )
    }

    static func parseBrewCaskVersion(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let first = casks.first,
              let version = first["version"] as? String else {
            return nil
        }
        return version.components(separatedBy: ",").first?.nilIfEmpty
    }

    static func parseClaudeDistTags(from output: String) -> [String: String]? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = root["dist-tags"] as? [String: String] else {
            return nil
        }
        return tags
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

private struct BrewFormulaStrategy: Strategy {
    let formula: String
    let brewExecutable: String
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
        CommandSpec(executablePath: brewExecutable, arguments: ["upgrade", formula])
    }

    private func info() async -> BrewFormulaInfo? {
        let result = await ShellRunner.run(
            CommandSpec(executablePath: brewExecutable, arguments: ["info", "--json=v2", formula]),
            timeout: 30
        )
        guard result.succeeded else { return nil }
        return StrategyPlanner.parseBrewFormulaInfo(from: result.stdout)
    }
}

private struct BrewCaskStrategy: Strategy {
    let token: String
    let brewExecutable: String
    let resolvedAppPath: String
    let requiresLatestVersion = true
    let requiresTargetVersion = false

    func currentVersion() async -> String? {
        bundleVersion(from: resolvedAppPath)
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        let result = await ShellRunner.run(
            CommandSpec(executablePath: brewExecutable, arguments: ["info", "--json=v2", "--cask", token]),
            timeout: 30
        )
        guard result.succeeded, let latest = StrategyPlanner.parseBrewCaskVersion(from: result.stdout) else {
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
        CommandSpec(executablePath: brewExecutable, arguments: ["upgrade", "--cask", token])
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

private struct NpmPackageStrategy: Strategy {
    let package: String
    let prefix: String
    let npmExecutable: String
    let requiresLatestVersion = true
    let requiresTargetVersion = true

    func currentVersion() async -> String? {
        let packageJSON = "\(prefix)/lib/node_modules/\(package)/package.json"
        guard let data = FileManager.default.contents(atPath: packageJSON),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = payload["version"] as? String else {
            return nil
        }
        return version.nilIfEmpty
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        let result = await ShellRunner.run(
            CommandSpec(
                executablePath: npmExecutable,
                arguments: ["view", "\(package)@latest", "version", "--json"],
                environment: ["PATH": "\(prefix)/bin:\(ShellRunner.defaultPath)"]
            ),
            timeout: 30
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

        guard isStrictSemVer(candidate) else {
            return LatestVersionOutcome(
                latestVersion: nil,
                failureMessage: "Latest npm version is not strict semver: \(candidate)"
            )
        }
        return LatestVersionOutcome(latestVersion: candidate)
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        guard let targetVersion = targetVersion?.nilIfEmpty, isStrictSemVer(targetVersion) else {
            return nil
        }
        return CommandSpec(
            executablePath: npmExecutable,
            arguments: ["install", "-g", "--prefix", prefix, "\(package)@\(targetVersion)"],
            environment: ["PATH": "\(prefix)/bin:\(ShellRunner.defaultPath)"]
        )
    }

    private func isStrictSemVer(_ value: String) -> Bool {
        value.range(
            of: #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil
    }
}

private struct ClaudeNativeStrategy: Strategy {
    let executable: String
    let requiresLatestVersion = true
    let requiresTargetVersion = false

    func currentVersion() async -> String? {
        let marker = "/versions/"
        guard let markerRange = executable.range(of: marker) else { return nil }
        let suffix = executable[markerRange.upperBound...]
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

        guard let payload = await fetchRegistryPayload(),
              let distTags = StrategyPlanner.parseClaudeDistTags(from: payload),
              let latest = distTags[channel]?.nilIfEmpty else {
            return LatestVersionOutcome(latestVersion: nil)
        }

        guard latest.range(
            of: #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
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

    private func fetchRegistryPayload() async -> String? {
        guard let url = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
