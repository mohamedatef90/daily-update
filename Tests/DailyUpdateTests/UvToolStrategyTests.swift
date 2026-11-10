import XCTest
@testable import DailyUpdate

/// ADR-002 §9 P2-3 task 2, and Amendment 1 F8: `UvToolStrategy`'s receipt validation (U1-U4), the
/// PyPI "latest" rule (skip yanked, skip prereleases unless current is one), and its wiring into
/// `StrategyPlanner.makeStrategy` (RC2: blocked when the login PATH isn't known).
final class UvToolStrategyTests: HermeticTestCase {
    // MARK: - F8 receipt validation (U1-U4)

    func testU1PlainPyPINameOnlyReceiptIsTyped() {
        let fixture = FixtureFileSystem()
        let toolDirectory = fixture.path("tools/browser-use")
        fixture.makeFile(at: "tools/browser-use/uv-receipt.toml", contents: """
        [tool]
        requirements = [{ name = "browser-use" }]
        """)
        XCTAssertEqual(
            UvToolStrategy.validateReceipt(packageDirectory: toolDirectory, name: "browser-use", environmentSnapshot: [:]),
            .ok
        )
    }

    func testU2GitInstallIsBlocked() {
        let fixture = FixtureFileSystem()
        let toolDirectory = fixture.path("tools/specify-cli")
        fixture.makeFile(at: "tools/specify-cli/uv-receipt.toml", contents: """
        [tool]
        requirements = [{ name = "specify-cli", git = "https://github.com/github/spec-kit.git" }]
        """)
        XCTAssertEqual(
            UvToolStrategy.validateReceipt(packageDirectory: toolDirectory, name: "specify-cli", environmentSnapshot: [:]),
            .blocked("Installed from git")
        )
    }

