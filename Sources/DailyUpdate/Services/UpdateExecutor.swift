import Foundation

enum UpdateExecutor {
    struct Runner {
        let runCommand: @Sendable (String, String?, TimeInterval) async -> ShellRunner.Result
        let runSpec: @Sendable (CommandSpec, TimeInterval) async -> ShellRunner.Result
        /// A one-shot lookup for the post-update owner check, so a binary the update put
        /// earlier on `PATH` is seen instead of the check-time snapshot.
        let lookupCommand: @Sendable (String) async -> CommandPathLookup

        init(
            runCommand: @escaping @Sendable (String, String?, TimeInterval) async -> ShellRunner.Result,
            runSpec: @escaping @Sendable (CommandSpec, TimeInterval) async -> ShellRunner.Result,
            lookupCommand: @escaping @Sendable (String) async -> CommandPathLookup = { name in
                await OwnerResolver.lookup(commandNames: [name])
            }
        ) {
            self.runCommand = runCommand
            self.runSpec = runSpec
            self.lookupCommand = lookupCommand
        }

        static let live = Runner(
            runCommand: { command, directory, timeout in
                await ShellRunner.run(command, workingDirectory: directory, timeout: timeout)
            },
            runSpec: { spec, timeout in
                await ShellRunner.run(spec, timeout: timeout)
            }
        )
    }

    static func update(
        _ item: UpdateItem,
        installing: Bool = false,
        stashRepos: Bool = true,
        runner: Runner = .live,
        config: DetectorConfig? = nil,
        pathLookup: CommandPathLookup? = nil,
        reviewedCommandHash: String? = nil
    ) async -> UpdateResult {
        if installing {
            return await performInstall(item, using: runner)
        }
        guard item.isInstalled else {
            return .failed(reason: "Cannot update an item that is not installed", current: nil, latest: item.latestVersion)
        }
        return await performUpdate(item, stashRepos: stashRepos, using: runner,
            config: config ?? detectorConfig(from: item), pathLookup: pathLookup, reviewedCommandHash: reviewedCommandHash)
    }

    private static func performInstall(_ item: UpdateItem, using runner: Runner) async -> UpdateResult {
        let command = item.installCommand
        let result = await runner.runCommand(command, item.workingDirectory?.expandingTilde, 600)
        guard result.succeeded else {
            let reason = failureReason(from: result, action: "Install")
            return .failed(reason: reason, current: item.currentVersion, latest: item.latestVersion)
        }

        let version = await DetectionService.getVersion(detectorConfig(from: item))
        return .success(current: version, latest: version)
    }

    private static func performUpdate(
        _ item: UpdateItem,
        stashRepos: Bool,
        using runner: Runner,
        config: DetectorConfig,
        pathLookup: CommandPathLookup?,
        reviewedCommandHash: String?
    ) async -> UpdateResult {
        var notes: [String] = []

        if item.category == .repo {
            if stashRepos {
                if let stashNote = await RepoSafetyService.stashLocalChanges(item) {
                    notes.append(stashNote)
                }
            } else {
                let (safe, message) = await RepoSafetyService.preflight(item)
                if !safe, let message {
                    return .failed(reason: message, current: item.currentVersion, latest: item.latestVersion)
                }
            }
        }

        let typed = StrategyPlanner.usesTypedEngine(config: config)
        let before = typed ? await StrategyPlanner.currentVersion(config: config, pathLookup: pathLookup) : nil
        let beforeVersion = typed ? before?.version : await DetectionService.getVersion(config)
        let targetLatest = item.latestVersion
        let command = item.updateCommand
        let result: ShellRunner.Result
        if let commandSpec = item.plannedUpdateCommandSpec {
            result = await runner.runSpec(commandSpec, 600)
        } else {
            result = await runner.runCommand(command, item.workingDirectory?.expandingTilde, 600)
        }

        if !result.succeeded {
            let reason = failureReason(from: result, action: "Update")
            return .failed(reason: reason, current: beforeVersion, latest: targetLatest)
        }

        if let message = appUpdaterHandoffMessage(from: result.stdout) {
            return .pendingInApp(
                current: beforeVersion,
                latest: targetLatest,
                message: message
            )
        }

        if let guidance = result.stdout.nilIfEmpty, looksLikeGuidanceOnly(guidance) {
            return .failed(
                reason: guidance,
                current: beforeVersion,
                latest: targetLatest
            )
        }

        if usesInAppUpdateFlow(command) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }

        let afterLookup = typed ? await runner.lookupCommand(config.command ?? "") : pathLookup
        let check = await UpdateCheckService.check(config, installed: true,
            reviewedCommandHash: reviewedCommandHash, pathLookup: afterLookup)
        let afterVersion = typed ? check.currentVersion : await DetectionService.getVersion(config)
        if typed {
            let afterOwner = await OwnerResolver.resolve(commandName: config.command ?? "", lookup: afterLookup,
                layout: afterLookup?.layout ?? .live()).active
            guard let beforeOwner = before?.owner, let afterOwner,
                  beforeOwner.owner == afterOwner.owner, beforeOwner.commandPath == afterOwner.commandPath,
                  check.status == .upToDate else {
                return .failedVerification(current: afterVersion, latest: check.latestVersion,
                    reason: check.message ?? "Could not verify the same owner at the latest version")
            }
        }
        let latest = resolvedLatest(
            afterVersion: afterVersion,
            checkLatest: check.latestVersion,
            targetLatest: targetLatest,
            checkStatus: check.status
        )

