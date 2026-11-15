import XCTest
@testable import DailyUpdate

/// M2.2: the GUI update flow. G1 discovered rows can be selected and run (only through the planner), G2 a check
/// does not make the table lay out once per item, G3 nothing is pre-selected after a check.
@MainActor
final class GUIUpdateFlowTests: HermeticTestCase {
    override func setUp() { super.setUp(); reset() }
    override func tearDown() { reset(); super.tearDown() }
    private func reset() {
        let store = UserSettingsStore()
        store.settings = .defaults
        store.save()
    }

    // MARK: - Fixtures

    nonisolated private func row(_ package: String = "widget") -> DetectorConfig {
        DetectorConfig(
            id: "inv-npm-\(package)", name: package, category: .cli, description: nil, source: .inventory,
            inventory: InventoryIdentity(ecosystem: .npm, packageID: package, rootPath: "/fixture/root", packageDirectory: "/fixture/root/lib/node_modules/\(package)"),
            handle: "npm:\(package)", detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil)
    }

    private func state(
        resolver: @escaping AppState.PlannedCommandResolver = { _, _, _ in nil }, rows: [DetectorConfig]? = nil
    ) async -> AppState {
        let rows = rows ?? [row()]
        let state = AppState(settingsStore: UserSettingsStore(), plannedCommandResolver: resolver, discoverer: { _, _ in
            DiscoveryRunResult(results: [], lookup: CommandPathLookup(candidatesByName: [:], loginPath: .known([])),
                               assembly: RowBuilder.Output(rows: rows, competing: [:], shadowedByUnownedFiles: [], inactiveInstalls: []), elapsedMs: 1)
        }, discoversOnLaunch: false)
        state.notificationsEnabled = false
        await state.runDiscovery()
        return state
    }

    private func makeUpdatable(_ state: AppState, id: String = "inv-npm-widget", spec: CommandSpec?, fingerprint: String? = "fp-1") {
        let index = try! XCTUnwrap(state.items.firstIndex { $0.id == id })
        state.items[index].isInstalled = true
        state.items[index].status = .updateAvailable
        state.items[index].latestVersion = "2.0.0"
        state.items[index].plannedUpdateCommandSpec = spec
        state.items[index].ownerFingerprint = fingerprint
    }

    // MARK: - G1

    func testADiscoveredRowWithAPlannerSpecIsSelectableAndShowsThePlannedCommandInTheDryRun() async {
        let spec = CommandSpec(executablePath: "/usr/local/bin/npm", arguments: ["install", "-g", "--prefix", "/fixture/root", "widget@2.0.0"])
        let state = await state()
        makeUpdatable(state, spec: spec)
        let item = try! XCTUnwrap(state.items.first { $0.id == "inv-npm-widget" })
        XCTAssertTrue(item.updateCommand.isEmpty, "it carries no hand-written command")
        XCTAssertTrue(item.isActionable, "but its planner spec makes it actionable (this is what enables the checkbox)")
        state.setSelection(for: item.id, selected: true)
        XCTAssertEqual(state.selectedActionableItems.map(\.id), [item.id])
        await state.requestUpdateSelected()
        XCTAssertTrue(state.showDryRun)
        XCTAssertEqual(state.dryRunEntries.map(\.command), [spec.displayString], "the sheet shows exactly the planned command")
    }

    func testADiscoveredRowWithoutAPlannerSpecStaysDisabled() async {
        let state = await state()
        makeUpdatable(state, spec: nil)
        let item = try! XCTUnwrap(state.items.first { $0.id == "inv-npm-widget" })
        XCTAssertFalse(item.isActionable)
        state.setSelection(for: item.id, selected: true)
        XCTAssertTrue(state.selectedActionableItems.isEmpty)
        await state.requestUpdateSelected()
        XCTAssertFalse(state.showDryRun)
    }

    func testRunningFromTheConfirmSheetExecutesOnlyWhatThePlannerReproduces() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m22-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let spec = CommandSpec(executablePath: "/usr/bin/touch", arguments: [marker.path])
        let other = CommandSpec(executablePath: "/usr/bin/touch", arguments: [marker.path + "-other"])
        let planned = Box<(CommandSpec, String)?>((spec, "fp-1"))
        let state = await state(resolver: { _, _, _ in planned.value })
        makeUpdatable(state, spec: spec)

