import Foundation

struct StrategyPlan {
    let ownerResolution: OwnerResolution
    let latestVersion: String?
    let updateCommandSpec: CommandSpec?
    let blockReason: BlockReason?
    let failureMessage: String?
}

enum StrategyPlanner {
    static func checkPlan(
        config: DetectorConfig,
        currentVersion: String?,
        layout: EcosystemLayout = .live()
    ) async -> StrategyPlan? {
        guard config.command != nil || config.packages != nil || config.selfUpdater != nil else {
            return nil
        }
        guard let commandName = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !commandName.isEmpty else {
            return StrategyPlan(
                ownerResolution: OwnerResolution(commandName: "", active: nil, competing: []),
                latestVersion: nil,
                updateCommandSpec: nil,
                blockReason: .unknownOwner,
                failureMessage: "Missing command name"
            )
        }

        let resolution = await OwnerResolver.resolve(commandName: commandName, layout: layout)
        guard let active = resolution.active else {
            return StrategyPlan(
                ownerResolution: resolution,
                latestVersion: nil,
                updateCommandSpec: nil,
                blockReason: .unknownOwner,
                failureMessage: "Could not resolve active command path"
            )
        }

        let strategy = makeStrategy(config: config, resolution: resolution)
        guard let strategy else {
            return StrategyPlan(
                ownerResolution: resolution,
                latestVersion: nil,
                updateCommandSpec: nil,
                blockReason: .noStrategy,
                failureMessage: "No strategy for resolved owner"
            )
        }

        if hasOwnerMismatch(config: config, owner: active.owner) {
            return StrategyPlan(
                ownerResolution: resolution,
                latestVersion: nil,
                updateCommandSpec: nil,
                blockReason: .ownerMismatch,
                failureMessage: "Resolved owner does not match catalog package identity"
            )
        }

        let latest = await strategy.latestVersion(currentVersion: currentVersion)
        if latest == nil, strategy.requiresLatestVersion {
            return StrategyPlan(
                ownerResolution: resolution,
                latestVersion: nil,
                updateCommandSpec: nil,
                blockReason: nil,
                failureMessage: "Could not determine latest version"
            )
        }

        return StrategyPlan(
            ownerResolution: resolution,
            latestVersion: latest,
            updateCommandSpec: strategy.updateCommand(targetVersion: latest),
            blockReason: nil,
            failureMessage: nil
        )
    }

    static func plannedCommand(
        config: DetectorConfig,
        targetVersion: String?,
        layout: EcosystemLayout = .live()
    ) async -> (commandSpec: CommandSpec, fingerprint: String)? {
        guard config.command != nil || config.packages != nil || config.selfUpdater != nil else { return nil }
        guard let commandName = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !commandName.isEmpty else {
            return nil
        }
        let resolution = await OwnerResolver.resolve(commandName: commandName, layout: layout)
        guard let spec = commandForResolvedOwner(
            config: config,
            resolution: resolution,
            targetVersion: targetVersion
        ),
              let fingerprint = resolution.fingerprint else {
            return nil
        }
        return (spec, fingerprint)
    }

    static func commandForResolvedOwner(
        config: DetectorConfig,
        resolution: OwnerResolution,
        targetVersion: String?
    ) -> CommandSpec? {
        guard let strategy = makeStrategy(config: config, resolution: resolution) else {
            return nil
        }
        return strategy.updateCommand(targetVersion: targetVersion)
    }

    private static func makeStrategy(config: DetectorConfig, resolution: OwnerResolution) -> Strategy? {
        guard let active = resolution.active else { return nil }
        switch active.owner {
        case .brewFormula(let formula):
            let brew = brewExecutable(from: active.resolvedPath) ?? "/opt/homebrew/bin/brew"
            return BrewFormulaStrategy(formula: config.packages?.brew ?? formula, brewExecutable: brew)
        case .brewCask(let token):
            let brew = brewExecutable(from: active.resolvedPath) ?? "/opt/homebrew/bin/brew"
            let resolvedToken = config.packages?.brewCask ?? token
            return BrewCaskStrategy(token: resolvedToken, brewExecutable: brew, includeGreedyFlag: config.autoUpdates == true)
        case .npm(let prefix, let package):
            let npmPath = "\(prefix)/bin/npm"
            let resolvedPackage = config.packages?.npm ?? package
            return NpmPackageStrategy(package: resolvedPackage, npmExecutable: npmPath)
        case .nativeInstaller(let installer):
            guard installer == .claudeCode, config.selfUpdater == "claudeCode" else { return nil }
            return ClaudeNativeStrategy(executable: active.commandPath)
        case .pipx(let package):
            let pipxPath = "\(EcosystemLayout.live().homeDirectory)/.local/bin/pipx"
            return PipxStrategy(package: config.packages?.pipx ?? package, pipxExecutable: pipxPath)
        case .uvTool(let name):
            let uvPath = "\(EcosystemLayout.live().homeDirectory)/.local/bin/uv"
            return UvToolStrategy(name: config.packages?.uv ?? name, uvExecutable: uvPath)
        case .unknown:
            return nil
        }
    }