        if usesInAppUpdateFlow(command), !versionChanged(from: beforeVersion, to: afterVersion) {
            return .pendingInApp(current: afterVersion ?? beforeVersion, latest: latest)
        }

        if VersionComparator.isAtLeast(current: afterVersion, latest: latest) {
            let note = notes.isEmpty ? nil : notes.joined(separator: "; ")
            return .success(current: afterVersion, latest: latest, note: note)
        }

        if versionChanged(from: beforeVersion, to: afterVersion) {
            let latestLabel = latest ?? "latest"
            return .failedVerification(
                current: afterVersion,
                latest: latest,
                reason: "Updated to \(afterVersion ?? "unknown") but latest is \(latestLabel)"
            )
        }

        if usesInAppUpdateFlow(command) {
            return .pendingInApp(current: afterVersion ?? beforeVersion, latest: latest)
        }

        if hasInAppFallback(command),
           check.status == .updateAvailable || check.status == .updatePending {
            return .pendingInApp(current: afterVersion ?? beforeVersion, latest: latest)
        }

        let latestLabel = latest ?? "unknown"
        let currentLabel = afterVersion ?? beforeVersion ?? "unknown"
        return .failedVerification(
            current: afterVersion ?? beforeVersion,
            latest: latest,
            reason: "Version still \(currentLabel) — latest is \(latestLabel). The update command may need to run outside Daily Update."
        )
    }

    private static func detectorConfig(from item: UpdateItem) -> DetectorConfig {
        DetectorConfig(
            id: item.id,
            name: item.name,
            category: item.category,
            description: item.description,
            source: item.source,
            command: item.command,
            packages: item.packages,
            selfUpdater: item.selfUpdater,
            appcastURL: item.appcastURL,
            autoUpdates: item.autoUpdates,
            detect: item.detectRule,
            versionCommand: item.versionCommand,
            versionPattern: item.versionPattern,
            checkCommand: item.checkCommand,
            installCommand: item.installCommand,
            updateCommand: item.updateCommand,
            workingDirectory: item.workingDirectory
        )
    }

    private static func resolvedLatest(
        afterVersion: String?,
        checkLatest: String?,
        targetLatest: String?,
        checkStatus: ItemStatus
    ) -> String? {
        if checkStatus == .upToDate {
            return afterVersion ?? checkLatest ?? targetLatest
        }
        return checkLatest ?? targetLatest ?? afterVersion
    }

    static func failureReason(from result: ShellRunner.Result, action: String) -> String {
        if result.exitCode == 15 {
            return "\(action) timed out after 10 minutes. Check your network connection and try again."
        }
        let details = [result.stderr, result.stdout]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let lower = details.lowercased()
        if lower.contains("sudo: a terminal is required") || lower.contains("sudo: a password is required") {
            return "\(action) needs an administrator password. Run it from Terminal, then try again."
        }
        if lower.contains("ebadengine") || lower.contains("unsupported engine") {
            return "\(action) requires a newer Node.js version before this package can be updated."
        }
        if lower.contains("eacces") || lower.contains("permission denied") {
            return "\(action) needs permission to modify the installed files. Run it from Terminal with administrator rights."
        }
        if let stderr = result.stderr.nilIfEmpty {
            return stderr
        }
        if let stdout = result.stdout.nilIfEmpty {
            return stdout
        }
        return "\(action) failed (exit \(result.exitCode))"
    }

    private static func appUpdaterHandoffMessage(from output: String) -> String? {
        let marker = "IN_APP_UPDATE:"
        guard let range = output.range(of: marker) else { return nil }
        return String(output[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func versionChanged(from before: String?, to after: String?) -> Bool {
        guard let after, !after.isEmpty else { return false }
        guard let before, !before.isEmpty else { return true }
        return VersionComparator.normalize(before) != VersionComparator.normalize(after)
    }

    private static func usesInAppUpdateFlow(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("if brew"), hasInAppFallback(command) {
            return false
        }
        let primary = command.components(separatedBy: "||").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? lower
        if primary.contains("open -a") || primary.contains("open \"-a") || primary.hasPrefix("open ") {
            return true
        }
        return primary.contains("macappstore://") || primary.contains("apps.apple.com")
    }

    private static func hasInAppFallback(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("|| open -a") ||
            lower.contains("|| open ") ||
            lower.contains("else open -a") ||
            lower.contains("else open ")
    }

    private static func looksLikeGuidanceOnly(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("reinstall:") ||
            lower.contains("update via") ||
            lower.contains("not found") ||
            lower.contains("add path in settings")
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
