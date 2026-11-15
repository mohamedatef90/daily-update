import XCTest
@testable import DailyUpdate

/// M2 (P2-5): discovery rows in the live item list. No test here scans the machine: the discoverer is
/// injected, and the one "real update path" test only ever runs a `touch` inside a temp folder.
@MainActor
final class AppStateDiscoveryTests: HermeticTestCase {

    override func setUp() {
        super.setUp()
        resetStoredSettings()
    }

    override func tearDown() {
        resetStoredSettings()
        super.tearDown()
    }

    /// These tests save settings (custom items, the flags). The settings file is shared by the whole test run,
    /// so each test starts from, and leaves, the defaults.
    private func resetStoredSettings() {
        let store = UserSettingsStore()
        store.settings = .defaults
        store.save()
    }
    // MARK: - Fixtures

    nonisolated private func identity(_ package: String, ecosystem: Ecosystem = .npm, root: String = "/fixture/root") -> InventoryIdentity {
        InventoryIdentity(ecosystem: ecosystem, packageID: package, rootPath: root, packageDirectory: "\(root)/lib/node_modules/\(package)")
    }

    nonisolated private func inventoryRow(
        id: String? = nil, package: String, ecosystem: Ecosystem = .npm, root: String = "/fixture/root"
    ) -> DetectorConfig {
        DetectorConfig(
            id: id ?? "inv-\(ecosystem.rawValue)-\(package)", name: package, category: .cli, description: nil, source: .inventory,
            inventory: identity(package, ecosystem: ecosystem, root: root), handle: "\(ecosystem.rawValue):\(package)",
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil)
    }

    nonisolated private func installRoot(_ path: String = "/fixture/root", label: String = "nvm v24") -> InstallRoot {
        InstallRoot(ecosystem: .npm, path: path, label: label, binDirectories: ["\(path)/bin"], activity: .active)
    }

    nonisolated private func record(_ package: String, root: InstallRoot, version: String = "1.0.0", ecosystem: Ecosystem = .npm) -> InstalledPackage {
        InstalledPackage(
            ecosystem: ecosystem, packageID: package, versionRaw: version, root: root,
            packageDirectory: "\(root.path)/lib/node_modules/\(package)", executables: ["\(root.path)/bin/\(package)"],
            owner: .npm(prefix: root.path, package: package), confidence: .proven, fileID: FileID(device: 1, inode: UInt64(abs(package.hashValue % 100_000))))
    }

    nonisolated private func result(
        rows: [DetectorConfig], records: [InstalledPackage] = [], competing: [String: [RowBuilder.CompetingInstall]] = [:],
        inactive: [RowBuilder.InactiveInstall] = [], shadowed: [RowBuilder.ShadowedByUnownedFile] = []
    ) -> DiscoveryRunResult {
        DiscoveryRunResult(
            results: [EnumerationResult(ecosystem: .npm, records: records, status: .complete)],
            lookup: CommandPathLookup(candidatesByName: [:], loginPath: .known([])),
            assembly: RowBuilder.Output(rows: rows, competing: competing, shadowedByUnownedFiles: shadowed, inactiveInstalls: inactive),
            elapsedMs: 7)
    }

    private func makeState(
        discoverer: @escaping AppState.Discoverer = { _, _ in throw NSError(domain: "unused", code: 1) },
        plannedCommandResolver: AppState.PlannedCommandResolver? = nil,
        autoDiscovers: Bool = false,
        configure: (UserSettingsStore) -> Void = { _ in }
    ) -> AppState {
        let store = UserSettingsStore()
        configure(store)
        if let plannedCommandResolver {
            return AppState(settingsStore: store, plannedCommandResolver: plannedCommandResolver, discoverer: discoverer, discoversOnLaunch: autoDiscovers)
        }
        return AppState(settingsStore: store, discoverer: discoverer, discoversOnLaunch: autoDiscovers)
    }

    // MARK: - Merge

    func testAJoinedRowReplacesItsCatalogEntryInPlaceAndNoIDIsListedTwice() {
        let catalog = [
            DetectorConfig(id: "gh-cli", name: "GitHub CLI", category: .cli, description: nil, command: "gh",
                           detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "x", workingDirectory: nil),
            DetectorConfig(id: "other", name: "Other", category: .cli, description: nil,
                           detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "y", workingDirectory: nil),
        ]
        let joined = inventoryRow(id: "gh-cli", package: "gh", ecosystem: .brew)
        let fresh = inventoryRow(package: "typescript")
        let merged = AppState.mergeDiscovery(catalog: catalog, rows: [fresh, joined, joined])
        XCTAssertEqual(merged.map(\.id), ["gh-cli", "other", "inv-npm-typescript"], "the joined row takes the catalog entry's place; new rows follow")
        XCTAssertEqual(merged.first?.source, .inventory)
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    }

