import XCTest
@testable import DailyUpdate

/// ADR-002 §7.1 / Amendment 1 RC1: everything under `Engine/Discovery/` must be read-only by
/// construction. This scans the actual source files (not just today's call graph), so a future
/// edit that reaches for `Process` or a write API fails the build the same way a missing test
/// would, rather than silently reintroducing the risk RC1-RC3 closed.
final class DiscoveryLintTests: XCTestCase {
    /// Anything under `Engine/Discovery/` that isn't one of the two named exemptions.
    private static let bannedEverywhere = [
        "Process(", "ShellRunner", "FileManager.default.createFile", "FileManager.default.removeItem",
        "FileManager.default.moveItem", "FileManager.default.copyItem", ".write(to:", "FileHandle(forWriting",
        "URLSession", "NSWorkspace",
    ]

    /// Only `ReadOnlyFileSystem.swift` may use these, and even there, never with a write flag.
    private static let fileSystemOnlyAPIs = ["FileManager", "FileHandle(forReadingAtPath:", "lstat(", "stat(", "readlink", "realpath"]
    private static let bannedWriteFlags = ["O_WRONLY", "O_RDWR", "O_CREAT"]

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
            let fileName = file.lastPathComponent

            for banned in Self.bannedEverywhere {
                XCTAssertFalse(
                    contents.contains(banned),
                    "\(fileName) must not reference \(banned) (ADR-002 §7.1)"
                )
            }

            if fileName != "ReadOnlyFileSystem.swift" {
                for api in Self.fileSystemOnlyAPIs {
                    XCTAssertFalse(
                        contents.contains(api),
                        "\(fileName) must not use \(api) directly; go through ReadOnlyFileSystem"
                    )
                }
            } else {
                for flag in Self.bannedWriteFlags {
                    XCTAssertFalse(contents.contains(flag), "ReadOnlyFileSystem.swift must not use \(flag)")
                }
            }

            if fileName != "ReadOnlyQueries.swift" {
                XCTAssertFalse(
                    contents.contains("BoundedProcessRunner"),
                    "\(fileName) must not reference BoundedProcessRunner; only ReadOnlyQueries.swift may (F10)"
                )
            }
        }
    }

    func testDiscoveryDirectoryIsNotEmpty() {
        // A guard against the lint silently checking zero files if the path ever moves.
        XCTAssertGreaterThan(discoverySourceFiles.count, 0)
    }
}
