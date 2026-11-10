import XCTest
@testable import DailyUpdate

/// ADR-002 §2 "cargo" / §9 P2-3 task 5: `.crates2.json` from the documentation (cargo isn't
/// installed on this Mac), covering registry, git and path sources.
final class CargoEnumeratorTests: HermeticTestCase {
    private func context(fixture: FixtureFileSystem, home: String, active: Bool = true) -> DiscoveryContext {
        let binDirectory = "\(fixture.path("cargo"))/bin"
        return DiscoveryContext(
            fileSystem: fixture.fileSystem,
            environmentSnapshot: ["CARGO_HOME": fixture.path("cargo")],
            loginPath: active ? .known([binDirectory]) : .known(["/other/bin"]),
            layout: .fixture(home: home)
        )
    }

    func testEnumeratesRegistryGitAndPathSources() async {
        let fixture = FixtureFileSystem()
        fixture.makeFile(at: "cargo/.crates2.json", contents: """
        {
          "v": 1,
          "installs": {
            "ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)": { "bins": ["rg"] },
            "my-tool 0.1.0 (git+https://github.com/example/my-tool#abc123)": { "bins": ["my-tool"] },
            "local-tool 0.2.0 (path+file:///Users/x/local-tool)": { "bins": ["local-tool"] }
          }
        }
        """)
        let rgScript = fixture.makeFile(at: "cargo/bin/rg", contents: "#!/bin/sh\n")
        fixture.chmod(rgScript, 0o755)

        let result = await CargoEnumerator().enumerate(context(fixture: fixture, home: fixture.path("home")))

        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 3)

        let ripgrep = try! XCTUnwrap(result.records.first { $0.packageID == "ripgrep" })
        XCTAssertEqual(ripgrep.versionRaw, "14.1.0")
        XCTAssertEqual(ripgrep.owner, .cargo(root: fixture.path("cargo"), crate: "ripgrep", source: .registry))
        XCTAssertEqual(ripgrep.executables.count, 1)

        let gitTool = try! XCTUnwrap(result.records.first { $0.packageID == "my-tool" })
        XCTAssertEqual(gitTool.owner, .cargo(root: fixture.path("cargo"), crate: "my-tool", source: .git))

        let pathTool = try! XCTUnwrap(result.records.first { $0.packageID == "local-tool" })
        XCTAssertEqual(pathTool.owner, .cargo(root: fixture.path("cargo"), crate: "local-tool", source: .path))
    }

    func testGitAndPathSourcesAreBlockedManualOnlyRegistryStaysNoStrategy() async {
        func plan(source: CargoSource) async -> StrategyPlan {
            let config = DetectorConfig(
                id: "test-item", name: "Test", category: .cli, description: nil, schemaVersion: 2,
                source: .bundled, command: "tool", packages: nil, selfUpdater: nil, appcastURL: nil,
                autoUpdates: nil, inventory: nil, detect: nil, versionCommand: nil, versionPattern: nil,
                checkCommand: nil, installCommand: nil, updateCommand: "noop", workingDirectory: nil, needsReview: nil
            )
            let candidate = OwnerCandidate(commandPath: "/x/tool", resolvedPath: "/x/tool", owner: .cargo(root: "/x", crate: "tool", source: source))
            let resolution = OwnerResolution(commandName: "tool", active: candidate, competing: [])
            return await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution)
        }
        let registryPlan = await plan(source: .registry)
        XCTAssertEqual(registryPlan.blockReason, .noStrategy)

        let gitPlan = await plan(source: .git)
        XCTAssertEqual(gitPlan.blockReason, .manualOnly)
        XCTAssertEqual(gitPlan.failureMessage, "Installed from git")

        let pathPlan = await plan(source: .path)
        XCTAssertEqual(pathPlan.blockReason, .manualOnly)
        XCTAssertEqual(pathPlan.failureMessage, "Installed from a local path")
    }

    func testOldMetadataFormatOnlyIsPartial() async {
        let fixture = FixtureFileSystem()
        fixture.makeFile(at: "cargo/.crates.toml", contents: "[v1]\n\"ripgrep 14.1.0\" = [\"rg\"]\n")

        let result = await CargoEnumerator().enumerate(context(fixture: fixture, home: fixture.path("home")))
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertTrue(issues.contains { $0.message == "old metadata format not read" })
        XCTAssertEqual(result.records.count, 0)
    }

    func testMissingRootIsCompleteWithNoRecords() async {
        let fixture = FixtureFileSystem()
        let result = await CargoEnumerator().enumerate(context(fixture: fixture, home: fixture.path("home")))
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testResolveFindsOneCrateByPackageID() async {
        let fixture = FixtureFileSystem()
        fixture.makeFile(at: "cargo/.crates2.json", contents: """
        { "v": 1, "installs": { "ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)": { "bins": ["rg"] } } }
        """)
        let ctx = context(fixture: fixture, home: fixture.path("home"))
        let identity = InventoryIdentity(ecosystem: .cargo, packageID: "ripgrep", rootPath: fixture.path("cargo"), packageDirectory: fixture.path("cargo"))
        let resolved = await CargoEnumerator().resolve(identity, ctx)
        XCTAssertEqual(resolved?.versionRaw, "14.1.0")
    }
}
