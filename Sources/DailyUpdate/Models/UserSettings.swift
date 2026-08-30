import Foundation

enum ItemSource: String, Codable {
    case bundled
    case user
    case discovered

    var label: String {
        switch self {
        case .bundled: return "Built-in"
        case .user: return "Custom"
        case .discovered: return "Discovered"
        }
    }
}

struct RepoScanSettings: Codable, Equatable {
    var maxDepth: Int = 4
    var skipHiddenDirectories: Bool = true
    var limitRootToSubfolders: Bool = true
    var subfolders: [String] = RepoScanSettings.defaultSubfolders
    var skipDirectories: [String] = RepoScanSettings.defaultSkipDirectories

    static let defaultSubfolders = [
        "Projects", "dev", "Development", "code", "Code", "repos", "workspace",
        "Downloads", "Documents", "04_App_Coding", "app", "apps", "src", "git"
    ]

    static let defaultSkipDirectories = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", ".Trash", "Library",
        ".cache", "vendor", ".venv", "venv", ".npm", ".cargo", ".rustup", "go",
        ".gradle", ".m2", "__pycache__", "dist", "build", "target", ".next",
        ".nuxt", "coverage", "Applications", "Movies", "Music", "Pictures",
        "Public", "Parallels", ".local", ".config", ".cursor", ".vscode",
        "Library/Application Support", "Library/Caches", "Library/Containers",
        "flutter", "Flutter", "android-sdk", "Android", "android", "homebrew",
        "Cellar", "sdk", "SDKs", "platform-tools", "cmdline-tools", "Library/Android"
    ]

    static var defaults: RepoScanSettings { RepoScanSettings() }

    var scanOptions: RepoScanOptions {
        RepoScanOptions(
            maxDepth: max(1, min(maxDepth, 10)),
            skipDirectories: Set(skipDirectories),
            skipHidden: skipHiddenDirectories,
            limitRootToSubfolders: limitRootToSubfolders,
            subfolders: subfolders
        )
    }
}

struct AppDiscoverySettings: Codable, Equatable {
    var enabled: Bool = true
    var developerOnly: Bool = true
    var scanUtilitiesFolder: Bool = true

    static var defaults: AppDiscoverySettings { AppDiscoverySettings() }
}

struct SkillDiscoverySettings: Codable, Equatable {
    var enabled: Bool = true
    var scanPluginCaches: Bool = true
    var skillRoots: [String] = SkillDiscoverySettings.defaultRoots

    static let defaultRoots = SkillsScanner.defaultSkillRoots
    static var defaults: SkillDiscoverySettings { SkillDiscoverySettings() }
}

struct UserSettings: Codable {
    var hasCompletedSetup: Bool = false
    var rootFolder: String = ""
    var additionalFolders: [String] = []
    var applicationFolders: [String] = ["/Applications", "~/Applications"]
    var customItems: [DetectorConfig] = []
    var disabledItemIDs: [String] = []
    var autoCheckOnLaunch: Bool = true
    var autoUpdateOnLaunch: Bool = false
    var autoCheckOnWake: Bool = true
    var rescanReposOnLaunch: Bool = true
    var rescanAppsOnLaunch: Bool = true
    var rescanSkillsOnLaunch: Bool = true
    var appDiscovery: AppDiscoverySettings = .defaults
    var skillDiscovery: SkillDiscoverySettings = .defaults
    var showMenuBarIcon: Bool = true
    var menuBarOnly: Bool = false
    var launchAtLogin: Bool = false
    var repoScan: RepoScanSettings = .defaults
    var itemPreferences: [String: ItemPreference] = [:]
    var updateCategoryOrder: [String] = UpdateGroupOrder.defaultOrder.map(\.rawValue)
    var notificationsEnabled: Bool = true
    var confirmBeforeUpdate: Bool = true
    var stashReposBeforeUpdate: Bool = true
    var scheduledCheckEnabled: Bool = false
    var scheduledCheckHour: Int = 9
    var scheduledCheckMinute: Int = 0
    var autoUpdateScheduledItems: Bool = false
    var showDashboardOnLaunch: Bool = false

    func preference(for id: String) -> ItemPreference {
        itemPreferences[id] ?? ItemPreference()
    }

