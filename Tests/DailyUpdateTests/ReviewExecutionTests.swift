import Foundation
import XCTest
@testable import DailyUpdate

final class ReviewExecutionTests: XCTestCase {
    @MainActor
    func testUnreviewedCustomItemRunsNoCommandsAcrossCheckPaths() async throws {
        try await assertUnreviewedCommandsDoNotRun(imported: false)
    }

    @MainActor
    func testUnreviewedImportedItemRunsNoCommandsAcrossCheckPaths() async throws {
        try await assertUnreviewedCommandsDoNotRun(imported: true)
    }

    @MainActor
    private func assertUnreviewedCommandsDoNotRun(imported: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigLoader.setAppSupportDirectoryForTesting(root)
        defer {
            ConfigLoader.setAppSupportDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }

        let markers = ["detect", "version", "check"].map { root.appendingPathComponent($0) }
        let config = DetectorConfig(
            id: "unreviewed",
            name: "Unreviewed",
            category: .cli,
            description: nil,
            source: .user,
            detect: DetectRule(
                type: .command,
                paths: nil,
                command: "echo detected > \(ShellEscaping.quote(markers[0].path))",
                appName: nil
            ),
            versionCommand: "echo 1.0.0 | tee \(ShellEscaping.quote(markers[1].path))",
            checkCommand: "echo UPDATE | tee \(ShellEscaping.quote(markers[2].path))",
            installCommand: "echo install",
            updateCommand: "echo update",
            workingDirectory: nil
        )
        var settings = UserSettings.defaults
        settings.disabledItemIDs = ConfigLoader.loadConfigs(settings: settings).map(\.id)
        settings.rescanReposOnLaunch = false
        settings.rescanAppsOnLaunch = false
        settings.rescanSkillsOnLaunch = false
        settings.notificationsEnabled = false
        settings.customItems = [config]

        let store = UserSettingsStore()
        if imported {
            settings.itemPreferences[config.id] = ItemPreference(
                reviewedCommandHash: GatePolicy.reviewedCommandHash(for: config)
            )
            try ConfigImportExport.importData(ConfigImportExport.export(settings: settings), into: store)
            XCTAssertNil(store.settings.itemPreferences[config.id]?.reviewedCommandHash)
        } else {
            store.settings = settings
        }

        let state = AppState(settingsStore: store)
        XCTAssertEqual(state.items.map(\.id), [config.id])
        let loaded = try XCTUnwrap(ConfigLoader.loadConfigs(settings: store.settings).first)
        XCTAssertTrue(loaded.requiresReviewBeforeAutomation)

        let direct = await UpdateCheckService.check(loaded, installed: true)
        XCTAssertEqual(direct.status, .gated)
        XCTAssertEqual(direct.gateReasons, [.needsReview])
        assertNoMarkers(markers)

        await state.recheckItems(ids: [config.id])
        XCTAssertEqual(state.items.first?.status, .gated)
        XCTAssertEqual(state.items.first?.gateReasons, [.needsReview])
        assertNoMarkers(markers)

        await state.checkAll()
        XCTAssertEqual(state.items.first?.status, .gated)
        XCTAssertEqual(state.items.first?.gateReasons, [.needsReview])
        assertNoMarkers(markers)
    }

    private func assertNoMarkers(_ markers: [URL], file: StaticString = #filePath, line: UInt = #line) {
        for marker in markers {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), marker.lastPathComponent, file: file, line: line)
        }
    }
}

extension ReviewExecutionTests {
    @MainActor
    func testD1CustomRemoteAndPrivilegedActionsCannotUseYesBeforeReview() async throws {
        try await assertPreReviewActionsRefused(imported: false)
    }

    @MainActor
    func testD1ImportedRemoteAndPrivilegedActionsCannotUseYesBeforeReview() async throws {
        try await assertPreReviewActionsRefused(imported: true)
    }

