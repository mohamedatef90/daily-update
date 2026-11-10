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

    /// P2-2 (Security FU1): a root that is a symlink into a folder under a world-writable parent.
    /// Every entry on the path as written is fine, and `stat` of the link itself reports the
    /// (trusted) target — only walking the canonical path's ancestors catches it.
    func testSymlinkedRootIntoAnUntrustedParentIsUntrusted() {
        let fixture = FixtureFileSystem()
        let target = fixture.makeDirectory("open/target")
        fixture.chmod(fixture.path("open"), 0o777)
        fixture.chmod(target, 0o755)
        let link = fixture.makeSymlink(at: "safe/root", absoluteTarget: target)
        fixture.chmod(fixture.path("safe"), 0o755)
        XCTAssertFalse(PathTrust.isTrustedDirectory(link))
    }

    func testSymlinkedRootIntoATrustedFolderIsTrusted() {
        let fixture = FixtureFileSystem()
        let target = fixture.makeDirectory("real/target")
        let link = fixture.makeSymlink(at: "safe/root", absoluteTarget: target)
        XCTAssertTrue(PathTrust.isTrustedDirectory(link))
    }

    func testMissingDirectoryIsUntrusted() {
        let fixture = FixtureFileSystem()
        XCTAssertFalse(PathTrust.isTrustedDirectory(fixture.path("missing")))
    }
}