    func testMergeWithNoRowsIsTheCatalog() {
        let catalog = [inventoryRow(package: "a")]
        XCTAssertEqual(AppState.mergeDiscovery(catalog: catalog, rows: []).map(\.id), catalog.map(\.id))
    }

    func testRunDiscoveryAddsRowsAfterTheCatalogAndKeepsEveryCatalogItem() async {
        let row = inventoryRow(package: "typescript")
        let state = makeState(discoverer: { _, _ in self.result(rows: [row]) })
        let catalogIDs = state.items.map(\.id)
        XCTAssertFalse(catalogIDs.isEmpty)
        await state.runDiscovery()
        XCTAssertEqual(Array(state.items.map(\.id).prefix(catalogIDs.count)), catalogIDs)
        XCTAssertTrue(state.items.contains { $0.id == row.id && $0.inventory?.packageID == "typescript" })
        XCTAssertEqual(Set(state.items.map(\.id)).count, state.items.count, "no duplicate rows")
        XCTAssertEqual(state.discoveryStatus, .ready(rows: 1, issues: 0, elapsedMs: 7))
    }

    func testRowsAlreadyListedKeepTheirStateWhenDiscoveryRunsAgain() async {
        let state = makeState(discoverer: { _, _ in self.result(rows: [self.inventoryRow(package: "typescript")]) })
        await state.runDiscovery()
        let index = try! XCTUnwrap(state.items.firstIndex { $0.id == "inv-npm-typescript" })
        state.items[index].status = .updateAvailable
        state.items[index].latestVersion = "9.9.9"
        await state.runDiscovery()
        let after = try! XCTUnwrap(state.items.first { $0.id == "inv-npm-typescript" })
        XCTAssertEqual(after.status, .updateAvailable)
        XCTAssertEqual(after.latestVersion, "9.9.9")
    }

    func testARowThatIsGoneIsDroppedOnTheNextRun() async {
        var rows = [inventoryRow(package: "a"), inventoryRow(package: "b")]
        let box = Box(rows)
        let state = makeState(discoverer: { _, _ in self.result(rows: box.value) })
        await state.runDiscovery()
        XCTAssertTrue(state.items.contains { $0.id == "inv-npm-b" })
        rows.removeLast()
        box.value = rows
        await state.runDiscovery()
        XCTAssertFalse(state.items.contains { $0.id == "inv-npm-b" })
        XCTAssertTrue(state.items.contains { $0.id == "inv-npm-a" })
    }

    // MARK: - Failure never blocks the legacy list

