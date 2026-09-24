import Foundation

struct CheckResult {
    var status: ItemStatus
    var currentVersion: String?
    var currentVersionRaw: String?
    var latestVersion: String?
    var message: String?
    var gateReasons: [GateReason]
    var blockReason: BlockReason?
}

enum UpdateCheckService {
    static func check(_ config: DetectorConfig, installed: Bool, reviewedCommandHash: String? = nil) async -> CheckResult {
        guard installed else {
            return CheckResult(
                status: .notInstalled,
                currentVersion: nil,
                currentVersionRaw: nil,
                latestVersion: nil,
                message: "Not installed",
                gateReasons: [],
                blockReason: nil
            )
        }

        if let versionPattern = config.versionPattern {
            do {
                try VersionTokenExtractor.validate(pattern: versionPattern)
            } catch {
                return CheckResult(
                    status: .checkFailed,
                    currentVersion: nil,
                    currentVersionRaw: nil,
                    latestVersion: nil,
                    message: "Invalid version pattern for \(config.id)",
                    gateReasons: [],
                    blockReason: nil
                )
            }
        }

        let cwd = config.workingDirectory?.expandingTilde
        let versionOutcome = await DetectionService.getVersionOutcome(config)
        if versionOutcome.blockReason == .unsafeCheckCommand {
            return CheckResult(
                status: .blocked,
                currentVersion: nil,
                currentVersionRaw: nil,
                latestVersion: nil,
                message: "Blocked unsafe version command",
                gateReasons: [],
                blockReason: .unsafeCheckCommand
            )
        }
        let currentRaw = versionOutcome.value
        let current = currentRaw.flatMap { VersionTokenExtractor.extract(from: $0, pattern: config.versionPattern) }

        if current == nil, config.versionCommand != nil {
            return CheckResult(
                status: .checkFailed,
                currentVersion: nil,
                currentVersionRaw: currentRaw,
                latestVersion: nil,
                message: "Version command returned no version token",
                gateReasons: [],
                blockReason: nil
            )
        }

        if let checkCommand = config.checkCommand {
            if GatePolicy.isUnsafeCheckPathCommand(checkCommand: checkCommand, updateCommand: config.updateCommand) {
                return CheckResult(
                    status: .blocked,
                    currentVersion: current,
                    currentVersionRaw: currentRaw,
                    latestVersion: nil,
                    message: "Blocked unsafe check command",
                    gateReasons: [],
                    blockReason: .unsafeCheckCommand
                )
            }

            let result = await ShellRunner.run(checkCommand, workingDirectory: cwd)
            let output = result.stdout
            let combined = [result.stdout, result.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let lower = output.lowercased()

            if !result.succeeded {
                let detail = result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty
                return CheckResult(
                    status: .checkFailed,
                    currentVersion: current,
                    currentVersionRaw: currentRaw,
                    latestVersion: nil,
                    message: detail ?? "Check command failed",
                    gateReasons: [],
                    blockReason: nil
                )
            }

            if lower.hasPrefix("manual:") {
                let message = output
                    .dropFirst("manual:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return CheckResult(
                    status: .unknown,
                    currentVersion: current,
                    currentVersionRaw: currentRaw,
                    latestVersion: nil,
                    message: message.nilIfEmpty ?? "Check manually",
                    gateReasons: [],
                    blockReason: nil
                )
            }

            if let explicitCheckFailure = checkFailureMarker(in: output) {
                return CheckResult(
                    status: .checkFailed,
                    currentVersion: current,
                    currentVersionRaw: currentRaw,
                    latestVersion: nil,
                    message: explicitCheckFailure,
                    gateReasons: [],
                    blockReason: nil
                )
            }

            let parsedCurrent = parseCurrent(from: output, pattern: config.versionPattern) ?? current
            let parsedLatest = parseLatest(from: output, pattern: config.versionPattern)

            if combined.lowercased().contains("broken") {
                return CheckResult(
                    status: .checkFailed,
                    currentVersion: parsedCurrent,
                    currentVersionRaw: currentRaw,
                    latestVersion: parsedLatest,
                    message: "Install appears broken",
                    gateReasons: [],
                    blockReason: nil
                )
            }

            if output.contains("UPDATE") || lower.contains("outdated") || lower.contains("behind") {
                return reconcileUpdateSignal(
                    config: config,
                    current: parsedCurrent,
                    currentRaw: currentRaw,
                    latest: parsedLatest,
                    rawIndicatesUpdate: true,
                    reviewedCommandHash: reviewedCommandHash
                )
            }

            if output.contains("OK") || lower.contains("up to date") || lower.contains("uptodate") {
                let latest = parsedLatest ?? parsedCurrent
                return CheckResult(
                    status: .upToDate,
                    currentVersion: parsedCurrent,
                    currentVersionRaw: currentRaw,
                    latestVersion: latest ?? parsedCurrent,
                    message: nil,
                    gateReasons: [],
                    blockReason: nil
                )
            }

            if let parsedLatest, !parsedLatest.isEmpty {
                return reconcileUpdateSignal(
                    config: config,
                    current: parsedCurrent,
                    currentRaw: currentRaw,
                    latest: parsedLatest,
                    rawIndicatesUpdate: true,
                    reviewedCommandHash: reviewedCommandHash
                )
            }

            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return CheckResult(
                    status: .checkFailed,
                    currentVersion: parsedCurrent,
                    currentVersionRaw: currentRaw,
                    latestVersion: nil,
                    message: "Check returned no status",
                    gateReasons: [],
                    blockReason: nil
                )
            }

            return CheckResult(
                status: .checkFailed,
                currentVersion: parsedCurrent,
                currentVersionRaw: currentRaw,
                latestVersion: parsedLatest,
                message: "Unrecognized check output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))",
                gateReasons: [],
                blockReason: nil
            )
        }

        if let current {
            return CheckResult(
                status: .upToDate,
                currentVersion: current,
                currentVersionRaw: currentRaw,
                latestVersion: current,
                message: nil,
                gateReasons: [],
                blockReason: nil
            )
        }
        return CheckResult(
            status: .unknown,
            currentVersion: nil,
            currentVersionRaw: currentRaw,
            latestVersion: nil,
            message: "No check configured",
            gateReasons: [],
            blockReason: nil
        )
    }

