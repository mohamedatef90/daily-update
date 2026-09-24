import AppKit
import Combine
import Foundation

enum AppStateRuntime {
    case application
    case commandLine

    var performsDiscovery: Bool { self == .application }
    var startsBackgroundServices: Bool { self == .application }
    /// UNUserNotificationCenter aborts the process when there is no app bundle (plain CLI run).
    var postsNotifications: Bool { self == .application }
}

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
    @Published var completedUpdateItemCount = 0
    @Published var totalUpdateItemCount = 0
    @Published var currentUpdateItemName: String?
    @Published var successfulUpdateItemCount = 0
    @Published var failedUpdateItemCount = 0
    @Published var showUpdateReport = false
    @Published var updateReport: UpdateRunReport?
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
    let runtimeMode: AppStateRuntime
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

    init(
        settingsStore: UserSettingsStore = UserSettingsStore(),
        runtimeMode: AppStateRuntime = .application
    ) {
        self.settingsStore = settingsStore
        self.runtimeMode = runtimeMode
        loadSettings()
        history = UpdateHistoryStore.load()
        showOnboarding = !settingsStore.settings.hasCompletedSetup
        reloadConfigs()
        if runtimeMode.startsBackgroundServices {
            setupWakeObserver()
            syncLaunchAtLogin()
            scheduler.start(appState: self)
        }
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

    var scheduledCheckInterval: ScheduledCheckInterval {
        get { settingsStore.settings.scheduledCheckInterval ?? .hours6 }
        set { settingsStore.settings.scheduledCheckInterval = newValue; settingsStore.save() }
    }

    var scheduledCheckCustomMinutes: Int {
        get { max(15, settingsStore.settings.scheduledCheckCustomMinutes ?? 120) }
        set { settingsStore.settings.scheduledCheckCustomMinutes = max(15, newValue); settingsStore.save() }
    }

    var scheduledCheckIntervalMinutes: Int {
        scheduledCheckInterval.minutes(customMinutes: scheduledCheckCustomMinutes)
    }

    var updateProgressFraction: Double {
        guard totalUpdateItemCount > 0 else { return 0 }
        return Double(completedUpdateItemCount) / Double(totalUpdateItemCount)
    }

    var updateProgressLabel: String {
        if let currentUpdateItemName {
            return "Updating \(currentUpdateItemName) · \(completedUpdateItemCount) of \(totalUpdateItemCount) complete"
        }
        return "Updated \(completedUpdateItemCount) of \(totalUpdateItemCount)"
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

    struct DiscoveryResult {
        var repos: [DetectorConfig] = []
        var apps: [DetectorConfig] = []
        var skills: [DetectorConfig] = []
    }

    private var lastDiscovery = DiscoveryResult()
    private var discoveryTask: Task<DiscoveryResult, Never>?

    /// Rebuilds the item list immediately from bundled/custom configs plus the last known
    /// discovery, then refreshes discovery in the background. Discovery walks the scan folders
    /// (Downloads and Documents by default) and used to run synchronously here, on the main
    /// thread, inside `AppState.init`; that kept the first window from appearing for minutes.
    func reloadConfigs() {
        ConfigLoader.ensureUserConfigExists()
        applyConfigs(discovery: lastDiscovery, preserveItemState: false)
        Task { await refreshDiscovery() }
    }

    /// Runs repo/app/skill discovery off the main thread and merges the result. Concurrent
    /// callers share one in-flight scan.
    func refreshDiscovery() async {
        let settings = settingsStore.settings
        guard runtimeMode.performsDiscovery, settings.hasCompletedSetup else {
            lastDiscovery = DiscoveryResult()
            return
        }
        if let inFlight = discoveryTask {
            _ = await inFlight.value
            return
        }
        let wantsRepos = rescanReposOnLaunch
        let wantsApps = settings.appDiscovery.enabled && rescanAppsOnLaunch
        let wantsSkills = settings.skillDiscovery.enabled && rescanSkillsOnLaunch
        // A detached Task was observed (via `sample`) still executing this scan on the main
        // thread; an explicit global queue guarantees it runs off the UI thread.
        let task = Task<DiscoveryResult, Never> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Self.discover(settings: settings, repos: wantsRepos, apps: wantsApps, skills: wantsSkills))
                }
            }
        }
        discoveryTask = task
        let result = await task.value
        discoveryTask = nil
        lastDiscovery = result
        let knownIDs = Set(items.map(\.id))
        applyConfigs(discovery: result, preserveItemState: true)
        let newIDs = Set(items.map(\.id)).subtracting(knownIDs)
        if !newIDs.isEmpty, !isChecking, !isUpdating, lastCheckDate != nil {
            await refreshUpdatedItems(newIDs, progressMessage: "Checking…")
        }
    }

    nonisolated private static func discover(settings: UserSettings, repos: Bool, apps: Bool, skills: Bool) -> DiscoveryResult {
        var result = DiscoveryResult()
        if repos {
            result.repos = RepoScanner.discoverRepos(
                in: settings.allScanFolders,
                rootFolder: settings.rootFolder,
                options: settings.repoScan.scanOptions
            )
        }
        let preliminary = ConfigLoader.loadConfigs(settings: settings, discoveredRepos: result.repos)
        if apps {
            result.apps = AppScanner.discoverApps(
                in: settings.applicationFolders,
                excludingPaths: ConfigLoader.knownAppPaths(from: preliminary),
                excludingBundleIDs: ConfigLoader.knownBundleIDs(from: preliminary),
                options: AppScanOptions(
                    developerOnly: settings.appDiscovery.developerOnly,
                    scanUtilitiesFolder: settings.appDiscovery.scanUtilitiesFolder
                )
            )
        }
        if skills {
            result.skills = SkillsScanner.discoverSkillItems(
                excludingPaths: ConfigLoader.knownItemPaths(from: preliminary),
                options: SkillScanOptions(
                    scanPluginCaches: settings.skillDiscovery.scanPluginCaches,
                    skillRoots: settings.skillDiscovery.skillRoots
                )
            )
        }
        return result
    }

    /// `preserveItemState` keeps check results for items that already exist, so a background
    /// discovery finishing after a check does not wipe every row back to "Unknown".
    private func applyConfigs(discovery: DiscoveryResult, preserveItemState: Bool) {
        let settings = settingsStore.settings
        configs = ConfigLoader.loadConfigs(
            settings: settings,
            discoveredRepos: discovery.repos,
            discoveredApps: discovery.apps,
            discoveredSkills: discovery.skills
        )
        let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items = configs.map { config in
            var item = applyPreferences(to: config.toUpdateItem())
            if preserveItemState, let old = previous[config.id] {
                item.status = old.status
                item.statusMessage = old.statusMessage
                item.currentVersion = old.currentVersion
                item.latestVersion = old.latestVersion
                item.isInstalled = old.isInstalled
                item.isSelected = old.isSelected
            }
            return item
        }
        discoveredRepoCount = discovery.repos.count
        discoveredAppCount = discovery.apps.count
        discoveredSkillCount = discovery.skills.count
        duplicateGroups = DuplicateDetector.find(in: installedItems)
        markDuplicates()
        appendLog("Loaded \(configs.count) items (\(discovery.repos.count) repos, \(discovery.apps.count) apps, \(discovery.skills.count) skills discovered)")
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
        for index in items.indices {
            items[index].duplicateGroupID = nil
        }
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
        setSelection(for: id, isSelected: !items[index].isSelected)
    }

    func setSelection(for id: String, isSelected: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].isActionable else {
            return
        }
        items[index].isSelected = isSelected
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
        let selectedItemIDs = Set(items.lazy.filter(\.isSelected).map(\.id))
        isChecking = true
        checkedItemCount = 0
        appendLog("Starting update check…")
        appendLog("Refreshing package metadata…")
        if !(await FreshnessService.refreshPackageMetadata()) {
            appendLog("Package metadata refresh skipped or unavailable; continuing with live checks")
        }
        if runtimeMode.performsDiscovery && rescanReposOnLaunch {
            // Not awaited: the check must never wait on a folder walk. Newly discovered items
            // are checked by refreshDiscovery() when the scan completes.
            appendLog("Scanning folders for repos, apps, and skills in the background…")
            Task { await self.refreshDiscovery() }
        }

        let appFolders = settingsStore.settings.applicationFolders
        let prefs = settingsStore.settings.itemPreferences
        totalItemCount = configs.count
        for index in items.indices { items[index].status = .checking }

        let checkInputs = Array(configs.enumerated())
        _ = await BoundedAsyncMap.run(
            checkInputs,
            maxConcurrent: 6,
            operation: { indexedConfig in
            let (index, config) = indexedConfig
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
            // Update checks must not silently select every available update.
            // Preserve only an explicit user selection from before this scan.
            item.isSelected = selectedItemIDs.contains(item.id) && item.isActionable
            return (index, item)
            },
            onResult: { [weak self] _, checkedItem in
                let (index, updated) = checkedItem
                await MainActor.run {
                    guard let self else { return }
                    self.items[index] = updated
                    self.checkedItemCount += 1
                }
            }
        )

        lastCheckDate = Date()
        isChecking = false
        refreshDuplicates()
        appendLog("Check complete — \(updateAvailableCount) update(s) available")
        saveSettings()
        publishWidgetSnapshot()
        appDelegate?.refreshStatusBar()

        if notificationsEnabled, runtimeMode.postsNotifications, updateAvailableCount > 0 {
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
        completedUpdateItemCount = 0
        totalUpdateItemCount = targets.count
        currentUpdateItemName = nil
        successfulUpdateItemCount = 0
        failedUpdateItemCount = 0
        appendLog("Running \(targets.count) action(s)…")
        var successCount = 0
        var failCount = 0
        var results: [UpdateRunItemResult] = []

        for target in targets {
            guard let index = items.firstIndex(where: { $0.id == target.id }) else { continue }
            let installing = items[index].canInstall
            let verb = installing ? "Installing" : "Updating"
            items[index].status = .updating
            items[index].statusMessage = "\(verb)…"
            currentUpdateItemName = target.name
            appendLog("\(verb) \(target.name)…")

            let fromVersion = items[index].currentVersion
            let command = actionCommand(for: items[index])
            let result = await UpdateExecutor.update(
                items[index],
                installing: installing,
                stashRepos: stashReposBeforeUpdate
            )
            let (status, version, message) = (result.status, result.version, result.message)
            let recordedCommand = UpdateExecutor.reportedCommand(executed: result.command, fallback: command)
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
                command: recordedCommand
            )
            UpdateHistoryStore.append(entry)
            history.insert(entry, at: 0)

            results.append(UpdateRunItemResult(
                id: target.id,
                name: target.name,
                success: status == .updated,
                message: message
            ))
            completedUpdateItemCount += 1

            if status == .updated {
                successCount += 1
                successfulUpdateItemCount = successCount
                appendLog("✓ \(target.name) \(installing ? "installed" : "updated")")
            } else {
                failCount += 1
                failedUpdateItemCount = failCount
                appendLog("✗ \(target.name): \(message ?? "failed")")
            }
        }

        isUpdating = false
        currentUpdateItemName = nil
        updateReport = UpdateRunReport(
            completedAt: Date(),
            succeededCount: successCount,
            failedCount: failCount,
            results: results
        )
        appendLog("Action run finished")
        publishWidgetSnapshot()
        appDelegate?.refreshStatusBar()

        if notificationsEnabled, runtimeMode.postsNotifications {
            await NotificationService.notifyUpdateComplete(success: successCount, failed: failCount)
        }
        // Re-check only the items that actually changed. A full scan here used to
        // put every row into "Checking…", making unrelated checkboxes appear frozen.
        let successfulItemIDs = Set(results.filter(\.success).map(\.id))
        await refreshUpdatedItems(successfulItemIDs)
        showUpdateReport = true
    }

    private func refreshUpdatedItems(_ ids: Set<String>, progressMessage: String = "Verifying update…") async {
        guard !ids.isEmpty else { return }

        let appFolders = settingsStore.settings.applicationFolders
        let preferences = settingsStore.settings.itemPreferences

        for config in configs where ids.contains(config.id) {
            guard let index = items.firstIndex(where: { $0.id == config.id }) else { continue }

            var item = items[index]
            item.status = .checking
            item.statusMessage = progressMessage
            items[index] = item

            if let preference = preferences[config.id] {
                item.autoUpdate = preference.autoUpdate
                item.snoozedUntil = preference.snoozedUntil
                item.pinnedVersion = preference.pinnedVersion
                item.permanentlyIgnored = preference.permanentlyIgnored
            }

            let (installed, detectionMessage) = await DetectionService.detect(
                config,
                applicationFolders: appFolders
            )
            item.isInstalled = installed
            guard installed else {
                item.status = .error
                item.statusMessage = "Updated, but no longer detected: \(detectionMessage ?? "Unknown detection error")"
                items[index] = item
                continue
            }

            let (status, current, latest, message) = await UpdateCheckService.check(config, installed: true)
            item.status = status
            item.currentVersion = current
            item.latestVersion = latest
            item.statusMessage = item.isPinnedMismatch
                ? "Pinned to \(item.pinnedVersion ?? "")"
                : message
            item.isSelected = false
            items[index] = item
        }

        refreshDuplicates()
        publishWidgetSnapshot()
        appDelegate?.refreshStatusBar()
    }

    /// Preview/fallback text for an action. Typed items never run their detector command, so
    /// showing it would misreport what happens; the real command is recorded after the run.
    private func actionCommand(for item: UpdateItem) -> String {
        guard let strategy = DeveloperCLIStrategy.strategy(for: item.id) else {
            return "No safe automatic update command"
        }
        let action = item.canInstall ? "install" : "update"
        return "\(strategy.displayName) \(action): owner-aware command is built from the live audit when it runs"
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

    func retryUpdate(id: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].isInstalled,
              UpdateExecutor.commandToRun(for: items[index]) != nil else {
            return
        }
        deselectAll()
        items[index].isSelected = true
        await updateSelected(skipDryRun: true)
    }

    private func orderedUpdateTargets(_ targets: [UpdateItem]) -> [UpdateItem] {
        let order = settingsStore.settings.updateCategoryOrder.compactMap { ItemCategory(rawValue: $0) }
        let effectiveOrder = order.isEmpty ? UpdateGroupOrder.defaultOrder : order
        let preferredTargets = targets.sorted {
            let lhsPriority = duplicateSourcePriority($0)
            let rhsPriority = duplicateSourcePriority($1)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var selectedGroups = Set<String>()
        var uniqueTargets: [UpdateItem] = []

        for item in preferredTargets {
            let memberships = duplicateGroups
                .filter { $0.itemIDs.contains(item.id) }
                .map(\.id)
            guard !memberships.contains(where: { selectedGroups.contains($0) }) else {
                appendLog("Skipped duplicate update target: \(item.name)")
                continue
            }
            selectedGroups.formUnion(memberships)
            uniqueTargets.append(item)
        }
        return UpdateGroupOrder.sortItems(uniqueTargets, order: effectiveOrder)
    }

    private func duplicateSourcePriority(_ item: UpdateItem) -> Int {
        switch item.source {
        case .user: return 0
        case .bundled, .none: return 1
        case .discovered: return 2
        }
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
