import XCTest
@testable import DailyUpdate

/// ADR-002 §9 P2-2 task 3: brew strategies read `BrewInfoProvider`. "A check with a snapshot
/// records 0 per-item `brew info` processes."
final class BrewInfoProviderPlannerTests: HermeticTestCase {
    private func config(brew: String? = nil, brewCask: String? = nil, command: String) -> DetectorConfig {
        DetectorConfig(
            id: "test-item", name: "Test", category: .cli, description: nil, schemaVersion: 2,
            source: .bundled, command: command,
            packages: PackageIdentifiers(brew: brew, brewCask: brewCask),
            selfUpdater: nil, appcastURL: nil, autoUpdates: nil, inventory: nil, detect: nil, versionCommand: nil,
            versionPattern: nil, checkCommand: nil, installCommand: nil, updateCommand: "noop", workingDirectory: nil, needsReview: nil
        )
    }

    private func resolution(_ command: String, resolvedPath: String, owner: ResolvedOwner, prefix: String) -> OwnerResolution {
        OwnerResolution(
            commandName: command,
            active: OwnerCandidate(commandPath: "\(prefix)/bin/\(command)", resolvedPath: resolvedPath, owner: owner),
            competing: []
        )
    }

    /// A recording runner that answers `brew info` with the Phase 1 single-formula shape.
    private func services(brewInfo: BrewInfoProvider?, calls: CallRecorder, infoJSON: String = "{}") -> StrategyPlanner.Services {
        var services = StrategyPlanner.Services.live(brewInfo: brewInfo)
        services.runProcess = { spec in
            calls.record(([spec.executablePath] + spec.arguments).joined(separator: " "))
            return ShellRunner.Result(exitCode: 0, stdout: infoJSON, stderr: "")
        }
        services.runBounded = { spec in
            calls.record(([spec.executable] + spec.arguments).joined(separator: " "))
            return QueryOutcome(evidence: ProcessEvidence(executable: spec.executable, arguments: spec.arguments,
                termination: .exited(1), stderr: "", stderrTruncated: false, elapsedMs: 0), stdout: Data())
        }
        return services
    }

