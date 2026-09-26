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

    static func install() { ConfigLoader.setAppSupportDirectoryForTesting(root) }
}