    func testAFailingDiscoveryKeepsTheCatalogAndShowsABanner() async {
        let state = makeState(discoverer: { _, _ in throw NSError(domain: "boom", code: 3) })
        let before = state.items.map(\.id)
        await state.runDiscovery()
        XCTAssertEqual(state.items.map(\.id), before, "the usual list is untouched")
        guard case .failed(let reason) = state.discoveryStatus else { return XCTFail("\(state.discoveryStatus)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(state.logLines.joined().contains("Discovery did not finish"))
    }

    func testASlowDiscoveryTimesOutWithoutBlockingTheList() async {
        let original = AppState.discoveryTimeout
        AppState.discoveryTimeout = 0.2
        defer { AppState.discoveryTimeout = original }
        let state = makeState(discoverer: { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return self.result(rows: [])
        })
        let before = state.items.map(\.id)
        let started = Date()
        await state.runDiscovery()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the timeout, not the slow discoverer, ends the wait")
        XCTAssertEqual(state.items.map(\.id), before)
        guard case .failed(let reason) = state.discoveryStatus else { return XCTFail("\(state.discoveryStatus)") }
        XCTAssertTrue(reason.contains("longer than"))
    }

    func testAFailedDiscoveryDoesNotStopAChecksFirstStep() async {
        // `checkAll` begins with `ensureFreshDiscovery()`. A failing discovery must return normally.
        let state = makeState(discoverer: { _, _ in throw NSError(domain: "boom", code: 3) }, autoDiscovers: true)
        await state.ensureFreshDiscovery()
        guard case .failed = state.discoveryStatus else { return XCTFail("\(state.discoveryStatus)") }
        XCTAssertFalse(state.isChecking)
    }

    func testAChecksDiscoveryStepNeverScansWhereAutomaticDiscoveryIsOff() async {
        let calls = Box(0)
        let state = makeState(discoverer: { _, _ in calls.value += 1; return self.result(rows: []) })   // autoDiscovers: false, as in tests
        await state.ensureFreshDiscovery()
        XCTAssertEqual(calls.value, 0)
    }

    /// `checkAll` and `updateSelected` address `items` and `configs` by position. A discovery result that arrives
    /// while one runs must wait, or the two lists misalign.
    func testADiscoveryResultThatArrivesDuringACheckOrAnUpdateWaits() async {
        let box = Box([inventoryRow(package: "a")])
        let state = makeState(discoverer: { _, _ in self.result(rows: box.value) })
        await state.runDiscovery()
        let before = state.items.map(\.id)
        XCTAssertTrue(before.contains("inv-npm-a"))

        box.value = [inventoryRow(package: "a"), inventoryRow(package: "b")]
        state.isChecking = true
        await state.runDiscovery()
        XCTAssertEqual(state.items.map(\.id), before, "the list is not replaced while a check runs")
        XCTAssertNotNil(state.pendingDiscovery)

        state.isChecking = false
        state.applyPendingDiscovery()
        XCTAssertTrue(state.items.contains { $0.id == "inv-npm-b" }, "it is applied once the check is over")
        XCTAssertNil(state.pendingDiscovery)
        XCTAssertEqual(state.discoveryStatus, .ready(rows: 2, issues: 0, elapsedMs: 7))

        box.value = [inventoryRow(package: "c")]
        state.isUpdating = true
        await state.runDiscovery()
        XCTAssertTrue(state.items.contains { $0.id == "inv-npm-b" }, "nor while an update runs")
        state.applyPendingDiscovery()
        XCTAssertNotNil(state.pendingDiscovery, "and not applied while the update still runs")
        state.isUpdating = false
        state.applyPendingDiscovery()
        XCTAssertTrue(state.items.contains { $0.id == "inv-npm-c" })
    }

    func testAFreshDiscoveryIsReusedByACheck() async {
        let calls = Box(0)
        let state = makeState(discoverer: { _, _ in calls.value += 1; return self.result(rows: []) }, autoDiscovers: true)
        await state.discoveryTask?.value            // the launch pass
        XCTAssertEqual(calls.value, 1)
        await state.ensureFreshDiscovery()
        XCTAssertEqual(calls.value, 1, "a check reuses a run younger than a minute")
    }

    // MARK: - The setting

    func testDiscoveryIsOnByDefaultAndOldSettingsFilesStillLoad() throws {
        XCTAssertTrue(UserSettings().discoverInstalledTools)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(UserSettings.defaults)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "discoverInstalledTools"))
        XCTAssertTrue(try JSONDecoder().decode(UserSettings.self, from: JSONSerialization.data(withJSONObject: object)).discoverInstalledTools)
    }

    func testWithTheSettingOffTheAppBehavesAsBefore() async {
        let calls = Box(0)
        let state = makeState(discoverer: { _, _ in calls.value += 1; return self.result(rows: [self.inventoryRow(package: "x")]) },
                              autoDiscovers: true, configure: { $0.settings.discoverInstalledTools = false })
        let before = state.items.map(\.id)
        state.startDiscovery()
        await state.runDiscovery()
        await state.ensureFreshDiscovery()
        await state.rescan()
        XCTAssertEqual(calls.value, 0, "discovery never runs")
        XCTAssertEqual(state.items.map(\.id), before)
        XCTAssertEqual(state.discoveryStatus, .off)
        XCTAssertTrue(state.ecosystemGroups.isEmpty)
    }

    func testTurningTheSettingOffRemovesTheDiscoveredRows() async {
        let state = makeState(discoverer: { _, _ in self.result(rows: [self.inventoryRow(package: "x")]) })
        await state.runDiscovery()
        XCTAssertTrue(state.items.contains { $0.id == "inv-npm-x" })
        state.discoveryEnabled = false
        XCTAssertFalse(state.items.contains { $0.id == "inv-npm-x" })
        XCTAssertEqual(state.discoveryStatus, .off)
    }

