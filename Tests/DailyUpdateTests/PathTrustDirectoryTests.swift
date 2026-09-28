import XCTest
@testable import DailyUpdate

/// Amendment 1 F3: `isTrustedDirectory` — D16 (world-writable is rejected) and D23 (group-writable
/// is trusted, unlike an executable file).
final class PathTrustDirectoryTests: HermeticTestCase {
    func testOwnedNonWorldWritableDirectoryIsTrusted() {
        let fixture = FixtureFileSystem()
        let dir = fixture.makeDirectory("root")
        fixture.chmod(dir, 0o755)
        XCTAssertTrue(PathTrust.isTrustedDirectory(dir))
    }

    /// D23: `/opt/homebrew/Cellar`-style `drwxrwxr-x`, owned by the current user, is trusted even
    /// though it's group-writable — only world-writable is rejected for a root.
    func testGroupWritableDirectoryIsStillTrusted() {
        let fixture = FixtureFileSystem()
        let dir = fixture.makeDirectory("cellar")
        fixture.chmod(dir, 0o775)
        XCTAssertTrue(PathTrust.isTrustedDirectory(dir))
    }

    /// D16: a world-writable root is untrusted.
    func testWorldWritableDirectoryIsUntrusted() {
        let fixture = FixtureFileSystem()
        let dir = fixture.makeDirectory("open")
        fixture.chmod(dir, 0o777)
        XCTAssertFalse(PathTrust.isTrustedDirectory(dir))
    }

    func testWorldWritableAncestorMakesADescendantUntrusted() {
        let fixture = FixtureFileSystem()
        let child = fixture.makeDirectory("open/child")
        fixture.chmod(fixture.path("open"), 0o777)
        fixture.chmod(child, 0o755)
        XCTAssertFalse(PathTrust.isTrustedDirectory(child))
    }

    func testMissingDirectoryIsUntrusted() {
        let fixture = FixtureFileSystem()
        XCTAssertFalse(PathTrust.isTrustedDirectory(fixture.path("missing")))
    }
}
