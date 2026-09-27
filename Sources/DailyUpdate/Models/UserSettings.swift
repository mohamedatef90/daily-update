import Foundation

enum ItemSource: String, Codable {
    case bundled
    case user
    case discovered
    /// P2-1 (D2): a row built by `RowBuilder` from an `InstalledPackage` record, not from the
    /// bundled catalog, a custom item, or the legacy repo/app scanners.
    case inventory

    var label: String {
        switch self {
        case .bundled: return "Built-in"
        case .user: return "Custom"
        case .discovered: return "Discovered"
        case .inventory: return "Discovered"
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

/// §1 R1B8's filters: an ecosystem the user hid entirely (its Homebrew row and every formula, for
/// example), separate from `disabledItemIDs` which hides one row by ID.
struct InventorySettings: Codable, Equatable {
    var hiddenEcosystems: Set<Ecosystem> = []

    static var defaults: InventorySettings { InventorySettings() }

    init() {}

    /// CR#1: a present-but-incomplete `inventory` object (missing `hiddenEcosystems`) must not
    /// fail the whole decode — it falls back to the same default an absent key would.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenEcosystems = try container.decodeIfPresent(Set<Ecosystem>.self, forKey: .hiddenEcosystems) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case hiddenEcosystems
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
    var inventory: InventorySettings = .defaults
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

    init() {}

    /// CR#1: `inventory` is decoded leniently (`decodeIfPresent(...) ?? .defaults`), because every
    /// `settings.json` written before this field existed lacks the key entirely. The synthesized
    /// decoder ignores a property's default value and requires every key present, so without this,
    /// decoding master's settings.json throws `keyNotFound`, `UserSettingsStore.init` silently
    /// falls back to `.defaults`, and the very next `save()` overwrites the user's real settings —
    /// custom items, disabled IDs, the schedule, `hasCompletedSetup` — with fresh defaults. Every
    /// other field already existed before this PR, so it keeps the old (strict) behavior.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedSetup = try container.decode(Bool.self, forKey: .hasCompletedSetup)
        rootFolder = try container.decode(String.self, forKey: .rootFolder)
        additionalFolders = try container.decode([String].self, forKey: .additionalFolders)
        applicationFolders = try container.decode([String].self, forKey: .applicationFolders)
        customItems = try container.decode([DetectorConfig].self, forKey: .customItems)
        disabledItemIDs = try container.decode([String].self, forKey: .disabledItemIDs)
        autoCheckOnLaunch = try container.decode(Bool.self, forKey: .autoCheckOnLaunch)
        autoUpdateOnLaunch = try container.decode(Bool.self, forKey: .autoUpdateOnLaunch)
        autoCheckOnWake = try container.decode(Bool.self, forKey: .autoCheckOnWake)
        rescanReposOnLaunch = try container.decode(Bool.self, forKey: .rescanReposOnLaunch)
        rescanAppsOnLaunch = try container.decode(Bool.self, forKey: .rescanAppsOnLaunch)
        rescanSkillsOnLaunch = try container.decode(Bool.self, forKey: .rescanSkillsOnLaunch)
        appDiscovery = try container.decode(AppDiscoverySettings.self, forKey: .appDiscovery)
        skillDiscovery = try container.decode(SkillDiscoverySettings.self, forKey: .skillDiscovery)
        inventory = try container.decodeIfPresent(InventorySettings.self, forKey: .inventory) ?? .defaults
        showMenuBarIcon = try container.decode(Bool.self, forKey: .showMenuBarIcon)
        menuBarOnly = try container.decode(Bool.self, forKey: .menuBarOnly)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        repoScan = try container.decode(RepoScanSettings.self, forKey: .repoScan)
        itemPreferences = try container.decode([String: ItemPreference].self, forKey: .itemPreferences)
        updateCategoryOrder = try container.decode([String].self, forKey: .updateCategoryOrder)
        notificationsEnabled = try container.decode(Bool.self, forKey: .notificationsEnabled)
        confirmBeforeUpdate = try container.decode(Bool.self, forKey: .confirmBeforeUpdate)
        stashReposBeforeUpdate = try container.decode(Bool.self, forKey: .stashReposBeforeUpdate)
        scheduledCheckEnabled = try container.decode(Bool.self, forKey: .scheduledCheckEnabled)
        scheduledCheckHour = try container.decode(Int.self, forKey: .scheduledCheckHour)
        scheduledCheckMinute = try container.decode(Int.self, forKey: .scheduledCheckMinute)
        autoUpdateScheduledItems = try container.decode(Bool.self, forKey: .autoUpdateScheduledItems)
        showDashboardOnLaunch = try container.decode(Bool.self, forKey: .showDashboardOnLaunch)
    }

    private enum CodingKeys: String, CodingKey {
        case hasCompletedSetup, rootFolder, additionalFolders, applicationFolders, customItems,
             disabledItemIDs, autoCheckOnLaunch, autoUpdateOnLaunch, autoCheckOnWake,
             rescanReposOnLaunch, rescanAppsOnLaunch, rescanSkillsOnLaunch, appDiscovery,
             skillDiscovery, inventory, showMenuBarIcon, menuBarOnly, launchAtLogin, repoScan,
             itemPreferences, updateCategoryOrder, notificationsEnabled, confirmBeforeUpdate,
             stashReposBeforeUpdate, scheduledCheckEnabled, scheduledCheckHour, scheduledCheckMinute,
             autoUpdateScheduledItems, showDashboardOnLaunch
    }

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

    private static var settingsURL: URL {
        ConfigLoader.appSupportDirectory.appendingPathComponent("settings.json")
    }

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
