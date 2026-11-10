import XCTest
@testable import DailyUpdate

/// ADR-002 §2 "pip (user)" / §9 P2-3 task 4: a captured pip user site (this Mac has one dist,
/// `pillow`, with a `REQUESTED` marker and no console scripts) plus a synthetic console-script
/// case built from `RECORD`'s documented shape.
final class PipUserEnumeratorTests: HermeticTestCase {
    private func context(fixture: FixtureFileSystem, home: String, active: Bool = true) -> DiscoveryContext {
        let layout = EcosystemLayout.fixture(home: home)
        return DiscoveryContext(fileSystem: fixture.fileSystem, loginPath: active ? .known(["\(home)/Library/Python/3.12/bin"]) : .known(["/other/bin"]), layout: layout)
    }

    func testEnumeratesARequestedDistWithNoConsoleScripts() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("home")
        fixture.makeFile(
            at: "home/Library/Python/3.12/lib/python/site-packages/pillow-12.3.0.dist-info/METADATA",
            contents: "Metadata-Version: 2.4\nName: pillow\nVersion: 12.3.0\n"
        )
        fixture.makeFile(at: "home/Library/Python/3.12/lib/python/site-packages/pillow-12.3.0.dist-info/REQUESTED", contents: "")
        fixture.makeFile(at: "home/Library/Python/3.12/lib/python/site-packages/pillow-12.3.0.dist-info/INSTALLER", contents: "pip\n")

        let result = await PipUserEnumerator().enumerate(context(fixture: fixture, home: home))

        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.packageID, "pillow")
        XCTAssertEqual(record.versionRaw, "12.3.0")
        XCTAssertEqual(record.owner, .pipUser(site: "\(home)/Library/Python/3.12/lib/python/site-packages", distribution: "pillow"))
        XCTAssertEqual(record.executables, [])
        XCTAssertTrue(record.flags.contains(.onRequest))
        XCTAssertTrue(record.evidence.contains { $0.kind == "INSTALLER" })
    }

    func testADependencyWithNoRequestedMarkerGetsNoRow() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("home")
        fixture.makeFile(
            at: "home/Library/Python/3.12/lib/python/site-packages/six-1.16.0.dist-info/METADATA",
            contents: "Metadata-Version: 2.4\nName: six\nVersion: 1.16.0\n"
        )
        // No REQUESTED file: six was pulled in as someone else's dependency.

        let result = await PipUserEnumerator().enumerate(context(fixture: fixture, home: home))
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testConsoleScriptFromRecordIsFoundByContainment() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("home")
        let distInfo = "home/Library/Python/3.12/lib/python/site-packages/cowsay-6.1.dist-info"
        fixture.makeFile(at: "\(distInfo)/METADATA", contents: "Metadata-Version: 2.4\nName: cowsay\nVersion: 6.1\n")
        fixture.makeFile(at: "\(distInfo)/REQUESTED", contents: "")
        fixture.makeFile(at: "\(distInfo)/RECORD", contents: "../../../bin/cowsay,sha256=abc,123\ncowsay/__init__.py,sha256=def,456\n")
        let script = fixture.makeFile(at: "home/Library/Python/3.12/bin/cowsay", contents: "#!/bin/sh\n")
        fixture.chmod(script, 0o755)

        let result = await PipUserEnumerator().enumerate(context(fixture: fixture, home: home))
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.executables, [fixture.fileSystem.realpath(script) ?? script])
        XCTAssertEqual(result.roots.first?.activity, .active)
    }

    func testMissingRootsAreCompleteWithNoRecords() async {
        let fixture = FixtureFileSystem()
        let result = await PipUserEnumerator().enumerate(context(fixture: fixture, home: fixture.path("home")))
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testResolveRereadsOneDist() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("home")
        fixture.makeFile(
            at: "home/Library/Python/3.12/lib/python/site-packages/pillow-12.3.0.dist-info/METADATA",
            contents: "Metadata-Version: 2.4\nName: pillow\nVersion: 12.3.0\n"
        )
        fixture.makeFile(at: "home/Library/Python/3.12/lib/python/site-packages/pillow-12.3.0.dist-info/REQUESTED", contents: "")
        let ctx = context(fixture: fixture, home: home)

        let identity = InventoryIdentity(
            ecosystem: .pip, packageID: "pillow",
            rootPath: "\(home)/Library/Python/3.12/lib/python/site-packages",
            packageDirectory: "\(home)/Library/Python/3.12/lib/python/site-packages/pillow-12.3.0.dist-info"
        )
        let resolved = await PipUserEnumerator().resolve(identity, ctx)
        XCTAssertEqual(resolved?.versionRaw, "12.3.0")
    }
}
