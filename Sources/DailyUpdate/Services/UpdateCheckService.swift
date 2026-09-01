import Foundation

enum UpdateCheckService {
    /// Returns (status, currentVersion, latestVersion, message)
    static func check(_ config: DetectorConfig, installed: Bool) async -> (ItemStatus, String?, String?, String?) {
        guard installed else {
            return (.notInstalled, nil, nil, "Not installed")
        }

        let cwd = config.workingDirectory?.expandingTilde
        let current = await DetectionService.getVersion(config)

        if let checkCommand = config.checkCommand {
            let result = await ShellRunner.run(checkCommand, workingDirectory: cwd)
            let output = result.stdout
            let combined = [result.stdout, result.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let lower = output.lowercased()
            let combinedLower = combined.lowercased()

            if combinedLower.contains("broken") {
                let latest = parseLatest(from: combined)
                return (.error, current, latest, "Install broken — select Update to reinstall")
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

            if result.succeeded, !output.isEmpty {
                return (.upToDate, current ?? output, current ?? output, nil)
            }

            if let parsed = parseLatest(from: output), !parsed.isEmpty {
                return reconcileUpdateSignal(
                    current: current,
                    latest: parsed,
                    rawIndicatesUpdate: true
                )
            }

            let detail = result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty
            if let detail, detail.lowercased().contains("parse error") {
                return (.error, current, nil, "Check script misconfigured — rebuild the app")
            }

            return (.error, current, nil, detail ?? "Check failed")
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
            if VersionComparator.isAtLeast(current: current, latest: latest) {
                return (.upToDate, current, latest, nil)
            }
            return (.updateAvailable, current, latest, nil)
        }

        if let current, !current.isEmpty {
            // Script reported UPDATE but we cannot parse a concrete latest — avoid false positives.
            return (.upToDate, current, current, nil)
        }

        return (.updateAvailable, current, latest, nil)
    }

    private static func isConcreteVersion(_ value: String) -> Bool {
        let normalized = VersionComparator.normalize(value)
        return normalized.contains(where: \.isNumber)
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
                return parsed.nilIfEmpty
            }
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
