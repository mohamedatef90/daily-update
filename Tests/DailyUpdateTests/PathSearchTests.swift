import XCTest
@testable import DailyUpdate

final class PathSearchTests: HermeticTestCase {
    func testFindsExecutableCandidatesInPathOrder() {
        let fixture = FixtureFileSystem()
        let first = fixture.makeFile(at: "a/gh", contents: "#!/bin/sh\n")
        fixture.chmod(first, 0o755)
        let second = fixture.makeFile(at: "b/gh", contents: "#!/bin/sh\n")
        fixture.chmod(second, 0o755)
        _ = fixture.makeDirectory("c")

        let results = PathSearch.candidates(
            for: "gh",
            pathEntries: [fixture.path("a"), fixture.path("b"), fixture.path("c")],
            fileSystem: fixture.fileSystem
        )
        XCTAssertEqual(results, [first, second])
    }

    func testSkipsNonExecutableAndMissingEntries() {
        let fixture = FixtureFileSystem()
        let notExecutable = fixture.makeFile(at: "a/tool", contents: "data")
        fixture.chmod(notExecutable, 0o644)
        let executable = fixture.makeFile(at: "b/tool", contents: "#!/bin/sh\n")
        fixture.chmod(executable, 0o755)

        let results = PathSearch.candidates(
            for: "tool",
            pathEntries: [fixture.path("a"), fixture.path("missing"), fixture.path("b")],
            fileSystem: fixture.fileSystem
        )
        XCTAssertEqual(results, [executable])
    }

    func testFollowsSymlinkToAnExecutableTarget() {
        let fixture = FixtureFileSystem()
        let target = fixture.makeFile(at: "real/gh", contents: "#!/bin/sh\n")
        fixture.chmod(target, 0o755)
        let link = fixture.makeSymlink(at: "bin/gh", absoluteTarget: target)

        let results = PathSearch.candidates(for: "gh", pathEntries: [fixture.path("bin")], fileSystem: fixture.fileSystem)
        XCTAssertEqual(results, [link])
    }

    func testDeduplicatesRepeatedPathEntries() {
        let fixture = FixtureFileSystem()
        let executable = fixture.makeFile(at: "a/gh", contents: "#!/bin/sh\n")
        fixture.chmod(executable, 0o755)

        let results = PathSearch.candidates(
            for: "gh",
            pathEntries: [fixture.path("a"), fixture.path("a")],
            fileSystem: fixture.fileSystem
        )
        XCTAssertEqual(results, [executable])
    }

    /// Cross-checks `PathSearch` against the real `whence -ap` on the same fixture tree — the
    /// P2-1 task list's own acceptance bar ("results must equal `whence -ap` on the fixture").
    func testMatchesRealWhenceApOnTheSameTree() async throws {
        let fixture = FixtureFileSystem()
        let first = fixture.makeFile(at: "a/mytool", contents: "#!/bin/sh\n")
        fixture.chmod(first, 0o755)
        let second = fixture.makeFile(at: "b/mytool", contents: "#!/bin/sh\n")
        fixture.chmod(second, 0o755)
        _ = fixture.makeFile(at: "c/mytool", contents: "not executable")

        let pathEntries = [fixture.path("a"), fixture.path("b"), fixture.path("c")]
        let ours = PathSearch.candidates(for: "mytool", pathEntries: pathEntries, fileSystem: fixture.fileSystem)

        let result = await ShellRunner.runProcess(
            executablePath: "/bin/zsh",
            arguments: ["-c", "whence -ap -- mytool"],
            environment: ["PATH": pathEntries.joined(separator: ":")]
        )
        let whenceResults = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(ours, whenceResults)
    }

    /// D9: `cargo` and `rustup` are hard links of each other. Invoked as `cargo`, the proxy gets a
    /// distinct key from `rustup`'s own row, even though they're the same file on disk.
    func testRustupProxyGetsADistinctKeyFromRustupItself() {
        let fixture = FixtureFileSystem()
        let rustup = fixture.makeFile(at: "cargo-bin/rustup", contents: "#!/bin/sh\n")
        fixture.chmod(rustup, 0o755)
        let cargo = fixture.makeHardLink(at: "cargo-bin/cargo", to: rustup)

        let rustupFileID = fixture.fileSystem.lstat(rustup)!.fileID
        let cargoFileID = fixture.fileSystem.lstat(cargo)!.fileID
        XCTAssertEqual(rustupFileID.device, cargoFileID.device)
        XCTAssertEqual(rustupFileID.inode, cargoFileID.inode)

        let cargoKey = FileID.rustupProxyAware(candidate: cargoFileID, invokedName: "cargo", rustupFileID: rustupFileID)
        let rustupKey = FileID.rustupProxyAware(candidate: rustupFileID, invokedName: "rustup", rustupFileID: rustupFileID)
        XCTAssertNotEqual(cargoKey, rustupKey)
        XCTAssertEqual(cargoKey.dispatchName, "cargo")
        XCTAssertNil(rustupKey.dispatchName)
    }

    func testNonRustupHardLinksAreUnaffected() {
        let fixture = FixtureFileSystem()
        let original = fixture.makeFile(at: "a/tool", contents: "#!/bin/sh\n")
        let linked = fixture.makeHardLink(at: "b/tool", to: original)
        let originalFileID = fixture.fileSystem.lstat(original)!.fileID
        let linkedFileID = fixture.fileSystem.lstat(linked)!.fileID
        // No rustup FileID in play, so the key is untouched.
        XCTAssertEqual(FileID.rustupProxyAware(candidate: linkedFileID, invokedName: "tool", rustupFileID: nil), originalFileID)
    }
}