    // MARK: - Display data

    func testItemDetailsShowTheActivePathCompetingInactiveAndShadowedInstalls() async {
        let active = installRoot("/fixture/nvm24", label: "nvm v24")
        let old = installRoot("/usr/local", label: "/usr/local")
        let inactiveRoot = installRoot("/fixture/nvm20", label: "nvm v20")
        let gemini = record("gemini-cli", root: active, version: "0.68.0")
        let oldGemini = record("gemini-cli", root: old, version: "0.1.21")
        let inactive = record("gemini-cli", root: inactiveRoot, version: "0.3.0")
        let row = inventoryRow(id: "gemini-cli", package: "gemini-cli", root: active.path)
        let shadowed = RowBuilder.ShadowedByUnownedFile(
            record: record("gemini-cli", root: old, version: "0.0.1"), command: "gemini", path: "/x", activePath: "/y")
        let state = makeState(discoverer: { _, _ in
            self.result(rows: [row], records: [gemini, oldGemini, inactive],
                        competing: ["gemini-cli": [RowBuilder.CompetingInstall(record: oldGemini, command: "gemini", path: "/usr/local/bin/gemini")]],
                        inactive: [RowBuilder.InactiveInstall(record: inactive, rowID: "gemini-cli"),
                                   RowBuilder.InactiveInstall(record: oldGemini, rowID: nil)],
                        shadowed: [shadowed])
        })
        await state.runDiscovery()
        let details = try! XCTUnwrap(state.discoveryDetails["gemini-cli"])
        XCTAssertEqual(details.activePath, "/fixture/nvm24/bin/gemini-cli")
        XCTAssertEqual(details.ownerBadge, "npm · nvm v24")
        XCTAssertEqual(details.competing.map(\.version), ["0.1.21"])
        XCTAssertEqual(details.competing.first?.path, "/usr/local/bin/gemini-cli")
        XCTAssertEqual(details.inactive.map(\.version), ["0.3.0"])
        XCTAssertEqual(details.shadowedByUnownedFiles.count, 1)
        XCTAssertEqual(state.discoveryUnlistedInactive.map(\.version), ["0.1.21"], "an inactive install with no row is listed at snapshot level")
        XCTAssertEqual(state.ownerBadge(for: try! XCTUnwrap(state.items.first { $0.id == "gemini-cli" })), "npm · nvm v24")
    }

    func testTheActivePathIsTheFileThatRunsNotThePackageManagersTool() async {
        let root = installRoot("/fixture/nvm24")
        let pkg = record("gemini-cli", root: root)
        var row = inventoryRow(id: "gemini-cli", package: "gemini-cli", root: root.path)
        row.inventory = InventoryIdentity(ecosystem: .npm, packageID: "gemini-cli", rootPath: root.path,
                                          packageDirectory: pkg.packageDirectory, toolPath: "/fixture/nvm24/bin/npm")
        let state = makeState(discoverer: { _, _ in self.result(rows: [row], records: [pkg]) })
        await state.runDiscovery()
        XCTAssertEqual(state.discoveryDetails["gemini-cli"]?.activePath, "/fixture/nvm24/bin/gemini-cli")
    }

    func testEcosystemGroupsCountRowsAndFilterTheList() async {
        let state = makeState(discoverer: { _, _ in
            self.result(rows: [self.inventoryRow(package: "a"), self.inventoryRow(package: "b"),
                               self.inventoryRow(package: "wget", ecosystem: .brew, root: "/opt/homebrew")])
        })
        await state.runDiscovery()
        XCTAssertEqual(state.ecosystemGroups.map { "\($0.ecosystem.rawValue):\($0.count)" }, ["brew:1", "npm:2"])
        state.setSidebarSelection("eco:npm")
        XCTAssertEqual(Set(state.filteredItems.map(\.id)), ["inv-npm-a", "inv-npm-b"])
        XCTAssertEqual(state.sidebarSelectionTag, "eco:npm")
        XCTAssertEqual(state.listTitle, "npm")
        state.setSidebarSelection("all")
        XCTAssertNil(state.selectedEcosystem)
        XCTAssertGreaterThan(state.filteredItems.count, 2, "the usual filters keep working")
    }

