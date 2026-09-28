import XCTest
@testable import DailyUpdate

/// ADR-002 §1 D2 / P2-1 scope: `inventory` is built fresh by `RowBuilder` every run and must
/// never be loaded from settings or an import.
final class DiscoveryImportRejectionTests: HermeticTestCase {
    func testImportRejectsACustomItemCarryingAnInventoryIdentity() throws {
        let store = UserSettingsStore()
        var settings = UserSettings.defaults
        settings.customItems = [DetectorConfig(
            id: "smuggled", name: "Smuggled", category: .cli, description: nil, source: .user,
            inventory: InventoryIdentity(ecosystem: .npm, packageID: "evil", rootPath: "/x", packageDirectory: "/x/evil"),
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil,
            updateCommand: "", workingDirectory: nil
        )]
        let data = try ConfigImportExport.export(settings: settings)

        XCTAssertThrowsError(try ConfigImportExport.importData(data, into: store)) { error in
            guard case ConfigImportExport.ImportError.typedFieldsNotAllowed(let itemID) = error else {
                return XCTFail("expected typedFieldsNotAllowed, got \(error)")
            }
            XCTAssertEqual(itemID, "smuggled")
        }
    }
}
