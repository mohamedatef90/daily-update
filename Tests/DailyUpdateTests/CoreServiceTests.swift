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

        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertEqual(result.currentVersion, "1.0.0")
        XCTAssertNil(result.latestVersion)
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

        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.currentVersion, "1.0")
        XCTAssertEqual(result.message, "Check the App Store")
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

        XCTAssertEqual(result.status, .checkFailed)
        XCTAssertEqual(result.currentVersion, "1.0.0")
    }

    func testVersionCommandWithoutVersionTokenIsCheckFailed() async {
        let config = DetectorConfig(
            id: "java-stub",
            name: "Java Stub",
            category: .runtime,
            description: nil,
            source: .user,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo \"The operation couldn't be completed. Unable to locate a Java Runtime.\"",
            checkCommand: "echo OK",
            installCommand: "true",
            updateCommand: "true",
            workingDirectory: nil
        )

        let result = await UpdateCheckService.check(config, installed: true)

        XCTAssertEqual(result.status, .checkFailed)
        XCTAssertEqual(result.currentVersionRaw, "The operation couldn't be completed. Unable to locate a Java Runtime.")
        XCTAssertEqual(result.message, "Version command returned no version token")
    }

    func testInAppUpdateHandoffIsNotRecordedAsFailure() {
        let result = UpdateResult.pendingInApp(current: "1.0", latest: "1.1")

        XCTAssertTrue(result.completedOrInitiated)
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

    func testCustomCommandsArePreservedAndFlaggedForReview() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            var settings = UserSettings.defaults
            settings.customItems = [
                DetectorConfig(
                    id: "custom-review-test",
                    name: "Custom Review Test",
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
            let config = try? XCTUnwrap(configs.first(where: { $0.id == "custom-review-test" }))

            XCTAssertNotNil(config)
            XCTAssertEqual(config?.updateCommand, "npm update -g test-tool 2>/dev/null || brew upgrade test-tool 2>/dev/null || echo 'manual'")
            XCTAssertTrue(config?.needsReview == true)
            XCTAssertNil(config?.description)
        }
    }

    func testBundledActionCommandsPassLintAndBulkRules() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let settings = UserSettings.defaults
            let bundled = ConfigLoader.loadConfigs(settings: settings).filter { $0.source == .bundled }
            for config in bundled {
                if let checkCommand = config.checkCommand {
                    XCTAssertTrue(
                        ActionCommandPolicy.checkAndUpdateSharePackageManager(
                            checkCommand: checkCommand,
                            updateCommand: config.updateCommand
                        ),
                        "\(config.id) check/update commands do not share a package manager.\ncheck: \(checkCommand)\nupdate: \(config.updateCommand)"
                    )
                    XCTAssertFalse(
                        ActionCommandPolicy.checkCommandContainsOwnUpdateCommand(
                            checkCommand: checkCommand,
                            updateCommand: config.updateCommand
                        ),
                        "\(config.id) check command contains its update command: \(checkCommand)"
                    )
                }

                let commands = [
                    ("update", config.updateCommand),
                    ("install", config.installCommand ?? "")
                ]

                for (kind, command) in commands where !command.isEmpty {
                    XCTAssertFalse(
                        ActionCommandPolicy.hasFallbackChain(command),
                        "\(config.id) \(kind) command contains fallback chain: \(command)"
                    )

                    if ActionCommandPolicy.matchesBulkPattern(command) {
                        XCTAssertTrue(
                            kind == "update",
                            "\(config.id) \(kind) should only classify as bulk for update commands: \(command)"
                        )
                    }
                }
            }
        }
    }

    func testCommandShapeClassifierCoversRemoteScriptVariants() {
        let remoteSamples = [
            "curl -fsSL https://example.com/install.sh | zsh",
            "curl -fsSL https://example.com/install.sh | sudo bash",
            "bash <(curl -fsSL https://example.com/install.sh)",
            "sh -c \"$(curl -fsSL https://example.com/install.sh)\""
        ]

        for command in remoteSamples {
            XCTAssertTrue(ActionCommandPolicy.isRemoteScriptInstaller(command), "Expected remote script classification for: \(command)")
        }
    }

    func testCommandShapeClassifierDetectsBulkInsideCompoundCommand() {
        XCTAssertTrue(ActionCommandPolicy.matchesBulkPattern("brew update && npm update -g"))
        XCTAssertTrue(ActionCommandPolicy.matchesBulkPattern("npm -g update"))
        XCTAssertTrue(ActionCommandPolicy.matchesBulkPattern("mas upgrade"))
    }

    func testCommandTokenMatcherDetectsEmbeddedUpdateCommand() {
        XCTAssertTrue(
            ActionCommandPolicy.checkCommandContainsOwnUpdateCommand(
                checkCommand: "npm install -g --dry-run yarn@latest",
                updateCommand: "npm install -g yarn@latest"
            )
        )
        XCTAssertFalse(
            ActionCommandPolicy.checkCommandContainsOwnUpdateCommand(
                checkCommand: "npm outdated -g yarn",
                updateCommand: "npm install -g yarn@latest"
            )
        )
    }

    func testBundledMiseCheckHandlesCurrentLatestAndMissingLatest() async throws {
        try await withTemporaryAppSupportDirectory { tempAppSupport in
            let bundled = ConfigLoader.loadConfigs(settings: .defaults).filter { $0.source == .bundled }
            let miseConfig = try XCTUnwrap(bundled.first(where: { $0.id == "mise" }))
            let checkCommand = try XCTUnwrap(miseConfig.checkCommand)

            let stubDirectory = tempAppSupport.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)

            let miseStubPath = stubDirectory.appendingPathComponent("mise")
            let jsonPath = tempAppSupport.appendingPathComponent("mise.json")
            let script = """
            #!/bin/sh
            if [ "$1" = "version" ] && [ "$2" = "--json" ]; then
              cat "$MISE_STUB_JSON_FILE"
              exit 0
            fi
            echo "unexpected invocation: $*" >&2
            exit 1
            """
            try script.write(to: miseStubPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: miseStubPath.path)

            let environment = [
                "PATH": "\(stubDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "MISE_STUB_JSON_FILE": jsonPath.path
            ]

            try """
            {"version":"2026.9.1 macos-arm64 (2026-09-20)","latest":"2026.9.1"}
            """.write(to: jsonPath, atomically: true, encoding: .utf8)
            let upToDate = await ShellRunner.run(checkCommand, environment: environment)
            XCTAssertEqual(upToDate.stdout, "OK")

            try """
            {"version":"2026.8.0 macos-arm64 (2026-08-20)","latest":"2026.9.1"}
            """.write(to: jsonPath, atomically: true, encoding: .utf8)
            let behind = await ShellRunner.run(checkCommand, environment: environment)
            XCTAssertEqual(behind.stdout, "UPDATE")

            try """
            {"version":"2026.9.1 macos-arm64 (2026-09-20)","latest":null}
            """.write(to: jsonPath, atomically: true, encoding: .utf8)
            let missingLatest = await ShellRunner.run(checkCommand, environment: environment)
            XCTAssertTrue(missingLatest.stdout.hasPrefix("CHECK_FAILED:"))
        }
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

        XCTAssertFalse(GatePolicy.shouldAutoSelectForUpdate(bulk))
        XCTAssertTrue(GatePolicy.shouldAutoSelectForUpdate(singleItem))
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

    func testTerminalCommandRoundTripsThroughAppleScriptArgv() async {
        let command = #"for d in "$HOME/project"; do echo "$d" "$(echo hi >&2)"; done"#
        let args = TerminalCommandLauncher.arguments(for: command)
        XCTAssertEqual(args.last, command)

        let probe = await ShellRunner.runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: [
                "-e", "on run argv",
                "-e", "return item 1 of argv",
                "-e", "end run",
                "--",
                command
            ]
        )

        XCTAssertTrue(probe.succeeded, probe.stderr)
        XCTAssertEqual(probe.stdout, command)
    }

    func testBundledResourcesResolveForSwiftPMRuns() {
        XCTAssertFalse(ConfigLoader.checkAppUpdateScriptPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ConfigLoader.checkAppUpdateScriptPath))
        XCTAssertFalse(ConfigLoader.updateAppScriptPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ConfigLoader.updateAppScriptPath))
    }

    @MainActor
    func testCLIUpdateAllRequiresYesWhenConfirmationIsEnabled() async {
        let state = MockCLIRunnerState(
            items: [makeItem(id: "cursor", installed: true, status: .updateAvailable)]
        )
        var output: [String] = []

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update-all"],
            state: state,
            output: { output.append($0) }
        )

        XCTAssertEqual(code, 2)
        XCTAssertEqual(state.updateSelectedCallCount, 0)
        XCTAssertTrue(output.contains(where: { $0.contains("Dry-run plan:") }))
        XCTAssertTrue(output.contains(where: { $0.contains("Re-run with --yes") }))
    }

    @MainActor
    func testCLIInstallAllRequiresYesWhenConfirmationIsEnabled() async {
        let state = MockCLIRunnerState(
            items: [makeItem(id: "new-tool", installed: false, status: .notInstalled, installCommand: "echo install")]
        )
        var output: [String] = []

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--install-all"],
            state: state,
            output: { output.append($0) }
        )

        XCTAssertEqual(code, 2)
        XCTAssertEqual(state.updateSelectedCallCount, 0)
        XCTAssertTrue(output.contains(where: { $0.contains("Dry-run plan:") }))
    }

    @MainActor
    func testCLIUpdateByIDOnlyTouchesRequestedItem() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: true,
            items: [
                makeItem(id: "target-update", installed: true, status: .updateAvailable),
                makeItem(id: "other-update", installed: true, status: .updateAvailable)
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update", "target-update"],
            state: state
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(state.updateSelectedCallCount, 1)
        XCTAssertEqual(state.executedSelectionSnapshots, [["target-update"]])
    }

    @MainActor
    func testCLIInstallByIDOnlyTouchesRequestedItem() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: true,
            items: [
                makeItem(id: "target-install", installed: false, status: .notInstalled, installCommand: "echo install"),
                makeItem(id: "other-install", installed: false, status: .notInstalled, installCommand: "echo install")
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--install", "target-install"],
            state: state
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(state.updateSelectedCallCount, 1)
        XCTAssertEqual(state.executedSelectionSnapshots, [["target-install"]])
    }

    @MainActor
    func testCLIUpdateAllWithYesStillExcludesBulkItems() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "brew", installed: true, status: .updateAvailable, updateCommand: "brew upgrade"),
                makeItem(id: "single-update", installed: true, status: .updateAvailable)
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update-all", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(state.executedSelectionSnapshots, [["single-update"]])
    }

    @MainActor
    func testCLIScopedBulkUpdateRequiresYes() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "brew", installed: true, status: .updateAvailable, updateCommand: "brew upgrade")
            ]
        )
        var output: [String] = []

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update", "brew"],
            state: state,
            output: { output.append($0) }
        )

        XCTAssertEqual(code, 2)
        XCTAssertEqual(state.updateSelectedCallCount, 0)
        XCTAssertTrue(output.contains(where: { $0.contains("Bulk updates require --yes") }))
    }

    @MainActor
    func testCLIScopedBulkUpdateAllowsYes() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "brew", installed: true, status: .updateAvailable, updateCommand: "brew upgrade")
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update", "brew", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(state.executedSelectionSnapshots, [["brew"]])
    }

    @MainActor
    func testCLIScopedGatedBulkUpdateRequiresYes() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "gated-bulk", installed: true, status: .gated, updateCommand: "brew upgrade", gateReasons: [.bulk])
            ]
        )
        var output: [String] = []

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update", "gated-bulk"],
            state: state,
            output: { output.append($0) }
        )

        XCTAssertEqual(code, 2)
        XCTAssertEqual(state.updateSelectedCallCount, 0)
        XCTAssertTrue(output.contains(where: { $0.contains("Re-run with --yes") }))
    }

    @MainActor
    func testCLIScopedGatedBulkUpdateAllowsYes() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "gated-bulk", installed: true, status: .gated, updateCommand: "brew upgrade", gateReasons: [.bulk])
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update", "gated-bulk", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(state.executedSelectionSnapshots, [["gated-bulk"]])
    }

    @MainActor
    func testCLIScopedGatedPrivilegedUpdateIsRefusedEvenWithYes() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "gated-privileged", installed: true, status: .gated, updateCommand: "sudo brew upgrade", gateReasons: [.privileged])
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update", "gated-privileged", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 1)
        XCTAssertEqual(state.updateSelectedCallCount, 0)
    }

    @MainActor
    func testCLIInstallAllExcludesRemoteScriptInstallers() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "safe-install", installed: false, status: .notInstalled, installCommand: "brew install safe-tool"),
                makeItem(id: "remote-install", installed: false, status: .notInstalled, installCommand: "curl -fsSL https://example.com/install.sh | bash")
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--install-all", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(state.executedSelectionSnapshots, [["safe-install"]])
    }

    @MainActor
    func testCLIScopedRemoteInstallRequiresYes() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "remote-install", installed: false, status: .notInstalled, installCommand: "curl -fsSL https://example.com/install.sh | bash")
            ]
        )
        var output: [String] = []

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--install", "remote-install"],
            state: state,
            output: { output.append($0) }
        )

        XCTAssertEqual(code, 2)
        XCTAssertEqual(state.updateSelectedCallCount, 0)
        XCTAssertTrue(output.contains(where: { $0.contains("remote script") }))
    }

    @MainActor
    func testCLIScopedRemoteInstallAllowsYes() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "remote-install", installed: false, status: .notInstalled, installCommand: "curl -fsSL https://example.com/install.sh | bash")
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--install", "remote-install", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(state.executedSelectionSnapshots, [["remote-install"]])
    }

    @MainActor
    func testCLICheckReturnsNonZeroWhenAnyItemCheckFailed() async {
        let state = MockCLIRunnerState(
            items: [
                makeItem(id: "ok-item", installed: true, status: .upToDate),
                makeItem(id: "failed-item", installed: true, status: .checkFailed)
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--check"],
            state: state
        )

        XCTAssertEqual(code, 1)
    }

    @MainActor
    func testCLIUpdateReturnsNonZeroWhenActionFails() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "failing-update", installed: true, status: .updateAvailable)
            ],
            resultStatusOverrides: ["failing-update": .error]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update-all", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 1)
    }

    @MainActor
    func testCLIUpdateAllReturnsZeroWhenNoItemsMatchAndChecksPass() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "brew", installed: true, status: .updateAvailable, updateCommand: "brew upgrade")
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update-all", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(state.updateSelectedCallCount, 0)
    }

    @MainActor
    func testCLIUpdateAllReturnsNonZeroWhenNoItemsMatchAndCheckFailedExists() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "brew", installed: true, status: .updateAvailable, updateCommand: "brew upgrade"),
                makeItem(id: "failed-check", installed: true, status: .checkFailed)
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update-all", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 1)
        XCTAssertEqual(state.updateSelectedCallCount, 0)
    }

    @MainActor
    func testCLIUpdateAllReturnsNonZeroWhenAnyItemCheckFailed() async {
        let state = MockCLIRunnerState(
            confirmBeforeUpdate: false,
            items: [
                makeItem(id: "update-item", installed: true, status: .updateAvailable),
                makeItem(id: "failed-check", installed: true, status: .checkFailed)
            ]
        )

        let code = await CLIRunner.run(
            arguments: ["DailyUpdate", "--update-all", "--yes"],
            state: state
        )

        XCTAssertEqual(code, 1)
    }

    @MainActor
    func testRequestUpdateSelectedShowsDryRunWhenConfirmationEnabled() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let store = UserSettingsStore()
            store.settings.confirmBeforeUpdate = true
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            state.items = [
                makeItem(id: "menu-bar-update", installed: true, status: .updateAvailable, isSelected: true)
            ]

            await state.requestUpdateSelected()

            XCTAssertTrue(state.showDryRun)
            XCTAssertEqual(state.dryRunEntries.map(\.id), ["menu-bar-update"])
        }
    }

    @MainActor
    func testAppStateSelectAllInstallableExcludesRemoteScriptInstallers() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let store = UserSettingsStore()
            let state = AppState(settingsStore: store)
            state.items = [
                makeItem(id: "safe-install", installed: false, status: .notInstalled, installCommand: "brew install safe-tool"),
                makeItem(id: "remote-install", installed: false, status: .notInstalled, installCommand: "curl -fsSL https://example.com/install.sh | bash")
            ]

            state.selectAllInstallable()

            XCTAssertTrue(state.items.first(where: { $0.id == "safe-install" })?.isSelected == true)
            XCTAssertTrue(state.items.first(where: { $0.id == "remote-install" })?.isSelected == false)
        }
    }

    @MainActor
    func testRetryUpdateForBulkItemUsesForcedDryRun() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let store = UserSettingsStore()
            store.settings.confirmBeforeUpdate = false
            let state = AppState(settingsStore: store)
            state.items = [
                UpdateItem(
                    id: "bulk-retry",
                    name: "Bulk Retry",
                    category: .runtime,
                    description: nil,
                    currentVersion: "1.0.0",
                    latestVersion: "1.1.0",
                    status: .updateAvailable,
                    statusMessage: "Still behind latest",
                    gateReasons: [.bulk],
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
            ]

            await state.retryUpdate(for: "bulk-retry")

            XCTAssertTrue(state.showDryRun)
            XCTAssertEqual(state.dryRunEntries.map(\.id), ["bulk-retry"])
        }
    }

    @MainActor
    func testRetryUpdateRunsConfirmedDryRunTargetsOnly() async throws {
        try await withTemporaryAppSupportDirectory { tempRoot in
            let retryMarker = tempRoot.appendingPathComponent("retry-marker")
            let otherMarker = tempRoot.appendingPathComponent("other-marker")

            let store = UserSettingsStore()
            store.settings.confirmBeforeUpdate = true
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            state.items = [
                UpdateItem(
                    id: "retry-item",
                    name: "Retry Item",
                    category: .runtime,
                    description: nil,
                    currentVersion: "1.0.0",
                    latestVersion: "1.1.0",
                    status: .updateAvailable,
                    statusMessage: "Retry requested",
                    isInstalled: true,
                    isSelected: false,
                    isUserDefined: false,
                    source: .bundled,
                    iconPath: nil,
                    detectCommand: nil,
                    versionCommand: nil,
                    checkCommand: nil,
                    installCommand: "",
                    updateCommand: "touch \(ShellEscaping.quote(retryMarker.path))",
                    workingDirectory: nil
                ),
                UpdateItem(
                    id: "other-item",
                    name: "Other Item",
                    category: .runtime,
                    description: nil,
                    currentVersion: "1.0.0",
                    latestVersion: "1.1.0",
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
                    updateCommand: "touch \(ShellEscaping.quote(otherMarker.path))",
                    workingDirectory: nil
                )
            ]

            await state.retryUpdate(for: "retry-item")
            XCTAssertTrue(state.showDryRun)
            XCTAssertEqual(state.dryRunEntries.map(\.id), ["retry-item"])

            if let index = state.items.firstIndex(where: { $0.id == "other-item" }) {
                state.items[index].isSelected = true
            }

            await state.confirmDryRun()

            XCTAssertTrue(FileManager.default.fileExists(atPath: retryMarker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: otherMarker.path))
        }
    }

    @MainActor
    func testConfirmDryRunSkipsTargetsThatChangedSinceConfirmation() async throws {
        try await withTemporaryAppSupportDirectory { tempRoot in
            let updateMarker = tempRoot.appendingPathComponent("update-marker")
            let installMarker = tempRoot.appendingPathComponent("install-marker")

            let store = UserSettingsStore()
            store.settings.confirmBeforeUpdate = true
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            state.items = [
                UpdateItem(
                    id: "flip-item",
                    name: "Flip Item",
                    category: .runtime,
                    description: nil,
                    currentVersion: "1.0.0",
                    latestVersion: "1.1.0",
                    status: .updateAvailable,
                    statusMessage: nil,
                    isInstalled: true,
                    isSelected: true,
                    isUserDefined: false,
                    source: .bundled,
                    iconPath: nil,
                    detectCommand: nil,
                    versionCommand: nil,
                    checkCommand: nil,
                    installCommand: "touch \(ShellEscaping.quote(installMarker.path))",
                    updateCommand: "touch \(ShellEscaping.quote(updateMarker.path))",
                    workingDirectory: nil
                )
            ]

            await state.requestUpdateSelected()
            XCTAssertTrue(state.showDryRun)
            XCTAssertEqual(state.dryRunEntries.first?.action, "Update")

            if let index = state.items.firstIndex(where: { $0.id == "flip-item" }) {
                state.items[index].status = .notInstalled
                state.items[index].isInstalled = false
                state.items[index].currentVersion = nil
                state.items[index].latestVersion = nil
            }

            await state.confirmDryRun()

            XCTAssertFalse(FileManager.default.fileExists(atPath: updateMarker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: installMarker.path))
            XCTAssertTrue(state.logLines.contains { $0.contains("changed since you confirmed, not run") })
            XCTAssertTrue(state.logLines.contains { $0.contains("Nothing run: all items changed since you confirmed") })
        }
    }

    @MainActor
    func testCheckAllSkipsWhileUpdating() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let store = UserSettingsStore()
            let state = AppState(settingsStore: store)
            state.isUpdating = true

            await state.checkAll()

            XCTAssertTrue(state.logLines.contains { $0.contains("Check skipped: an update is running") })
        }
    }

    func testDuplicateDetectorUsesResolvedPathGrouping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appPath = root.appendingPathComponent("Tool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: true)
        let symlinkPath = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(atPath: symlinkPath.path, withDestinationPath: appPath.path)

        let first = makeItem(id: "first", installed: true, status: .upToDate)
        let second = makeItem(id: "second", installed: true, status: .upToDate)
        var firstWithPath = first
        firstWithPath.detectedPaths = [appPath.path]
        var secondWithPath = second
        secondWithPath.detectedPaths = [symlinkPath.path]

        let groups = DuplicateDetector.find(in: [firstWithPath, secondWithPath])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].itemIDs), Set(["first", "second"]))
        XCTAssertTrue(groups[0].reason.contains("Same resolved path"))
    }

    @MainActor
    func testDismissDryRunClearsPendingTargets() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let store = UserSettingsStore()
            store.settings.confirmBeforeUpdate = true
            let state = AppState(settingsStore: store)
            state.items = [
                makeItem(id: "dismiss-item", installed: true, status: .updateAvailable, isSelected: true)
            ]

            await state.requestUpdateSelected()
            XCTAssertTrue(state.showDryRun)
            XCTAssertEqual(state.dryRunEntries.map(\.id), ["dismiss-item"])

            state.dismissDryRun()
            await state.confirmDryRun()

            XCTAssertFalse(state.showDryRun)
            XCTAssertTrue(state.dryRunEntries.isEmpty)
            XCTAssertTrue(state.logLines.contains { $0.contains("No items selected") })
        }
    }

    private func withTemporaryAppSupportDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.setAppSupportDirectoryForTesting(tempRoot)
        defer {
            ConfigLoader.setAppSupportDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try await operation(tempRoot)
    }

    private func makeItem(
        id: String,
        installed: Bool,
        status: ItemStatus,
        installCommand: String = "",
        updateCommand: String = "echo update",
        isSelected: Bool = false,
        gateReasons: [GateReason] = []
    ) -> UpdateItem {
        UpdateItem(
            id: id,
            name: id,
            category: .cli,
            description: nil,
            currentVersion: installed ? "1.0.0" : nil,
            latestVersion: installed ? "1.1.0" : nil,
            status: status,
            statusMessage: nil,
            gateReasons: gateReasons,
            isInstalled: installed,
            isSelected: isSelected,
            isUserDefined: true,
            source: .user,
            iconPath: nil,
            detectCommand: nil,
            versionCommand: nil,
            checkCommand: nil,
            installCommand: installCommand,
            updateCommand: updateCommand,
            workingDirectory: nil
        )
    }
}

