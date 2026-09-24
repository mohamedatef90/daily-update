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