        // The planner now builds a DIFFERENT command: nothing runs.
        planned.value = (other, "fp-1")
        state.setSelection(for: "inv-npm-widget", selected: true)
        await state.requestUpdateSelected()
        XCTAssertTrue(state.showDryRun)
        await state.confirmDryRun()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path + "-other"), "the planner's new command is not run either")
        XCTAssertEqual(state.lastActionOutcomes["inv-npm-widget"]?.kind, .skipped)

        // The planner changed ownership: nothing runs.
        planned.value = (spec, "fp-OTHER-OWNER")
        makeUpdatable(state, spec: spec)
        state.setSelection(for: "inv-npm-widget", selected: true)
        await state.requestUpdateSelected()
        await state.confirmDryRun()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // The planner reproduces the same spec and fingerprint: that spec runs, and only that.
        planned.value = (spec, "fp-1")
        makeUpdatable(state, spec: spec)
        state.setSelection(for: "inv-npm-widget", selected: true)
        await state.requestUpdateSelected()
        await state.confirmDryRun()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the planner-built spec ran")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path + "-other"))
    }

    func testSelectAllUpdatesSelectsDiscoveredRowsToo() async {
        let spec = CommandSpec(executablePath: "/usr/local/bin/npm", arguments: ["update"])
        let state = await state(rows: [row("a"), row("b")])
        makeUpdatable(state, id: "inv-npm-a", spec: spec)
        makeUpdatable(state, id: "inv-npm-b", spec: nil)
        state.selectAllUpdates()
        XCTAssertEqual(Set(state.selectedActionableItems.map(\.id)), ["inv-npm-a"], "only the one with a planner spec can run")
    }

    // MARK: - G3

    func testNothingIsPreselectedAfterACheckExceptAutoUpdateItems() {
        var item = UpdateItem(
            id: "x", name: "x", category: .cli, description: nil, currentVersion: nil, latestVersion: nil, status: .updateAvailable,
            statusMessage: nil, isInstalled: true, isSelected: false, isUserDefined: false, source: nil, autoUpdate: false, iconPath: nil,
            detectCommand: nil, versionCommand: nil, checkCommand: nil, installCommand: "", updateCommand: "x", workingDirectory: nil)
        XCTAssertFalse(AppState.isPreselectedAfterCheck(item))
        item.autoUpdate = true
        XCTAssertTrue(AppState.isPreselectedAfterCheck(item))
        item.snoozedUntil = Date().addingTimeInterval(3600)
        XCTAssertFalse(AppState.isPreselectedAfterCheck(item), "a snoozed item is never preselected")
        item.snoozedUntil = nil
        item.status = .upToDate
        XCTAssertFalse(AppState.isPreselectedAfterCheck(item))
    }

    func testARecheckLeavesUpdatableItemsUnselectedAndSelectAllIsExplicit() async throws {
        let store = UserSettingsStore()
        func custom(_ id: String, auto: Bool) -> DetectorConfig {
            DetectorConfig(
                id: id, name: id, category: .cli, description: nil, source: .user,
                detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo UPDATE", installCommand: nil, updateCommand: "true", workingDirectory: nil)
        }
        store.settings.customItems = [custom("manual", auto: false), custom("auto", auto: true)]
        store.settings.itemPreferences["auto"] = ItemPreference(autoUpdate: true)
        let state = AppState(settingsStore: store, discoversOnLaunch: false)
        for id in ["manual", "auto"] { state.markCommandReviewed(id: id) }
        await state.recheckItems(ids: ["manual", "auto"])
        XCTAssertEqual(state.items.first { $0.id == "manual" }?.status, .updateAvailable)
        XCTAssertEqual(state.items.first { $0.id == "manual" }?.isSelected, false, "not pre-selected")
        XCTAssertEqual(state.items.first { $0.id == "auto" }?.isSelected, true, "an auto-update item is")
        state.deselectAll()
        state.selectAllUpdates()
        XCTAssertEqual(state.items.first { $0.id == "manual" }?.isSelected, true, "Select All Updates still selects it")
    }


    // MARK: - G2

    func testTheResultBufferTurnsManyResultsIntoFewApplications() {
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        var buffer = CheckResultBuffer(now: { clock.value })
        let item = UpdateItem(
            id: "x", name: "x", category: .cli, description: nil, currentVersion: nil, latestVersion: nil, status: .upToDate,
            statusMessage: nil, isInstalled: true, isSelected: false, isUserDefined: false, source: nil, autoUpdate: false, iconPath: nil,
            detectCommand: nil, versionCommand: nil, checkCommand: nil, installCommand: "", updateCommand: "x", workingDirectory: nil)
        var applications = 0
        var applied = 0
        // 114 results arriving 25 ms apart (a 2.9 s check).
        for index in 0..<114 {
            clock.value = clock.value.addingTimeInterval(0.025)
            buffer.add(index: index, item: item)
            if buffer.shouldFlush() { applied += buffer.take().count; applications += 1 }
        }
        applied += buffer.take().count   // the final application after the last batch
        applications += 1
        XCTAssertEqual(applied, 114, "no result is lost")
        XCTAssertLessThanOrEqual(applications, 9, "9 or fewer table updates instead of 114 (was: one per item)")
        XCTAssertGreaterThan(applications, 1)
    }

    func testTheBufferNeverHoldsResultsBackPastTheInterval() {
        let clock = Box(Date(timeIntervalSince1970: 0))
        var buffer = CheckResultBuffer(now: { clock.value })
        XCTAssertFalse(buffer.shouldFlush(), "nothing to apply")
        let item = UpdateItem(
            id: "x", name: "x", category: .cli, description: nil, currentVersion: nil, latestVersion: nil, status: .upToDate,
            statusMessage: nil, isInstalled: true, isSelected: false, isUserDefined: false, source: nil, autoUpdate: false, iconPath: nil,
            detectCommand: nil, versionCommand: nil, checkCommand: nil, installCommand: "", updateCommand: "x", workingDirectory: nil)
        buffer.add(index: 0, item: item)
        clock.value = Date(timeIntervalSince1970: CheckResultBuffer.interval - 0.01)
        XCTAssertFalse(buffer.shouldFlush())
        clock.value = Date(timeIntervalSince1970: CheckResultBuffer.interval + 0.01)
        XCTAssertTrue(buffer.shouldFlush(), "a result waits at most the interval")
    }

    // MARK: - G2

    /// The launch freeze came from `init` scanning every repo, app and skill folder on the main thread: the window
    /// could not exist until the scans ended. Now `init` returns with the configured items and the scans follow.
    func testLaunchShowsTheConfiguredItemsBeforeTheFolderScansFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("du-g2-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("sample-repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = UserSettingsStore()
        var settings = UserSettings.defaults
        settings.hasCompletedSetup = true
        settings.rootFolder = root.path
        settings.repoScan.limitRootToSubfolders = false
        settings.appDiscovery.enabled = false
        settings.skillDiscovery.enabled = false
        settings.notificationsEnabled = false
        store.settings = settings

        let state = AppState(settingsStore: store, discoverer: { _, _ in
            DiscoveryRunResult(results: [], lookup: CommandPathLookup(candidatesByName: [:], loginPath: .known([])),
                               assembly: RowBuilder.Output(rows: [], competing: [:], shadowedByUnownedFiles: [], inactiveInstalls: []), elapsedMs: 1)
        }, discoversOnLaunch: true)
        XCTAssertEqual(state.discoveredRepoCount, 0, "init did not scan the folders")
        XCTAssertFalse(state.items.isEmpty, "but the configured items are already there")

        await state.reloadConfigsOffMain()
        XCTAssertEqual(state.discoveredRepoCount, 1, "the background scan found the repo")
        XCTAssertTrue(state.items.contains { $0.name == "sample-repo" })
        state.discoveryTask?.cancel()
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }

}
