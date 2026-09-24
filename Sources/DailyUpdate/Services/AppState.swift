import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    typealias PlannedCommandResolver = @Sendable (DetectorConfig, String?, CommandPathLookup) async -> (commandSpec: CommandSpec, fingerprint: String)?

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
    @Published var administratorPermissionItem: UpdateItem?
    @Published var discoveredRepoCount = 0
    @Published var discoveredAppCount = 0
    @Published var discoveredSkillCount = 0
    @Published var history: [UpdateHistoryEntry] = []
    @Published var healthIssues: [HealthIssue] = []
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var launchAtLoginError: String?

    let settingsStore: UserSettingsStore
    private let scheduler = SchedulerService()

    weak var appDelegate: AppDelegate?
    private var configs: [DetectorConfig] = []
    private let plannedCommandResolver: PlannedCommandResolver
    private var wakeObserver: NSObjectProtocol?
    private var hasRunStartupCheck = false
    private var cancellables = Set<AnyCancellable>()
    private var administratorPermissionQueue: [UpdateItem] = []
    private var pendingDryRunItemIDs: [String] = []
    private var pendingExecutionPlan: [String: PlannedExecutionItem] = [:]

    struct PlannedExecutionItem {
        let id: String
        let action: String
        let command: String
        let workingDirectory: String?
        let ownerFingerprint: String?
    }

    init(
        settingsStore: UserSettingsStore = UserSettingsStore(),
        plannedCommandResolver: @escaping PlannedCommandResolver = { config, targetVersion, lookup in
            await StrategyPlanner.plannedCommand(
                config: config,
                targetVersion: targetVersion,
                pathLookup: lookup
            )
        }
    ) {
        self.settingsStore = settingsStore
        self.plannedCommandResolver = plannedCommandResolver
        settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
            if let error = LaunchAtLogin.setEnabled(newValue) {
                launchAtLoginError = error
                appendLog("Launch at login: \(error)")
                return
            }
            launchAtLoginError = nil
            settingsStore.settings.launchAtLogin = newValue
            settingsStore.save()
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
        if showUpdatesOnly {
            result = result.filter {
                $0.status == .updateAvailable || $0.status == .gated || $0.status == .updatePending
            }
        }
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
        items.filter { !$0.permanentlyIgnored && !$0.isSnoozed }
    }

    var listTitle: String {
        if showDashboard { return "Dashboard" }
        if showHistory { return "History" }
        if showUpdatesOnly { return "Updates Available" }
        if let selectedCategory { return selectedCategory.label }
        return "All Items"
    }

    var updateAvailableCount: Int {
        activeItems.filter { $0.status == .updateAvailable || $0.status == .gated || $0.status == .updatePending }.count
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
            totalItems: activeItems.count,
            installedCount: installedItems.count,
            updatesAvailable: updateAvailableCount,
            snoozedCount: items.filter(\.isSnoozed).count,
            autoUpdateCount: items.filter(\.autoUpdate).count,
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

    func markCommandReviewed(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let hash = configs
            .first(where: { $0.id == id })
            .map(GatePolicy.reviewedCommandHash(for:))
            ?? items[index].commandReviewHash
        settingsStore.updatePreference(for: id) { $0.reviewedCommandHash = hash }
        items[index].needsReview = false
        items[index].gateReasons.removeAll { $0 == .needsReview }
        if items[index].status == .gated {
            if items[index].gateReasons.isEmpty {
                items[index].status = .updateAvailable
                items[index].statusMessage = nil
            } else {
                let labels = items[index].gateReasons.map(\.label).joined(separator: ", ")
                items[index].statusMessage = "Gated: \(labels)"
            }
        }
        appendLog("Marked \(items[index].name) command as reviewed")
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

    func unignoreItem(id: String) {
        settingsStore.updatePreference(for: id) { $0.permanentlyIgnored = false }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].permanentlyIgnored = false
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
        guard settingsStore.settings.hasCompletedSetup else { return }
        guard !hasRunStartupCheck else { return }
        hasRunStartupCheck = true

        if settingsStore.settings.showDashboardOnLaunch { setSidebarSelection("dashboard") }
        if autoCheckOnLaunch { await checkAll() }
        if autoUpdateOnLaunch, updateAvailableCount > 0 {
            selectAllUpdates()
            await requestUpdateSelected()
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

    func setSelection(for id: String, selected: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].isSelected != selected else { return }
        items[index].isSelected = selected
    }

    func toggleSelection(for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSelected.toggle()
    }

    func selectAllUpdates(limitTo ids: [String]? = nil) {
        let visibleIDs = ids.map(Set.init)
        for index in items.indices {
            if let visibleIDs, !visibleIDs.contains(items[index].id) { continue }
            let item = items[index]
            items[index].isSelected = GatePolicy.shouldAutoSelectForUpdate(item) && !item.isSnoozed
        }
    }

    func selectAllInstallable() {
        for index in items.indices {
            items[index].isSelected = ActionCommandPolicy.shouldAutoSelectForInstall(items[index])
        }
    }

    func selectAllActionable(limitTo ids: [String]? = nil) {
        let visibleIDs = ids.map(Set.init)
        for index in items.indices {
            if let visibleIDs, !visibleIDs.contains(items[index].id) { continue }
            let item = items[index]
            items[index].isSelected = item.isActionable && !(item.isBulkOperation && item.canUpdate)
        }
    }

    func deselectAll(limitTo ids: [String]? = nil) {
        let visibleIDs = ids.map(Set.init)
        for index in items.indices {
            if let visibleIDs, !visibleIDs.contains(items[index].id) { continue }
            items[index].isSelected = false
        }
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
        guard !isUpdating else {
            appendLog("Check skipped: an update is running")
            return
        }
        isChecking = true
        checkedItemCount = 0
        appendLog("Starting update check…")
        if rescanReposOnLaunch { reloadConfigs() }

        let appFolders = settingsStore.settings.applicationFolders
        let prefs = settingsStore.settings.itemPreferences
        let pathLookup = await strategyLookup(for: configs)
        totalItemCount = configs.count
        for index in items.indices { items[index].status = .checking }

        let maximumConcurrentChecks = 6
        for batchStart in stride(from: 0, to: configs.count, by: maximumConcurrentChecks) {
            let batchEnd = min(batchStart + maximumConcurrentChecks, configs.count)
            await withTaskGroup(of: (Int, UpdateItem).self) { group in
            for index in batchStart..<batchEnd {
                let config = configs[index]
                group.addTask {
                    var item = config.toUpdateItem()
                    let pref = prefs[config.id]
                    let reviewedHash = pref?.reviewedCommandHash
                    if let pref {
                        item.autoUpdate = pref.autoUpdate
                        item.snoozedUntil = pref.snoozedUntil
                        item.pinnedVersion = pref.pinnedVersion
                        item.permanentlyIgnored = pref.permanentlyIgnored
                    }
                    if item.permanentlyIgnored || item.isSnoozed {
                        item.status = .unknown
                        item.statusMessage = item.isSnoozed ? "Snoozed" : "Ignored"
                        return (index, item)
                    }
                    if config.requiresReviewBeforeAutomation &&
                        !GatePolicy.isReviewSatisfied(for: config, reviewedHash: reviewedHash) {
                        item.status = .gated
                        item.statusMessage = "Needs review before running commands"
                        item.gateReasons = [.needsReview]
                        item.blockReason = nil
                        item.plannedUpdateCommandSpec = nil
                        item.ownerFingerprint = nil
                        item.isSelected = false
                        return (index, item)
                    }
                    let detection = await DetectionService.detect(config, applicationFolders: appFolders)
                    if detection.blockReason == .unsafeCheckCommand {
                        item.status = .blocked
                        item.statusMessage = detection.message ?? "Blocked unsafe detect command"
                        item.blockReason = .unsafeCheckCommand
                        item.isSelected = false
                        return (index, item)
                    }
                    item.isInstalled = detection.installed
                    if !detection.installed {
                        item.status = .notInstalled
                        item.statusMessage = detection.message
                        item.plannedUpdateCommandSpec = nil
                        item.ownerFingerprint = nil
                        return (index, item)
                    }
                    let check = await UpdateCheckService.check(
                        config,
                        installed: detection.installed,
                        reviewedCommandHash: reviewedHash,
                        pathLookup: pathLookup
                    )
                    item.status = check.status
                    item.currentVersionRaw = check.currentVersionRaw
                    item.currentVersion = check.currentVersion
                    item.latestVersion = check.latestVersion
                    item.statusMessage = check.message
                    item.gateReasons = check.gateReasons
                    item.blockReason = check.blockReason
                    item.needsReview = check.gateReasons.contains(.needsReview)
                    item.plannedUpdateCommandSpec = check.plannedUpdateCommandSpec
                    item.ownerFingerprint = check.ownerFingerprint
                    applyPinnedGateIfNeeded(to: &item)
                    item.isSelected = item.status == .updateAvailable && !item.isSnoozed
                    return (index, item)
                }
            }
            for await (index, updated) in group {
                items[index] = updated
                checkedItemCount += 1
            }
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

        if confirmBeforeUpdate || requiresForcedConfirmation(for: targets) {
            presentDryRun(for: targets)
            return
        }
        await updateSelected(skipDryRun: true)
    }

    func retryUpdate(for id: String) async {
        guard let item = items.first(where: { $0.id == id }), item.canRetryUpdate else { return }
        if configs.contains(where: { $0.id == id }) {
            appendLog("Re-checking \(item.name) before retry…")
            await recheckItems(ids: [id])
        }
        guard let refreshed = items.first(where: { $0.id == id }) else { return }
        guard refreshed.status == .updateAvailable else {
            appendLog("Retry skipped for \(refreshed.name): update is no longer available")
            return
        }
        deselectAll()
        if let index = items.firstIndex(where: { $0.id == refreshed.id }) {
            items[index].isSelected = true
        }
        await requestUpdateSelected()
    }

    func dismissDryRun() {
        showDryRun = false
        dryRunEntries = []
        pendingDryRunItemIDs = []
        pendingExecutionPlan = [:]
    }

    func confirmDryRun() async {
        let targetIDs = pendingDryRunItemIDs
        let plannedEntries = dryRunEntries
        let plannedExecution = pendingExecutionPlan
        guard !targetIDs.isEmpty else {
            appendLog("No items selected")
            return
        }
        dismissDryRun()

        let plannedByID = Dictionary(uniqueKeysWithValues: plannedEntries.map { ($0.id, $0) })
        let confirmedPlan = actionTargets(for: targetIDs).compactMap { target -> PlannedExecutionItem? in
            guard let planned = plannedByID[target.id] else { return nil }
            guard let execution = plannedExecution[target.id] else { return nil }
            if planned.action != target.actionLabel ||
                planned.command != actionCommand(for: target) ||
                execution.workingDirectory != normalizedWorkingDirectory(for: target.workingDirectory) {
                appendLog("\(target.name): changed since you confirmed, not run")
                return nil
            }
            return execution
        }
        guard !confirmedPlan.isEmpty else {
            appendLog("Nothing run: all items changed since you confirmed")
            return
        }
        let planByID = Dictionary(uniqueKeysWithValues: confirmedPlan.map { ($0.id, $0) })
        await updateSelected(
            skipDryRun: true,
            explicitTargetIDs: confirmedPlan.map(\.id),
            explicitPlan: planByID
        )
    }

    func updateSelected(
        skipDryRun: Bool = false,
        retryItemID: String? = nil,
        explicitTargetIDs: [String]? = nil,
        explicitPlan: [String: PlannedExecutionItem]? = nil
    ) async {
        guard !isUpdating else { return }
        let targets: [UpdateItem]
        let plannedByID: [String: PlannedExecutionItem]

        if let explicitPlan, !explicitPlan.isEmpty {
            let requestedOrder = (explicitTargetIDs ?? [])
                .filter { explicitPlan[$0] != nil }
            let idsInOrder = requestedOrder.isEmpty ? Array(explicitPlan.keys).sorted() : requestedOrder
            targets = actionTargets(for: idsInOrder)
            plannedByID = explicitPlan
        } else if let explicitTargetIDs, !explicitTargetIDs.isEmpty {
            targets = actionTargets(for: explicitTargetIDs)
            plannedByID = Dictionary(uniqueKeysWithValues: targets.map { item in
                (
                    item.id,
                    PlannedExecutionItem(
                        id: item.id,
                        action: item.actionLabel,
                        command: actionCommand(for: item),
                        workingDirectory: normalizedWorkingDirectory(for: item.workingDirectory),
                        ownerFingerprint: item.ownerFingerprint
                    )
                )
            })
        } else if let retryItemID,
                  let retryItem = activeItems.first(where: { $0.id == retryItemID }) {
            targets = [retryItem]
            plannedByID = Dictionary(uniqueKeysWithValues: targets.map { item in
                (
                    item.id,
                    PlannedExecutionItem(
                        id: item.id,
                        action: item.actionLabel,
                        command: actionCommand(for: item),
                        workingDirectory: normalizedWorkingDirectory(for: item.workingDirectory),
                        ownerFingerprint: item.ownerFingerprint
                    )
                )
            })
        } else {
            targets = orderedActionTargets(selectedActionableItems)
            plannedByID = Dictionary(uniqueKeysWithValues: targets.map { item in
                (
                    item.id,
                    PlannedExecutionItem(
                        id: item.id,
                        action: item.actionLabel,
                        command: actionCommand(for: item),
                        workingDirectory: normalizedWorkingDirectory(for: item.workingDirectory),
                        ownerFingerprint: item.ownerFingerprint
                    )
                )
            })
        }
        guard !targets.isEmpty else { appendLog("No items selected"); return }

        if !skipDryRun && (confirmBeforeUpdate || requiresForcedConfirmation(for: targets)) {
            presentDryRun(for: targets)
            return
        }

        isUpdating = true
        appendLog("Running \(targets.count) action(s)…")
        var successCount = 0
        var failCount = 0
        var skippedDueToChanges = 0
        var updatedIDs: [String] = []
        var successfulIDs = Set<String>()
        let targetIDs = targets.map(\.id)
        let strategyConfigs = configs.filter { targetIDs.contains($0.id) }
        let pathLookup = await strategyLookup(for: strategyConfigs)

        for target in targets {
            guard let initialPlan = plannedByID[target.id],
                  let initialIndex = items.firstIndex(where: { $0.id == target.id }) else {
                continue
            }

            let plannedCommand = initialPlan.command
            let plannedWorkingDirectory = initialPlan.workingDirectory

            if actionCommand(for: items[initialIndex]) != plannedCommand ||
                normalizedWorkingDirectory(for: items[initialIndex].workingDirectory) != plannedWorkingDirectory {
                skippedDueToChanges += 1
                items[initialIndex].isSelected = false
                appendLog("\(items[initialIndex].name): changed since you confirmed, not run")
                continue
            }

            if let config = configs.first(where: { $0.id == target.id }),
               items[initialIndex].plannedUpdateCommandSpec != nil {
                guard let expectedFingerprint = initialPlan.ownerFingerprint,
                      let replanned = await plannedCommandResolver(
                          config,
                          items[initialIndex].latestVersion,
                          pathLookup
                      ),
                      replanned.commandSpec.displayString == plannedCommand,
                      replanned.fingerprint == expectedFingerprint else {
                    skippedDueToChanges += 1
                    items[initialIndex].isSelected = false
                    appendLog("\(items[initialIndex].name): changed since you confirmed, not run")
                    continue
                }

                guard let postAwaitIndex = items.firstIndex(where: { $0.id == target.id }),
                      actionCommand(for: items[postAwaitIndex]) == plannedCommand,
                      normalizedWorkingDirectory(for: items[postAwaitIndex].workingDirectory) == plannedWorkingDirectory else {
                    skippedDueToChanges += 1
                    if let postAwaitIndex = items.firstIndex(where: { $0.id == target.id }) {
                        items[postAwaitIndex].isSelected = false
                        appendLog("\(items[postAwaitIndex].name): changed since you confirmed, not run")
                    }
                    continue
                }
                items[postAwaitIndex].plannedUpdateCommandSpec = replanned.commandSpec
                items[postAwaitIndex].ownerFingerprint = replanned.fingerprint
            }

            guard let index = items.firstIndex(where: { $0.id == target.id }),
                  actionCommand(for: items[index]) == plannedCommand,
                  normalizedWorkingDirectory(for: items[index].workingDirectory) == plannedWorkingDirectory else {
                if let index = items.firstIndex(where: { $0.id == target.id }) {
                    items[index].isSelected = false
                    appendLog("\(items[index].name): changed since you confirmed, not run")
                }
                skippedDueToChanges += 1
                continue
            }

            let installing = items[index].canInstall
            let verb = installing ? "Installing" : "Updating"
            items[index].status = .updating
            appendLog("\(verb) \(target.name)…")

            let fromVersion = items[index].currentVersion
            let command = actionCommand(for: items[index])
            let result = await UpdateExecutor.update(
                items[index],
                installing: installing,
                stashRepos: stashReposBeforeUpdate
            )
            items[index].status = result.status
            items[index].gateReasons = []
            items[index].blockReason = nil
            if result.status == .updated {
                items[index].isInstalled = true
            }
            items[index].currentVersion = result.currentVersion ?? items[index].currentVersion
            items[index].latestVersion = result.latestVersion ?? items[index].latestVersion
            items[index].statusMessage = result.message
            items[index].isSelected = result.canRetry && !items[index].isBulkOperation
            updatedIDs.append(target.id)

            if items[index].needsAdministratorPermission {
                queueAdministratorPermission(for: items[index])
            }

            let entry = UpdateHistoryEntry(
                itemID: target.id,
                itemName: target.name,
                fromVersion: fromVersion,
                toVersion: result.currentVersion,
                success: result.completedOrInitiated,
                message: result.message,
                command: command
            )
            UpdateHistoryStore.append(entry)
            history.insert(entry, at: 0)

            switch result.status {
            case .updated:
                successCount += 1
                successfulIDs.insert(target.id)
                appendLog("✓ \(target.name) \(installing ? "installed" : "updated")")
            case .updatePending:
                successCount += 1
                appendLog("↪ \(target.name): \(result.message ?? "Finish update in app")")
            case .failedVerification:
                failCount += 1
                appendLog("↪ \(target.name): \(result.message ?? "Verification failed after update")")
            default:
                failCount += 1
                appendLog("✗ \(target.name): \(result.message ?? "failed")")
            }
        }

        isUpdating = false
        appendLog("Action run finished")
        if successCount == 0, failCount == 0, skippedDueToChanges == targets.count {
            appendLog("Nothing run: all items changed since you confirmed")
        }
        publishWidgetSnapshot()
        appDelegate?.refreshStatusBar()

        if notificationsEnabled {
            await NotificationService.notifyUpdateComplete(success: successCount, failed: failCount)
        }
        await recheckItems(ids: updatedIDs, successfulIDs: successfulIDs)
        presentNextAdministratorPermissionRequest()
    }

    func manualActionCommand(for id: String) -> String? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let command = ConfigLoader.resolveCommand(actionCommand(for: item))
        guard !command.isEmpty else { return nil }
        if let workingDirectory = item.workingDirectory?.expandingTilde, !workingDirectory.isEmpty {
            return "cd \(ShellEscaping.quote(workingDirectory)) && \(command)"
        }
        return command
    }

    @discardableResult
    func copyActionCommandToClipboard(for id: String) -> Bool {
        guard let command = manualActionCommand(for: id) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didCopy = pasteboard.setString(command, forType: .string)
        if let item = items.first(where: { $0.id == id }), didCopy {
            appendLog("Copied manual update command for \(item.name).")
        }
        return didCopy
    }

    func openActionCommandInTerminal(for id: String) async {
        guard let command = manualActionCommand(for: id) else { return }
        let result = await TerminalCommandLauncher.openInTerminal(command: command)
        guard result.succeeded else {
            appendLog("Failed to open Terminal command (\(result.stderr.nilIfEmpty ?? "unknown error")).")
            return
        }
        if let item = items.first(where: { $0.id == id }) {
            appendLog("Opened Terminal command for \(item.name).")
        }
    }

    func dismissAdministratorPermissionRequest() {
        administratorPermissionItem = nil
    }

    func recheckItems(ids: [String], successfulIDs: Set<String> = []) async {
        guard !ids.isEmpty else { return }
        let appFolders = settingsStore.settings.applicationFolders
        let prefs = settingsStore.settings.itemPreferences
        let idSet = Set(ids)
        let scopedConfigs = configs.filter { idSet.contains($0.id) }
        let pathLookup = await strategyLookup(for: scopedConfigs)

        for index in items.indices where idSet.contains(items[index].id) {
            items[index].status = .checking
        }

        for index in items.indices where idSet.contains(items[index].id) {
            guard let config = configs.first(where: { $0.id == items[index].id }) else { continue }
            if items[index].permanentlyIgnored || items[index].isSnoozed { continue }
            let reviewedHash = prefs[config.id]?.reviewedCommandHash
            if config.requiresReviewBeforeAutomation &&
                !GatePolicy.isReviewSatisfied(for: config, reviewedHash: reviewedHash) {
                items[index].status = .gated
                items[index].statusMessage = "Needs review before running commands"
                items[index].gateReasons = [.needsReview]
                items[index].blockReason = nil
                items[index].plannedUpdateCommandSpec = nil
                items[index].ownerFingerprint = nil
                items[index].isSelected = false
                continue
            }

            let detection = await DetectionService.detect(config, applicationFolders: appFolders)
            if detection.blockReason == .unsafeCheckCommand {
                items[index].status = .blocked
                items[index].statusMessage = detection.message ?? "Blocked unsafe detect command"
                items[index].blockReason = .unsafeCheckCommand
                items[index].isSelected = false
                continue
            }
            items[index].isInstalled = detection.installed
            if !detection.installed {
                items[index].status = .notInstalled
                items[index].statusMessage = detection.message
                items[index].plannedUpdateCommandSpec = nil
                items[index].ownerFingerprint = nil
                continue
            }

            let check = await UpdateCheckService.check(
                config,
                installed: detection.installed,
                reviewedCommandHash: reviewedHash,
                pathLookup: pathLookup
            )
            let reconciled = reconcileAfterUpdate(
                wasSuccessfulUpdate: successfulIDs.contains(items[index].id),
                checkStatus: check.status,
                current: check.currentVersion,
                latest: check.latestVersion
            )
            items[index].status = reconciled
            items[index].currentVersion = check.currentVersion
            items[index].currentVersionRaw = check.currentVersionRaw
            items[index].latestVersion = check.latestVersion
            items[index].gateReasons = check.gateReasons
            items[index].blockReason = check.blockReason
            items[index].needsReview = check.gateReasons.contains(.needsReview)
            items[index].plannedUpdateCommandSpec = check.plannedUpdateCommandSpec
            items[index].ownerFingerprint = check.ownerFingerprint
            applyPinnedGateIfNeeded(to: &items[index])
            if items[index].status == .gated,
               items[index].statusMessage == nil {
                let labels = items[index].gateReasons.map(\.label).joined(separator: ", ")
                items[index].statusMessage = labels.isEmpty ? "Gated" : "Gated: \(labels)"
            } else if let message = check.message {
                items[index].statusMessage = message
            } else if reconciled == .upToDate {
                items[index].statusMessage = nil
            }
            items[index].isSelected = items[index].status == .updateAvailable && !items[index].isBulkOperation
        }

        refreshDuplicates()
        publishWidgetSnapshot()
        appDelegate?.refreshStatusBar()
    }

    private func reconcileAfterUpdate(
        wasSuccessfulUpdate: Bool,
        checkStatus: ItemStatus,
        current: String?,
        latest: String?
    ) -> ItemStatus {
        if wasSuccessfulUpdate,
           let current,
           let latest,
           VersionComparator.isAtLeast(current: current, latest: latest) {
            return .upToDate
        }
        if checkStatus == .updateAvailable || checkStatus == .gated,
           let current,
           let latest,
           VersionComparator.isAtLeast(current: current, latest: latest) {
            return .upToDate
        }
        return checkStatus
    }

    private func strategyLookup(for configs: [DetectorConfig]) async -> CommandPathLookup {
        let commandNames = configs
            .filter { StrategyPlanner.usesTypedEngine(config: $0) }
            .compactMap { $0.command?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return await OwnerResolver.lookup(commandNames: commandNames)
    }

    private func normalizedWorkingDirectory(for value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func actionCommand(for item: UpdateItem) -> String {
        if item.canInstall {
            return item.installCommand
        }
        if let commandSpec = item.plannedUpdateCommandSpec {
            return commandSpec.displayString
        }
        return item.updateCommand
    }

    private func queueAdministratorPermission(for item: UpdateItem) {
        guard administratorPermissionItem?.id != item.id,
              !administratorPermissionQueue.contains(where: { $0.id == item.id }) else { return }
        administratorPermissionQueue.append(item)
    }

    private func presentNextAdministratorPermissionRequest() {
        guard !isUpdating, administratorPermissionItem == nil else { return }

        while !administratorPermissionQueue.isEmpty {
            let item = administratorPermissionQueue.removeFirst()
            guard items.contains(where: { $0.id == item.id }) else { continue }
            administratorPermissionItem = item
            appendLog("Manual Terminal update is needed for \(item.name).")
            return
        }
    }

    private func orderedActionTargets(_ targets: [UpdateItem]) -> [UpdateItem] {
        orderedUpdateTargets(targets)
    }

    func updateAutoItems() async {
        for index in items.indices {
            items[index].isSelected = items[index].autoUpdate &&
                !items[index].isSnoozed &&
                !items[index].permanentlyIgnored &&
                !items[index].isBulkOperation &&
                items[index].status == .updateAvailable
        }
        await requestUpdateSelected()
    }

    private func requiresForcedConfirmation(for targets: [UpdateItem]) -> Bool {
        targets.contains { $0.isBulkOperation || $0.isRemoteScriptOperation || $0.requiresCommandReview }
    }

    private func presentDryRun(for targets: [UpdateItem]) {
        pendingDryRunItemIDs = targets.map(\.id)
        pendingExecutionPlan = Dictionary(uniqueKeysWithValues: targets.map { item in
            (
                item.id,
                PlannedExecutionItem(
                    id: item.id,
                    action: item.actionLabel,
                    command: actionCommand(for: item),
                    workingDirectory: normalizedWorkingDirectory(for: item.workingDirectory),
                    ownerFingerprint: item.ownerFingerprint
                )
            )
        })
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
    }

    private func actionTargets(for ids: [String]) -> [UpdateItem] {
        let activeByID = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, $0) })
        return ids.compactMap { activeByID[$0] }
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

private func applyPinnedGateIfNeeded(to item: inout UpdateItem) {
    guard let pinned = item.pinnedVersion?.nilIfEmpty,
          let target = item.latestVersion?.nilIfEmpty,
          !GatePolicy.versionsMatch(target, pinned) else {
        return
    }
    guard item.status == .updateAvailable || item.status == .gated else {
        return
    }
    if !item.gateReasons.contains(.pinned) {
        item.gateReasons.append(.pinned)
    }
    item.status = .gated
    let labels = item.gateReasons.map(\.label).joined(separator: ", ")
    item.statusMessage = labels.isEmpty ? "Gated" : "Gated: \(labels)"
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
