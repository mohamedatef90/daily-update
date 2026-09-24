import Foundation

enum UpdateCheckService {
    /// Returns (status, currentVersion, latestVersion, message)
    static func check(_ config: DetectorConfig, installed: Bool) async -> (ItemStatus, String?, String?, String?) {
        guard installed else {
            return (.notInstalled, nil, nil, "Not installed")
        }

        let cwd = config.workingDirectory?.expandingTilde
        let currentRaw = await DetectionService.getVersion(config)
        let current = currentRaw.flatMap(VersionTokenExtractor.extract)

        if current == nil, config.versionCommand != nil {
            return (.checkFailed, currentRaw, nil, "Version command returned no version token")
        }

        if let checkCommand = config.checkCommand {
            let result = await ShellRunner.run(checkCommand, workingDirectory: cwd)
            let output = result.stdout
            let combined = [result.stdout, result.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let lower = output.lowercased()

            if !result.succeeded {
                let detail = result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty
                return (.checkFailed, current, nil, detail ?? "Check command failed")
            }

            if lower.hasPrefix("manual:") {
                let message = output
                    .dropFirst("manual:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (.unknown, current, nil, message.nilIfEmpty ?? "Check manually")
            }

            if let explicitCheckFailure = checkFailureMarker(in: output) {
                return (.checkFailed, current, nil, explicitCheckFailure)
            }

            if combined.lowercased().contains("broken") {
                let latest = parseLatest(from: combined)
                return (.checkFailed, current, latest, "Install appears broken")
            }

            if output.contains("UPDATE") || lower.contains("outdated") || lower.contains("behind") {
                let latest = parseLatest(from: output)
                return reconcileUpdateSignal(
                    current: current,
                    latest: latest,
                    rawIndicatesUpdate: true
                )
            }

            if output.contains("OK") || lower.contains("up to date") || lower.contains("uptodate") {
                let latest = parseLatest(from: output) ?? current
                return (.upToDate, current, latest ?? current, nil)
            }

            if let parsed = parseLatest(from: output), !parsed.isEmpty {
                return reconcileUpdateSignal(
                    current: current,
                    latest: parsed,
                    rawIndicatesUpdate: true
                )
            }

            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (.checkFailed, current, nil, "Check returned no status")
            }

            return (.checkFailed, current, nil, "Unrecognized check output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        if let current {
            return (.upToDate, current, current, nil)
        }
        return (.unknown, nil, nil, "No check configured")
    }

    /// When both versions are known, trust numeric comparison over raw script output.
    private static func reconcileUpdateSignal(
        current: String?,
        latest: String?,
        rawIndicatesUpdate: Bool
    ) -> (ItemStatus, String?, String?, String?) {
        guard rawIndicatesUpdate else {
            return (.upToDate, current, latest ?? current, nil)
        }

        if let current, let latest, isConcreteVersion(latest) {
            switch VersionComparator.compare(current: current, latest: latest) {
            case .same, .newer:
                return (.upToDate, current, latest, nil)
            case .older:
                return (.updateAvailable, current, latest, nil)
            case .incomparable:
                return (.checkFailed, current, latest, "Could not compare \(current) with \(latest)")
            }
        }

        // A detector explicitly reporting UPDATE is authoritative even when its
        // upstream source does not expose a concrete version number.
        return (
            .updateAvailable,
            current,
            latest,
            latest == nil ? "Update available (latest version not reported)" : nil
        )
    }

    private static func isConcreteVersion(_ value: String) -> Bool {
        VersionTokenExtractor.extract(from: value) != nil
    }

    private static func parseLatest(from output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("latest:") || lower.contains("remote:") || lower.contains("→") {
                let parsed = line
                    .replacingOccurrences(of: "latest:", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "remote:", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let token = VersionTokenExtractor.extract(from: parsed) {
                    return token
                }
                return parsed.nilIfEmpty
            }
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
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