    @MainActor
    private func assertPreReviewActionsRefused(imported: Bool) async throws {
        try await withReviewFixture { root, store in
            let installMarker = root.appendingPathComponent("installed")
            let updateMarker = root.appendingPathComponent("updated")
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let sudo = bin.appendingPathComponent("sudo")
            try "#!/bin/sh\nexec \"$@\"\n".write(to: sudo, atomically: true, encoding: .utf8)
            let curl = bin.appendingPathComponent("curl")
            try "#!/bin/sh\nprintf 'touch %s\\n' \"$1\"\n".write(to: curl, atomically: true, encoding: .utf8)
            for path in [sudo.path, curl.path] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
            let prefix = "PATH=\(ShellEscaping.quote(bin.path)):$PATH"
            for shape in ["remote", "privileged"] {
                func command(_ marker: URL) -> String {
                    shape == "remote"
                        ? "\(prefix) curl \(ShellEscaping.quote(marker.path)) | sh"
                        : "\(prefix) sudo touch \(ShellEscaping.quote(marker.path))"
                }
                let config = DetectorConfig(id: "unreviewed-action", name: "Unreviewed", category: .cli, description: nil,
                    source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                    versionCommand: "echo 1.0.0", checkCommand: "echo UPDATE", installCommand: command(installMarker),
                    updateCommand: command(updateMarker), workingDirectory: nil)
                store.settings.customItems = [config]
                if imported {
                    store.settings.itemPreferences[config.id] = ItemPreference(reviewedCommandHash: GatePolicy.reviewedCommandHash(for: config))
                    let data = try ConfigImportExport.export(settings: store.settings)
                    try ConfigImportExport.importData(data, into: store)
                }
                let state = AppState(settingsStore: store)
                for flag in ["--update", "--install"] {
                    var output: [String] = []
                    let exit = await CLIRunner.run(arguments: ["DailyUpdate", flag, config.id, "--yes"], state: state, output: { output.append($0) })
                    XCTAssertEqual(exit, 2, "\(shape) \(flag): \(output)")
                    XCTAssertEqual(output, ["Review this item in the app first: \(config.id)"])
                    XCTAssertEqual(state.items.first?.status, .gated)
                    XCTAssertEqual(state.items.first?.gateReasons, [.needsReview])
                    XCTAssertFalse(FileManager.default.fileExists(atPath: installMarker.path))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: updateMarker.path))
                }
            }
        }
    }

    func testM1WorkingDirectoryChangeRequiresReview() async throws { try await assertReviewContextChange(key: "workingDirectory", value: "/changed") }
    func testM1DetectTypeChangeRequiresReview() async throws { try await assertReviewContextChange(key: "type", value: "path", detect: true) }
    func testM1DetectPathsChangeRequiresReview() async throws { try await assertReviewContextChange(key: "paths", value: ["/changed"], detect: true) }
    func testM1DetectCommandChangeRequiresReview() async throws { try await assertReviewContextChange(key: "command", value: "echo changed", detect: true) }
    func testM1DetectAppNameChangeRequiresReview() async throws { try await assertReviewContextChange(key: "appName", value: "Changed", detect: true) }
    func testM1VersionPatternChangeRequiresReview() async throws { try await assertReviewContextChange(key: "versionPattern", value: "([0-9]+)") }
    func testM1VersionCommandChangeRequiresReview() async throws { try await assertReviewContextChange(key: "versionCommand", value: "echo 2.0.0") }
    func testM1CheckCommandChangeRequiresReview() async throws { try await assertReviewContextChange(key: "checkCommand", value: "echo OK") }
    func testM1UpdateCommandChangeRequiresReview() async throws { try await assertReviewContextChange(key: "updateCommand", value: "echo changed") }
    func testM1InstallCommandChangeRequiresReview() async throws { try await assertReviewContextChange(key: "installCommand", value: "echo changed") }
    func testM1CommandNameChangeRequiresReview() async throws { try await assertReviewContextChange(key: "command", value: "changed") }
    func testM1PackagesChangeRequiresReview() async throws { try await assertReviewContextChange(key: "packages", value: ["npm": "changed"]) }
    func testM1SelfUpdaterChangeRequiresReview() async throws { try await assertReviewContextChange(key: "selfUpdater", value: "claudeCode") }
    func testM1AppcastURLChangeRequiresReview() async throws { try await assertReviewContextChange(key: "appcastURL", value: "https://example.invalid/appcast.xml") }
    func testM1AutoUpdatesChangeRequiresReview() async throws { try await assertReviewContextChange(key: "autoUpdates", value: true) }

    private func assertReviewContextChange(key: String, value: Any, detect: Bool = false) async throws {
        let base = DetectorConfig(id: "review", name: "Review", category: .cli, description: nil, source: .user,
            detect: DetectRule(type: .command, paths: ["/original"], command: "true", appName: "Original"),
            versionCommand: "echo 1.0.0", checkCommand: "echo UPDATE", installCommand: "echo install",
            updateCommand: "echo update", workingDirectory: "/original", needsReview: true)
        let hash = GatePolicy.reviewedCommandHash(for: base)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        if detect {
            var rule = try XCTUnwrap(json["detect"] as? [String: Any]); rule[key] = value; json["detect"] = rule
        } else { json[key] = value }
        let changed = try JSONDecoder().decode(DetectorConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNotEqual(GatePolicy.reviewedCommandHash(for: changed), hash)
        let result = await UpdateCheckService.check(changed, installed: true, reviewedCommandHash: hash)
        XCTAssertEqual(result.status, .gated)
        XCTAssertEqual(result.gateReasons, [.needsReview])
        XCTAssertEqual(result.message, "Needs review before running commands")
    }

    @MainActor
    func testF2ReviewTriggersRecheckInsteadOfAssumingUpdateAvailable() async throws {
        try await withReviewFixture { root, store in
            let marker = root.appendingPathComponent("checked")
            let config = DetectorConfig(id: "review-recheck", name: "Review recheck", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "touch \(ShellEscaping.quote(marker.path)); echo OK",
                installCommand: "echo install", updateCommand: "echo one && echo two", workingDirectory: nil)
            store.settings.customItems = [config]
            let state = AppState(settingsStore: store)
            await state.recheckItems(ids: [config.id])
            XCTAssertEqual(state.items.first?.status, .gated)
            state.markCommandReviewed(id: config.id)
            XCTAssertEqual(state.items.first?.status, .checking)
            XCTAssertFalse(state.items.first?.isSelected ?? true)
            for _ in 0..<100 where state.items.first?.status == .checking {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(state.items.first?.status, .upToDate)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @MainActor
    private func withReviewFixture(_ body: (URL, UserSettingsStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigLoader.setAppSupportDirectoryForTesting(root)
        defer { ConfigLoader.setAppSupportDirectoryForTesting(nil); try? FileManager.default.removeItem(at: root) }
        let store = UserSettingsStore()
        store.settings.disabledItemIDs = ConfigLoader.loadConfigs(settings: .defaults).map(\.id)
        store.settings.rescanReposOnLaunch = false
        store.settings.rescanAppsOnLaunch = false
        store.settings.rescanSkillsOnLaunch = false
        store.settings.notificationsEnabled = false
        try await body(root, store)
    }
}
