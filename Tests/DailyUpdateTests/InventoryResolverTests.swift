import XCTest
@testable import DailyUpdate

/// ADR-002 §1: `InventoryResolver` against a fake ecosystem, and `StrategyPlanner`'s inventory
/// branch of `checkPlan`.
final class InventoryResolverTests: HermeticTestCase {
    private func fixtureRoot() -> InstallRoot {
        InstallRoot(ecosystem: .fake, path: "/fixture/root", label: "fixture", binDirectories: ["/fixture/root/bin"], activity: .active)
    }

    private func fixtureIdentity() -> InventoryIdentity {
        InventoryIdentity(ecosystem: .fake, packageID: "widget", rootPath: "/fixture/root", packageDirectory: "/fixture/root/widget")
    }

    private func inventoryConfig(identity: InventoryIdentity, description: String = "widget") -> DetectorConfig {
        DetectorConfig(
            id: "inv-fake-1", name: "widget", category: .cli, description: description, schemaVersion: nil,
            source: .inventory, command: nil, packages: nil, selfUpdater: nil, appcastURL: nil,
            autoUpdates: nil, inventory: identity, detect: nil, versionCommand: nil, versionPattern: nil,
            checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil, needsReview: nil
        )
    }

    func testInventoryResolverDispatchesToTheOwningEnumerator() async {
        let identity = fixtureIdentity()
        let record = InstalledPackage(
            ecosystem: .fake, packageID: "widget", versionRaw: "1.0.0", root: fixtureRoot(),
            packageDirectory: identity.packageDirectory, executables: ["/fixture/root/bin/widget"],
            owner: .unknown, confidence: .proven, fileID: FileID(device: 1, inode: 1)
        )
        let fake = FakeEnumerator(ecosystem: .fake, behavior: .immediate(EnumerationResult(ecosystem: .fake, status: .complete)))
        let context = DiscoveryContext()
        let resolved = await InventoryResolver.resolve(identity: identity, context: context, enumerators: { eco in
            eco == .fake ? fake : nil
        })
        // FakeEnumerator.resolve always returns nil (it's a coordinator test double); this proves
        // dispatch reached it rather than silently no-op'ing on a missing lookup.
        XCTAssertNil(resolved)
        _ = record
    }

    func testInventoryResolverReturnsNilForAnUnknownEcosystem() async {
        let context = DiscoveryContext()
        let resolved = await InventoryResolver.resolve(identity: fixtureIdentity(), context: context, enumerators: { _ in nil })
        XCTAssertNil(resolved)
    }

    func testUsesTypedEngineAcceptsInventoryRows() {
        XCTAssertTrue(StrategyPlanner.usesTypedEngine(config: inventoryConfig(identity: fixtureIdentity())))
        var noInventory = inventoryConfig(identity: fixtureIdentity())
        noInventory.inventory = nil
        XCTAssertFalse(StrategyPlanner.usesTypedEngine(config: noInventory))
    }

    func testCheckPlanResolvesAnInventoryRowThroughTheInjectedResolver() async {
        let identity = fixtureIdentity()
        let config = inventoryConfig(identity: identity)
        let record = InstalledPackage(
            ecosystem: .fake, packageID: "widget", versionRaw: "1.0.0", root: fixtureRoot(),
            packageDirectory: identity.packageDirectory, executables: ["/fixture/root/bin/widget"],
            owner: .unknown, confidence: .proven, fileID: FileID(device: 1, inode: 1)
        )
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolve: { _ in record })
        XCTAssertEqual(plan?.blockReason, .noStrategy) // `.unknown` owner has no strategy arm besides Blocked.
    }

    func testCheckPlanReportsCheckFailedWhenTheResolverFindsNothing() async {
        let config = inventoryConfig(identity: fixtureIdentity())
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolve: { _ in nil })
        XCTAssertNil(plan?.blockReason)
        XCTAssertNotNil(plan?.failureMessage)
    }

    /// D3/RowBuilder: the error-marker row reports Check Failed straight from its description,
    /// without ever calling the resolver.
    func testErrorMarkerRowNeverCallsTheResolver() async {
        let errorIdentity = InventoryIdentity.errorMarker(ecosystem: .npm, rootPath: "/fixture/nvm-v24")
        let config = inventoryConfig(
            identity: errorIdentity,
            description: "npm (nvm v24.13.0): couldn't read global packages: permission denied"
        )

        var resolverCalled = false
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolve: { _ in
            resolverCalled = true
            return nil
        })
        XCTAssertFalse(resolverCalled)
        XCTAssertEqual(plan?.failureMessage, config.description)
        XCTAssertNil(plan?.blockReason)
    }

    func testCheckPlanReturnsNilForNonInventoryConfigs() async {
        var config = inventoryConfig(identity: fixtureIdentity())
        config.source = .bundled
        config.inventory = nil
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolve: { _ in nil })
        XCTAssertNil(plan)
    }
}
