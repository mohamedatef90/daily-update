import XCTest
@testable import DailyUpdate

/// RC3 against the real filesystem: `LiveFileSystem` must open the canonical path only, refuse
/// anything that isn't a regular file, and never block reading a FIFO. `FixtureFileSystem` builds
/// each fixture tree on disk (real symlinks, real hard links, a real FIFO) so these are the actual
/// POSIX edge cases the coordinator has to survive, not a simulation of them.
final class ReadOnlyFileSystemTests: HermeticTestCase {
    func testReadsAnOrdinaryFile() throws {
        let fixture = FixtureFileSystem()
        let path = fixture.makeFile(at: "a.txt", contents: "hello")
        let data = try fixture.fileSystem.readFile(path, maxBytes: 1024)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testFollowsRelativeAndAbsoluteSymlinks() throws {
        let fixture = FixtureFileSystem()
        let target = fixture.makeFile(at: "real/version.json", contents: "1.2.3")
        let relative = fixture.makeSymlink(at: "link-relative", relativeTarget: "real/version.json")
        let absolute = fixture.makeSymlink(at: "link-absolute", absoluteTarget: target)
        XCTAssertEqual(try String(data: fixture.fileSystem.readFile(relative, maxBytes: 1024), encoding: .utf8), "1.2.3")
        XCTAssertEqual(try String(data: fixture.fileSystem.readFile(absolute, maxBytes: 1024), encoding: .utf8), "1.2.3")
    }

    func testSymlinkLoopFailsWithoutHanging() {
        let fixture = FixtureFileSystem()
        fixture.makeSymlinkLoop(at: "loop-a", pointingTo: "loop-b")
        XCTAssertThrowsError(try fixture.fileSystem.readFile(fixture.path("loop-a"), maxBytes: 1024)) { error in
            XCTAssertEqual(error as? ReadOnlyFileSystemError, .unreadable(fixture.path("loop-a")))
        }
    }

    func testHardLinksShareOneFileID() throws {
        let fixture = FixtureFileSystem()
        let original = fixture.makeFile(at: "cargo", contents: "#!/bin/sh")
        let linked = fixture.makeHardLink(at: "rustup", to: original)
        let a = fixture.fileSystem.lstat(original)!
        let b = fixture.fileSystem.lstat(linked)!
        XCTAssertEqual(a.fileID, b.fileID)
    }

    /// D22: a file over the byte cap gives `tooLarge`, checked from `fstat` before any read.
    func testOversizeFileIsRejectedBeforeReading() throws {
        let fixture = FixtureFileSystem()
        let path = fixture.makeFile(at: "big.json", contents: String(repeating: "x", count: 2048))
        XCTAssertThrowsError(try fixture.fileSystem.readFile(path, maxBytes: 1024)) { error in
            XCTAssertEqual(error as? ReadOnlyFileSystemError, .tooLarge(path))
        }
    }

    /// RC3: a file that grows past the cap while it's being read is still caught, not just a file
    /// that starts too big.
    func testFileThatGrowsDuringReadIsCaught() throws {
        let fixture = FixtureFileSystem()
        let path = fixture.makeFile(at: "growing.json", contents: String(repeating: "a", count: 10))
        let handle = FileHandle(forWritingAtPath: path)!
        defer { handle.closeFile() }
        // The reader sees an fstat size under the cap, then more bytes land before EOF.
        handle.seekToEndOfFile()
        handle.write(String(repeating: "b", count: 2048).data(using: .utf8)!)
        XCTAssertThrowsError(try fixture.fileSystem.readFile(path, maxBytes: 1024)) { error in
            XCTAssertEqual(error as? ReadOnlyFileSystemError, .tooLarge(path))
        }
    }

    /// RC3 / D21: a FIFO planted as a manifest must fail instantly (`O_NONBLOCK`), not hang
    /// waiting for a writer that will never come.
    func testFIFOIsRejectedAsNotRegularFileWithoutBlocking() throws {
        let fixture = FixtureFileSystem()
        let path = fixture.makeFIFO(at: "lib/node_modules/x/package.json")
        let start = Date()
        XCTAssertThrowsError(try fixture.fileSystem.readFile(path, maxBytes: 1024)) { error in
            XCTAssertEqual(error as? ReadOnlyFileSystemError, .notRegularFile(path))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    /// `open(2)` on a UNIX-domain socket special file fails outright (`ENXIO`) rather than
    /// succeeding and letting `fstat` reject it, so this reaches `unreadable`, not
    /// `notRegularFile` — but either way, it's never read and never blocks.
    func testSocketIsRejectedWithoutBlocking() throws {
        let fixture = FixtureFileSystem()
        let path = try fixture.makeSocket(at: "sock")
        XCTAssertThrowsError(try fixture.fileSystem.readFile(path, maxBytes: 1024)) { error in
            XCTAssertEqual(error as? ReadOnlyFileSystemError, .unreadable(path))
        }
    }

    func testMissingFileIsUnreadable() {
        let fixture = FixtureFileSystem()
        XCTAssertThrowsError(try fixture.fileSystem.readFile(fixture.path("missing"), maxBytes: 1024)) { error in
            XCTAssertEqual(error as? ReadOnlyFileSystemError, .unreadable(fixture.path("missing")))
        }
    }

    func testDirectoryEntryCap() throws {
        let fixture = FixtureFileSystem()
        for index in 0..<10 { _ = fixture.makeFile(at: "many/\(index).txt", contents: "x") }
        let live = LiveFileSystem(maxDirectoryEntries: 3)
        let entries = try live.contentsOfDirectory(fixture.path("many"))
        XCTAssertEqual(entries.count, 3)
    }

    func testWorldWritableDetection() {
        let fixture = FixtureFileSystem()
        let path = fixture.makeFile(at: "world.txt", contents: "x")
        fixture.chmod(path, 0o777)
        let info = fixture.fileSystem.lstat(path)!
        XCTAssertTrue(info.isWorldWritable)
        fixture.chmod(path, 0o775)
        XCTAssertFalse(fixture.fileSystem.lstat(path)!.isWorldWritable)
        XCTAssertTrue(fixture.fileSystem.lstat(path)!.isGroupWritable)
    }
}
