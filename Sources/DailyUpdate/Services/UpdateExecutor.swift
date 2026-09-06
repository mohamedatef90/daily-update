import Foundation

enum UpdateExecutor {
    typealias CommandRunner = @Sendable (String, String?, TimeInterval) async -> ShellRunner.Result

    static func update(
        _ item: UpdateItem,
        installing: Bool = false,
        stashRepos: Bool = true,
        withAdministratorPrivileges: Bool = false
    ) async -> UpdateResult {
        let runner: CommandRunner
        if withAdministratorPrivileges {
            runner = { command, directory, timeout in
                await AdminCommandRunner.run(command, workingDirectory: directory, timeout: timeout)
            }
        } else {
            runner = { command, directory, timeout in
                await ShellRunner.run(command, workingDirectory: directory, timeout: timeout)
            }
        }
        if installing || !item.isInstalled {
            return await performInstall(item, using: runner)
        }
        return await performUpdate(item, stashRepos: stashRepos, using: runner)
    }

    private static func performInstall(_ item: UpdateItem, using runner: CommandRunner) async -> UpdateResult {
        let command = item.installCommand
        let result = await runner(command, item.workingDirectory?.expandingTilde, 600)
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
        using runner: CommandRunner
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

        let config = detectorConfig(from: item)
        let beforeVersion = await DetectionService.getVersion(config)
        let targetLatest = item.latestVersion
        let command = item.updateCommand
        let result = await runner(command, item.workingDirectory?.expandingTilde, 600)

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

        if UpdateCommandSemantics.usesInAppUpdateFlow(command) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }

        let afterVersion = await DetectionService.getVersion(config)
        let (checkStatus, _, refreshedLatest, _) = await UpdateCheckService.check(config, installed: true)
        let latest = resolvedLatest(
            afterVersion: afterVersion,
            checkLatest: refreshedLatest,
            targetLatest: targetLatest,
            checkStatus: checkStatus
        )

        if UpdateCommandSemantics.usesInAppUpdateFlow(command), !versionChanged(from: beforeVersion, to: afterVersion) {
            return .pendingInApp(current: afterVersion ?? beforeVersion, latest: latest)
        }

        if VersionComparator.isAtLeast(current: afterVersion, latest: latest) {
            let note = notes.isEmpty ? nil : notes.joined(separator: "; ")
            return .success(current: afterVersion, latest: latest, note: note)
        }

        if versionChanged(from: beforeVersion, to: afterVersion) {
            let latestLabel = latest ?? "latest"
            return .stillBehind(
                current: afterVersion,
                latest: latest,
                reason: "Updated to \(afterVersion ?? "unknown") but latest is \(latestLabel)"
            )
        }

        if UpdateCommandSemantics.usesInAppUpdateFlow(command) {
            return .pendingInApp(current: afterVersion ?? beforeVersion, latest: latest)
        }

        if UpdateCommandSemantics.hasInAppFallback(command),
           checkStatus == .updateAvailable || checkStatus == .updatePending {
            return .pendingInApp(current: afterVersion ?? beforeVersion, latest: latest)
        }

        let latestLabel = latest ?? "unknown"
        let currentLabel = afterVersion ?? beforeVersion ?? "unknown"
        return .stillBehind(
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
            detect: nil,
            versionCommand: item.versionCommand,
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
