import XCTest
@testable import DailyUpdate

/// ADR-002 §1's new `ResolvedOwner` cases and their `StrategyPlanner.makeStrategy` arms: every one
/// is Blocked with its own reason until the PR that owns its ecosystem wires a real strategy.
final class DiscoveryOwnerPlannerTests: HermeticTestCase {
    private func typedConfig(commandName: String) -> DetectorConfig {
        DetectorConfig(
            id: "test-item", name: "Test", category: .cli, description: nil, schemaVersion: 2,
            source: .bundled, command: commandName, packages: nil, selfUpdater: nil, appcastURL: nil,
            autoUpdates: nil, inventory: nil, detect: nil, versionCommand: nil, versionPattern: nil,
            checkCommand: nil, installCommand: nil, updateCommand: "noop", workingDirectory: nil, needsReview: nil
        )
    }

    private func plan(owner: ResolvedOwner, commandName: String = "tool") async -> StrategyPlan {
        let config = typedConfig(commandName: commandName)
        let candidate = OwnerCandidate(commandPath: "/fixture/\(commandName)", resolvedPath: "/fixture/\(commandName)", owner: owner)
        let resolution = OwnerResolution(commandName: commandName, active: candidate, competing: [])
        return await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution)
    }

    func testPnpmYarnBunPipUserAreListedOnly() async {
        for owner: ResolvedOwner in [
            .pnpm(home: "/x", package: "y"), .yarnClassic(globalDir: "/x", package: "y"),
            .bun(root: "/x", package: "y"), .pipUser(site: "/x", distribution: "y"),
        ] {
            let plan = await plan(owner: owner)
            XCTAssertEqual(plan.blockReason, .noStrategy)
            XCTAssertEqual(plan.failureMessage, "Listed only")
        }
    }

    func testCargoIsListedOnly() async {
        let plan = await plan(owner: .cargo(root: "/x", crate: "ripgrep"))
        XCTAssertEqual(plan.blockReason, .noStrategy)
    }

    func testSystemGemIsSystemOwnedButOtherGemsAreListedOnly() async {
        let systemPlan = await plan(owner: .gem(gemDir: "/x", name: "rails", systemOwned: true))
        XCTAssertEqual(systemPlan.blockReason, .systemOwned)
        let userPlan = await plan(owner: .gem(gemDir: "/x", name: "rails", systemOwned: false))
        XCTAssertEqual(userPlan.blockReason, .noStrategy)
    }

    func testAppStoreSparkleAndSelfUpdatingAreNoStrategyForNow() async {
        let appStorePlan = await plan(owner: .appStore(adamID: "12345"))
        XCTAssertEqual(appStorePlan.blockReason, .noStrategy)
        let sparklePlan = await plan(owner: .sparkleApp(feedURL: "https://example.com/feed.xml"))
        XCTAssertEqual(sparklePlan.blockReason, .noStrategy)
        let selfUpdatingPlan = await plan(owner: .selfUpdatingApp(kind: "electronBuilder"))
        XCTAssertEqual(selfUpdatingPlan.blockReason, .noStrategy)
    }

    func testVersionManagerIsBlockedManagedByVersionManager() async {
        let plan = await plan(owner: .versionManager(kind: .pyenv, root: "/x"))
        XCTAssertEqual(plan.blockReason, .managedByVersionManager)
        XCTAssertEqual(plan.failureMessage, "Managed by pyenv")
    }

    func testAgentSkillAndPluginAreManualOnly() async {
        let skillPlan = await plan(owner: .agentSkill(lockFile: "/x/.skill-lock.json", name: "gsap-skills"))
        XCTAssertEqual(skillPlan.blockReason, .manualOnly)
        let pluginPlan = await plan(owner: .agentPlugin(agent: "Claude Code", marketplace: "m", plugin: "p"))
        XCTAssertEqual(pluginPlan.blockReason, .manualOnly)
        XCTAssertEqual(pluginPlan.failureMessage, "Managed by Claude Code")
    }

    func testSystemProviderIsSystemOwned() async {
        let plan = await plan(owner: .system(provider: "Command Line Tools"))
        XCTAssertEqual(plan.blockReason, .systemOwned)
        XCTAssertEqual(plan.failureMessage, "Managed by Command Line Tools")
    }

    func testOwnerMismatchStillAppliesToCargoGemAndAppStore() async {
        var config = typedConfig(commandName: "rg")
        config.packages = PackageIdentifiers(cargo: "expected-crate")
        let candidate = OwnerCandidate(commandPath: "/fixture/rg", resolvedPath: "/fixture/rg", owner: .cargo(root: "/x", crate: "actual-crate"))
        let resolution = OwnerResolution(commandName: "rg", active: candidate, competing: [])
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution)
        XCTAssertEqual(plan.blockReason, .ownerMismatch)
    }

    /// D6: a catalog entry that only declares a *different* ecosystem's package identity doesn't
    /// conflict with an owner from an ecosystem the schema has no field for yet.
    func testMissingCatalogFieldForNewEcosystemsIsNeverAMismatch() async {
        var config = typedConfig(commandName: "tool")
        config.packages = PackageIdentifiers(npm: "unrelated")
        let candidate = OwnerCandidate(commandPath: "/fixture/tool", resolvedPath: "/fixture/tool", owner: .pnpm(home: "/x", package: "tool"))
        let resolution = OwnerResolution(commandName: "tool", active: candidate, competing: [])
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution)
        XCTAssertNotEqual(plan.blockReason, .ownerMismatch)
    }
}
