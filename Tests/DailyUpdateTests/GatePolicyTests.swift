import XCTest
@testable import DailyUpdate

final class GatePolicyTests: XCTestCase {
    func testSelectionMatrixRowS1OnlyUpdateAvailableAutoSelects() {
        let statuses: [ItemStatus] = [
            .unknown, .checking, .checkFailed, .upToDate, .updateAvailable, .gated,
            .blocked, .failedVerification, .updatePending, .notInstalled, .error,
            .updating, .updated,
        ]

        for status in statuses {
            let item = makeItem(id: status.rawValue, status: status, gateReasons: status == .gated ? [.bulk] : [])
            XCTAssertEqual(
                GatePolicy.shouldAutoSelectForUpdate(item),
                status == .updateAvailable,
                "status=\(status)"
            )
        }
    }

    @MainActor
    func testSelectionMatrixRowS2RetryRechecksBeforeOpeningDryRun() async throws {
        try await withTemporaryAppSupportDirectory { root in
            let updateMarker = root.appendingPathComponent("available")
            let runMarker = root.appendingPathComponent("ran")
            let checkCommand = "[ -f \(ShellEscaping.quote(updateMarker.path)) ] && echo UPDATE || echo OK"
            let updateCommand = "touch \(ShellEscaping.quote(runMarker.path))"

            let store = UserSettingsStore()
            store.settings.confirmBeforeUpdate = true
            store.settings.customItems = [
                DetectorConfig(
                    id: "retry-custom",
                    name: "Retry Custom",
                    category: .cli,
                    description: nil,
                    source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                    versionCommand: "echo 1.0.0",
                    checkCommand: checkCommand,
                    installCommand: nil,
                    updateCommand: updateCommand,
                    workingDirectory: nil
                ),
            ]

            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            await state.checkAll()

            guard let index = state.items.firstIndex(where: { $0.id == "retry-custom" }) else {
                XCTFail("Missing retry item")
                return
            }
            state.items[index].status = .error
            state.items[index].statusMessage = "Update failed"

            await state.retryUpdate(for: "retry-custom")
            XCTAssertFalse(state.showDryRun)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runMarker.path))

            FileManager.default.createFile(atPath: updateMarker.path, contents: Data())
            state.items[index].status = .error
            state.items[index].statusMessage = "Update failed"

