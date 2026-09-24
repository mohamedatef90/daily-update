import Foundation

enum UpdateCheckService {
    /// Detector-script update discoveries stay audit-only until the item has a typed,
    /// owner-aware strategy with independent post-update verification.
    static func legacyUpdateStatus(updateCommand _: String) -> ItemStatus {
        .gated
    }

    private static func legacyUpdateMessage(updateCommand _: String) -> String? {
        "Gated: update detected, but this legacy item has no typed owner-aware update strategy and independent verification"
    }

    /// Returns (status, currentVersion, latestVersion, message)
    static func check(_ config: DetectorConfig, installed: Bool) async -> (ItemStatus, String?, String?, String?) {
        guard installed else {
            return (.notInstalled, nil, nil, "Not installed")
        }

        let cwd = config.workingDirectory?.expandingTilde

        if let strategy = DeveloperCLIStrategy.strategy(for: config.id) {
            let audit = await DeveloperCLIAuditService.audit(strategy)
            switch audit.outcome {
            case .current:
                return (itemStatus(for: audit.outcome), audit.currentVersion, audit.latestVersion ?? audit.currentVersion, audit.statusMessage)
            case .updateAvailable:
                return (itemStatus(for: audit.outcome), audit.currentVersion, audit.latestVersion, audit.statusMessage)
            case .gated:
                return (itemStatus(for: audit.outcome), audit.currentVersion, audit.latestVersion, "Gated: \(audit.statusMessage)")
            case .blocked:
                return (itemStatus(for: audit.outcome), audit.currentVersion, audit.latestVersion, "Blocked: \(audit.statusMessage)")
            case .checkFailed:
                return (itemStatus(for: audit.outcome), audit.currentVersion, nil, "Check failed: \(audit.statusMessage)")
            case .notInstalled:
                return (itemStatus(for: audit.outcome), nil, nil, audit.statusMessage)
            case .updated:
                return (itemStatus(for: audit.outcome), audit.currentVersion, audit.latestVersion, audit.statusMessage)
            case .failedVerification:
                return (itemStatus(for: audit.outcome), audit.currentVersion, audit.latestVersion, "Failed Verification: \(audit.statusMessage)")
            }
        }

        let current = await DetectionService.getVersion(config)

        if let checkCommand = config.checkCommand {
            // npm otherwise favors its local metadata cache; prefer a live registry lookup.
            let result = await ShellRunner.run(
                checkCommand,
                workingDirectory: cwd,
                environment: ["npm_config_prefer_online": "true"]
            )
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

            if combinedLower.contains("check_failed") {
                let detail = result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty
                return (.error, current, nil, detail ?? "Could not verify the latest available version")
            }

            if output.contains("UPDATE") || lower.contains("outdated") || lower.contains("behind") {
                let latest = parseLatest(from: output) ?? "newer"
                return (legacyUpdateStatus(updateCommand: config.updateCommand), current, latest, legacyUpdateMessage(updateCommand: config.updateCommand))
            }

            if output.contains("OK") || lower.contains("up to date") || lower.contains("uptodate") {
                return (.upToDate, current, current, nil)
            }

            if result.succeeded, !output.isEmpty {
                return (.error, current, nil, "Unrecognized check output; refusing to assume the item is current")
            }

            if let parsed = parseLatest(from: output), !parsed.isEmpty {
                return (legacyUpdateStatus(updateCommand: config.updateCommand), current, parsed, legacyUpdateMessage(updateCommand: config.updateCommand))
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

    static func itemStatus(for outcome: AuditOutcome) -> ItemStatus {
        switch outcome {
        case .current: return .upToDate
        case .updateAvailable: return .updateAvailable
        case .updated: return .updated
        case .gated: return .gated
        case .blocked: return .blocked
        case .failedVerification: return .failedVerification
        case .checkFailed: return .error
        case .notInstalled: return .notInstalled
        }
    }

    private static func parseLatest(from output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("latest:") || lower.contains("remote:") || lower.contains("→") {
                return line
                    .replacingOccurrences(of: "latest:", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "remote:", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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
