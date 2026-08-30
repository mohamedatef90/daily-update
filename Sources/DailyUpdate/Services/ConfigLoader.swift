import Foundation

enum ConfigLoader {
    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("DailyUpdate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var userConfigURL: URL {
        appSupportDirectory.appendingPathComponent("detectors.json")
    }

    static func loadConfigs(
        settings: UserSettings,
        discoveredRepos: [DetectorConfig] = [],
        discoveredApps: [DetectorConfig] = [],
        discoveredSkills: [DetectorConfig] = []
    ) -> [DetectorConfig] {
        var configs: [DetectorConfig] = []
        var byID: [String: DetectorConfig] = [:]

        if let bundled = loadBundledConfigs() {
            for var item in bundled {
                item = expandConfig(item, settings: settings)
                byID[item.id] = item
            }
        }

        if let legacyUser = loadLegacyUserConfigs() {
            for item in legacyUser where byID[item.id] == nil {
                byID[item.id] = expandConfig(item, settings: settings)
            }
        }

        for item in settings.customItems {
            byID[item.id] = expandConfig(item, settings: settings)
        }

        for item in discoveredRepos where byID[item.id] == nil {
            byID[item.id] = expandConfig(item, settings: settings)
        }

        for item in discoveredApps where byID[item.id] == nil {
            byID[item.id] = expandConfig(item, settings: settings)
        }

        for item in discoveredSkills where byID[item.id] == nil {
            byID[item.id] = expandConfig(item, settings: settings)
        }

        configs = Array(byID.values)
        configs = configs.filter { !settings.disabledItemIDs.contains($0.id) }

        return configs.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func knownAppPaths(from configs: [DetectorConfig]) -> Set<String> {
        var paths = Set<String>()
        for config in configs where config.category == .app {
            config.detect?.paths?.forEach { paths.insert($0.expandingTilde) }
        }
        return paths
    }

    static func knownItemPaths(from configs: [DetectorConfig]) -> Set<String> {
        var paths = Set<String>()
        for config in configs {
            config.detect?.paths?.forEach { paths.insert($0.expandingTilde) }
        }
        return paths
    }

    static func knownBundleIDs(from configs: [DetectorConfig]) -> Set<String> {
        var ids = Set<String>()
        for path in knownAppPaths(from: configs) {
            if let info = AppScanner.readAppInfo(at: path) {
                ids.insert(info.bundleID)
            }
        }
        return ids
    }

    static func ensureUserConfigExists() {
        guard !FileManager.default.fileExists(atPath: userConfigURL.path) else { return }
        let template = """
        {
          "items": []
        }
        """
        try? template.write(to: userConfigURL, atomically: true, encoding: .utf8)
    }

    static var checkAppUpdateScriptPath: String {
        let candidates: [URL] = [
            Bundle.module.url(forResource: "check-app-update", withExtension: "sh", subdirectory: "scripts"),
            Bundle.main.resourceURL?.appendingPathComponent("scripts/check-app-update.sh"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scripts/check-app-update.sh")
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }

        if let execURL = Bundle.main.executableURL {
            let sibling = execURL.deletingLastPathComponent().appendingPathComponent("check-app-update.sh")
            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling.path
            }
        }

        return ""
    }

    static var quotedCheckScript: String {
        let path = checkAppUpdateScriptPath
        guard !path.isEmpty else { return "" }
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func resolveCommand(_ command: String) -> String {
        guard command.contains("{CHECK_SCRIPT}") else { return command }
        return command.replacingOccurrences(of: "{CHECK_SCRIPT}", with: quotedCheckScript)
    }

    private static func expandConfig(_ config: DetectorConfig, settings: UserSettings) -> DetectorConfig {
        let home = settings.rootFolder.isEmpty ? NSHomeDirectory() : settings.rootFolder
        let folders = settings.allScanFolders
        var detect = config.detect

        if var rule = detect {
            if rule.type == .app, let appName = rule.appName {
                let appPaths = settings.applicationFolders.map { "\($0.expandingTilde)/\(appName).app" }
                rule = DetectRule(type: .app, paths: appPaths, command: rule.command, appName: appName)
            }

            if var paths = rule.paths {
                paths = paths.map { path in
                    path
                        .replacingOccurrences(of: "{HOME}", with: home)
                        .replacingOccurrences(of: "{ROOT}", with: home)
                        .replacingOccurrences(of: "~", with: NSHomeDirectory())
                }
                if rule.type == .path, paths.contains(where: { $0.contains("impeccable") || $0.contains("Projects") }) {
                    var expanded: [String] = paths
                    for folder in folders {
                        expanded.append("\(folder.expandingTilde)/impeccable")
                        expanded.append("\(folder.expandingTilde)/Projects/impeccable")
                        expanded.append("\(folder.expandingTilde)/dev/impeccable")
                    }
                    paths = Array(Set(expanded))
                }
                rule = DetectRule(type: rule.type, paths: paths, command: rule.command, appName: rule.appName)
            }
            detect = rule
        }

        return DetectorConfig(
            id: config.id,
            name: config.name,
            category: config.category,
            description: config.description,
            source: config.source ?? .bundled,
            detect: detect,
            versionCommand: expandVariables(config.versionCommand, home: home),
            checkCommand: expandVariables(config.checkCommand, home: home),
            installCommand: resolvedInstallCommand(config, home: home),
            updateCommand: expandVariables(config.updateCommand, home: home) ?? config.updateCommand,
            workingDirectory: expandVariables(config.workingDirectory, home: home)
        )
    }

    private static func resolvedInstallCommand(_ config: DetectorConfig, home: String) -> String {
        let update = expandVariables(config.updateCommand, home: home) ?? config.updateCommand
        let install = expandVariables(config.installCommand, home: home)
        return InstallCommandResolver.resolve(id: config.id, installCommand: install, updateCommand: update)
    }

    private static func expandVariables(_ value: String?, home: String) -> String? {
        guard let value else { return nil }
        var expanded = value
            .replacingOccurrences(of: "{HOME}", with: home)
            .replacingOccurrences(of: "{ROOT}", with: home)
        if expanded.contains("{CHECK_SCRIPT}") {
            let script = quotedCheckScript
            if !script.isEmpty {
                expanded = expanded.replacingOccurrences(of: "{CHECK_SCRIPT}", with: script)
            }
        }
        return expanded
    }

    private static func loadBundledConfigs() -> [DetectorConfig]? {
        guard let url = Bundle.module.url(forResource: "detectors", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private static func loadLegacyUserConfigs() -> [DetectorConfig]? {
        guard FileManager.default.fileExists(atPath: userConfigURL.path),
              let data = try? Data(contentsOf: userConfigURL) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> [DetectorConfig]? {
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(DetectorConfigFile.self, from: data) else { return nil }
        return file.items
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
