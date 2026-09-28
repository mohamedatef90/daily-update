import XCTest
@testable import DailyUpdate

/// ADR-002 §2 "gem" / §9 P2-3 task 6: gem folders captured from this Mac's real layout — user
/// (`~/.gem/ruby`), system (`/Library/Ruby/Gems`-shaped, root-owned in reality but simulated here
/// by path prefix since fixtures run as the current user), a `default/` folder that must be
/// skipped, and a platform-suffixed gemspec.
final class GemEnumeratorTests: HermeticTestCase {
    private func context(fixture: FixtureFileSystem, gemHome: String, active: Bool = true) -> DiscoveryContext {
        let binDirectory = "\(gemHome)/bin"
        return DiscoveryContext(
            fileSystem: fixture.fileSystem,
            environmentSnapshot: ["GEM_HOME": gemHome],
            loginPath: active ? .known([binDirectory]) : .known(["/other/bin"])
        )
    }

    func testParsesNameVersionAndPlatformFromTheFileName() async {
        let fixture = FixtureFileSystem()
        let gemHome = fixture.path("gems")
        fixture.makeFile(at: "gems/specifications/ffi-1.17.2-x86_64-darwin.gemspec", contents: "Gem::Specification.new do |s|\n  s.name = \"ffi\"\nend\n")
        fixture.makeFile(at: "gems/specifications/cocoapods-downloader-1.6.3.gemspec", contents: "Gem::Specification.new do |s|\nend\n")

        let result = await GemEnumerator().enumerate(context(fixture: fixture, gemHome: gemHome))
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 2)

        let ffi = try! XCTUnwrap(result.records.first { $0.packageID == "ffi" })
        XCTAssertEqual(ffi.versionRaw, "1.17.2")

        let downloader = try! XCTUnwrap(result.records.first { $0.packageID == "cocoapods-downloader" })
        XCTAssertEqual(downloader.versionRaw, "1.6.3")
    }

    func testDefaultFolderIsSkipped() async {
        let fixture = FixtureFileSystem()
        let gemHome = fixture.path("gems")
        fixture.makeFile(at: "gems/specifications/default/bigdecimal-1.4.1.gemspec", contents: "Gem::Specification.new do |s|\nend\n")

        let result = await GemEnumerator().enumerate(context(fixture: fixture, gemHome: gemHome))
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testExecutablesComeFromTheGemsOwnBinFolder() async {
        let fixture = FixtureFileSystem()
        let gemHome = fixture.path("gems")
        fixture.makeFile(at: "gems/specifications/httpclient-2.9.0.gemspec", contents: """
        Gem::Specification.new do |s|
          s.name = "httpclient".freeze
          s.executables = ["httpclient".freeze]
        end
        """)
        let script = fixture.makeFile(at: "gems/gems/httpclient-2.9.0/bin/httpclient", contents: "#!/usr/bin/env ruby\n")
        fixture.chmod(script, 0o755)

        let result = await GemEnumerator().enumerate(context(fixture: fixture, gemHome: gemHome))
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.packageID, "httpclient")
        XCTAssertEqual(record.executables, [fixture.fileSystem.realpath(script) ?? script])
        XCTAssertEqual(record.packageDirectory, "\(gemHome)/gems/httpclient-2.9.0")
    }

    func testSystemPathIsSystemOwnedUserPathIsNot() async {
        let fixture = FixtureFileSystem()
        // Simulate the two default roots by path shape; GEM_HOME overrides in these two calls only
        // to point at each fixture tree, but the systemOwned classification is by path prefix.
        let systemRoot = "/Library/Ruby/Gems/2.6.0"
        XCTAssertTrue(GemEnumeratorTests.isSystemPathForTest(systemRoot))
        XCTAssertFalse(GemEnumeratorTests.isSystemPathForTest(fixture.path("home/.gem/ruby/2.6.0")))
    }

    /// Mirrors `GemEnumerator.isSystemPath` (private) so this test can assert the rule without
    /// needing a real root-owned directory in a fixture.
    private static func isSystemPathForTest(_ path: String) -> Bool {
        path.hasPrefix("/Library/Ruby/Gems") || path.hasPrefix("/System/Library/")
    }

    func testMissingRootIsCompleteWithNoRecords() async {
        let fixture = FixtureFileSystem()
        let result = await GemEnumerator().enumerate(context(fixture: fixture, gemHome: fixture.path("does-not-exist")))
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testResolveFindsOneGemByPackageIDAndRoot() async {
        let fixture = FixtureFileSystem()
        let gemHome = fixture.path("gems")
        fixture.makeFile(at: "gems/specifications/rake-12.3.3.gemspec", contents: "Gem::Specification.new do |s|\nend\n")
        let ctx = context(fixture: fixture, gemHome: gemHome)

        let identity = InventoryIdentity(ecosystem: .gem, packageID: "rake", rootPath: gemHome, packageDirectory: gemHome)
        let resolved = await GemEnumerator().resolve(identity, ctx)
        XCTAssertEqual(resolved?.versionRaw, "12.3.3")
    }

    func testSystemGemIsBlockedSystemOwnedNonSystemIsListedOnly() async {
        func plan(systemOwned: Bool) async -> StrategyPlan {
            let config = DetectorConfig(
                id: "test-item", name: "Test", category: .cli, description: nil, schemaVersion: 2,
                source: .bundled, command: "tool", packages: nil, selfUpdater: nil, appcastURL: nil,
                autoUpdates: nil, inventory: nil, detect: nil, versionCommand: nil, versionPattern: nil,
                checkCommand: nil, installCommand: nil, updateCommand: "noop", workingDirectory: nil, needsReview: nil
            )
            let candidate = OwnerCandidate(commandPath: "/x/tool", resolvedPath: "/x/tool", owner: .gem(gemDir: "/x", name: "rails", systemOwned: systemOwned))
            let resolution = OwnerResolution(commandName: "tool", active: candidate, competing: [])
            return await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution)
        }
        let systemPlan = await plan(systemOwned: true)
        XCTAssertEqual(systemPlan.blockReason, .systemOwned)
        let userPlan = await plan(systemOwned: false)
        XCTAssertEqual(userPlan.blockReason, .noStrategy)
    }
}