    private static func hasOwnerMismatch(config: DetectorConfig, owner: ResolvedOwner) -> Bool {
        let packages = config.packages
        switch owner {
        case .brewFormula(let formula):
            if let expected = packages?.brew { return expected != formula }
            return false
        case .brewCask(let token):
            if let expected = packages?.brewCask { return expected != token }
            return false
        case .npm(_, let package):
            if let expected = packages?.npm { return expected != package }
            return false
        case .pipx(let package):
            if let expected = packages?.pipx { return expected != package }
            return false
        case .uvTool(let name):
            if let expected = packages?.uv { return expected != name }
            return false
        case .nativeInstaller:
            return false
        case .unknown:
            return true
        }
    }

    private static func brewExecutable(from resolvedPath: String) -> String? {
        let marker = "/Cellar/"
        guard let markerRange = resolvedPath.range(of: marker) else { return nil }
        let prefix = String(resolvedPath[..<markerRange.lowerBound])
        guard !prefix.isEmpty else { return nil }
        return "\(prefix)/bin/brew"
    }
}

private protocol Strategy {
    var requiresLatestVersion: Bool { get }
    func latestVersion(currentVersion: String?) async -> String?
    func updateCommand(targetVersion: String?) -> CommandSpec?
}

private struct BrewFormulaStrategy: Strategy {
    let formula: String
    let brewExecutable: String
    let requiresLatestVersion = true

    func latestVersion(currentVersion: String?) async -> String? {
        let result = await ShellRunner.run(
            CommandSpec(executablePath: brewExecutable, arguments: ["info", "--json=v2", formula]),
            timeout: 30
        )
        guard result.succeeded, let data = result.stdout.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulas = root["formulae"] as? [[String: Any]],
              let first = formulas.first,
              let versions = first["versions"] as? [String: Any],
              let stable = versions["stable"] as? String,
              !stable.isEmpty else {
            return nil
        }
        return stable
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: brewExecutable, arguments: ["upgrade", formula])
    }
}

private struct BrewCaskStrategy: Strategy {
    let token: String
    let brewExecutable: String
    let includeGreedyFlag: Bool
    let requiresLatestVersion = true

    func latestVersion(currentVersion: String?) async -> String? {
        let result = await ShellRunner.run(
            CommandSpec(executablePath: brewExecutable, arguments: ["info", "--json=v2", "--cask", token]),
            timeout: 30
        )
        guard result.succeeded, let data = result.stdout.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let first = casks.first,
              let version = first["version"] as? String else {
            return nil
        }
        return version.components(separatedBy: ",").first?.nilIfEmpty
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        var args = ["upgrade", "--cask"]
        if includeGreedyFlag {
            args.append("--greedy")
        }
        args.append(token)
        return CommandSpec(executablePath: brewExecutable, arguments: args)
    }
}

private struct NpmPackageStrategy: Strategy {
    let package: String
    let npmExecutable: String
    let requiresLatestVersion = true

    func latestVersion(currentVersion: String?) async -> String? {
        let result = await ShellRunner.run(
            CommandSpec(executablePath: npmExecutable, arguments: ["view", package, "version"]),
            timeout: 30
        )
        guard result.succeeded else { return nil }
        return VersionTokenExtractor.extract(from: result.stdout) ?? result.stdout.nilIfEmpty
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        let pinned = targetVersion?.nilIfEmpty ?? "latest"
        return CommandSpec(
            executablePath: npmExecutable,
            arguments: ["install", "-g", "\(package)@\(pinned)"]
        )
    }
}

private struct PipxStrategy: Strategy {
    let package: String
    let pipxExecutable: String
    let requiresLatestVersion = false

    func latestVersion(currentVersion: String?) async -> String? {
        nil
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: pipxExecutable, arguments: ["upgrade", package])
    }
}

private struct UvToolStrategy: Strategy {
    let name: String
    let uvExecutable: String
    let requiresLatestVersion = false

    func latestVersion(currentVersion: String?) async -> String? {
        nil
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: uvExecutable, arguments: ["tool", "upgrade", name])
    }
}

private struct ClaudeNativeStrategy: Strategy {
    let executable: String
    let requiresLatestVersion = true

    func latestVersion(currentVersion: String?) async -> String? {
        let channel = claudeChannel()
        let field = "dist-tags.\(channel)"
        let result = await ShellRunner.run(
            CommandSpec(
                executablePath: "/opt/homebrew/bin/npm",
                arguments: ["view", "@anthropic-ai/claude-code", field]
            ),
            timeout: 30
        )
        guard result.succeeded else { return nil }
        return VersionTokenExtractor.extract(from: result.stdout) ?? result.stdout.nilIfEmpty
    }

    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: executable, arguments: ["update"])
    }

    private func claudeChannel() -> String {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "latest"
        }
        if let channel = root["channel"] as? String, !channel.isEmpty {
            return channel
        }
        if let updates = root["updates"] as? [String: Any],
           let channel = updates["channel"] as? String,
           !channel.isEmpty {
            return channel
        }
        return "latest"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
