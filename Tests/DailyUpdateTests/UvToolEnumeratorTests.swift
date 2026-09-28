import XCTest
@testable import DailyUpdate

/// ADR-002 §2 "uv tool" / §9 P2-3 task 1: a captured `browser-use` uv tool folder (receipt plus
/// dist-info), redacted.
final class UvToolEnumeratorTests: HermeticTestCase {
    private func makeBrowserUseTool(in fixture: FixtureFileSystem, root: String, binDirectory: String) {
        fixture.makeFile(
            at: "tools/browser-use/lib/python3.12/site-packages/browser_use-1.2.3.dist-info/METADATA",
            contents: "Metadata-Version: 2.1\nName: browser-use\nVersion: 1.2.3\n"
        )
        fixture.makeFile(at: "tools/browser-use/uv-receipt.toml", contents: "[tool]\nrequirements = [{ name = \"browser-use\" }]\n")
        let script = fixture.makeFile(at: "tools/browser-use/bin/browser-use", contents: "#!/bin/sh\necho browser-use\n")
        fixture.chmod(script, 0o755)
        fixture.makeSymlink(at: "bin/browser-use", absoluteTarget: script)
    }

    private func context(fixture: FixtureFileSystem, root: String, binDirectory: String, active: Bool = true) -> DiscoveryContext {
        DiscoveryContext(
            fileSystem: fixture.fileSystem,
            environmentSnapshot: ["UV_TOOL_DIR": root, "UV_TOOL_BIN_DIR": binDirectory],
            loginPath: active ? .known([binDirectory]) : .known(["/other/bin"])
        )
    }

    func testEnumeratesABrowserUseToolFromDistInfo() async throws {
        let fixture = FixtureFileSystem()
        let root = fixture.path("tools")
        let binDirectory = fixture.path("bin")
        makeBrowserUseTool(in: fixture, root: root, binDirectory: binDirectory)

        let result = await UvToolEnumerator().enumerate(context(fixture: fixture, root: root, binDirectory: binDirectory))

        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 1)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.packageID, "browser-use")
        XCTAssertEqual(record.versionRaw, "1.2.3")
        XCTAssertEqual(record.owner, .uvTool(name: "browser-use"))
        XCTAssertEqual(record.executables, ["\(binDirectory)/browser-use"])
        XCTAssertTrue(record.evidence.contains { $0.kind == "uv-receipt.toml" })
        XCTAssertEqual(result.roots.first?.activity, .active)
    }

    func testMissingRootIsCompleteWithNoRecords() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("does-not-exist")
        let result = await UvToolEnumerator().enumerate(context(fixture: fixture, root: root, binDirectory: fixture.path("bin")))
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testFallsBackToDistInfoFolderVersionWhenMetadataHasNoVersionLine() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("tools")
        let binDirectory = fixture.path("bin")
        fixture.makeFile(
            at: "tools/browser-use/lib/python3.12/site-packages/browser_use-1.2.3.dist-info/METADATA",
            contents: "Metadata-Version: 2.1\nName: browser-use\n"
        )
        let script = fixture.makeFile(at: "tools/browser-use/bin/browser-use", contents: "#!/bin/sh\n")
        fixture.chmod(script, 0o755)

        let result = await UvToolEnumerator().enumerate(context(fixture: fixture, root: root, binDirectory: binDirectory))
        XCTAssertEqual(result.records.first?.versionRaw, "1.2.3")
    }

    func testUntrustedRootIsPartialWithUntrustedRootIssue() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("tools")
        fixture.makeDirectory("tools")
        fixture.chmod(root, 0o777)

        let result = await UvToolEnumerator().enumerate(context(fixture: fixture, root: root, binDirectory: fixture.path("bin")))
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertTrue(issues.contains { $0.kind == .untrustedRoot })
    }

    func testResolveRereadsOneTool() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("tools")
        let binDirectory = fixture.path("bin")
        makeBrowserUseTool(in: fixture, root: root, binDirectory: binDirectory)
        let ctx = context(fixture: fixture, root: root, binDirectory: binDirectory)

        let identity = InventoryIdentity(
            ecosystem: .uv, packageID: "browser-use", rootPath: root,
            packageDirectory: "\(root)/browser-use"
        )
        let resolved = await UvToolEnumerator().resolve(identity, ctx)
        XCTAssertEqual(resolved?.versionRaw, "1.2.3")
    }

    func testUnrelatedDistInfoInSitePackagesIsIgnored() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("tools")
        let binDirectory = fixture.path("bin")
        makeBrowserUseTool(in: fixture, root: root, binDirectory: binDirectory)
        // A dependency's dist-info sitting next to the tool's own — must not be picked instead.
        fixture.makeFile(
            at: "tools/browser-use/lib/python3.12/site-packages/click-8.1.7.dist-info/METADATA",
            contents: "Metadata-Version: 2.1\nName: click\nVersion: 8.1.7\n"
        )

        let result = await UvToolEnumerator().enumerate(context(fixture: fixture, root: root, binDirectory: binDirectory))
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.versionRaw, "1.2.3")
    }
}