    private static func reconcileUpdateSignal(
        config: DetectorConfig,
        current: String?,
        currentRaw: String?,
        latest: String?,
        rawIndicatesUpdate: Bool,
        reviewedCommandHash: String?
    ) -> CheckResult {
        guard rawIndicatesUpdate else {
            return CheckResult(
                status: .upToDate,
                currentVersion: current,
                currentVersionRaw: currentRaw,
                latestVersion: latest ?? current,
                message: nil,
                gateReasons: [],
                blockReason: nil
            )
        }

        if let current, let latest, isConcreteVersion(latest) {
            switch VersionComparator.compare(current: current, latest: latest) {
            case .same, .newer:
                return CheckResult(
                    status: .upToDate,
                    currentVersion: current,
                    currentVersionRaw: currentRaw,
                    latestVersion: latest,
                    message: nil,
                    gateReasons: [],
                    blockReason: nil
                )
            case .older:
                return gatedOrUpdatableResult(
                    config: config,
                    current: current,
                    currentRaw: currentRaw,
                    latest: latest,
                    reviewedCommandHash: reviewedCommandHash
                )
            case .incomparable:
                return CheckResult(
                    status: .checkFailed,
                    currentVersion: current,
                    currentVersionRaw: currentRaw,
                    latestVersion: latest,
                    message: "Could not compare \(current) with \(latest)",
                    gateReasons: [],
                    blockReason: nil
                )
            }
        }

        return gatedOrUpdatableResult(
            config: config,
            current: current,
            currentRaw: currentRaw,
            latest: latest,
            fallbackMessage: latest == nil ? "Update available (latest version not reported)" : nil,
            reviewedCommandHash: reviewedCommandHash
        )
    }

    private static func isConcreteVersion(_ value: String) -> Bool {
        VersionTokenExtractor.extract(from: value) != nil
    }

    private static func parseLatest(from output: String, pattern: String?) -> String? {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("latest:") || lower.contains("remote:") || lower.contains("→") {
                let parsed = line
                    .replacingOccurrences(of: "latest:", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "remote:", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let token = VersionTokenExtractor.extract(from: parsed, pattern: pattern) {
                    return token
                }
                return parsed.nilIfEmpty
            }
        }
        return nil
    }

    private static func parseCurrent(from output: String, pattern: String?) -> String? {
        for line in output.components(separatedBy: .newlines) {
            guard line.lowercased().contains("current:") else { continue }
            let value = line
                .replacingOccurrences(of: "current:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let token = VersionTokenExtractor.extract(from: value, pattern: pattern) {
                return token
            }
            return value.nilIfEmpty
        }
        return nil
    }

    private static func checkFailureMarker(in output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("CHECK_FAILED:") else { continue }
            let message = trimmed
                .dropFirst("CHECK_FAILED:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message.nilIfEmpty ?? "Check failed"
        }
        return nil
    }

    private static func gatedOrUpdatableResult(
        config: DetectorConfig,
        current: String?,
        currentRaw: String?,
        latest: String?,
        fallbackMessage: String? = nil,
        reviewedCommandHash: String?
    ) -> CheckResult {
        let gateReasons = GatePolicy.updateGateReasons(for: config, reviewedHash: reviewedCommandHash)

        if !gateReasons.isEmpty {
            let labels = gateReasons.map(\.label).joined(separator: ", ")
            return CheckResult(
                status: .gated,
                currentVersion: current,
                currentVersionRaw: currentRaw,
                latestVersion: latest,
                message: "Gated: \(labels)",
                gateReasons: gateReasons,
                blockReason: nil
            )
        }

        return CheckResult(
            status: .updateAvailable,
            currentVersion: current,
            currentVersionRaw: currentRaw,
            latestVersion: latest,
            message: fallbackMessage,
            gateReasons: [],
            blockReason: nil
        )
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
