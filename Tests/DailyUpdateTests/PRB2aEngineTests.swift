import XCTest
@testable import DailyUpdate

/// PR-B2a: the engine items deferred from Phase 1 (TIF-10 items 1 and 4).
final class PRB2aEngineTests: HermeticTestCase {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".dailyupdate-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeDirectory(_ url: URL, mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: - Item 4: PathTrust checks every hop

    /// Security round 6: link → hop in a `0777` directory → trusted target. Another user could
    /// re-point the hop between the check and the exec, so the chain is not trusted.
    func testPathTrustRejectsAHopInAWritableDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target/tool")
        try makeExecutable(at: target)
        let open = root.appendingPathComponent("open")
        try makeDirectory(open, mode: 0o777)
        try FileManager.default.createSymbolicLink(atPath: open.appendingPathComponent("hop").path, withDestinationPath: target.path)
        try makeDirectory(root.appendingPathComponent("link"))
        let link = root.appendingPathComponent("link/tool")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: open.appendingPathComponent("hop").path)

        XCTAssertFalse(PathTrust.isTrustedExecutable(link.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        XCTAssertTrue(PathTrust.isTrustedExecutable(link.path))
    }

    func testPathTrustRejectsARelativeHopInAWritableDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(at: root.appendingPathComponent("target/tool"))
        let open = root.appendingPathComponent("open")
        try makeDirectory(open, mode: 0o777)
        try FileManager.default.createSymbolicLink(atPath: open.appendingPathComponent("hop").path, withDestinationPath: "../target/tool")
        try makeDirectory(root.appendingPathComponent("link"))
        let link = root.appendingPathComponent("link/tool")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../open/hop")

        XCTAssertFalse(PathTrust.isTrustedExecutable(link.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        XCTAssertTrue(PathTrust.isTrustedExecutable(link.path))
    }

    /// A hop through a directory symlink that sits in a writable directory is not trusted either.
    func testPathTrustRejectsADirectorySymlinkHopInAWritableDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(at: root.appendingPathComponent("target/tool"))
        let open = root.appendingPathComponent("open")
        try makeDirectory(open, mode: 0o777)
        try FileManager.default.createSymbolicLink(atPath: open.appendingPathComponent("dir").path,
            withDestinationPath: root.appendingPathComponent("target").path)
        try makeDirectory(root.appendingPathComponent("link"))
        let link = root.appendingPathComponent("link/tool")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: open.appendingPathComponent("dir/tool").path)

        XCTAssertFalse(PathTrust.isTrustedExecutable(link.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        XCTAssertTrue(PathTrust.isTrustedExecutable(link.path))
    }

    func testPathTrustRejectsASymlinkLoop() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a")
        let second = root.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: first.path)
        XCTAssertFalse(PathTrust.isTrustedExecutable(first.path))
    }
}