    func testOwnerBadgeNamesTheRootButNotForHomebrew() {
        XCTAssertEqual(EcosystemPresentation.ownerBadge(owner: .npm(prefix: "/x", package: "p"), rootLabel: "nvm v24"), "npm · nvm v24")
        XCTAssertEqual(EcosystemPresentation.ownerBadge(owner: .brewFormula("wget"), rootLabel: "Homebrew (/opt/homebrew)"), "Homebrew")
        XCTAssertEqual(PathDisplay.home("/Users/tester/.nvm/bin/x", home: "/Users/tester"), "~/.nvm/bin/x")
        XCTAssertEqual(PathDisplay.home("/usr/local/bin/x", home: "/Users/tester"), "/usr/local/bin/x")
    }

    // MARK: - Inventory rows reach the executor only with a planner-built spec

    private func stateWithAnInventoryRowReadyToUpdate(
        marker: URL, resolver: @escaping AppState.PlannedCommandResolver
    ) async -> (AppState, spec: CommandSpec) {
        let row = inventoryRow(package: "widget")
        let spec = CommandSpec(executablePath: "/usr/bin/touch", arguments: [marker.path])
        let state = makeState(discoverer: { _, _ in self.result(rows: [row]) }, plannedCommandResolver: resolver)
        state.notificationsEnabled = false
        await state.runDiscovery()
        let index = try! XCTUnwrap(state.items.firstIndex { $0.id == row.id })
        state.items[index].isInstalled = true
        state.items[index].status = .updateAvailable
        state.items[index].latestVersion = "2.0.0"
        state.items[index].plannedUpdateCommandSpec = spec
        state.items[index].ownerFingerprint = "fingerprint-1"
        state.items[index].isSelected = true
        return (state, spec)
    }

    func testAnInventoryRowWithoutAPlannerSpecIsNotActionable() async {
        let state = makeState(discoverer: { _, _ in self.result(rows: [self.inventoryRow(package: "widget")]) })
        await state.runDiscovery()
        var item = try! XCTUnwrap(state.items.first { $0.id == "inv-npm-widget" })
        item.isInstalled = true
        item.status = .updateAvailable
        XCTAssertNil(item.plannedUpdateCommandSpec)
        XCTAssertTrue(item.updateCommand.isEmpty, "a discovered row carries no hand-written command")
        XCTAssertFalse(item.isActionable, "so it can never be selected for a run")
    }