    func testU3URLPathAndEditableInstallsAreBlocked() {
        let cases: [(String, String)] = [
            (#"requirements = [{ name = "x", url = "https://example.com/x.whl" }]"#, "from a URL"),
            (#"requirements = [{ name = "x", path = "/local/x" }]"#, "from a local path"),
            (#"requirements = [{ name = "x", editable = true, path = "/local/x" }]"#, "from a local path"),
        ]
        for (line, expectedMessage) in cases {
            let fixture = FixtureFileSystem()
            let toolDirectory = fixture.path("tools/x")
            fixture.makeFile(at: "tools/x/uv-receipt.toml", contents: "[tool]\n\(line)\n")
            XCTAssertEqual(
                UvToolStrategy.validateReceipt(packageDirectory: toolDirectory, name: "x", environmentSnapshot: [:]),
                .blocked(expectedMessage),
                "line: \(line)"
            )
        }
    }

    func testU4CustomIndexInUvTomlIsBlocked() {
        let fixture = FixtureFileSystem()
        let toolDirectory = fixture.path("tools/browser-use")
        fixture.makeFile(at: "tools/browser-use/uv-receipt.toml", contents: """
        [tool]
        requirements = [{ name = "browser-use" }]
        """)
        fixture.makeFile(at: "tools/browser-use/uv.toml", contents: """
        index-url = "https://example.com/simple"
        """)
        XCTAssertEqual(
            UvToolStrategy.validateReceipt(packageDirectory: toolDirectory, name: "browser-use", environmentSnapshot: [:]),
            .blocked("Uses a custom package index")
        )
    }

    func testCustomIndexFromEnvironmentSnapshotIsAlsoBlocked() {
        let fixture = FixtureFileSystem()
        let toolDirectory = fixture.path("tools/browser-use")
        fixture.makeFile(at: "tools/browser-use/uv-receipt.toml", contents: """
        [tool]
        requirements = [{ name = "browser-use" }]
        """)
        XCTAssertEqual(
            UvToolStrategy.validateReceipt(packageDirectory: toolDirectory, name: "browser-use", environmentSnapshot: ["UV_DEFAULT_INDEX": "https://example.com/simple"]),
            .blocked("Uses a custom package index")
        )
    }

    func testNoReceiptAtAllIsBlocked() {
        let fixture = FixtureFileSystem()
        XCTAssertEqual(
            UvToolStrategy.validateReceipt(packageDirectory: fixture.path("tools/nothing"), name: "nothing", environmentSnapshot: [:]),
            .blocked("No uv receipt")
        )
    }

    // MARK: - PyPI "latest" (skip yanked, skip prereleases unless current is one)

    private func pypiJSON(_ releases: [String: [[String: Any]]]) -> String {
        let payload: [String: Any] = ["info": ["version": "irrelevant"], "releases": releases]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    func testPicksTheHighestNonYankedStableRelease() {
        let body = pypiJSON([
            "1.0.0": [["yanked": false]],
            "1.2.0": [["yanked": false]],
            "1.3.0": [["yanked": true]],
        ])
        XCTAssertEqual(UvToolStrategy.bestVersion(fromPyPIJSON: body, currentVersion: "1.0.0"), "1.2.0")
    }

    func testSkipsPrereleasesWhenCurrentIsStable() {
        let body = pypiJSON([
            "1.2.0": [["yanked": false]],
            "1.3.0a1": [["yanked": false]],
        ])
        XCTAssertEqual(UvToolStrategy.bestVersion(fromPyPIJSON: body, currentVersion: "1.2.0"), "1.2.0")
    }

    func testAllowsPrereleasesWhenCurrentIsItselfAPrerelease() {
        let body = pypiJSON([
            "1.2.0": [["yanked": false]],
            "1.3.0a1": [["yanked": false]],
        ])
        XCTAssertEqual(UvToolStrategy.bestVersion(fromPyPIJSON: body, currentVersion: "1.3.0.dev0"), "1.3.0a1")
    }

    func testAVersionWhereEveryFileIsYankedIsSkippedEntirely() {
        let body = pypiJSON([
            "1.0.0": [["yanked": false]],
            "2.0.0": [["yanked": true], ["yanked": true]],
        ])
        XCTAssertEqual(UvToolStrategy.bestVersion(fromPyPIJSON: body, currentVersion: "1.0.0"), "1.0.0")
    }

    // MARK: - Wiring into StrategyPlanner (RC2 + the argv)

    private func typedConfig(commandName: String) -> DetectorConfig {
        DetectorConfig(
            id: "test-item", name: "Test", category: .cli, description: nil, schemaVersion: 2,
            source: .bundled, command: commandName, packages: nil, selfUpdater: nil, appcastURL: nil,
            autoUpdates: nil, inventory: nil, detect: nil, versionCommand: nil, versionPattern: nil,
            checkCommand: nil, installCommand: nil, updateCommand: "noop", workingDirectory: nil, needsReview: nil
        )
    }

    func testUvToolIsBlockedNoStrategyWhenLoginPathIsUnknown() async {
        let config = typedConfig(commandName: "browser-use")
        let candidate = OwnerCandidate(commandPath: "/x/browser-use", resolvedPath: "/x/browser-use", owner: .uvTool(name: "browser-use"))
        let resolution = OwnerResolution(commandName: "browser-use", active: candidate, competing: [])
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution, loginPath: .unknown("whence failed"))
        XCTAssertEqual(plan.blockReason, .noStrategy)
        XCTAssertEqual(plan.failureMessage, "uv not found")
    }

    func testUvToolIsBlockedNoStrategyWhenLoginPathIsEmpty() async {
        let config = typedConfig(commandName: "browser-use")
        let candidate = OwnerCandidate(commandPath: "/x/browser-use", resolvedPath: "/x/browser-use", owner: .uvTool(name: "browser-use"))
        let resolution = OwnerResolution(commandName: "browser-use", active: candidate, competing: [])
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution, loginPath: .empty)
        XCTAssertEqual(plan.blockReason, .noStrategy)
        XCTAssertEqual(plan.failureMessage, "uv not found")
    }

    func testPipxStaysListedOnlyNowThatUvHasItsOwnStrategy() async {
        let config = typedConfig(commandName: "some-pipx-tool")
        let candidate = OwnerCandidate(commandPath: "/x/some-pipx-tool", resolvedPath: "/x/some-pipx-tool", owner: .pipx(package: "some-pipx-tool"))
        let resolution = OwnerResolution(commandName: "some-pipx-tool", active: candidate, competing: [])
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution)
        XCTAssertEqual(plan.blockReason, .noStrategy)
        XCTAssertEqual(plan.failureMessage, "Listed only")
    }

    func testTrustedUvOnLoginPathBuildsAWorkingStrategyWithTheConfirmedArgv() async throws {
        let fixture = FixtureFileSystem()
        let binDirectory = fixture.path("bin")
        let uvPath = fixture.makeFile(at: "bin/uv", contents: "#!/bin/sh\n")
        fixture.chmod(uvPath, 0o755)

        let toolsRoot = fixture.path("tools")
        fixture.makeFile(
            at: "tools/browser-use/lib/python3.12/site-packages/browser_use-1.2.3.dist-info/METADATA",
            contents: "Metadata-Version: 2.1\nName: browser-use\nVersion: 1.2.3\n"
        )
        fixture.makeFile(at: "tools/browser-use/uv-receipt.toml", contents: """
        [tool]
        requirements = [{ name = "browser-use" }]
        """)
        let resolvedExecutable = "\(toolsRoot)/browser-use/bin/browser-use"

        let config = typedConfig(commandName: "browser-use")
        let candidate = OwnerCandidate(commandPath: resolvedExecutable, resolvedPath: resolvedExecutable, owner: .uvTool(name: "browser-use"))
        let resolution = OwnerResolution(commandName: "browser-use", active: candidate, competing: [])
        let layout = EcosystemLayout.fixture(home: fixture.path("home"))
        let customLayout = EcosystemLayout(
            homeDirectory: layout.homeDirectory, brewPrefixes: layout.brewPrefixes, brewCellars: layout.brewCellars,
            brewCaskrooms: layout.brewCaskrooms, claudeNativeRoot: layout.claudeNativeRoot,
            opencodeNativeRoot: layout.opencodeNativeRoot, cursorAgentNativeRoot: layout.cursorAgentNativeRoot,
            uvToolRoots: [toolsRoot], pipxVenvRoots: layout.pipxVenvRoots, npmGlobalRoots: layout.npmGlobalRoots,
            nvmVersionsRoot: layout.nvmVersionsRoot, voltaRoot: layout.voltaRoot, fnmRoots: layout.fnmRoots
        )

        let plan = await StrategyPlanner.checkPlan(
            config: config, currentVersion: nil, resolution: resolution, layout: customLayout,
            loginPath: .known([binDirectory]),
            fetchRelease: { _ in self.pypiJSON(["1.2.3": [["yanked": false]], "1.4.0": [["yanked": false]]]) }
        )

        XCTAssertNil(plan.blockReason)
        XCTAssertEqual(plan.currentVersion, "1.2.3")
        XCTAssertEqual(plan.latestVersion, "1.4.0")
        let spec = try XCTUnwrap(plan.updateCommandSpec)
        XCTAssertEqual(spec.executablePath, uvPath)
        XCTAssertEqual(spec.arguments, ["tool", "upgrade", "browser-use"])
    }

    // MARK: - Package directory derivation

    func testPackageDirectoryIsDerivedFromTheResolvedExecutableUnderTheToolsRoot() {
        let directory = UvToolStrategy.packageDirectory(
            resolvedPath: "/Users/x/.local/share/uv/tools/browser-use/bin/browser-use",
            roots: ["/Users/x/.local/share/uv/tools"]
        )
        XCTAssertEqual(directory, "/Users/x/.local/share/uv/tools/browser-use")
    }
}
