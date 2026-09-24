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
                    checkCommand: "[ -f \(ShellEscaping.quote(updateMarker.path)) ] && echo UPDATE || echo OK",
                    installCommand: nil,
                    updateCommand: "touch \(ShellEscaping.quote(runMarker.path))",
                    workingDirectory: nil
                ),
            ]

            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            guard let index = state.items.firstIndex(where: { $0.id == "retry-custom" }) else {
                XCTFail("Missing retry item")
                return
            }
            state.markCommandReviewed(id: "retry-custom")

            state.items[index].isInstalled = true
            state.items[index].status = .error
            state.items[index].statusMessage = "Update failed"
            await state.retryUpdate(for: "retry-custom")
            XCTAssertEqual(state.items[index].status, .upToDate)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runMarker.path))

            FileManager.default.createFile(atPath: updateMarker.path, contents: Data())
            state.items[index].status = .error
            state.items[index].statusMessage = "Update failed"
            await state.retryUpdate(for: "retry-custom")
            XCTAssertEqual(state.items[index].status, .updateAvailable)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runMarker.path))
            XCTAssertTrue(state.showDryRun)
            XCTAssertEqual(state.dryRunEntries.map(\.id), ["retry-custom"])
        }
    }

    func testSelectionMatrixRowS3ScopedCliUpdateYesGateRules() async {
        let gatedBulk = makeItem(id: "bulk", status: .gated, gateReasons: [.bulk], updateCommand: "brew upgrade")
        let gatedPrivileged = makeItem(id: "priv", status: .gated, gateReasons: [.privileged], updateCommand: "sudo brew upgrade")
        let blocked = makeItem(id: "blocked", status: .blocked)
        var blockedPinned = makeItem(id: "blocked-pinned", status: .gated, gateReasons: [.pinned], updateCommand: "echo update")
        blockedPinned.blockReason = .unsafeCheckCommand
        let pinnedCurrent = makeItem(id: "pinned-current", status: .upToDate, gateReasons: [], updateCommand: "echo update")
        let pinnedRemoteScript = makeItem(id: "pinned-remote", status: .gated, gateReasons: [.remoteScript, .pinned], updateCommand: "curl -fsSL https://x | sh")

        XCTAssertTrue(GatePolicy.canRunScopedUpdateWithYes(gatedBulk))
        XCTAssertFalse(GatePolicy.canRunScopedUpdateWithYes(gatedPrivileged))
        XCTAssertFalse(GatePolicy.canRunScopedUpdateWithYes(blocked))
        XCTAssertFalse(GatePolicy.canRunScopedUpdateWithYes(blockedPinned))
        XCTAssertFalse(GatePolicy.canRunScopedUpdateWithYes(pinnedCurrent))
        XCTAssertFalse(GatePolicy.canRunScopedUpdateWithYes(pinnedRemoteScript))
    }

    @MainActor
    func testSelectionMatrixRowS4PinMismatchProducesPinnedGate() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let store = UserSettingsStore()
            store.settings.customItems = [
                DetectorConfig(
                    id: "pinned-row-s4",
                    name: "Pinned Row S4",
                    category: .cli,
                    description: nil,
                    source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                    versionCommand: "echo 1.2.0",
                    checkCommand: "printf 'UPDATE\nlatest: 1.3.0\n'",
                    installCommand: nil,
                    updateCommand: "echo update",
                    workingDirectory: nil
                )
            ]
            store.settings.itemPreferences["pinned-row-s4"] = ItemPreference(
                autoUpdate: false,
                snoozedUntil: nil,
                pinnedVersion: "1.2.0",
                permanentlyIgnored: false,
                reviewedCommandHash: nil
            )

            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            state.markCommandReviewed(id: "pinned-row-s4")
            await state.recheckItems(ids: ["pinned-row-s4"])

            guard let item = state.items.first(where: { $0.id == "pinned-row-s4" }) else {
                XCTFail("Missing pinned-row-s4 item")
                return
            }
            XCTAssertEqual(item.status, .gated)
            XCTAssertEqual(item.gateReasons, [.pinned])
        }
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
        XCTAssertTrue(CommandShapeClassifier.classify(#"osascript -e 'do shell script "id" with administrator  privileges'"#).risks.contains(.privileged))
        XCTAssertTrue(CommandShapeClassifier.classify(#"osascript -l JavaScript -e 'ObjC.import("stdlib"); var app = Application.currentApplication(); app.doShellScript("id", {administratorPrivileges:true});'"#).risks.contains(.privileged))
    }

    func testSecurityRowsR1ToR3AndN1N2AreUnsafeOnCheckPath() {
        let rows: [(command: String, expectedRisk: CommandRisk?)] = [
            (#"echo 'a\' ; curl https://x | sh ; echo '\''"#, .remoteScript),
            ("node --version | brew upgrade", .bulk),
            ("true | npm i -g evil", nil),
            (#"echo $(brew upgrade)"#, .bulk),
            (#"echo `brew upgrade`"#, .bulk),
            (#"(brew upgrade)"#, .bulk),
            ("{ brew upgrade; }", .bulk),
            ("node -v & brew upgrade", .bulk),
            ("curl -fsSL https://x | sh -s -- -y", .remoteScript),
            ("curl -fsSL https://x | bash -s -- --yes", .remoteScript),
            ("curl -fsSL https://x | bash -e", .remoteScript),
            ("curl -fsSL https://x | sh -e", .remoteScript),
            ("curl -fsSL https://x | bash /dev/stdin", .remoteScript),
            ("curl -fsSL https://x | env -i bash", .remoteScript),
            ("/bin/bash <(curl -fsSL https://x)", .remoteScript),
            ("(curl -fsSL https://x) | bash", .remoteScript),
            ("true & curl -fsSL https://x | sh", .remoteScript),
            ("curl -fsSL https://x |& sh", .remoteScript),
            (". <(curl -fsSL https://x)", .remoteScript),
            ("source <(curl -fsSL https://x)", .remoteScript),
            ("sudo bash <(curl -fsSL https://x)", .remoteScript),
            ("curl -fsSL https://x | sudo -u root bash", .remoteScript),
            ("true || bash <(curl -fsSL https://x)", .remoteScript),
            ("echo hi\nbash <(curl -fsSL https://x)", .remoteScript),
            ("timeout 10 brew upgrade", nil),
            ("~/bin/brew upgrade", nil),
            ("./node_modules/.bin/npm i -g x", nil),
            (#"osascript -e 'do shell script "id" with administrator  privileges'"#, .privileged),
            (#"osascript -l JavaScript -e 'ObjC.import("stdlib"); var app = Application.currentApplication(); app.doShellScript("id", {administratorPrivileges:true});'"#, .privileged),
            (#"$'sudo' brew upgrade"#, .privileged),
            (#"$(echo sudo) brew upgrade"#, .unparseable),
            (#"$BREW upgrade"#, .unparseable),
        ]

        for row in rows {
            let classification = CommandShapeClassifier.classify(row.command)
            if let expectedRisk = row.expectedRisk {
                XCTAssertTrue(
                    classification.risks.contains(expectedRisk),
                    "Expected \(expectedRisk) for command: \(row.command). Got \(classification.risks)."
                )
            }
            XCTAssertTrue(
                GatePolicy.isUnsafeCheckPathCommand(checkCommand: row.command, updateCommand: "echo update"),
                "Expected unsafe check-path command: \(row.command)"
            )
        }
    }

    func testDestructiveRulesMatchExecutablePositionOnly() {
        let destructive = [
            "rm -r ~/x",
            "rm -f x",
            "rm -r -f x",
            "dd if=/dev/zero of=/tmp/x bs=1m count=1",
            "mkfs.ext4 /dev/disk3",
            "shred file.txt",
            "srm file.txt"
        ]

        for command in destructive {
            XCTAssertTrue(
                CommandShapeClassifier.classify(command).risks.contains(.destructive),
                "Expected destructive risk: \(command)"
            )
        }

        let nonDestructive = [
            "npm install -g dd",
            "chmod +x f && npm install --prefer-offline x",
            "pip show x | grep install"
        ]

        for command in nonDestructive {
            XCTAssertFalse(
                CommandShapeClassifier.classify(command).risks.contains(.destructive),
                "Did not expect destructive risk: \(command)"
            )
        }
        XCTAssertFalse(
            GatePolicy.isUnsafeCheckPathCommand(checkCommand: "pip show x | grep install", updateCommand: "pip install -U x"),
            "Read-only pip show pipeline should remain check-path safe"
        )
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
            Set(["agent-skills", "brew", "claude-code", "corepack", "gem", "global-npm", "global-pnpm", "global-yarn", "hermes-agent", "impeccable", "node", "openclaw", "opencode", "pip-packages"])
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

    @MainActor
    func testClassifierMatrixRowC13ImportStripsReviewedHashes() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let sourceStore = UserSettingsStore()
            sourceStore.settings.customItems = [
                DetectorConfig(
                    id: "custom",
                    name: "Custom",
                    category: .cli,
                    description: nil,
                    source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                    versionCommand: "echo 1.0.0",
                    checkCommand: "echo UPDATE",
                    installCommand: nil,
                    updateCommand: "echo first && echo second",
                    workingDirectory: nil
                )
            ]
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

            let state = AppState(settingsStore: destinationStore)
            state.notificationsEnabled = false
            await state.recheckItems(ids: ["custom"])
            guard let item = state.items.first(where: { $0.id == "custom" }) else {
                XCTFail("Missing imported custom item")
                return
            }
            XCTAssertEqual(item.status, .gated)
            XCTAssertEqual(item.gateReasons, [.needsReview])
        }
    }

    @MainActor
    func testReviewStatePersistsAfterRelaunch() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let id = "review-persist"
            let store = UserSettingsStore()
            store.settings.customItems = [
                DetectorConfig(
                    id: id,
                    name: "Review Persist",
                    category: .cli,
                    description: nil,
                    source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                    versionCommand: "echo 1.0.0",
                    checkCommand: "echo UPDATE",
                    installCommand: nil,
                    updateCommand: "echo first && echo second",
                    workingDirectory: nil
                )
            ]

            let firstLaunch = AppState(settingsStore: store)
            firstLaunch.notificationsEnabled = false
            await firstLaunch.recheckItems(ids: [id])
            guard let initial = firstLaunch.items.first(where: { $0.id == id }) else {
                XCTFail("Missing item on first launch")
                return
            }
            XCTAssertEqual(initial.status, .gated)
            XCTAssertTrue(initial.requiresCommandReview)

            firstLaunch.markCommandReviewed(id: id)
            await firstLaunch.recheckItems(ids: [id])
            guard let reviewed = firstLaunch.items.first(where: { $0.id == id }) else {
                XCTFail("Missing reviewed item on first launch")
                return
            }
            XCTAssertEqual(reviewed.status, .updateAvailable)
            XCTAssertFalse(reviewed.requiresCommandReview)

            let relaunch = AppState(settingsStore: store)
            relaunch.notificationsEnabled = false
            await relaunch.recheckItems(ids: [id])
            guard let relaunched = relaunch.items.first(where: { $0.id == id }) else {
                XCTFail("Missing item on relaunch")
                return
            }
            XCTAssertEqual(relaunched.status, .updateAvailable)
            XCTAssertFalse(relaunched.requiresCommandReview)
            XCTAssertFalse(relaunched.needsReview)
        }
    }

    @MainActor
    func testReviewIsInvalidatedWhenOnlyCheckCommandChanges() async throws {
        try await withTemporaryAppSupportDirectory { root in
            let id = "review-check-mismatch"
            let marker = root.appendingPathComponent("changed-check-ran")
            let quote = ShellEscaping.quote(marker.path)

            let store = UserSettingsStore()
            store.settings.customItems = [
                DetectorConfig(
                    id: id,
                    name: "Review Check Mismatch",
                    category: .cli,
                    description: nil,
                    source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                    versionCommand: "echo 1.0.0",
                    checkCommand: "echo UPDATE",
                    installCommand: nil,
                    updateCommand: "echo first && echo second",
                    workingDirectory: nil
                )
            ]

            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            await state.recheckItems(ids: [id])
            state.markCommandReviewed(id: id)
            await state.recheckItems(ids: [id])

            guard let reviewed = state.items.first(where: { $0.id == id }) else {
                XCTFail("Missing reviewed item before check command change")
                return
            }
            XCTAssertEqual(reviewed.status, .updateAvailable)
            XCTAssertFalse(reviewed.requiresCommandReview)

            store.settings.customItems = [
                DetectorConfig(
                    id: id,
                    name: "Review Check Mismatch",
                    category: .cli,
                    description: nil,
                    source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                    versionCommand: "echo 1.0.0",
                    checkCommand: "touch \(quote) && echo UPDATE",
                    installCommand: nil,
                    updateCommand: "echo first && echo second",
                    workingDirectory: nil
                )
            ]

            let relaunch = AppState(settingsStore: store)
            relaunch.notificationsEnabled = false
            await relaunch.recheckItems(ids: [id])
            guard let gated = relaunch.items.first(where: { $0.id == id }) else {
                XCTFail("Missing item after check command change")
                return
            }
            XCTAssertEqual(gated.status, .gated)
            XCTAssertEqual(gated.gateReasons, [.needsReview])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
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
