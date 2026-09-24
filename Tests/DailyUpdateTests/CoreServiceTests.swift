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
            status: .checkFailed,
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

    func testCheckFailureProducesCheckFailedStatus() async {
        let config = DetectorConfig(
            id: "failing-check",
            name: "Failing Check",
            category: .cli,
            description: nil,
            source: .user,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo 1.0.0",
            checkCommand: "echo CHECK_FAILED: boom >&2; exit 1",
            installCommand: "true",
            updateCommand: "true",
            workingDirectory: nil
        )

        let result = await UpdateCheckService.check(config, installed: true)

        XCTAssertEqual(result.0, .checkFailed)
        XCTAssertEqual(result.1, "1.0.0")
    }

    func testInAppUpdateHandoffIsNotRecordedAsFailure() {
        let result = UpdateResult.pendingInApp(current: "1.0", latest: "1.1")

        XCTAssertTrue(result.completedOrInitiated)
    }

    func testBrewFallbackOpenIsNotTreatedAsInAppUpdate() {
        let command = "brew upgrade --cask cursor 2>/dev/null || open -a Cursor"
        XCTAssertFalse(UpdateCommandSemantics.usesInAppUpdateFlow(command))
        XCTAssertTrue(UpdateCommandSemantics.hasInAppFallback(command))
    }

    func testBrewElseOpenHasInAppFallback() {
        let command = "if brew list --cask chatgpt >/dev/null 2>&1; then brew upgrade --cask chatgpt; else open -a ChatGPT; fi"
        XCTAssertFalse(UpdateCommandSemantics.usesInAppUpdateFlow(command))
        XCTAssertTrue(UpdateCommandSemantics.hasInAppFallback(command))
    }

    func testPrimaryOpenCommandIsInAppUpdate() {
        XCTAssertTrue(UpdateCommandSemantics.usesInAppUpdateFlow("open -a \"ChatGPT Atlas\""))
        XCTAssertTrue(UpdateCommandSemantics.usesInAppUpdateFlow("open 'macappstore://apps.apple.com/app/id497799835'"))
    }

    func testTimedOutCommandsExposeAUsefulFailureReason() async {
        let result = await ShellRunner.run("sleep 2", timeout: 0.01)

        XCTAssertEqual(result.exitCode, 15)
    }

    func testFailureReasonsAreActionable() {
        let permissionFailure = ShellRunner.Result(
            exitCode: 1,
            stdout: "",
            stderr: "npm error code EACCES\nnpm error permission denied"
        )
        let nodeFailure = ShellRunner.Result(
            exitCode: 1,
            stdout: "",
            stderr: "npm error code EBADENGINE"
        )

        XCTAssertEqual(
            UpdateExecutor.failureReason(from: permissionFailure, action: "Update"),
            "Update needs permission to modify the installed files. Run it from Terminal with administrator rights."
        )
        XCTAssertEqual(
            UpdateExecutor.failureReason(from: nodeFailure, action: "Update"),
            "Update requires a newer Node.js version before this package can be updated."
        )
    }

    func testFriendlyPermissionFailureRequestsAdministratorAuthentication() {
        let item = UpdateItem(
            id: "permission-required",
            name: "Permission Required",
            category: .runtime,
            description: nil,
            currentVersion: "1.0",
            latestVersion: "1.1",
            status: .error,
            statusMessage: "Update needs permission to modify the installed files. Run it from Terminal with administrator rights.",
            isInstalled: true,
            isSelected: true,
            isUserDefined: false,
            source: .bundled,
            iconPath: nil,
            detectCommand: nil,
            versionCommand: nil,
            checkCommand: nil,
            installCommand: "",
            updateCommand: "npm update -g example",
            workingDirectory: nil
        )

        XCTAssertTrue(item.needsAdministratorPermission)
    }

    func testFallbackChainsAreRemovedFromActionCommands() {
        var settings = UserSettings.defaults
        settings.customItems = [
            DetectorConfig(
                id: "fallback-test",
                name: "Fallback Test",
                category: .cli,
                description: nil,
                source: .user,
                detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                versionCommand: "echo 1.0.0",
                checkCommand: "echo OK",
                installCommand: nil,
                updateCommand: "npm update -g test-tool 2>/dev/null || brew upgrade test-tool 2>/dev/null || echo 'manual'",
                workingDirectory: nil
            )
        ]

        let configs = ConfigLoader.loadConfigs(settings: settings)
        let config = try? XCTUnwrap(configs.first(where: { $0.id == "fallback-test" }))

        XCTAssertNotNil(config)
        XCTAssertEqual(config?.updateCommand, "npm update -g test-tool")
        XCTAssertFalse(UpdateCommandSemantics.hasFallbackChain(config?.updateCommand ?? ""))
        XCTAssertFalse((config?.updateCommand ?? "").contains("2>/dev/null"))
    }

    func testBulkItemsAreNotAutoSelectedForUpdateAll() {
        let bulk = UpdateItem(
            id: "brew",
            name: "Homebrew",
            category: .runtime,
            description: nil,
            currentVersion: "1.0",
            latestVersion: "1.1",
            status: .updateAvailable,
            statusMessage: nil,
            isInstalled: true,
            isSelected: false,
            isUserDefined: false,
            source: .bundled,
            iconPath: nil,
            detectCommand: nil,
            versionCommand: nil,
            checkCommand: nil,
            installCommand: "",
            updateCommand: "brew upgrade",
            workingDirectory: nil
        )
        let singleItem = UpdateItem(
            id: "npm",
            name: "npm",
            category: .runtime,
            description: nil,
            currentVersion: "10.0.0",
            latestVersion: "10.1.0",
            status: .updateAvailable,
            statusMessage: nil,
            isInstalled: true,
            isSelected: false,
            isUserDefined: false,
            source: .bundled,
            iconPath: nil,
            detectCommand: nil,
            versionCommand: nil,
            checkCommand: nil,
            installCommand: "",
            updateCommand: "npm install -g npm@latest",
            workingDirectory: nil
        )

        XCTAssertFalse(BulkUpdatePolicy.shouldAutoSelectForUpdate(bulk))
        XCTAssertTrue(BulkUpdatePolicy.shouldAutoSelectForUpdate(singleItem))
    }

    func testSparkleDirectInstallIsDisabled() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appPath = temporaryRoot.appendingPathComponent("FakeApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let scriptPath = ConfigLoader.updateAppScriptPath
        XCTAssertFalse(scriptPath.isEmpty)

        let command = "DAILY_UPDATE_TEST_MODE=1 \(ShellEscaping.quote(scriptPath)) sparkle-feed https://example.com/feed.xml \(ShellEscaping.quote(appPath.path))"
        let result = await ShellRunner.run(command)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("Sparkle direct install is disabled"))
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
        XCTAssertFalse(ConfigLoader.updateAppScriptPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ConfigLoader.updateAppScriptPath))
    }
}
