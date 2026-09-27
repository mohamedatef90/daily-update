import XCTest
@testable import DailyUpdate

/// CR#1 regression: `UserSettings.inventory` is new in P2-1. The synthesized `Decodable` ignores a
/// property's default value and requires every key present, so before this fix, decoding any
/// `settings.json` written by `master` (which never wrote `inventory`) threw `keyNotFound`.
/// `UserSettingsStore.init` silently swallowed that and fell back to `.defaults`, and the very next
/// `save()` overwrote the user's real settings — custom items, disabled IDs, the schedule,
/// `hasCompletedSetup` — with fresh defaults.
final class UserSettingsDecodeTests: HermeticTestCase {
    /// Simulates a `settings.json` written by `master`: every key this PR's `UserSettings` still
    /// has, except `inventory`, which master never wrote.
    private func removingInventoryKey(from settings: UserSettings) throws -> Data {
        let encoded = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "inventory"), "fixture must actually carry the key being removed")
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testDecodingASettingsJSONWithoutInventoryKeepsEveryOtherField() throws {
        var original = UserSettings.defaults
        original.disabledItemIDs = ["some-item"]
        original.hasCompletedSetup = true

        let data = try removingInventoryKey(from: original)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)

        XCTAssertEqual(decoded.inventory, InventorySettings.defaults)
        // The actual regression: before the fix, the whole decode threw and the caller silently
        // substituted UserSettings.defaults, discarding disabledItemIDs and hasCompletedSetup along
        // with everything else in the file.
        XCTAssertEqual(decoded.disabledItemIDs, ["some-item"])
        XCTAssertTrue(decoded.hasCompletedSetup)
    }

    func testUserSettingsStoreLoadsASettingsFileWithoutInventoryInPlace() throws {
        var original = UserSettings.defaults
        original.disabledItemIDs = ["keep-me"]
        let data = try removingInventoryKey(from: original)
        let url = ConfigLoader.appSupportDirectory.appendingPathComponent("settings.json")
        try data.write(to: url)

        let store = UserSettingsStore()
        XCTAssertEqual(store.settings.disabledItemIDs, ["keep-me"])
        XCTAssertEqual(store.settings.inventory, InventorySettings.defaults)
    }

    /// A present-but-incomplete `inventory` object (missing `hiddenEcosystems`) must not fail
    /// either — it falls back the same way an absent key would.
    func testInventoryPresentButMissingHiddenEcosystemsFallsBackToEmptySet() throws {
        let decoded = try JSONDecoder().decode(InventorySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, InventorySettings.defaults)
    }

    /// An older exported bundle (pre-P2-1) has a `settings` object without `inventory` either.
    func testImportingAnOlderExportBundleWithoutInventorySucceeds() throws {
        let store = UserSettingsStore()
        var original = UserSettings.defaults
        original.disabledItemIDs = ["exported-item"]
        let bundleData = try ConfigImportExport.export(settings: original)

        var bundleObject = try XCTUnwrap(JSONSerialization.jsonObject(with: bundleData) as? [String: Any])
        var settingsObject = try XCTUnwrap(bundleObject["settings"] as? [String: Any])
        XCTAssertNotNil(settingsObject.removeValue(forKey: "inventory"))
        bundleObject["settings"] = settingsObject
        let olderBundleData = try JSONSerialization.data(withJSONObject: bundleObject)

        try ConfigImportExport.importData(olderBundleData, into: store)
        XCTAssertEqual(store.settings.disabledItemIDs, ["exported-item"])
        XCTAssertEqual(store.settings.inventory, InventorySettings.defaults)
    }
}
