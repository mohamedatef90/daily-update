import XCTest
@testable import DailyUpdate

/// ADR-002 §9 P2-2 task 7 and §10's drift set (extra keys, a missing version, a truncated file, an
/// empty root) for the P2-2 enumerators, plus the P2-1 carry-overs that need a real enumerator:
/// D22 at the enumerator level (Security re-review FU1) and a FIFO manifest end to end (QA).
/// Only `complete` over an empty root may ever mean "0 installed" (D3).
final class P2DriftFixtureTests: HermeticTestCase {
    private func npm(_ fixture: FixtureFileSystem, fileSystem: ReadOnlyFileSystem = LiveFileSystem(),
                     loginPath: LoginPath = .known(["/usr/bin"])) async -> EnumerationResult {
        await NpmEnumerator().enumerate(DiscoveryContext(fileSystem: fileSystem, loginPath: loginPath, layout: .fixture(home: fixture.root.path)))
    }

    // MARK: D22 at the enumerator level

    /// 5,001 entries in `lib/node_modules` → `partial(capReached)`, exactly. (Dot entries aren't
    /// packages, so the only issue is the cap itself.)
    func testD22FiveThousandAndOneEntriesIsPartialCapReached() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        for index in 0..<5001 {
            FileManager.default.createFile(atPath: "\(prefix)/lib/node_modules/.pad-\(String(format: "%04d", index))", contents: nil)
        }
        let result = await npm(fixture)
        XCTAssertEqual(result.records, [])
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .capReached, rootPath: prefix,
            message: "\(prefix)/lib/node_modules has more than 5000 entries; only the first 5000 were read")]))
    }

    /// The cap keeps what it read: a capped listing still yields its records, in sorted order.
    func testCappedListingKeepsTheSortedPrefix() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        for name in ["delta", "alpha", "charlie", "bravo"] {
            NodeFixtures.addPackage(fixture, prefix: "usr/local", name: name, version: "1.0.0")
        }
        let result = await npm(fixture, fileSystem: LiveFileSystem(maxDirectoryEntries: 3))
        XCTAssertEqual(result.records.map(\.packageID), ["alpha", "bravo", "charlie"])
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertEqual(issues.map(\.kind), [.capReached])
        XCTAssertEqual(issues.map(\.rootPath), [prefix])
    }

    /// A `package.json` of 1 MB + 1 byte → `tooLarge` on that package.
    func testD22OversizedManifestIsTooLarge() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        fixture.makeFile(at: "usr/local/lib/node_modules/huge/package.json", contents: String(repeating: " ", count: 1_000_001))
        let result = await npm(fixture)
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .tooLarge, rootPath: "\(prefix)/lib/node_modules/huge",
            message: "\(prefix)/lib/node_modules/huge/package.json is larger than the size cap")]))
    }

    /// A package folder behind a 33-hop symlink chain → `capReached`, not `unreadable`.
    func testD22ThirtyThreeHopChainIsCapReached() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.writeManifest(fixture, folder: "real/deep", name: "deep", version: "1.0.0")
        let head = fixture.makeSymlinkChain(target: fixture.path("real/deep"), hops: 33)
        try FileManager.default.createSymbolicLink(atPath: "\(prefix)/lib/node_modules/deep", withDestinationPath: head)
        let result = await npm(fixture)
        XCTAssertEqual(result.records, [])
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .capReached, rootPath: "\(prefix)/lib/node_modules/deep",
            message: "\(prefix)/lib/node_modules/deep/package.json is behind too many symlinks")]))
    }

    // MARK: FIFO end to end (QA, first P2-1 review)

    /// A FIFO planted as a manifest makes the real npm enumerator return `partial(notRegularFile)`
    /// promptly — it never blocks on the open (a blocking open would never return at all). The
    /// bound is loose on purpose: the timing tests in this suite must survive a loaded machine.
    func testFIFOManifestMakesNpmPartialWithinTheDeadline() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "fine", version: "1.0.0")
        fixture.makeFIFO(at: "usr/local/lib/node_modules/x/package.json")
        let start = ContinuousClock.now
        let result = await npm(fixture)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
        XCTAssertEqual(result.records.map(\.packageID), ["fine"])
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .notRegularFile, rootPath: "\(prefix)/lib/node_modules/x",
            message: "\(prefix)/lib/node_modules/x/package.json isn't a regular file")]))
    }

    // MARK: Drift: npm

    func testNpmExtraKeysAreIgnoredAndAnEmptyRootIsCompleteZero() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        let empty = await npm(fixture)
        XCTAssertEqual(empty.status, .complete)
        XCTAssertEqual(empty.roots.map(\.path), [prefix])
        XCTAssertEqual(empty.records, [])

        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "extra", version: "2.0.0",
            extra: #""engines": {"node": ">=20"}, "_ignored": [1, 2, {"deep": true}], "bin": "not-a-map-or-file""#)
        let drifted = await npm(fixture)
        XCTAssertEqual(drifted.status, .complete)
        XCTAssertEqual(drifted.records.map(\.versionRaw), ["2.0.0"])
        XCTAssertEqual(drifted.records.first?.commands, [])
    }

    func testNpmTruncatedManifestIsMalformed() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        fixture.makeFile(at: "usr/local/lib/node_modules/cut/package.json", contents: #"{"name": "cut", "vers"#)
        let result = await npm(fixture)
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .malformed, rootPath: "\(prefix)/lib/node_modules/cut",
            message: "\(prefix)/lib/node_modules/cut/package.json isn't a JSON object")]))
    }

    /// A version that's a number, not a string, is treated as missing (Check Failed later).
    func testNpmNonStringVersionIsMissing() async throws {
        let fixture = FixtureFileSystem()
        NodeFixtures.makePrefix(fixture, "usr/local")
        fixture.makeFile(at: "usr/local/lib/node_modules/num/package.json", contents: #"{"name": "num", "version": 5}"#)
        let result = await npm(fixture)
        XCTAssertEqual(result.records.map(\.packageID), ["num"])
        XCTAssertNil(result.records.first?.versionRaw)
    }

    // MARK: Drift: brew

    /// Truncated brew JSON: the enricher "succeeded" but its output can't be read → the Cellar
    /// fallback, `partial(enricherFailed)`.
    func testBrewTruncatedJSONFallsBackToTheCellar() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let truncated = String(BrewFixtures.installedJSON.prefix(300))
        let result = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome(truncated) }).enumerate(BrewFixtures.context(fixture))
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertEqual(issues.map(\.kind), [.enricherFailed])
        XCTAssertEqual(issues.map(\.message), ["Homebrew (\(prefix)): latest versions unavailable: brew info returned JSON that couldn't be read"])
        XCTAssertEqual(result.brewInfo?.prefixes[prefix]?.source, .filesystem)
        XCTAssertEqual(result.records.count, 7)
    }

    /// Extra keys, a formula with no `installed`, and a cask with an unexpected artifact shape.
    func testBrewDriftedJSONStillParses() throws {
        let json = #"""
        {"formulae": [
          {"name": "gh", "full_name": "gh", "tap": "homebrew/core", "versions": {"stable": "2.102.0"}, "revision": 0,
           "linked_keg": "2.101.0", "installed": [{"version": "2.101.0", "installed_on_request": true}],
           "future_key": {"nested": [1, 2]}},
          {"name": "ghost", "full_name": "ghost", "tap": "homebrew/core", "versions": {"stable": "1.0"}}
        ], "casks": [
          {"token": "odd", "full_token": "odd", "tap": "homebrew/cask", "version": "1.0", "installed": "1.0",
           "artifacts": [{"app": [42]}, {"binary": []}, "not-a-dict"]}
        ], "new_top_level": true}
        """#
        let parsed = try XCTUnwrap(BrewInstalledJSON.parse(Data(json.utf8), prefix: "/p"))
        XCTAssertEqual(parsed.info.formulae["gh"]?.latestVersion, "2.102.0")
        XCTAssertEqual(parsed.info.formulae["ghost"]?.installedVersions, [])
        XCTAssertNil(parsed.info.formulae["ghost"]?.currentVersion)
        XCTAssertEqual(parsed.info.casks["odd"]?.appTargets, [])
        XCTAssertEqual(parsed.info.casks["odd"]?.binaries, [])
    }

    /// A formula with no version folder left in the Cellar isn't a record (nothing is installed).
    func testBrewEmptyFormulaFolderIsNotARecord() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        fixture.makeDirectory("opt/homebrew/Cellar/leftover")
        let result = await BrewEnumerator(enricher: { _ in .sandboxUnavailable }).enumerate(BrewFixtures.context(fixture))
        XCTAssertFalse(result.records.contains { $0.packageID == "leftover" })
        XCTAssertNil(result.brewInfo?.prefixes[prefix]?.formulae["leftover"])
    }

    /// A malformed receipt in the fallback is an issue, not a crash and not a silent skip.
    func testBrewMalformedReceiptIsAnIssue() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        fixture.makeFile(at: "opt/homebrew/Cellar/gh/2.101.0/INSTALL_RECEIPT.json", contents: "{not json")
        let result = await BrewEnumerator(enricher: { _ in .sandboxUnavailable }).enumerate(BrewFixtures.context(fixture))
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertEqual(issues.map(\.kind), [.sandboxUnavailable, .malformed])
        XCTAssertEqual(issues.last?.message, "\(prefix)/Cellar/gh/2.101.0/INSTALL_RECEIPT.json isn't a JSON object")
        // The formula is still listed, from its folder: an unreadable receipt proves nothing, so
        // it's treated as on request (visible) rather than hidden as a dependency.
        XCTAssertEqual(result.records.first { $0.packageID == "gh" }?.flags, [.onRequest])
    }

    // MARK: Drift: pnpm, yarn, bun

    func testGlobalFolderTruncatedManifestIsMalformed() async throws {
        let fixture = FixtureFileSystem()
        fixture.makeFile(at: ".bun/install/global/package.json", contents: #"{"dependencies": {"cow"#)
        let global = NodeFixtures.canonical(fixture, ".bun") + "/install/global"
        let result = await BunEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .malformed, rootPath: global, message: "\(global)/package.json isn't a JSON object")]))
    }

    /// A dependency listed in `package.json` with no folder is reported, never silently dropped.
    func testGlobalFolderListedButMissingPackage() async throws {
        let fixture = FixtureFileSystem()
        fixture.makeFile(at: ".config/yarn/global/package.json", contents: #"{"dependencies": {"gone": "^1.0.0"}, "extra": 1}"#)
        let global = NodeFixtures.canonical(fixture, ".config/yarn/global")
        let result = await YarnClassicEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .unreadable, rootPath: "\(global)/node_modules/gone",
            message: "yarn (\(global)): gone is listed but not installed")]))
    }

    /// An empty global folder (`{}`) is `complete` with 0 packages.
    func testGlobalFolderWithNoDependenciesIsCompleteZero() async throws {
        let fixture = FixtureFileSystem()
        fixture.makeFile(at: "Library/pnpm/global/5/package.json", contents: "{}")
        let result = await PnpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.records, [])
    }

    // MARK: Drift: nvm

    /// Alias folders, a half-installed version (no `bin/node`) and a stray file are skipped.
    func testNvmSkipsAliasesAndHalfInstalledVersions() async throws {
        let fixture = FixtureFileSystem()
        let v24 = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        fixture.makeDirectory(".nvm/versions/node/v25.0.0/lib")
        fixture.makeSymlink(at: ".nvm/versions/node/lts", relativeTarget: "v24.13.0")
        fixture.makeFile(at: ".nvm/versions/node/.DS_Store", contents: "")
        let result = await NodeRuntimeEnumerator.nvm.enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(v24)/bin"])))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.records.map(\.versionRaw), ["24.13.0"])
    }

    /// An `alias/default` naming a version that isn't installed adds no evidence and no error.
    func testNvmDefaultAliasForAMissingVersion() async throws {
        let fixture = FixtureFileSystem()
        let v24 = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        fixture.makeFile(at: ".nvm/alias/default", contents: "lts/iron\n")
        let result = await NodeRuntimeEnumerator.nvm.enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(v24)/bin"])))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.records.first?.evidence.map(\.kind), ["node"])
    }
}