    private func snapshot(_ fixture: FixtureFileSystem) async throws -> (prefix: String, provider: BrewInfoProvider) {
        let prefix = BrewFixtures.makeTree(fixture)
        let result = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() }).enumerate(BrewFixtures.context(fixture))
        return (prefix, try XCTUnwrap(result.brewInfo))
    }

    func testFormulaCheckWithASnapshotStartsNoBrewProcess() async throws {
        let fixture = FixtureFileSystem()
        let (prefix, provider) = try await snapshot(fixture)
        let calls = CallRecorder()
        let plan = await StrategyPlanner.checkPlan(
            config: config(brew: "gh", command: "gh"), currentVersion: nil,
            resolution: resolution("gh", resolvedPath: "\(prefix)/Cellar/gh/2.101.0/bin/gh", owner: .brewFormula("gh"), prefix: prefix),
            layout: .fixture(home: fixture.root.path), services: services(brewInfo: provider, calls: calls)
        )
        XCTAssertEqual(calls.calls, [])
        XCTAssertEqual(plan.currentVersion, "2.101.0")
        XCTAssertEqual(plan.latestVersion, "2.102.0")
        XCTAssertNil(plan.failureMessage)
        // The planner derives brew from the layout's prefix as written (here `/var/…`, not the
        // canonical `/private/var/…`); the snapshot is found through its alias either way.
        XCTAssertEqual(plan.updateCommandSpec, CommandSpec(executablePath: "\(BrewFixtures.prefix(fixture))/bin/brew",
            arguments: ["upgrade", "--formula", "gh"]))
    }

    /// Without a snapshot the Phase 1 behavior is unchanged: exactly one `brew info` per plan.
    func testFormulaCheckWithoutASnapshotAsksBrewOnce() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let calls = CallRecorder()
        let infoJSON = #"{"formulae": [{"name": "gh", "versions": {"stable": "2.102.0"}, "revision": 0, "pinned": false, "linked_keg": "2.101.0"}]}"#
        let plan = await StrategyPlanner.checkPlan(
            config: config(brew: "gh", command: "gh"), currentVersion: nil,
            resolution: resolution("gh", resolvedPath: "\(prefix)/Cellar/gh/2.101.0/bin/gh", owner: .brewFormula("gh"), prefix: prefix),
            layout: .fixture(home: fixture.root.path), services: services(brewInfo: nil, calls: calls, infoJSON: infoJSON)
        )
        XCTAssertEqual(calls.calls, ["\(BrewFixtures.prefix(fixture))/bin/brew info --json=v2 gh"])
        XCTAssertEqual(plan.latestVersion, "2.102.0")
    }

    /// The filesystem fallback has no latest versions, so the planner still asks brew once.
    func testFallbackSnapshotStillAsksBrewForTheLatestVersion() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let fallback = await BrewEnumerator(enricher: { _ in .sandboxUnavailable }).enumerate(BrewFixtures.context(fixture))
        let calls = CallRecorder()
        _ = await StrategyPlanner.checkPlan(
            config: config(brew: "gh", command: "gh"), currentVersion: nil,
            resolution: resolution("gh", resolvedPath: "\(prefix)/Cellar/gh/2.101.0/bin/gh", owner: .brewFormula("gh"), prefix: prefix),
            layout: .fixture(home: fixture.root.path), services: services(brewInfo: fallback.brewInfo, calls: calls)
        )
        XCTAssertEqual(calls.calls, ["\(BrewFixtures.prefix(fixture))/bin/brew info --json=v2 gh"])
    }

    /// Pinned in the snapshot → gated `pinned`, still with no process.
    func testPinnedFormulaFromTheSnapshotIsGated() async throws {
        let fixture = FixtureFileSystem()
        let (prefix, provider) = try await snapshot(fixture)
        let calls = CallRecorder()
        let plan = await StrategyPlanner.checkPlan(
            config: config(brew: "jq", command: "jq"), currentVersion: nil,
            resolution: resolution("jq", resolvedPath: "\(prefix)/Cellar/jq/1.7.1/bin/jq", owner: .brewFormula("jq"), prefix: prefix),
            layout: .fixture(home: fixture.root.path), services: services(brewInfo: provider, calls: calls)
        )
        XCTAssertEqual(calls.calls, [])
        XCTAssertEqual(plan.gateReasons, [.pinned])
        XCTAssertEqual(plan.latestVersion, "1.8.1")
    }

    /// F7: a third-party tap formula is upgraded by its full name.
    func testTapFormulaUpgradesByFullName() async throws {
        let fixture = FixtureFileSystem()
        let (prefix, provider) = try await snapshot(fixture)
        let calls = CallRecorder()
        let plan = await StrategyPlanner.checkPlan(
            config: config(brew: "bird", command: "bird"), currentVersion: nil,
            resolution: resolution("bird", resolvedPath: "\(prefix)/Cellar/bird/0.8.0/bin/bird", owner: .brewFormula("bird"), prefix: prefix),
            layout: .fixture(home: fixture.root.path), services: services(brewInfo: provider, calls: calls)
        )
        XCTAssertEqual(calls.calls, [])
        XCTAssertEqual(plan.updateCommandSpec?.arguments, ["upgrade", "--formula", "steipete/tap/bird"])
    }

    /// §7.4: a catalog formula name that fails the regex never reaches argv.
    func testInvalidFormulaNameBuildsNoCommand() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let calls = CallRecorder()
        let plan = await StrategyPlanner.checkPlan(
            config: config(brew: "-rf", command: "gh"), currentVersion: nil,
            resolution: resolution("gh", resolvedPath: "\(prefix)/Cellar/gh/2.101.0/bin/gh", owner: .brewFormula("-rf"), prefix: prefix),
            layout: .fixture(home: fixture.root.path), services: services(brewInfo: nil, calls: calls)
        )
        XCTAssertEqual(calls.calls, [])
        XCTAssertEqual(plan.blockReason, .unknownOwner)
        XCTAssertEqual(plan.failureMessage, "Formula name isn't a valid Homebrew name")
        XCTAssertNil(plan.updateCommandSpec)
    }

    func testCaskCheckWithASnapshotStartsNoBrewProcess() async throws {
        let fixture = FixtureFileSystem()
        let (prefix, provider) = try await snapshot(fixture)
        // `auto_updates` is true, so the version that counts is the bundle's own.
        let app = "opt/homebrew/Caskroom/openclaw/2026.1.23/OpenClaw.app"
        let binary = fixture.makeFile(at: "\(app)/Contents/MacOS/OpenClaw", contents: "#!/bin/sh\n")
        fixture.chmod(binary, 0o755)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2026.1.23"], format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: fixture.path("\(app)/Contents/Info.plist")))
        let calls = CallRecorder()
        let plan = await StrategyPlanner.checkPlan(
            config: config(brewCask: "openclaw", command: "openclaw"), currentVersion: nil,
            resolution: resolution("openclaw", resolvedPath: "\(prefix)/Caskroom/openclaw/2026.1.23/OpenClaw.app/Contents/MacOS/OpenClaw",
                owner: .brewCask("openclaw"), prefix: prefix),
            layout: .fixture(home: fixture.root.path), services: services(brewInfo: provider, calls: calls)
        )
        XCTAssertEqual(calls.calls, [])
        XCTAssertEqual(plan.currentVersion, "2026.1.23")
        XCTAssertEqual(plan.latestVersion, "2026.1.24")
        XCTAssertEqual(plan.updateCommandSpec?.arguments, ["upgrade", "--cask", "openclaw"])
    }

    /// §7.2: an inventory record under an untrusted root is Blocked(untrustedPath), with no command.
    func testInventoryRecordUnderAnUntrustedRootIsBlocked() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        fixture.chmod(prefix, 0o777)
        let result = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() }).enumerate(BrewFixtures.context(fixture))
        let record = try XCTUnwrap(result.records.first { $0.packageID == "gh" })
        let identity = InventoryIdentity(ecosystem: .brew, packageID: "gh", rootPath: prefix,
            packageDirectory: record.packageDirectory, toolPath: record.root.toolPath)
        var row = config(command: "gh")
        row.source = .inventory
        row.inventory = identity
        let calls = CallRecorder()
        let plan = await StrategyPlanner.checkPlan(
            config: row, currentVersion: nil, resolve: { _ in record }, layout: .fixture(home: fixture.root.path),
            services: services(brewInfo: result.brewInfo, calls: calls)
        )
        XCTAssertEqual(calls.calls, [])
        XCTAssertEqual(plan?.blockReason, .untrustedPath)
        XCTAssertEqual(plan?.failureMessage, "Homebrew (\(prefix)) can be written by other users")
        XCTAssertNil(plan?.updateCommandSpec)
    }
}
