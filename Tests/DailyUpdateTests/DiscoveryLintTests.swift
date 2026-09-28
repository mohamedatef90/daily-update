import XCTest
@testable import DailyUpdate

/// ADR-002 §7.1 / Amendment 1 RC1: everything under `Engine/Discovery/` must be read-only by
/// construction. This scans the actual source files (not just today's call graph), so a future
/// edit that reaches for `Process` or a write API fails the build the same way a missing test
/// would, rather than silently reintroducing the risk RC1-RC3 closed.
final class DiscoveryLintTests: XCTestCase {
    /// Anything under `Engine/Discovery/` that isn't one of the two named exemptions.
    private static let bannedEverywhere = [
        "Process(", "Process.run", "ShellRunner", "FileManager.default.createFile", "FileManager.default.removeItem",
        "FileManager.default.moveItem", "FileManager.default.copyItem", ".write(to:", "FileHandle(forWriting",
        "FileHandle(forUpdating", "URLSession", "NSWorkspace", "posix_spawn",
    ]

    /// P2-2 (Security FU6, CR FU11): libc process and write calls. Only a bare call counts, so
    /// `ResolvedOwner.system(provider:)` or a method that merely ends in one of these names isn't a
    /// violation, while `system("…")` or `unlink(path)` is.
    private static let bannedBareCalls = [
        "system", "fork", "vfork", "popen", "execv", "execve", "execvp", "execl", "execlp", "execle",
        "mkdir", "rmdir", "unlink", "rename", "fopen", "symlink", "truncate", "chmod", "chown",
    ]

    /// Only `ReadOnlyFileSystem.swift` may use these directly. A call through the protocol
    /// (`someFileSystem.stat(...)`) is what every other file is supposed to do instead, so only a
    /// bare (undotted) call counts as a violation here.
    private static let fileSystemOnlyAPIs = ["FileManager", "FileHandle(forReadingAtPath:"]
    private static let fileSystemOnlyBarePOSIXCalls = ["lstat", "stat", "readlink", "realpath"]
    /// P2-2 (Security FU6): no file under Discovery may ask `open` for write access, not only
    /// `ReadOnlyFileSystem.swift`.
    private static let bannedWriteFlags = ["O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND"]

    private static func containsBareCall(_ name: String, in contents: String) -> Bool {
        contents.range(of: #"(?<![.\w])"# + name + #"\s*\("#, options: .regularExpression) != nil
    }

    /// Every rule above, applied to one file's text. Returns one message per violation.
    static func violations(in contents: String, fileName: String) -> [String] {
        var found: [String] = []
        for banned in bannedEverywhere where contents.contains(banned) {
            found.append("\(fileName) must not reference \(banned) (ADR-002 §7.1)")
        }
        for name in bannedBareCalls where containsBareCall(name, in: contents) {
            found.append("\(fileName) must not call \(name)(...) (ADR-002 §7.1)")
        }
        for flag in bannedWriteFlags where contents.contains(flag) {
            found.append("\(fileName) must not use \(flag)")
        }
        if fileName != "ReadOnlyFileSystem.swift" {
            for api in fileSystemOnlyAPIs where contents.contains(api) {
                found.append("\(fileName) must not use \(api) directly; go through ReadOnlyFileSystem")
            }
            for name in fileSystemOnlyBarePOSIXCalls where containsBareCall(name, in: contents) {
                found.append("\(fileName) must not call \(name)(...) directly; go through ReadOnlyFileSystem")
            }
        }
        if fileName != "ReadOnlyQueries.swift", contents.contains("BoundedProcessRunner") {
            found.append("\(fileName) must not reference BoundedProcessRunner; only ReadOnlyQueries.swift may (F10)")
        }
        return found
    }

    private var discoverySourceFiles: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/DailyUpdateTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/DailyUpdate/Engine/Discovery")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testDiscoveryFilesNeverReferenceWriteOrProcessAPIs() throws {
        for file in discoverySourceFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(Self.violations(in: contents, fileName: file.lastPathComponent), [])
        }
    }

    func testDiscoveryDirectoryIsNotEmpty() {
        // A guard against the lint silently checking zero files if the path ever moves.
        XCTAssertGreaterThan(discoverySourceFiles.count, 0)
    }

    /// The rules themselves: each banned shape is caught, and the look-alikes the enumerators
    /// legitimately use are not.
    func testLintCatchesEveryBannedShape() {
        let caught: [(String, String)] = [
            ("let p = Process()", "Process("),
            ("try Process.run(url, arguments: [])", "Process.run"),
            ("posix_spawn(&pid, path, nil, nil, argv, envp)", "posix_spawn"),
            ("popen(\"id\", \"r\")", "popen(...)"),
            ("system(\"id\")", "system(...)"),
            ("let pid = fork()", "fork(...)"),
            ("execv(path, argv)", "execv(...)"),
            ("mkdir(path, 0o700)", "mkdir(...)"),
            ("unlink(path)", "unlink(...)"),
            ("rename(a, b)", "rename(...)"),
            ("let f = fopen(path, \"r\")", "fopen(...)"),
            ("FileHandle(forUpdatingAtPath: p)", "FileHandle(forUpdating"),
            ("open(p, O_RDWR)", "O_RDWR"),
        ]
        for (source, expected) in caught {
            let found = Self.violations(in: source, fileName: "Example.swift")
            XCTAssertTrue(found.contains { $0.contains(expected) }, "\(source) should be caught as \(expected); got \(found)")
        }
        let allowed = [
            "return .system(provider: \"macOS\")",
            "case .system: break",
            "let x = fileSystem.stat(path)",
            "record.owner == .system(provider: p)",
            "hasPrefix(\"sandbox-exec: execvp\")",
        ]
        for source in allowed {
            XCTAssertEqual(Self.violations(in: source, fileName: "Example.swift"), [], source)
        }
    }
}