@MainActor
private final class MockCLIRunnerState: CLIRunnerState {
    var items: [UpdateItem]
    var confirmBeforeUpdate: Bool
    var resultStatusOverrides: [String: ItemStatus]
    var updateSelectedCallCount = 0
    var executedSelectionSnapshots: [[String]] = []

    var selectedActionableItems: [UpdateItem] {
        items.filter { $0.isSelected && $0.isActionable }
    }

    init(
        confirmBeforeUpdate: Bool = true,
        items: [UpdateItem],
        resultStatusOverrides: [String: ItemStatus] = [:]
    ) {
        self.confirmBeforeUpdate = confirmBeforeUpdate
        self.items = items
        self.resultStatusOverrides = resultStatusOverrides
    }

    func checkAll() async {}

    func selectAllInstallable() {
        for index in items.indices {
            items[index].isSelected = ActionCommandPolicy.shouldAutoSelectForInstall(items[index])
        }
    }

    func selectAllUpdates(limitTo ids: [String]?) {
        let allowed = ids.map(Set.init)
        for index in items.indices {
            if let allowed, !allowed.contains(items[index].id) { continue }
            items[index].isSelected = GatePolicy.shouldAutoSelectForUpdate(items[index])
        }
    }

    func deselectAll(limitTo ids: [String]?) {
        let allowed = ids.map(Set.init)
        for index in items.indices {
            if let allowed, !allowed.contains(items[index].id) { continue }
            items[index].isSelected = false
        }
    }

    func setSelection(for id: String, selected: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSelected = selected
    }

    func updateSelected(skipDryRun: Bool, explicitTargetIDs: [String]?) async {
        updateSelectedCallCount += 1
        let selectedIDs: [String]
        if let explicitTargetIDs {
            let targetSet = Set(explicitTargetIDs)
            selectedIDs = items.filter { targetSet.contains($0.id) }.map(\.id).sorted()
        } else {
            selectedIDs = items.filter { $0.isSelected && $0.isActionable }.map(\.id).sorted()
        }
        executedSelectionSnapshots.append(selectedIDs)
        for index in items.indices where selectedIDs.contains(items[index].id) {
            let id = items[index].id
            items[index].status = resultStatusOverrides[id] ?? .updated
        }
    }
}
