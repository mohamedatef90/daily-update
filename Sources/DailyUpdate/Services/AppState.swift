import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var items: [UpdateItem] = []
    @Published var selectedCategory: ItemCategory? = nil
    @Published var showUpdatesOnly = false
    @Published var showDashboard = false
    @Published var showHistory = false
    @Published var searchText = ""
    @Published var isChecking = false
    @Published var checkedItemCount = 0
    @Published var totalItemCount = 0
    @Published var isUpdating = false
    @Published var lastCheckDate: Date? = nil
    @Published var logLines: [String] = []
    @Published var showOnboarding = false
    @Published var showAddItem = false
    @Published var showDryRun = false
    @Published var dryRunEntries: [DryRunEntry] = []
    @Published var discoveredRepoCount = 0
    @Published var discoveredAppCount = 0
    @Published var discoveredSkillCount = 0
    @Published var history: [UpdateHistoryEntry] = []
    @Published var healthIssues: [HealthIssue] = []
    @Published var duplicateGroups: [DuplicateGroup] = []

    let settingsStore: UserSettingsStore
    private let scheduler = SchedulerService()

    weak var appDelegate: AppDelegate?
    private var configs: [DetectorConfig] = []
    private var wakeObserver: NSObjectProtocol?
    private var hasRunStartupCheck = false
    private var pendingSkipDryRun = false

    func confirmDryRunUpdate() {
        pendingSkipDryRun = true
    }

    var shouldSkipDryRun: Bool {
        get { pendingSkipDryRun }
        set { pendingSkipDryRun = newValue }
    }

    init(settingsStore: UserSettingsStore = UserSettingsStore()) {
        self.settingsStore = settingsStore
        loadSettings()
        history = UpdateHistoryStore.load()
        showOnboarding = !settingsStore.settings.hasCompletedSetup
        reloadConfigs()
        setupWakeObserver()
        syncLaunchAtLogin()
        scheduler.start(appState: self)
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - Settings accessors

    var autoCheckOnLaunch: Bool {
        get { settingsStore.settings.autoCheckOnLaunch }
        set { settingsStore.settings.autoCheckOnLaunch = newValue; settingsStore.save() }
    }

    var autoUpdateOnLaunch: Bool {
        get { settingsStore.settings.autoUpdateOnLaunch }
        set { settingsStore.settings.autoUpdateOnLaunch = newValue; settingsStore.save() }
    }

    var autoCheckOnWake: Bool {
        get { settingsStore.settings.autoCheckOnWake }
        set { settingsStore.settings.autoCheckOnWake = newValue; settingsStore.save() }
    }

    var rescanReposOnLaunch: Bool {
        get { settingsStore.settings.rescanReposOnLaunch }
        set { settingsStore.settings.rescanReposOnLaunch = newValue; settingsStore.save() }
    }

    var rescanAppsOnLaunch: Bool {
        get { settingsStore.settings.rescanAppsOnLaunch }
        set { settingsStore.settings.rescanAppsOnLaunch = newValue; settingsStore.save() }
    }

    var rescanSkillsOnLaunch: Bool {
        get { settingsStore.settings.rescanSkillsOnLaunch }
        set { settingsStore.settings.rescanSkillsOnLaunch = newValue; settingsStore.save() }
    }

    var showMenuBarIcon: Bool {
        get { settingsStore.settings.showMenuBarIcon }
        set { settingsStore.settings.showMenuBarIcon = newValue; settingsStore.save(); appDelegate?.refreshStatusBarVisibility() }
    }

    var menuBarOnly: Bool {
        get { settingsStore.settings.menuBarOnly }
        set { settingsStore.settings.menuBarOnly = newValue; settingsStore.save(); appDelegate?.applyActivationPolicy() }
    }

    var launchAtLogin: Bool {
        get { settingsStore.settings.launchAtLogin }
        set {
            settingsStore.settings.launchAtLogin = newValue
            settingsStore.save()
            if let error = LaunchAtLogin.setEnabled(newValue) { appendLog("Launch at login: \(error)") }
        }
    }

    var notificationsEnabled: Bool {
        get { settingsStore.settings.notificationsEnabled }
        set { settingsStore.settings.notificationsEnabled = newValue; settingsStore.save() }
    }

    var confirmBeforeUpdate: Bool {
        get { settingsStore.settings.confirmBeforeUpdate }
        set { settingsStore.settings.confirmBeforeUpdate = newValue; settingsStore.save() }
    }

    var stashReposBeforeUpdate: Bool {
        get { settingsStore.settings.stashReposBeforeUpdate }
        set { settingsStore.settings.stashReposBeforeUpdate = newValue; settingsStore.save() }
    }

    var scheduledCheckEnabled: Bool {
        get { settingsStore.settings.scheduledCheckEnabled }
        set { settingsStore.settings.scheduledCheckEnabled = newValue; settingsStore.save() }
    }

    // MARK: - Menu bar

    var menuBarStatusTitle: String {
        if isChecking { return "Checking…" }
        if isUpdating { return "Updating…" }
        if updateAvailableCount > 0 { return "\(updateAvailableCount) update\(updateAvailableCount == 1 ? "" : "s") available" }
        return "Up to date"
    }

    var menuBarStatusSubtitle: String? {
        if isChecking || isUpdating { return nil }
        if let lastCheckDate { return "Checked \(lastCheckDate.formatted(.relative(presentation: .named)))" }
        return "Daily Update"
    }

    var menuBarIconName: String {
        if isChecking || isUpdating { return "arrow.triangle.2.circlepath" }
        if updateAvailableCount > 0 { return "exclamationmark.arrow.circlepath" }
        return "checkmark.circle"
    }

    // MARK: - Filtering

    var filteredItems: [UpdateItem] {
        var result = activeItems
        if let selectedCategory { result = result.filter { $0.category == selectedCategory } }
        if showUpdatesOnly { result = result.filter { $0.status == .updateAvailable } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                ($0.description?.lowercased().contains(q) ?? false) ||
                $0.category.label.lowercased().contains(q)
            }
        }
        return result
    }

    /// Items confirmed by the most recent detection pass. Configured detectors that
    /// are not present on this Mac stay internal to the scan and are not listed.
    var installedItems: [UpdateItem] {
        items.filter(\.isInstalled)
    }

    var activeItems: [UpdateItem] {
        installedItems.filter { !$0.permanentlyIgnored && !$0.isSnoozed }
    }

    var listTitle: String {
        if showDashboard { return "Dashboard" }
        if showHistory { return "History" }
        if showUpdatesOnly { return "Updates Available" }
        if let selectedCategory { return selectedCategory.label }
        return "All Items"
    }

    var updateAvailableCount: Int {
        activeItems.filter { $0.status == .updateAvailable }.count
    }

    var selectedActionableItems: [UpdateItem] {
        activeItems.filter { $0.isSelected && $0.isActionable }
    }

    var selectedActionLabel: String {
        let selected = selectedActionableItems
        let installs = selected.filter(\.canInstall).count
        let updates = selected.filter(\.canUpdate).count
        if installs > 0 && updates == 0 { return "Install Selected" }
        if updates > 0 && installs == 0 { return "Update Selected" }
        return "Run Selected"
    }

    var selectedUpdatableItems: [UpdateItem] {
        activeItems.filter { $0.isSelected && $0.canUpdate }
    }

    var dashboardStats: DashboardStats {
        DashboardStats(
            totalItems: installedItems.count,
            installedCount: installedItems.count,
            updatesAvailable: updateAvailableCount,
            snoozedCount: installedItems.filter(\.isSnoozed).count,
            autoUpdateCount: installedItems.filter(\.autoUpdate).count,
            duplicateCount: duplicateGroups.count,
            byCategory: ItemCategory.allCases.map { cat in (cat, installedItems.filter { $0.category == cat }.count) },
            lastCheck: lastCheckDate
        )
    }

    var sidebarSelectionTag: String {
        if showDashboard { return "dashboard" }
        if showHistory { return "history" }
        if showUpdatesOnly { return "updates" }
        return selectedCategory?.rawValue ?? "all"
    }

    func setSidebarSelection(_ tag: String) {
        switch tag {
        case "dashboard":
            showDashboard = true
            showHistory = false
            selectedCategory = nil
            showUpdatesOnly = false
        case "all":
            showDashboard = false
            showHistory = false
            selectedCategory = nil
            showUpdatesOnly = false
        case "updates":
            showDashboard = false
            showHistory = false
            selectedCategory = nil
            showUpdatesOnly = true
        case "history":
            showDashboard = false
            showHistory = true
            selectedCategory = nil
            showUpdatesOnly = false
        default:
            showDashboard = false
            showHistory = false
            selectedCategory = ItemCategory(rawValue: tag)
            showUpdatesOnly = false
        }
    }

    // MARK: - Config

    func reloadConfigs() {
        ConfigLoader.ensureUserConfigExists()
        let settings = settingsStore.settings
        var discoveredRepos: [DetectorConfig] = []
        var discoveredApps: [DetectorConfig] = []
        var discoveredSkills: [DetectorConfig] = []

        if settings.hasCompletedSetup && rescanReposOnLaunch {
            let options = settings.repoScan.scanOptions
            discoveredRepos = RepoScanner.discoverRepos(
                in: settings.allScanFolders,
                rootFolder: settings.rootFolder,
                options: options
            )
            discoveredRepoCount = discoveredRepos.count
        } else {
            discoveredRepoCount = 0
        }

        let preliminary = ConfigLoader.loadConfigs(
            settings: settings,
            discoveredRepos: discoveredRepos
        )

        if settings.hasCompletedSetup && settings.appDiscovery.enabled && rescanAppsOnLaunch {
            discoveredApps = AppScanner.discoverApps(
                in: settings.applicationFolders,
                excludingPaths: ConfigLoader.knownAppPaths(from: preliminary),
                excludingBundleIDs: ConfigLoader.knownBundleIDs(from: preliminary),
                options: AppScanOptions(
                    developerOnly: settings.appDiscovery.developerOnly,
                    scanUtilitiesFolder: settings.appDiscovery.scanUtilitiesFolder
                )
            )
            discoveredAppCount = discoveredApps.count
        } else {
            discoveredAppCount = 0
        }

        if settings.hasCompletedSetup && settings.skillDiscovery.enabled && rescanSkillsOnLaunch {
            discoveredSkills = SkillsScanner.discoverSkillItems(
                excludingPaths: ConfigLoader.knownItemPaths(from: preliminary),
                options: SkillScanOptions(
                    scanPluginCaches: settings.skillDiscovery.scanPluginCaches,
                    skillRoots: settings.skillDiscovery.skillRoots
                )
            )
            discoveredSkillCount = discoveredSkills.count
        } else {
            discoveredSkillCount = 0
        }

        configs = ConfigLoader.loadConfigs(
            settings: settings,
            discoveredRepos: discoveredRepos,
            discoveredApps: discoveredApps,
            discoveredSkills: discoveredSkills
        )
        items = configs.map { applyPreferences(to: $0.toUpdateItem()) }
        duplicateGroups = DuplicateDetector.find(in: installedItems)
        markDuplicates()
        appendLog("Loaded \(configs.count) items (\(discoveredRepos.count) repos, \(discoveredApps.count) apps, \(discoveredSkills.count) skills discovered)")
        publishWidgetSnapshot()
    }

    private func applyPreferences(to item: UpdateItem) -> UpdateItem {
        var item = item
        let pref = settingsStore.preference(for: item.id)
        item.autoUpdate = pref.autoUpdate
        item.snoozedUntil = pref.snoozedUntil
        item.pinnedVersion = pref.pinnedVersion
        item.permanentlyIgnored = pref.permanentlyIgnored
        return item
    }

    private func markDuplicates() {
        for group in duplicateGroups {
            for id in group.itemIDs {
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].duplicateGroupID = group.id
                }
            }
        }
    }

    // MARK: - Item preferences

    func snoozeItem(id: String, days: Int) {
        let until = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        settingsStore.updatePreference(for: id) { $0.snoozedUntil = until }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].snoozedUntil = until
            items[index].isSelected = false
        }
        appendLog("Snoozed item for \(days) day(s)")
    }

    func setAutoUpdate(id: String, enabled: Bool) {
        settingsStore.updatePreference(for: id) { $0.autoUpdate = enabled }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].autoUpdate = enabled
        }
    }

    func setPinnedVersion(id: String, version: String?) {
        settingsStore.updatePreference(for: id) { $0.pinnedVersion = version?.nilIfEmpty }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].pinnedVersion = version?.nilIfEmpty
        }
    }

    func ignoreItem(id: String) {
        settingsStore.updatePreference(for: id) { $0.permanentlyIgnored = true }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].permanentlyIgnored = true
            items[index].isSelected = false
        }
    }

    // MARK: - Lifecycle

    func completeOnboarding(rootFolder: String, additionalFolders: [String]) {
        settingsStore.completeSetup(rootFolder: rootFolder, additionalFolders: additionalFolders)
        showOnboarding = false
        reloadConfigs()
        Task { await runStartupFlow() }
    }

    func runStartupFlow() async {
        guard !hasRunStartupCheck else { return }
        hasRunStartupCheck = true
        guard settingsStore.settings.hasCompletedSetup else { return }
        if settingsStore.settings.showDashboardOnLaunch { setSidebarSelection("dashboard") }
        if autoCheckOnLaunch { await checkAll() }
        if autoUpdateOnLaunch, updateAvailableCount > 0 {
            selectAllUpdates()
            await updateSelected(skipDryRun: true)
        }
        await runHealthCheck()
    }

    func addCustomItem(_ config: DetectorConfig) {
        settingsStore.addCustomItem(config)
        reloadConfigs()
        appendLog("Added \(config.name) to update list")
        Task { await checkAll() }
    }

    func removeCustomItem(id: String) {
        settingsStore.removeCustomItem(id: id)
        reloadConfigs()
        appendLog("Removed item from update list")
    }

    func toggleSelection(for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSelected.toggle()
    }

    func selectAllUpdates() {
        for index in items.indices {
            items[index].isSelected = items[index].canUpdate && !items[index].isSnoozed
        }
    }

    func selectAllInstallable() {
        for index in items.indices {
            items[index].isSelected = items[index].canInstall && !items[index].isSnoozed
        }
    }

    func selectAllActionable() {
        for index in items.indices {
            items[index].isSelected = items[index].isActionable
        }
    }

    func deselectAll() {
        for index in items.indices { items[index].isSelected = false }
    }

    func items(for group: DuplicateGroup) -> [UpdateItem] {
        group.itemIDs.compactMap { id in items.first { $0.id == id } }
    }

    func refreshDuplicates() {
        duplicateGroups = DuplicateDetector.find(in: installedItems)
        markDuplicates()
    }

    // MARK: - Check & Update

    func checkAll() async {
        guard !isChecking else { return }
        isChecking = true
        checkedItemCount = 0
        appendLog("Starting update check…")
        if rescanReposOnLaunch { reloadConfigs() }

        let appFolders = settingsStore.settings.applicationFolders
        let prefs = settingsStore.settings.itemPreferences
        totalItemCount = configs.count
        for index in items.indices { items[index].status = .checking }

        await withTaskGroup(of: (Int, UpdateItem).self) { group in
            for (index, config) in configs.enumerated() {
                group.addTask {
                    var item = config.toUpdateItem()
                    if let pref = prefs[config.id] {
                        item.autoUpdate = pref.autoUpdate
                        item.snoozedUntil = pref.snoozedUntil
                        item.pinnedVersion = pref.pinnedVersion
                        item.permanentlyIgnored = pref.permanentlyIgnored
                    }
                    if item.permanentlyIgnored || item.isSnoozed {
                        item.status = .upToDate
                        item.statusMessage = item.isSnoozed ? "Snoozed" : "Ignored"
                        return (index, item)
                    }
                    let (installed, detectMsg) = await DetectionService.detect(config, applicationFolders: appFolders)
                    item.isInstalled = installed
                    if !installed {
                        item.status = .notInstalled
                        item.statusMessage = detectMsg
                        return (index, item)
                    }
                    let (status, current, latest, message) = await UpdateCheckService.check(config, installed: installed)
                    item.status = status
                    item.currentVersion = current
                    item.latestVersion = latest
                    item.statusMessage = message
                    if item.isPinnedMismatch {
                        item.statusMessage = "Pinned to \(item.pinnedVersion ?? "")"
                    }
                    item.isSelected = item.canUpdate
                    return (index, item)
                }
            }
            for await (index, updated) in group {
                items[index] = updated
                checkedItemCount += 1
            }
        }

        lastCheckDate = Date()
        isChecking = false
        refreshDuplicates()
        appendLog("Check complete — \(updateAvailableCount) update(s) available")
        saveSettings()
        publishWidgetSnapshot()
        appDelegate?.refreshStatusBar()

        if notificationsEnabled, updateAvailableCount > 0 {
            await NotificationService.notifyUpdatesAvailable(count: updateAvailableCount)
        }
    }

    func requestUpdateSelected() async {
        let targets = orderedActionTargets(selectedActionableItems)
        guard !targets.isEmpty else { appendLog("No items selected"); return }

        if confirmBeforeUpdate && !pendingSkipDryRun {
            dryRunEntries = targets.map { item in
                DryRunEntry(
                    id: item.id,
                    name: item.name,
                    command: actionCommand(for: item),
                    action: item.actionLabel,
                    category: item.category
                )
            }
            showDryRun = true
            return
        }
        pendingSkipDryRun = false
        await updateSelected(skipDryRun: true)
    }

    func updateSelected(skipDryRun: Bool = false) async {
        if !skipDryRun && confirmBeforeUpdate {
            await requestUpdateSelected()
            return
        }

        guard !isUpdating else { return }
        let targets = orderedActionTargets(selectedActionableItems)
        guard !targets.isEmpty else { appendLog("No items selected"); return }

        isUpdating = true
        appendLog("Running \(targets.count) action(s)…")
        var successCount = 0
        var failCount = 0

        for target in targets {
            guard let index = items.firstIndex(where: { $0.id == target.id }) else { continue }
            let installing = items[index].canInstall
            let verb = installing ? "Installing" : "Updating"
            items[index].status = .updating
            appendLog("\(verb) \(target.name)…")

            let fromVersion = items[index].currentVersion
            let command = actionCommand(for: items[index])
            let (status, version, message) = await UpdateExecutor.update(
                items[index],
                installing: installing,
                stashRepos: stashReposBeforeUpdate
            )
            items[index].status = status
            if status == .updated {
                items[index].isInstalled = true
            }
            items[index].currentVersion = version ?? items[index].currentVersion
            items[index].statusMessage = message
            items[index].isSelected = false

            let entry = UpdateHistoryEntry(
                itemID: target.id,
                itemName: target.name,
                fromVersion: fromVersion,
                toVersion: version,
                success: status == .updated,
                message: message,
                command: command
            )
            UpdateHistoryStore.append(entry)
            history.insert(entry, at: 0)

            if status == .updated {
                successCount += 1
                appendLog("✓ \(target.name) \(installing ? "installed" : "updated")")
            } else {
                failCount += 1
                appendLog("✗ \(target.name): \(message ?? "failed")")
            }
        }

        isUpdating = false
        appendLog("Action run finished")
        publishWidgetSnapshot()
        appDelegate?.refreshStatusBar()

        if notificationsEnabled {
            await NotificationService.notifyUpdateComplete(success: successCount, failed: failCount)
        }
        await checkAll()
    }

    private func actionCommand(for item: UpdateItem) -> String {
        item.canInstall ? item.installCommand : item.updateCommand
    }

    private func orderedActionTargets(_ targets: [UpdateItem]) -> [UpdateItem] {
        orderedUpdateTargets(targets)
    }

    func updateAutoItems() async {
        for index in items.indices where items[index].autoUpdate && items[index].status == .updateAvailable {
            items[index].isSelected = true
        }
        await updateSelected(skipDryRun: true)
    }

    private func orderedUpdateTargets(_ targets: [UpdateItem]) -> [UpdateItem] {
        let order = settingsStore.settings.updateCategoryOrder.compactMap { ItemCategory(rawValue: $0) }
        let effectiveOrder = order.isEmpty ? UpdateGroupOrder.defaultOrder : order
        return UpdateGroupOrder.sortItems(targets, order: effectiveOrder)
    }

    // MARK: - Health & Import/Export

    func runHealthCheck() async {
        healthIssues = await HealthCheckService.run(settings: settingsStore.settings)
    }

    func exportConfig() throws -> URL {
        let data = try ConfigImportExport.export(settings: settingsStore.settings)
        let url = ConfigLoader.appSupportDirectory.appendingPathComponent("daily-update-export.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func importConfig(from url: URL) throws {
        let data = try Data(contentsOf: url)
        try ConfigImportExport.importData(data, into: settingsStore)
        history = UpdateHistoryStore.load()
        reloadConfigs()
        appendLog("Imported configuration")
    }

    func clearHistory() {
        UpdateHistoryStore.clear()
        history = []
    }

    // MARK: - Window

    func showMainWindow() {
        if menuBarOnly { NSApp.setActivationPolicy(.regular) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }.first?.makeKeyAndOrderFront(nil)
    }

    func openUserConfig() { NSWorkspace.shared.open(ConfigLoader.userConfigURL) }
    func openAppSupportFolder() { NSWorkspace.shared.open(ConfigLoader.appSupportDirectory) }

    func syncLaunchAtLogin() {
        let enabled = LaunchAtLogin.isEnabled
        if settingsStore.settings.launchAtLogin != enabled {
            settingsStore.settings.launchAtLogin = enabled
            settingsStore.save()
        }
    }

    private func publishWidgetSnapshot() {
        WidgetDataStore.save(WidgetSnapshot(
            updateCount: updateAvailableCount,
            lastCheck: lastCheckDate,
            status: menuBarStatusTitle
        ))
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.insert("[\(formatter.string(from: Date()))] \(line)", at: 0)
        if logLines.count > 200 { logLines = Array(logLines.prefix(200)) }
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCheckOnWake else { return }
                await self.checkAll()
            }
        }
    }

    private func loadSettings() {
        lastCheckDate = UserDefaults.standard.object(forKey: "lastCheckDate") as? Date
    }

    private func saveSettings() {
        UserDefaults.standard.set(lastCheckDate, forKey: "lastCheckDate")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