    func testAnInventoryRowIsNotRunWhenThePlannerNoLongerProducesItsCommand() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m2-marker-\(UUID().uuidString)")
        let (state, _) = await stateWithAnInventoryRowReadyToUpdate(marker: marker, resolver: { _, _, _ in nil })
        await state.updateSelected(skipDryRun: true, explicitTargetIDs: ["inv-npm-widget"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing ran")
        XCTAssertTrue(state.logLines.joined().contains("changed since you confirmed, not run"))
    }

    func testAnInventoryRowIsNotRunWhenThePlannerBuildsADifferentCommandOrOwner() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m2-marker-\(UUID().uuidString)")
        let other = CommandSpec(executablePath: "/usr/bin/touch", arguments: [marker.path + "-other"])
        let (state, _) = await stateWithAnInventoryRowReadyToUpdate(marker: marker, resolver: { _, _, _ in (other, "fingerprint-1") })
        await state.updateSelected(skipDryRun: true, explicitTargetIDs: ["inv-npm-widget"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path + "-other"))

        let (state2, spec) = await stateWithAnInventoryRowReadyToUpdate(marker: marker, resolver: { _, _, _ in
            (CommandSpec(executablePath: "/usr/bin/touch", arguments: [marker.path]), "another-owner")
        })
        _ = spec
        await state2.updateSelected(skipDryRun: true, explicitTargetIDs: ["inv-npm-widget"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a changed ownership fingerprint also stops the run")
    }

    /// The positive control: when the planner reproduces the same spec and fingerprint, the executor runs
    /// exactly that planner-built spec (a `touch` in a temp folder), and nothing else.
    func testAnInventoryRowRunsOnlyTheSpecThePlannerBuilt() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m2-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let planned = Box<[CommandSpec]>([])
        let (state, spec) = await stateWithAnInventoryRowReadyToUpdate(marker: marker, resolver: { _, _, _ in
            let spec = CommandSpec(executablePath: "/usr/bin/touch", arguments: [marker.path])
            planned.value.append(spec)
            return (spec, "fingerprint-1")
        })
        await state.updateSelected(skipDryRun: true, explicitTargetIDs: ["inv-npm-widget"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the planner-built spec ran")
        XCTAssertEqual(planned.value.first, spec)
        XCTAssertTrue(planned.value.count >= 1, "the planner was asked again right before the run")
    }

    func testTheInventoryCheckPathUsesOnlyThePlanner() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let extensionText = try String(contentsOf: root.appendingPathComponent("Sources/DailyUpdate/Services/AppState+Discovery.swift"), encoding: .utf8)
        for forbidden in ["ShellRunner", "Process()", "UpdateExecutor", "runSpec", "runCommand", "BoundedProcessRunner"] {
            XCTAssertFalse(extensionText.contains(forbidden), "AppState+Discovery must never run a command: \(forbidden)")
        }
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// P2-5 engine wiring: an inventory row (no `command`) is planned by identity, with the same refusals as
/// its check. The record comes from an injected resolver, so nothing reads the machine.
final class InventoryPlannerWiringTests: HermeticTestCase {
    private func row(error: Bool = false) -> DetectorConfig {
        let identity = error
            ? InventoryIdentity.errorMarker(ecosystem: .npm, rootPath: "/fixture/root")
            : InventoryIdentity(ecosystem: .npm, packageID: "widget", rootPath: "/fixture/root", packageDirectory: "/fixture/root/lib/node_modules/widget")
        return DetectorConfig(
            id: "inv-npm-widget", name: "widget", category: .cli, description: nil, source: .inventory, inventory: identity,
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil)
    }

    private func record(flags: Set<PackageFlag> = []) -> InstalledPackage {
        let root = InstallRoot(ecosystem: .npm, path: "/fixture/root", label: "fixture", binDirectories: ["/fixture/root/bin"], activity: .active)
        return InstalledPackage(
            ecosystem: .npm, packageID: "widget", versionRaw: "1.0.0", root: root,
            packageDirectory: "/fixture/root/lib/node_modules/widget", executables: ["/fixture/root/bin/widget"],
            owner: .npm(prefix: "/fixture/root", package: "widget"), flags: flags, confidence: .proven, fileID: FileID(device: 1, inode: 77))
    }

    func testAnInventoryRowIsUsableByTheTypedEngineWithoutACommand() {
        XCTAssertNil(row().command)
        XCTAssertTrue(StrategyPlanner.usesTypedEngine(config: row()))
    }

    func testNoCommandWhenTheInstallIsGone() async {
        let planned = await StrategyPlanner.plannedCommand(config: row(), targetVersion: "2.0.0", inventoryResolve: { _ in nil })
        XCTAssertNil(planned)
        let current = await StrategyPlanner.currentVersion(config: row(), pathLookup: nil, inventoryResolve: { _ in nil })
        XCTAssertNil(current.version)
        XCTAssertNil(current.owner)
    }

    func testNoCommandForAnUntrustedRootOrALinkedPackage() async {
        for flags: Set<PackageFlag> in [[.untrustedRoot], [.linked]] {
            let planned = await StrategyPlanner.plannedCommand(config: row(), targetVersion: "2.0.0", inventoryResolve: { _ in self.record(flags: flags) })
            XCTAssertNil(planned, "\(flags)")
        }
    }

    func testNoCommandForAnErrorMarkerRow() async {
        let planned = await StrategyPlanner.plannedCommand(config: row(error: true), targetVersion: "2.0.0", inventoryResolve: { _ in self.record() })
        XCTAssertNil(planned, "an error marker row is a message, not a package")
    }

    func testTheOwnerIsTheRecordsOwnerAndTheCommandPathIsItsExecutable() async throws {
        let resolved = await StrategyPlanner.inventoryResolution(config: row(), pathLookup: nil, resolve: { _ in self.record() })
        let found = try XCTUnwrap(resolved)
        XCTAssertEqual(found.resolution.active?.owner, .npm(prefix: "/fixture/root", package: "widget"))
        XCTAssertEqual(found.resolution.active?.commandPath, "/fixture/root/bin/widget")
    }

    func testACatalogRowStillResolvesByCommandAndIsNotAffected() async {
        var catalogRow = row()
        catalogRow = DetectorConfig(
            id: "x", name: "x", category: .cli, description: nil, source: .bundled, command: nil,
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil)
        let found = await StrategyPlanner.inventoryResolution(config: catalogRow, pathLookup: nil, resolve: { _ in self.record() })
        XCTAssertNil(found, "only inventory rows resolve by identity")
    }
}