            await state.retryUpdate(for: "retry-custom")
            XCTAssertTrue(state.showDryRun)
            XCTAssertEqual(state.dryRunEntries.map(\.id), ["retry-custom"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: runMarker.path))
        }
    }

    func testSelectionMatrixRowS3ScopedCliUpdateYesGateRules() async {
        let gatedBulk = makeItem(id: "bulk", status: .gated, gateReasons: [.bulk], updateCommand: "brew upgrade")
        let gatedPrivileged = makeItem(id: "priv", status: .gated, gateReasons: [.privileged], updateCommand: "sudo brew upgrade")
        let blocked = makeItem(id: "blocked", status: .blocked)

        XCTAssertTrue(GatePolicy.canRunScopedUpdateWithYes(gatedBulk))
        XCTAssertFalse(GatePolicy.canRunScopedUpdateWithYes(gatedPrivileged))
        XCTAssertFalse(GatePolicy.canRunScopedUpdateWithYes(blocked))
    }

    func testSelectionMatrixRowS4PinnedCanBeOverriddenOnlyWithYes() {
        let pinned = makeItem(id: "pinned", status: .gated, gateReasons: [.pinned], updateCommand: "npm install -g npm@latest")
        XCTAssertTrue(GatePolicy.canRunScopedUpdateWithYes(pinned))
    }

    func testSecurityB1DetectVersionAndCheckUseSameSafetyGate() async {
        let detectBlocked = DetectorConfig(
            id: "detect-blocked",
            name: "Detect Blocked",
            category: .cli,
            description: nil,
            source: .user,
            detect: DetectRule(type: .command, paths: nil, command: "brew upgrade", appName: nil),
            versionCommand: "echo 1.0.0",
            checkCommand: "echo OK",
            installCommand: nil,
            updateCommand: "brew upgrade",
            workingDirectory: nil
        )
        let detectResult = await DetectionService.detect(detectBlocked)
        XCTAssertEqual(detectResult.blockReason, .unsafeCheckCommand)

        let versionBlocked = DetectorConfig(
            id: "version-blocked",
            name: "Version Blocked",
            category: .cli,
            description: nil,
            source: .user,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "npm install -g yarn",
            checkCommand: "echo OK",
            installCommand: nil,
            updateCommand: "npm install -g yarn",
            workingDirectory: nil
        )
        let versionResult = await UpdateCheckService.check(versionBlocked, installed: true)
        XCTAssertEqual(versionResult.status, .blocked)
        XCTAssertEqual(versionResult.blockReason, .unsafeCheckCommand)

        let checkBlocked = DetectorConfig(
            id: "check-blocked",
            name: "Check Blocked",
            category: .cli,
            description: nil,
            source: .user,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo 1.0.0",
            checkCommand: "brew upgrade",
            installCommand: nil,
            updateCommand: "brew upgrade",
            workingDirectory: nil
        )
        let checkResult = await UpdateCheckService.check(checkBlocked, installed: true)
        XCTAssertEqual(checkResult.status, .blocked)
        XCTAssertEqual(checkResult.blockReason, .unsafeCheckCommand)
    }

    func testSecurityB3PrivilegeDetectionUsesTokenBasenames() {
        XCTAssertTrue(CommandShapeClassifier.classify(#"s\udo brew upgrade"#).risks.contains(.privileged))
        XCTAssertTrue(CommandShapeClassifier.classify(#"osascript -e 'do shell script "echo hi" with administrator privileges'"#).risks.contains(.privileged))
    }

    func testShellRunnerUsesNullDeviceForStandardInput() async {
        let result = await ShellRunner.runProcess(
            executablePath: "/bin/cat",
            arguments: [],
            timeout: 0.5
        )
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertEqual(result.stdout, "")
    }

    func testBundledCatalogGatedAndBlockedIDsArePinned() {
        let bundled = ConfigLoader.loadConfigs(settings: .defaults).filter { $0.source == .bundled }
        let gated = Set(
            bundled
                .filter { !GatePolicy.updateGateReasons(for: $0, reviewedHash: nil).isEmpty }
                .map(\.id)
        )

        let blocked = Set(
            bundled.compactMap { config -> String? in
                if let detect = config.detect?.command,
                   GatePolicy.isUnsafeCheckPathCommand(checkCommand: detect, updateCommand: config.updateCommand) {
                    return config.id
                }
                if let version = config.versionCommand,
                   GatePolicy.isUnsafeCheckPathCommand(checkCommand: version, updateCommand: config.updateCommand) {
                    return config.id
                }
                if let check = config.checkCommand,
                   GatePolicy.isUnsafeCheckPathCommand(checkCommand: check, updateCommand: config.updateCommand) {
                    return config.id
                }
                return nil
            }
        )

        XCTAssertEqual(
            gated,
            Set(["agent-skills", "brew", "corepack", "gem", "global-npm", "global-pnpm", "global-yarn", "impeccable", "node", "pip-packages"])
        )
        XCTAssertTrue(blocked.isEmpty)

        guard let flutter = bundled.first(where: { $0.id == "flutter" }),
              let flutterCheck = flutter.checkCommand else {
            XCTFail("Missing flutter check command")
            return
        }
        XCTAssertFalse(
            GatePolicy.isUnsafeCheckPathCommand(checkCommand: flutterCheck, updateCommand: flutter.updateCommand),
            "python3 -c in flutter check should not be blocked as remote script"
        )
    }

    func testClassifierMatrixRowC13ImportStripsReviewedHashes() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let sourceStore = UserSettingsStore()
            sourceStore.settings.itemPreferences["custom"] = ItemPreference(
                autoUpdate: false,
                snoozedUntil: nil,
                pinnedVersion: nil,
                permanentlyIgnored: false,
                reviewedCommandHash: "deadbeef"
            )
            let exported = try ConfigImportExport.export(settings: sourceStore.settings)

            let destinationStore = UserSettingsStore()
            try ConfigImportExport.importData(exported, into: destinationStore)
            XCTAssertNil(destinationStore.settings.itemPreferences["custom"]?.reviewedCommandHash)
        }
    }

    private func makeItem(
        id: String,
        status: ItemStatus,
        gateReasons: [GateReason] = [],
        updateCommand: String = "echo update"
    ) -> UpdateItem {
        UpdateItem(
            id: id,
            name: id,
            category: .cli,
            description: nil,
            currentVersion: "1.0.0",
            latestVersion: "1.1.0",
            status: status,
            statusMessage: nil,
            gateReasons: gateReasons,
            blockReason: status == .blocked ? .manualOnly : nil,
            isInstalled: true,
            isSelected: false,
            isUserDefined: true,
            source: .user,
            iconPath: nil,
            detectCommand: nil,
            versionCommand: nil,
            checkCommand: nil,
            installCommand: "",
            updateCommand: updateCommand,
            workingDirectory: nil
        )
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
}
