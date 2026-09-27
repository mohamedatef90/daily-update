import XCTest
@testable import DailyUpdate

/// Builds a real directory tree under a fresh temp folder for each fixture, so discovery tests
/// exercise `LiveFileSystem` against the actual POSIX object each fixture claims to be (a real
/// symlink, a real hard link, a real FIFO, a real socket) rather than a simulation of one. §10
/// calls this `FixtureFileSystem`; it is a test-only builder, never shipped code, so it may use the
/// full (writing) `FileManager` API to set up each tree.
final class FixtureFileSystem {
    let root: URL
    let fileSystem: ReadOnlyFileSystem
    private var socketPaths: [String] = []

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoveryFixture-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileSystem = LiveFileSystem()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        for socketPath in socketPaths {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    @discardableResult
    func makeDirectory(_ relative: String) -> String {
        let full = path(relative)
        try! FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func makeFile(at relative: String, contents: String) -> String {
        let full = path(relative)
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try! contents.data(using: .utf8)!.write(to: URL(fileURLWithPath: full))
        return full
    }

    @discardableResult
    func makeSymlink(at relative: String, relativeTarget: String) -> String {
        let full = path(relative)
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try! FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: relativeTarget)
        return full
    }

    @discardableResult
    func makeSymlink(at relative: String, absoluteTarget: String) -> String {
        let full = path(relative)
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try! FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: absoluteTarget)
        return full
    }

    func makeSymlinkLoop(at first: String, pointingTo second: String) {
        let firstPath = path(first)
        let secondPath = path(second)
        try! FileManager.default.createSymbolicLink(atPath: firstPath, withDestinationPath: secondPath)
        try! FileManager.default.createSymbolicLink(atPath: secondPath, withDestinationPath: firstPath)
    }

    @discardableResult
    func makeHardLink(at relative: String, to original: String) -> String {
        let full = path(relative)
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try! FileManager.default.linkItem(atPath: original, toPath: full)
        return full
    }

    @discardableResult
    func makeFIFO(at relative: String) -> String {
        let full = path(relative)
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let result = full.withCString { mkfifo($0, 0o600) }
        precondition(result == 0, "mkfifo failed for \(full)")
        return full
    }

    /// `sockaddr_un.sun_path` is 104 bytes, far shorter than a fixture path under the per-process
    /// temp directory, so the real socket file is created under `/tmp` directly and linked into
    /// the fixture tree at the requested (readable) location.
    @discardableResult
    func makeSocket(at relative: String) throws -> String {
        let shortPath = "/tmp/du-fixture-\(UUID().uuidString.prefix(12))"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed")
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: 104) { buffer in
                shortPath.withCString { strncpy(buffer, $0, 103) }
            }
        }
        let boundResult = withUnsafePointer(to: &address) { rawAddress -> Int32 in
            rawAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(boundResult == 0, "bind() failed for \(shortPath)")
        socketPaths.append(shortPath)
        return makeSymlink(at: relative, absoluteTarget: shortPath)
    }

    func chmod(_ path: String, _ mode: Int16) {
        try! FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}
