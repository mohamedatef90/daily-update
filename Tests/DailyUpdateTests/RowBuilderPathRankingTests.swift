import XCTest
@testable import DailyUpdate

/// P2-2 (CR FU on P2-1's R2): R2 is decided by what the login PATH runs — command → `PathSearch`
/// → `FileID` — over real enumerator output on real fixture trees, not by `(ecosystem, packageID)`.
/// Also R3 (task 6) and the S4 join test gap (Security re-review FU2).
final class RowBuilderPathRankingTests: HermeticTestCase {
    private func enumerate(_ fixture: FixtureFileSystem, loginPath: LoginPath) async -> [EnumerationResult] {
        let context = DiscoveryContext(loginPath: loginPath, layout: .fixture(home: fixture.root.path))
        return [
            await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() }).enumerate(context),
            await NodeRuntimeEnumerator.nvm.enumerate(context),
            await NpmEnumerator().enumerate(context),
        ]
    }

    private func assemble(_ fixture: FixtureFileSystem, loginPath: LoginPath, catalog: [DetectorConfig] = [],
                          candidates: [String: [String]] = [:]) async -> RowBuilder.Output {
        let results = await enumerate(fixture, loginPath: loginPath)
        return RowBuilder.assemble(
            input: .init(results: results, lookup: CommandPathLookup(candidatesByName: candidates, loginPath: loginPath)),
            catalog: catalog
        )
    }

    private func rowID(_ ecosystem: Ecosystem, _ root: String, _ packageID: String) -> String {
        ItemBuilder.stableID(prefix: "inv-\(ecosystem.rawValue)", path: "\(root)\u{0}\(packageID)")
    }

    // MARK: QA defect 4: brew node and nvm node

    func testNvmNodeFirstOnPathShadowsBrewNode() async throws {
        let fixture = FixtureFileSystem()
        let brew = BrewFixtures.makeTree(fixture)
        let nvm = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        let output = await assemble(fixture, loginPath: .known(["\(nvm)/bin", "\(brew)/bin", "/usr/bin"]))

        let nodeRow = rowID(.nvm, nvm, "node")
        XCTAssertTrue(output.rows.contains { $0.id == nodeRow })
        XCTAssertFalse(output.rows.contains { $0.inventory?.packageID == "node@22" })
        XCTAssertEqual(output.competing[nodeRow]?.map { "\($0.record.ecosystem.rawValue):\($0.record.packageID)" }, ["brew:node@22"])
        XCTAssertEqual(output.competing[nodeRow]?.map(\.command), ["node"])
        XCTAssertEqual(output.competing[nodeRow]?.map(\.path), ["\(brew)/bin/node"])
    }

    func testBrewNodeFirstOnPathShadowsNvmNode() async throws {
        let fixture = FixtureFileSystem()
        let brew = BrewFixtures.makeTree(fixture)
        let nvm = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        let output = await assemble(fixture, loginPath: .known(["\(brew)/bin", "\(nvm)/bin", "/usr/bin"]))

        let brewNodeRow = rowID(.brew, brew, "node@22")
        XCTAssertTrue(output.rows.contains { $0.id == brewNodeRow })
        XCTAssertFalse(output.rows.contains { $0.id == rowID(.nvm, nvm, "node") })
        XCTAssertEqual(output.competing[brewNodeRow]?.map { "\($0.record.ecosystem.rawValue):\($0.record.packageID)" }, ["nvm:node"])
    }

    // MARK: D2: the same npm package in two roots

    func testLaterPathCopyOfAPackageIsCompetingNotARow() async throws {
        let fixture = FixtureFileSystem()
        let nvm = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "@google/gemini-cli", version: "0.9.0",
            bins: ["gemini": "dist/index.js"])
        let usrLocal = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "@google/gemini-cli", version: "0.8.0",
            bins: ["gemini": "dist/index.js"])
        let output = await assemble(fixture, loginPath: .known(["\(nvm)/bin", "\(usrLocal)/bin"]))

        let geminiRows = output.rows.filter { $0.inventory?.packageID == "@google/gemini-cli" }
        XCTAssertEqual(geminiRows.map(\.id), [rowID(.npm, nvm, "@google/gemini-cli")])
        let competing = try XCTUnwrap(output.competing[rowID(.npm, nvm, "@google/gemini-cli")])
        XCTAssertEqual(competing.map(\.record.root.path), [usrLocal])
        XCTAssertEqual(competing.map(\.record.versionRaw), ["0.8.0"])
        XCTAssertEqual(competing.map(\.path), ["\(usrLocal)/bin/gemini"])
    }

    // MARK: D3/D4 (R3): inactive nvm versions

    func testInactiveVersionAndItsPackagesAreListedUnderTheActiveNode() async throws {
        let fixture = FixtureFileSystem()
        let v24 = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        let v20 = NodeFixtures.makeNvmVersion(fixture, "20.19.0")
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v20.19.0", name: "clawdbot", version: "2026.1.23",
            bins: ["clawdbot": "bin/cli.js"])
        let output = await assemble(fixture, loginPath: .known(["\(v24)/bin", "/usr/bin"]))

        let activeNode = rowID(.nvm, v24, "node")
        XCTAssertEqual(output.rows.map(\.id), [activeNode])
        XCTAssertEqual(output.inactiveInstalls.map { "\($0.record.ecosystem.rawValue):\($0.record.packageID)@\($0.record.root.path)" },
            ["npm:clawdbot@\(v20)", "nvm:node@\(v20)"])
        XCTAssertEqual(output.inactiveInstalls.map(\.rowID), [activeNode, activeNode])
    }

    /// With no active version-manager row, inactive installs are snapshot-level.
    func testInactiveInstallWithoutAnActiveManagerRowIsSnapshotLevel() async throws {
        let fixture = FixtureFileSystem()
        NodeFixtures.makeNvmVersion(fixture, "20.19.0")
        let output = await assemble(fixture, loginPath: .known(["/usr/bin"]))
        XCTAssertEqual(output.rows.map(\.id), [])
        XCTAssertEqual(output.inactiveInstalls.map(\.rowID), [nil])
    }

    // MARK: D5: what runs isn't a record

    func testRecordShadowedByAnUnownedFileGetsNoRow() async throws {
        let fixture = FixtureFileSystem()
        let native = fixture.makeFile(at: "native/bin/claude", contents: "#!/bin/sh\n")
        fixture.chmod(native, 0o755)
        let usrLocal = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "@anthropic-ai/claude-code", version: "2.0.0",
            bins: ["claude": "cli.js"])
        let nativeBin = NodeFixtures.canonical(fixture, "native/bin")
        let output = await assemble(fixture, loginPath: .known([nativeBin, "\(usrLocal)/bin"]))

        XCTAssertFalse(output.rows.contains { $0.inventory?.packageID == "@anthropic-ai/claude-code" })
        XCTAssertEqual(output.shadowedByUnownedFiles.map(\.record.packageID), ["@anthropic-ai/claude-code"])
        XCTAssertEqual(output.shadowedByUnownedFiles.map(\.activePath), ["\(nativeBin)/claude"])
        XCTAssertEqual(output.shadowedByUnownedFiles.map(\.command), ["claude"])
    }

    // MARK: No name merging

    /// CR (P2-1): the old key merged command-less packages across two active roots. They're two
    /// installs, so two rows, each handle suffixed with its root's label (CR FU10).
    func testCommandlessPackagesInTwoActiveRootsAreTwoRows() async throws {
        let fixture = FixtureFileSystem()
        let nvm = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "libonly", version: "1.0.0")
        let usrLocal = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "libonly", version: "1.1.0")
        let output = await assemble(fixture, loginPath: .known(["\(nvm)/bin", "\(usrLocal)/bin"]))

        let rows = output.rows.filter { $0.inventory?.packageID == "libonly" }
        XCTAssertEqual(Set(rows.map(\.id)), [rowID(.npm, nvm, "libonly"), rowID(.npm, usrLocal, "libonly")])
        XCTAssertEqual(Set(rows.compactMap(\.handle)), ["npm:libonly@nvm v24.13.0", "npm:libonly@~/usr/local"])
    }

    // MARK: Joins

    private func ghCatalog(packages: PackageIdentifiers? = nil) -> [DetectorConfig] {
        [DetectorConfig(
            id: "gh-cli", name: "GitHub CLI", category: .cli, description: "GitHub's CLI", command: "gh", packages: packages,
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil
        )]
    }

    /// D1: `{BREW}/bin/gh → Cellar/gh/…`; catalog `gh-cli` → one row `gh-cli`, handle `brew:gh`.
    func testD1CatalogCommandJoinsTheBrewRecord() async throws {
        let fixture = FixtureFileSystem()
        let brew = BrewFixtures.makeTree(fixture)
        let output = await assemble(fixture, loginPath: .known(["\(brew)/bin"]), catalog: ghCatalog(),
            candidates: ["gh": ["\(brew)/bin/gh"]])
        let row = try XCTUnwrap(output.rows.first { $0.inventory?.packageID == "gh" })
        XCTAssertEqual(row.id, "gh-cli")
        XCTAssertEqual(row.handle, "brew:gh")
        XCTAssertFalse(output.rows.contains { $0.id == rowID(.brew, brew, "gh") })
    }

    /// S4 (Security re-review FU2): the same catalog command resolves to the record's own file, but
    /// with the login PATH unknown the command join must not happen.
    func testUnknownPathNeverJoinsByCommand() async throws {
        let fixture = FixtureFileSystem()
        let brew = BrewFixtures.makeTree(fixture)
        let output = await assemble(fixture, loginPath: .unknown("exit 1"), catalog: ghCatalog(),
            candidates: ["gh": ["\(brew)/bin/gh"]])
        let row = try XCTUnwrap(output.rows.first { $0.inventory?.packageID == "gh" })
        XCTAssertEqual(row.id, rowID(.brew, brew, "gh"))
        XCTAssertFalse(output.rows.contains { $0.id == "gh-cli" })
        XCTAssertEqual(row.description, "PATH unknown")
    }

    /// CR re-review FU3: a row joined by package under an unknown PATH is marked "PATH unknown",
    /// and keeps its catalog id.
    func testUnknownPathJoinedRowIsMarked() async throws {
        let fixture = FixtureFileSystem()
        let brew = BrewFixtures.makeTree(fixture)
        let output = await assemble(fixture, loginPath: .unknown("exit 1"), catalog: ghCatalog(packages: PackageIdentifiers(brew: "gh")),
            candidates: ["gh": ["\(brew)/bin/gh"]])
        let row = try XCTUnwrap(output.rows.first { $0.inventory?.packageID == "gh" })
        XCTAssertEqual(row.id, "gh-cli")
        XCTAssertEqual(row.description, "PATH unknown")
    }
}

