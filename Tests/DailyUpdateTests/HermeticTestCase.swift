import XCTest
@testable import DailyUpdate

/// One App Support directory for the whole test bundle, in a temp dir. Every test class
/// inherits from this, so nothing a test writes (`widget-state.json` included) reaches the
/// real `~/Library/Application Support/DailyUpdate`. Per-test fixtures restore `root`, never `nil`.
class HermeticTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestAppSupport.install()
    }
}

enum TestAppSupport {
    static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// `ConfigLoader`'s DEBUG default under XCTest, used by a test that clears the override.
    static var xctestDefault: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyUpdate-xctest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    static var temporaryDirectories: [URL] { [root, xctestDefault] }

    private static let cleanup = TemporaryDirectoryCleanup()
    static var isCleanupRegistered: Bool { cleanup.isRegistered }

    static func install() {
        ConfigLoader.setAppSupportDirectoryForTesting(root)
        cleanup.register()
    }

    static func remove(_ directories: [URL]) {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Removes the bundle's temp App Support directories once every test has run.
private final class TemporaryDirectoryCleanup: NSObject, XCTestObservation {
    private(set) var isRegistered = false

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        TestAppSupport.remove(TestAppSupport.temporaryDirectories)
    }
}

final class TestAppSupportTests: HermeticTestCase {
    private var realAppSupport: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DailyUpdate", isDirectory: true).path
    }

    func testTheBundleUsesItsOwnAppSupport() {
        XCTAssertEqual(ConfigLoader.appSupportDirectory.standardizedFileURL, TestAppSupport.root.standardizedFileURL)
        XCTAssertNotEqual(ConfigLoader.appSupportDirectory.path, realAppSupport)
    }

    /// Even without an override, a DEBUG build under XCTest never resolves the real directory.
    func testTheDefaultDirectoryIsNotTheRealOneUnderXCTest() {
        ConfigLoader.setAppSupportDirectoryForTesting(nil)
        defer { TestAppSupport.install() }
        XCTAssertTrue(ConfigLoader.isRunningUnderXCTest)
        XCTAssertNotEqual(ConfigLoader.appSupportDirectory.path, realAppSupport)
        XCTAssertTrue(ConfigLoader.appSupportDirectory.lastPathComponent.hasPrefix("DailyUpdate-xctest-"))
        XCTAssertEqual(ConfigLoader.appSupportDirectory.standardizedFileURL, TestAppSupport.xctestDefault.standardizedFileURL)
    }

    /// Both temp directories are removed when the bundle finishes, so runs leave nothing behind.
    func testTheBundleRemovesItsTemporaryDirectoriesWhenItFinishes() throws {
        XCTAssertTrue(TestAppSupport.isCleanupRegistered)
        XCTAssertEqual(TestAppSupport.temporaryDirectories.map(\.standardizedFileURL),
            [TestAppSupport.root.standardizedFileURL, TestAppSupport.xctestDefault.standardizedFileURL])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyUpdateTests-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("settings.json"))
        TestAppSupport.remove([directory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
