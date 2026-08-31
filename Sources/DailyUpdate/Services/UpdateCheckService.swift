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

            if output.contains("UPDATE") || lower.contains("outdated") || lower.contains("behind") {
                let latest = parseLatest(from: output) ?? "newer"
                return (.updateAvailable, current, latest, nil)
            }

            if output.contains("OK") || lower.contains("up to date") || lower.contains("uptodate") {
                return (.upToDate, current, current, nil)
            }

            if result.succeeded, !output.isEmpty {
                return (.upToDate, current ?? output, current ?? output, nil)
            }

            if let parsed = parseLatest(from: output), !parsed.isEmpty {
                return (.updateAvailable, current, parsed, nil)
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