/// Task 6: the nvm and fnm runtime records.
final class NodeRuntimeEnumeratorTests: HermeticTestCase {
    func testNvmRecordsOneNodePerVersionWithActivity() async throws {
        let fixture = FixtureFileSystem()
        let v24 = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        let v20 = NodeFixtures.makeNvmVersion(fixture, "20.19.0")
        fixture.makeFile(at: ".nvm/alias/default", contents: "24.13.0\n")
        fixture.makeSymlink(at: ".nvm/versions/node/latest", relativeTarget: "v24.13.0")
        let nvmDir = NodeFixtures.canonical(fixture, ".nvm")

        let result = await NodeRuntimeEnumerator.nvm.enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(v24)/bin"])))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.records.map(\.root.path), [v20, v24])
        XCTAssertEqual(result.records.map(\.root.label), ["nvm v20.19.0", "nvm v24.13.0"])
        XCTAssertEqual(result.records.map(\.root.activity), [.inactive, .active])
        XCTAssertEqual(result.records.map(\.versionRaw), ["20.19.0", "24.13.0"])
        let active = try XCTUnwrap(result.records.last)
        XCTAssertEqual(active.packageID, "node")
        XCTAssertEqual(active.commands, ["node"])
        XCTAssertEqual(active.executables, ["\(v24)/bin/node"])
        XCTAssertEqual(active.owner, .versionManager(kind: .nvm, root: nvmDir))
        XCTAssertEqual(active.evidence, [Evidence(kind: "node", path: "\(v24)/bin/node"),
                                         Evidence(kind: "alias/default", path: "\(nvmDir)/alias/default")])
        XCTAssertEqual(result.records.first?.evidence, [Evidence(kind: "node", path: "\(v20)/bin/node")])
    }

