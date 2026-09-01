import Foundation

enum UpdateExecutor {
    static func update(_ item: UpdateItem, installing: Bool = false, stashRepos: Bool = true) async -> UpdateResult {
        if installing || !item.isInstalled {
            return await performInstall(item, stashRepos: stashRepos)
        }
        return await performUpdate(item, stashRepos: stashRepos)
    }

    private static func performInstall(_ item: UpdateItem, stashRepos: Bool) async -> UpdateResult {
        var notes: [String] = []

        if stashRepos, item.category == .repo {
            let (safe, message) = await RepoSafetyService.preflight(item)
            if !safe, let message {
                return .failed(reason: message, current: item.currentVersion, latest: item.latestVersion)
            }
            if let stashNote = await RepoSafetyService.stashAndPull(item) {
                notes.append(stashNote)
            }
        }

        let command = item.installCommand
        let result = await ShellRunner.run(command, workingDirectory: item.workingDirectory?.expandingTilde, timeout: 600)
        guard result.succeeded else {
            let reason = failureReason(from: result, action: "Install")
            return .failed(reason: reason, current: item.currentVersion, latest: item.latestVersion)
        }

        let version = await DetectionService.getVersion(detectorConfig(from: item))
        let note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        return .success(current: version, latest: version, note: note)
    }

    private static func performUpdate(_ item: UpdateItem, stashRepos: Bool) async -> UpdateResult {
        var notes: [String] = []

        if stashRepos, item.category == .repo {
            let (safe, message) = await RepoSafetyService.preflight(item)
            if !safe, let message {
                return .failed(reason: message, current: item.currentVersion, latest: item.latestVersion)
            }
            if let stashNote = await RepoSafetyService.stashAndPull(item) {
                notes.append(stashNote)
            }
        }

        let config = detectorConfig(from: item)
        let beforeVersion = await DetectionService.getVersion(config)
        let targetLatest = item.latestVersion
        let command = item.updateCommand
        let result = await ShellRunner.run(command, workingDirectory: item.workingDirectory?.expandingTilde, timeout: 600)

        if !result.succeeded {
            let reason = failureReason(from: result, action: "Update")
            return .failed(reason: reason, current: beforeVersion, latest: targetLatest)
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

        let afterVersion = await DetectionService.getVersion(config)
        let (checkStatus, _, refreshedLatest, _) = await UpdateCheckService.check(config, installed: true)
        let latest = resolvedLatest(
            afterVersion: afterVersion,
            checkLatest: refreshedLatest,
            targetLatest: targetLatest,
            checkStatus: checkStatus
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
            return .stillBehind(
                current: afterVersion,
                latest: latest,
                reason: "Updated to \(afterVersion ?? "unknown") but latest is \(latestLabel)"
            )
        }

        if usesInAppUpdateFlow(command) {
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

    private static func failureReason(from result: ShellRunner.Result, action: String) -> String {
        if let stderr = result.stderr.nilIfEmpty {
            return stderr
        }
        if let stdout = result.stdout.nilIfEmpty {
            return stdout
        }
        return "\(action) failed (exit \(result.exitCode))"
    }

    private static func versionChanged(from before: String?, to after: String?) -> Bool {
        guard let after, !after.isEmpty else { return false }
        guard let before, !before.isEmpty else { return true }
        return VersionComparator.normalize(before) != VersionComparator.normalize(after)
    }

    private static func usesInAppUpdateFlow(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("open -a") || lower.contains("open \"-a") {
            return true
        }
        if lower.contains("macappstore://") || lower.contains("apps.apple.com") {
            return true
        }
        return false
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
