import XCTest
@testable import DailyUpdate

/// ADR-002 §2 "pipx" / §9 P2-3 task 3: `pipx_metadata.json`, built from pipx's documented shape
/// since pipx isn't installed on this Mac (§2 "documented ⚠️").
final class PipxEnumeratorTests: HermeticTestCase {
    private func makeBlackVenv(in fixture: FixtureFileSystem) {
        fixture.makeFile(at: "pipx/venvs/black/pipx_metadata.json", contents: """
        {
          "main_package": {
            "package": "black",
            "package_or_url": "black",
            "apps": ["black", "blackd"],
            "package_version": "23.3.0"
          },
          "python_version": "Python 3.11.4",
          "pipx_metadata_version": "0.5"
        }
        """)
        let blackScript = fixture.makeFile(at: "pipx/venvs/black/bin/black", contents: "#!/bin/sh\n")
        fixture.chmod(blackScript, 0o755)
        fixture.makeSymlink(at: "bin/black", absoluteTarget: blackScript)
    }

    private func context(fixture: FixtureFileSystem, home: String, binDirectory: String, active: Bool = true) -> DiscoveryContext {
        DiscoveryContext(
            fileSystem: fixture.fileSystem,
            environmentSnapshot: ["PIPX_HOME": home, "PIPX_BIN_DIR": binDirectory],
            loginPath: active ? .known([binDirectory]) : .known(["/other/bin"])
        )
    }

    func testEnumeratesAPipxVenvFromMetadata() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("pipx")
        let binDirectory = fixture.path("bin")
        makeBlackVenv(in: fixture)

        let result = await PipxEnumerator().enumerate(context(fixture: fixture, home: home, binDirectory: binDirectory))

        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.packageID, "black")
        XCTAssertEqual(record.displayName, "black")
        XCTAssertEqual(record.versionRaw, "23.3.0")
        XCTAssertEqual(record.owner, .pipx(package: "black"))
        XCTAssertEqual(record.executables.count, 1)
        XCTAssertTrue(record.executables[0].hasSuffix("/venvs/black/bin/black"))
        XCTAssertEqual(result.roots.first?.activity, .active)
    }

    func testMissingRootsAreCompleteWithNoRecords() async {
        let fixture = FixtureFileSystem()
        let result = await PipxEnumerator().enumerate(context(fixture: fixture, home: fixture.path("does-not-exist"), binDirectory: fixture.path("bin")))
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testMalformedMetadataIsPartialWithMalformedIssue() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("pipx")
        fixture.makeFile(at: "pipx/venvs/broken/pipx_metadata.json", contents: "{ \"not\": \"the expected shape\" }")

        let result = await PipxEnumerator().enumerate(context(fixture: fixture, home: home, binDirectory: fixture.path("bin")))
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertTrue(issues.contains { $0.kind == .malformed })
        XCTAssertEqual(result.records.count, 0)
    }

    func testResolveRereadsOneVenv() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("pipx")
        let binDirectory = fixture.path("bin")
        makeBlackVenv(in: fixture)
        let ctx = context(fixture: fixture, home: home, binDirectory: binDirectory)

        let identity = InventoryIdentity(ecosystem: .pipx, packageID: "black", rootPath: "\(home)/venvs", packageDirectory: "\(home)/venvs/black")
        let resolved = await PipxEnumerator().resolve(identity, ctx)
        XCTAssertEqual(resolved?.versionRaw, "23.3.0")
    }
}