    /// F4/D24: `NVM_DIR` from the login shell.
    func testNvmDirOverride() async {
        let fixture = FixtureFileSystem()
        NodeFixtures.makePrefix(fixture, "custom-nvm/versions/node/v22.11.0")
        let result = await NodeRuntimeEnumerator.nvm.enumerate(NodeFixtures.context(
            fixture, loginPath: .known(["/usr/bin"]), snapshot: ["NVM_DIR": fixture.path("custom-nvm")]))
        XCTAssertEqual(result.records.map(\.versionRaw), ["22.11.0"])
    }

    func testFnmDocumentedLayout() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, ".local/share/fnm/node-versions/v22.11.0/installation")
        let fnmDir = NodeFixtures.canonical(fixture, ".local/share/fnm")
        let result = await NodeRuntimeEnumerator.fnm.enumerate(NodeFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(result.records.map(\.root.path), [prefix])
        XCTAssertEqual(result.records.map(\.root.label), ["fnm v22.11.0"])
        XCTAssertEqual(result.records.first?.owner, .versionManager(kind: .fnm, root: fnmDir))
        // Each fnm version is also an npm root.
        NodeFixtures.addPackage(fixture, prefix: ".local/share/fnm/node-versions/v22.11.0/installation", name: "x", version: "1.0.0")
        let npm = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(npm.roots.map(\.label), ["fnm v22.11.0"])
    }

    func testNoManagerIsUnavailable() async {
        let fixture = FixtureFileSystem()
        let nvm = await NodeRuntimeEnumerator.nvm.enumerate(NodeFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(nvm.status, .unavailable("nvm isn't installed"))
        let fnm = await NodeRuntimeEnumerator.fnm.enumerate(NodeFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(fnm.status, .unavailable("fnm isn't installed"))
    }

    /// Runtime rows are Blocked(managedByVersionManager).
    func testNodeRuntimeRowIsManagedByItsVersionManager() async throws {
        let fixture = FixtureFileSystem()
        let v24 = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        let loginPath = LoginPath.known(["\(v24)/bin"])
        let result = await NodeRuntimeEnumerator.nvm.enumerate(NodeFixtures.context(fixture, loginPath: loginPath))
        let record = try XCTUnwrap(result.records.first)
        let row = try XCTUnwrap(RowBuilder.build(input: .init(results: [result],
            lookup: CommandPathLookup(candidatesByName: [:], loginPath: loginPath))).first)
        let plan = await StrategyPlanner.checkPlan(config: row, currentVersion: nil, resolve: { _ in record })
        XCTAssertEqual(plan?.blockReason, .managedByVersionManager)
        XCTAssertEqual(plan?.failureMessage, "Managed by nvm")
    }
}