    mutating func setPreference(_ pref: ItemPreference, for id: String) {
        itemPreferences[id] = pref
    }

    var allScanFolders: [String] {
        var folders: [String] = []
        if !rootFolder.isEmpty { folders.append(rootFolder) }
        folders.append(contentsOf: additionalFolders)
        return folders
    }

    static var defaultRootFolder: String {
        NSHomeDirectory()
    }

    static var defaults: UserSettings {
        var settings = UserSettings()
        settings.rootFolder = defaultRootFolder
        return settings
    }
}

final class UserSettingsStore: ObservableObject {
    @Published var settings: UserSettings

    private static let settingsURL: URL = {
        ConfigLoader.appSupportDirectory.appendingPathComponent("settings.json")
    }()

    init() {
        if let loaded = Self.load() {
            settings = loaded
        } else {
            settings = .defaults
        }
    }

    func save() {
        objectWillChange.send()
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: Self.settingsURL, options: .atomic)
    }

    func completeSetup(rootFolder: String, additionalFolders: [String]) {
        settings.rootFolder = rootFolder
        settings.additionalFolders = additionalFolders
        settings.hasCompletedSetup = true
        save()
    }

    func addFolder(_ path: String) {
        let expanded = path.expandingTilde
        guard !settings.allScanFolders.contains(expanded) else { return }
        if settings.rootFolder.isEmpty {
            settings.rootFolder = expanded
        } else {
            settings.additionalFolders.append(expanded)
        }
        save()
    }

    func removeFolder(_ path: String) {
        let expanded = path.expandingTilde
        if settings.rootFolder == expanded {
            settings.rootFolder = settings.additionalFolders.first ?? ""
            if !settings.additionalFolders.isEmpty {
                settings.additionalFolders.removeFirst()
            }
        } else {
            settings.additionalFolders.removeAll { $0 == expanded }
        }
        save()
    }

    func addApplicationFolder(_ path: String) {
        let expanded = path.expandingTilde
        guard !settings.applicationFolders.contains(expanded) else { return }
        settings.applicationFolders.append(expanded)
        save()
    }

    func removeApplicationFolder(_ path: String) {
        settings.applicationFolders.removeAll { $0 == path.expandingTilde }
        if settings.applicationFolders.isEmpty {
            settings.applicationFolders = ["/Applications", "~/Applications"]
        }
        save()
    }

    func addCustomItem(_ item: DetectorConfig) {
        settings.customItems.removeAll { $0.id == item.id }
        settings.customItems.append(item)
        save()
    }

    func removeCustomItem(id: String) {
        settings.customItems.removeAll { $0.id == id }
        settings.disabledItemIDs.removeAll { $0 == id }
        save()
    }

    func disableItem(id: String) {
        if !settings.disabledItemIDs.contains(id) {
            settings.disabledItemIDs.append(id)
            save()
        }
    }

    func enableItem(id: String) {
        settings.disabledItemIDs.removeAll { $0 == id }
        save()
    }

    func preference(for id: String) -> ItemPreference {
        settings.preference(for: id)
    }

    func updatePreference(for id: String, _ update: (inout ItemPreference) -> Void) {
        var pref = settings.preference(for: id)
        update(&pref)
        settings.setPreference(pref, for: id)
        save()
    }

    func resetSkillDiscoverySettings() {
        settings.skillDiscovery = .defaults
        save()
    }

    func resetAppDiscoverySettings() {
        settings.appDiscovery = .defaults
        save()
    }

    func resetRepoScanSettings() {
        settings.repoScan = .defaults
        save()
    }

    func addRepoScanSubfolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.repoScan.subfolders.contains(trimmed) else { return }
        settings.repoScan.subfolders.append(trimmed)
        save()
    }

    func removeRepoScanSubfolder(_ name: String) {
        settings.repoScan.subfolders.removeAll { $0 == name }
        save()
    }

    func addRepoScanSkipDirectory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.repoScan.skipDirectories.contains(trimmed) else { return }
        settings.repoScan.skipDirectories.append(trimmed)
        save()
    }

    func removeRepoScanSkipDirectory(_ name: String) {
        settings.repoScan.skipDirectories.removeAll { $0 == name }
        save()
    }

    private static func load() -> UserSettings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(UserSettings.self, from: data)
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
