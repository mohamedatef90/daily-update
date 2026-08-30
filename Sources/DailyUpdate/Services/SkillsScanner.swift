import Foundation

struct SkillScanOptions {
    let scanPluginCaches: Bool
    let skillRoots: [String]
}

enum SkillsScanner {
    static let defaultSkillRoots = [
        "~/.agents/skills",
        "~/.cursor/skills",
        "~/.cursor/skills-cursor",
        "~/.claude/skills",
        "~/.cursor/plugins/cache",
        "~/.claude/plugins/cache",
        "~/.cursor/plugins/marketplaces"
    ]

    static func discoverSkillItems(
        excludingPaths: Set<String>,
        options: SkillScanOptions
    ) -> [DetectorConfig] {
        var results: [DetectorConfig] = []
        var seenPaths: Set<String> = []

        for root in options.skillRoots {
            let expanded = root.expandingTilde
            guard FileManager.default.fileExists(atPath: expanded) else { continue }

            if expanded.contains("plugins/cache") || expanded.contains("plugins/marketplaces") {
                guard options.scanPluginCaches else { continue }
                discoverGitRepos(in: expanded, maxDepth: 4, excludingPaths: excludingPaths,
                                 results: &results, seenPaths: &seenPaths, label: "plugin")
            } else {
                discoverSkillFolders(in: expanded, excludingPaths: excludingPaths,
                                     results: &results, seenPaths: &seenPaths)
            }
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func discoverSkillFolders(
        in root: String,
        excludingPaths: Set<String>,
        results: inout [DetectorConfig],
        seenPaths: inout Set<String>
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }

        for entry in entries {
            if entry.hasPrefix(".") { continue }
            let path = (root as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }

            let skillFile = (path as NSString).appendingPathComponent("SKILL.md")
            let hasSkill = FileManager.default.fileExists(atPath: skillFile)
            let hasGit = FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))

            if hasGit, !excludingPaths.contains(path), !seenPaths.contains(path) {
                seenPaths.insert(path)
                let name = hasSkill ? skillDisplayName(at: path, fallback: entry) : entry
                results.append(ItemBuilder.discoveredSkill(path: path, name: name, kind: "Agent skill"))
            }
        }
    }

    private static func discoverGitRepos(
        in root: String,
        maxDepth: Int,
        excludingPaths: Set<String>,
        results: inout [DetectorConfig],
        seenPaths: inout Set<String>,
        label: String,
        depth: Int = 0
    ) {
        let gitPath = (root as NSString).appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitPath) {
            if !RepoScanner.isSDKInstallation(root), !excludingPaths.contains(root), !seenPaths.contains(root) {
                seenPaths.insert(root)
                let name = pluginDisplayName(for: root)
                results.append(ItemBuilder.discoveredSkill(path: root, name: name, kind: "Cursor/Claude plugin"))
            }
            return
        }

        guard depth < maxDepth else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }

        for entry in entries {
            if entry.hasPrefix(".") { continue }
            let subpath = (root as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: subpath, isDirectory: &isDir), isDir.boolValue else { continue }
            discoverGitRepos(in: subpath, maxDepth: maxDepth, excludingPaths: excludingPaths,
                               results: &results, seenPaths: &seenPaths, label: label, depth: depth + 1)
        }
    }

    private static func skillDisplayName(at path: String, fallback: String) -> String {
        let skillFile = (path as NSString).appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOfFile: skillFile, encoding: .utf8) else { return fallback }
        for line in content.components(separatedBy: .newlines).prefix(10) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                return trimmed.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return fallback
    }

    private static func pluginDisplayName(for path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        if let skillsIndex = components.lastIndex(where: { $0 == "skills" || $0 == "cache" || $0 == "marketplaces" }),
           skillsIndex + 1 < components.count {
            let nameParts = components[(skillsIndex + 1)...].filter { $0.count != 40 || !$0.allSatisfy(\.isHexDigit) }
            if let first = nameParts.first {
                return first.replacingOccurrences(of: "-", with: " ").capitalized + " (plugin)"
            }
        }
        return URL(fileURLWithPath: path).lastPathComponent + " (plugin)"
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
