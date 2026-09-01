import Foundation

enum DuplicateDetector {
    static func find(in items: [UpdateItem]) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        var byName: [String: [UpdateItem]] = [:]

        for item in items {
            let key = item.name.lowercased().trimmingCharacters(in: .whitespaces)
            byName[key, default: []].append(item)
        }

        for (_, group) in byName where group.count > 1 {
            groups.append(DuplicateGroup(
                id: group.map(\.id).joined(separator: "-"),
                itemIDs: group.map(\.id),
                reason: "Same name: \(group[0].name)"
            ))
        }

        let commandGroups = Dictionary(grouping: items.filter { !$0.updateCommand.isEmpty }) {
            normalizeCommand($0.updateCommand)
        }
        for (_, group) in commandGroups where group.count > 1 {
            let ids = group.map(\.id)
            if !groups.contains(where: { Set($0.itemIDs) == Set(ids) }) {
                groups.append(DuplicateGroup(
                    id: ids.joined(separator: "-"),
                    itemIDs: ids,
                    reason: "Similar update command"
                ))
            }
        }

        return groups
    }

    private static func normalizeCommand(_ command: String) -> String {
        command
            .replacingOccurrences(of: "brew upgrade --cask", with: "brew")
            .replacingOccurrences(of: "brew upgrade", with: "brew")
            .replacingOccurrences(of: "npm update -g", with: "npm")
            .replacingOccurrences(of: "npm install -g", with: "npm")
            .components(separatedBy: .whitespaces)
            .prefix(3)
            .joined(separator: " ")
            .lowercased()
    }
}

enum HealthCheckService {
    static func run(settings: UserSettings) async -> [HealthIssue] {
        var issues: [HealthIssue] = []

        let pathCheck = await ShellRunner.run("echo $PATH")
        if pathCheck.succeeded {
            let path = pathCheck.stdout
            if !path.contains("homebrew") && !path.contains("/opt/homebrew") && !path.contains("/usr/local/bin") {
                issues.append(HealthIssue(title: "Homebrew not in PATH", detail: "Install or add /opt/homebrew/bin to PATH", severity: .warning))
            }
        }

        for tool in ["git", "node", "npm", "brew"] {
            let result = await ShellRunner.run("command -v \(tool) >/dev/null 2>&1 && echo OK || echo MISSING")
            if result.stdout.contains("MISSING") {
                issues.append(HealthIssue(title: "\(tool) not found", detail: "\(tool) is not available in PATH", severity: .warning))
            }
        }

        for folder in settings.allScanFolders {
            let expanded = (folder as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: expanded) {
                issues.append(HealthIssue(title: "Missing scan folder", detail: expanded, severity: .error))
            }
        }

        let gitCheck = await ShellRunner.run("git config --global user.email >/dev/null 2>&1 && echo OK || echo MISSING")
        if gitCheck.stdout.contains("MISSING") {
            issues.append(HealthIssue(title: "Git email not configured", detail: "Run: git config --global user.email you@example.com", severity: .warning))
        }

        if issues.isEmpty {
            issues.append(HealthIssue(title: "All checks passed", detail: "PATH, tools, and folders look good", severity: .ok))
        }

        return issues
    }
}

enum RepoSafetyService {
    static func preflight(_ item: UpdateItem) async -> (safe: Bool, message: String?) {
        guard item.category == .repo, item.updateCommand.contains("git pull") || item.updateCommand.contains("git fetch") else {
            return (true, nil)
        }

        let cwd = item.workingDirectory?.expandingTilde ?? "."
        let status = await ShellRunner.run("git -C \(ShellEscaping.quote(cwd)) status --porcelain 2>/dev/null")
        guard status.succeeded else { return (true, nil) }

        if !status.stdout.isEmpty {
            return (false, "Uncommitted changes in repo. Commit, stash, or discard before updating.")
        }

        return (true, nil)
    }

    static func stashLocalChanges(_ item: UpdateItem) async -> String? {
        let cwd = item.workingDirectory?.expandingTilde ?? "."
        let stash = await ShellRunner.run("git -C \(ShellEscaping.quote(cwd)) stash push -m 'Daily Update auto-stash' 2>/dev/null")
        if stash.succeeded && !stash.stdout.isEmpty && !stash.stdout.contains("No local changes") {
            return "Stashed local changes before pull"
        }
        return nil
    }
}

enum ConfigImportExport {
    struct ExportBundle: Codable {
        let exportedAt: Date
        let settings: UserSettings
        let history: [UpdateHistoryEntry]
    }

    static func export(settings: UserSettings) throws -> Data {
        let bundle = ExportBundle(
            exportedAt: Date(),
            settings: settings,
            history: UpdateHistoryStore.load()
        )
        return try JSONEncoder().encode(bundle)
    }

    static func importData(_ data: Data, into store: UserSettingsStore) throws {
        let bundle = try JSONDecoder().decode(ExportBundle.self, from: data)
        store.settings = bundle.settings
        store.save()
        if let encoded = try? JSONEncoder().encode(bundle.history) {
            let url = ConfigLoader.appSupportDirectory.appendingPathComponent("history.json")
            try encoded.write(to: url, options: .atomic)
        }
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
