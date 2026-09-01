import XCTest
@testable import DailyUpdate

final class CoreServiceTests: XCTestCase {
    func testExplicitUpdateWithoutLatestVersionRemainsActionable() async {
        let config = DetectorConfig(
            id: "test",
            name: "Test",
            category: .cli,
            description: nil,
            source: .user,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "printf '1.0.0'",
            checkCommand: "printf UPDATE",
            installCommand: "true",
            updateCommand: "true",
            workingDirectory: nil
        )

        let result = await UpdateCheckService.check(config, installed: true)

        XCTAssertEqual(result.0, .updateAvailable)
        XCTAssertEqual(result.1, "1.0.0")
        XCTAssertNil(result.2)
    }

    func testManualCheckShowsGuidanceInsteadOfFailure() async {
        let config = DetectorConfig(
            id: "manual-check",
            name: "Manual Check",
            category: .runtime,
            description: nil,
            source: .bundled,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo 1.0",
            checkCommand: "echo 'MANUAL: Check the App Store'",
            installCommand: "",
            updateCommand: "",
            workingDirectory: nil
        )

        let result = await UpdateCheckService.check(config, installed: true)

        XCTAssertEqual(result.0, .unknown)
        XCTAssertEqual(result.1, "1.0")
        XCTAssertEqual(result.3, "Check the App Store")
    }

    func testFailedCheckIsNotAnAvailableUpdate() {
        let item = UpdateItem(
            id: "failed-check",
            name: "Failed Check",
            category: .runtime,
            description: nil,
            currentVersion: nil,
            latestVersion: nil,
            status: .error,
            statusMessage: "Check failed",
            isInstalled: true,
            isSelected: false,
            isUserDefined: false,
            source: .bundled,
            iconPath: nil,
            detectCommand: nil,
            versionCommand: nil,
            checkCommand: nil,
            installCommand: "",
            updateCommand: "echo update",
            workingDirectory: nil
        )

        XCTAssertFalse(item.canUpdate)
        XCTAssertFalse(item.isActionable)
    }

    func testInAppUpdateHandoffIsNotRecordedAsFailure() {
        let result = UpdateResult.pendingInApp(current: "1.0", latest: "1.1")

        XCTAssertTrue(result.completedOrInitiated)
    }

    func testTimedOutCommandsExposeAUsefulFailureReason() async {
        let result = await ShellRunner.run("sleep 2", timeout: 0.01)

        XCTAssertEqual(result.exitCode, 15)
    }

    func testDiscoveredObsidianUsesItsManagedPackageVersion() {
        let config = ItemBuilder.discoveredApp(info: InstalledAppInfo(
            path: "/Applications/Obsidian.app",
            name: "Obsidian",
            bundleID: "md.obsidian",
            sparkleFeed: nil
        ))

        XCTAssertEqual(config.checkCommand, "echo OK")
        XCTAssertTrue(config.versionCommand?.contains("obsidian-*.asar") == true)
    }

    func testShellRunnerDrainsLargeOutput() async {
        let result = await ShellRunner.run("yes x | head -c 100000", timeout: 5)

        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.stdout.count, 99_000)
    }

    func testStableDiscoveredIDsDoNotDependOnProcessHashSeed() {
        let path = "/Users/example/Projects/Daily Update"

        XCTAssertEqual(
            ItemBuilder.stableID(prefix: "discovered", path: path),
            ItemBuilder.stableID(prefix: "discovered", path: path)
        )
    }

    func testShellEscapingHandlesApostrophes() {
        XCTAssertEqual(ShellEscaping.quote("Ada's Repo"), "'Ada'\\''s Repo'")
    }

    func testShellEscapingRoundTripsThroughZsh() async {
        let original = "Ada's $(Not Executed) Repo"
        let result = await ShellRunner.run("printf %s \(ShellEscaping.quote(original))")

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, original)
    }

    func testBundledResourcesResolveForSwiftPMRuns() {
        XCTAssertFalse(ConfigLoader.checkAppUpdateScriptPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ConfigLoader.checkAppUpdateScriptPath))
    }
}
