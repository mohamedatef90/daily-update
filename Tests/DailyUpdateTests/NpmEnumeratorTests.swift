import XCTest
@testable import DailyUpdate

/// ADR-002 §9 P2-2 task 4: npm roots, records and commands; linked packages (D10); a malformed
/// manifest and an unreadable `lib/node_modules` (D11); a name mismatch (D15).
final class NpmEnumeratorTests: HermeticTestCase {
    private func standardTree(_ fixture: FixtureFileSystem) -> (nvm: String, usrLocal: String) {
        let nvm = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "typescript", version: "5.4.0",
            bins: ["tsc": "bin/tsc", "tsserver": "bin/tsserver"])
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "@google/gemini-cli", version: "0.9.0",
            bins: ["gemini": "dist/index.js"])
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "npm", version: "11.6.2",
            bins: ["npm-cli": "bin/npm-cli.js"])
        let usrLocal = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "@google/gemini-cli", version: "0.8.0",
            bins: ["gemini": "dist/index.js"])
        return (nvm, usrLocal)
    }

    func testRootsRecordsAndCommandsAreExact() async throws {
        let fixture = FixtureFileSystem()
        let (nvm, usrLocal) = standardTree(fixture)
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(nvm)/bin", "/usr/bin"])))

        XCTAssertEqual(result.status, .complete)
        // Candidate order: overrides, Homebrew prefixes (the layout lists `/usr/local` there),
        // version managers, then the rest.
        XCTAssertEqual(result.roots.map(\.path), [usrLocal, nvm])
        XCTAssertEqual(result.roots.map(\.label), ["~/usr/local", "nvm v24.13.0"])
        XCTAssertEqual(result.roots.map(\.activity), [.inactive, .active])
        XCTAssertEqual(result.roots.map(\.toolPath), ["\(usrLocal)/bin/npm", "\(nvm)/bin/npm"])
        XCTAssertEqual(result.records.map { "\($0.root.path == nvm ? "nvm" : "usr"):\($0.packageID)@\($0.versionRaw ?? "-")" },
            ["usr:@google/gemini-cli@0.8.0", "nvm:@google/gemini-cli@0.9.0", "nvm:npm@11.6.2", "nvm:typescript@5.4.0"])

        let typescript = try XCTUnwrap(result.records.first { $0.packageID == "typescript" })
        XCTAssertEqual(typescript.commands, ["tsc", "tsserver"])
        XCTAssertEqual(typescript.executables, ["\(nvm)/lib/node_modules/typescript/bin/tsc", "\(nvm)/lib/node_modules/typescript/bin/tsserver"])
        XCTAssertEqual(typescript.packageDirectory, "\(nvm)/lib/node_modules/typescript")
        XCTAssertEqual(typescript.owner, .npm(prefix: nvm, package: "typescript"))
        XCTAssertEqual(typescript.flags, [])
        XCTAssertEqual(typescript.confidence, .proven)
        XCTAssertEqual(typescript.fileID, fixture.fileSystem.stat("\(nvm)/lib/node_modules/typescript/bin/tsc")?.fileID)

        let scoped = try XCTUnwrap(result.records.first { $0.packageID == "@google/gemini-cli" && $0.root.path == nvm })
        XCTAssertEqual(scoped.commands, ["gemini"])
    }

    /// §7.2: a `bin` entry is a command only when `<P>/bin/<cmd>` resolves to the manifest's target
    /// inside the package folder.
    func testCommandsNeedAMatchingLinkInsideThePackage() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "nolink", version: "1.0.0", bins: ["nolink": "cli.js"], linkBins: false)
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "escape", version: "1.0.0", bins: ["escape": "../other/cli.js"], linkBins: false)
        let other = fixture.makeFile(at: "usr/local/lib/node_modules/other/cli.js", contents: "")
        fixture.chmod(other, 0o755)
        NodeFixtures.writeManifest(fixture, folder: "usr/local/lib/node_modules/other", name: "other", version: "1.0.0")
        fixture.makeSymlink(at: "usr/local/bin/escape", relativeTarget: "../lib/node_modules/other/cli.js")

        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(prefix)/bin"])))
        XCTAssertEqual(result.records.first { $0.packageID == "nolink" }?.commands, [])
        XCTAssertEqual(result.records.first { $0.packageID == "escape" }?.commands, [])
    }

    /// A root needs both `lib/node_modules` and `bin/node`.
    func testAPrefixWithoutNodeIsNotARoot() async {
        let fixture = FixtureFileSystem()
        fixture.makeDirectory(".npm-global/lib/node_modules/x")
        NodeFixtures.writeManifest(fixture, folder: ".npm-global/lib/node_modules/x", name: "x", version: "1.0.0")
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(result.status, .unavailable("No npm global folder found"))
        let unknown = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .unknown("timed out")))
        XCTAssertEqual(unknown.status, .partial([EnumerationIssue(
            kind: .loginEnvironmentUnknown, message: "No npm global folder found, and the login PATH is unknown")]))
    }

    /// F4: `NPM_CONFIG_PREFIX` from the login snapshot adds a root.
    func testNpmConfigPrefixOverrideAddsARoot() async {
        let fixture = FixtureFileSystem()
        let custom = NodeFixtures.makePrefix(fixture, "custom/npm")
        NodeFixtures.addPackage(fixture, prefix: "custom/npm", name: "x", version: "1.0.0")
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(
            fixture, loginPath: .known(["/usr/bin"]), snapshot: ["NPM_CONFIG_PREFIX": fixture.path("custom/npm")]))
        XCTAssertEqual(result.roots.map(\.path), [custom])
        XCTAssertEqual(result.roots.map(\.label), ["npm prefix \(fixture.path("custom/npm"))"])
        XCTAssertEqual(result.records.map(\.packageID), ["x"])
    }

    /// D10: `<P>/lib/node_modules/x → ~/src/x` is flagged `linked`, with the source as evidence.
    func testLinkedPackageIsFlaggedWithItsSource() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.writeManifest(fixture, folder: "src/x", name: "x", version: "0.1.0", bins: ["x": "cli.js"])
        fixture.chmod(fixture.makeFile(at: "src/x/cli.js", contents: ""), 0o755)
        fixture.makeSymlink(at: "usr/local/lib/node_modules/x", absoluteTarget: fixture.path("src/x"))
        fixture.makeSymlink(at: "usr/local/bin/x", relativeTarget: "../lib/node_modules/x/cli.js")
        let source = NodeFixtures.canonical(fixture, "src/x")

        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(prefix)/bin"])))
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.flags, [.linked])
        XCTAssertEqual(record.packageDirectory, source)
        XCTAssertEqual(record.evidence.last, Evidence(kind: "npm-link", path: source))
        XCTAssertEqual(record.commands, ["x"])
    }

    /// D10 at plan time: Blocked(manualOnly, "Linked from …"), and no npm command is built.
    func testLinkedPackagePlansAsManualOnly() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.writeManifest(fixture, folder: "src/x", name: "x", version: "0.1.0")
        fixture.makeSymlink(at: "usr/local/lib/node_modules/x", absoluteTarget: fixture.path("src/x"))
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(prefix)/bin"])))
        let record = try XCTUnwrap(result.records.first)
        let rows = RowBuilder.build(input: .init(results: [result]))
        let row = try XCTUnwrap(rows.first { $0.inventory?.packageID == "x" })
        let calls = CallRecorder()
        var services = StrategyPlanner.Services.live
        services.runProcess = { spec in calls.record(spec.executablePath); return ShellRunner.Result(exitCode: 1, stdout: "", stderr: "") }
        let plan = await StrategyPlanner.checkPlan(config: row, currentVersion: nil, resolve: { _ in record }, services: services)
        XCTAssertEqual(plan?.blockReason, .manualOnly)
        XCTAssertEqual(plan?.failureMessage, "Linked from \(NodeFixtures.canonical(fixture, "src/x"))")
        XCTAssertNil(plan?.updateCommandSpec)
        XCTAssertEqual(calls.calls, [])
    }

    /// A manifest without a version is still a record (Check Failed later), never skipped.
    func testMissingVersionKeepsTheRecord() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "noversion", version: nil)
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(prefix)/bin"])))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.records.map(\.packageID), ["noversion"])
        XCTAssertNil(result.records.first?.versionRaw)
    }

    /// D11: a malformed `package.json` makes that package a `malformed` issue on its own folder;
    /// the other packages are unaffected.
    func testMalformedManifestIsAnIssueOnThatPackageOnly() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "good", version: "1.0.0")
        fixture.makeFile(at: "usr/local/lib/node_modules/broken/package.json", contents: "{\"name\": \"broken\",")
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(prefix)/bin"])))
        XCTAssertEqual(result.records.map(\.packageID), ["good"])
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .malformed, rootPath: "\(prefix)/lib/node_modules/broken",
            message: "\(prefix)/lib/node_modules/broken/package.json isn't a JSON object")]))
    }

    /// D15: a folder whose manifest names another package is rejected; no record, no command.
    func testNameMismatchIsRejected() async throws {
        let fixture = FixtureFileSystem()
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.writeManifest(fixture, folder: "usr/local/lib/node_modules/innocent", name: "-rf", version: "1.0.0")
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(prefix)/bin"])))
        XCTAssertEqual(result.records, [])
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .malformed, rootPath: "\(prefix)/lib/node_modules/innocent",
            message: "npm (~/usr/local): innocent's package.json names a different package, or no valid one")]))
    }

    /// D11: a `lib/node_modules` with mode 000 is an `unreadable` issue on that root.
    func testUnreadableNodeModulesIsAnIssueOnThatRoot() async throws {
        let fixture = FixtureFileSystem()
        let nvm = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "ok", version: "1.0.0")
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        fixture.chmod("\(prefix)/lib/node_modules", 0o000)
        defer { fixture.chmod("\(prefix)/lib/node_modules", 0o755) }
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(nvm)/bin"])))
        XCTAssertEqual(result.records.map(\.packageID), ["ok"])
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .unreadable, rootPath: prefix, message: "couldn't read \(prefix)/lib/node_modules")]))
    }

    func testResolveRereadsOnePackage() async throws {
        let fixture = FixtureFileSystem()
        let (nvm, _) = standardTree(fixture)
        let identity = InventoryIdentity(ecosystem: .npm, packageID: "typescript", rootPath: nvm,
            packageDirectory: "\(nvm)/lib/node_modules/typescript", toolPath: "\(nvm)/bin/npm")
        let context = NodeFixtures.context(fixture, loginPath: .known(["\(nvm)/bin"]))
        let record = await NpmEnumerator().resolve(identity, context)
        XCTAssertEqual(record?.versionRaw, "5.4.0")
        XCTAssertEqual(record?.root.label, "nvm v24.13.0")
        // L1: once the package folder is gone, resolve finds nothing.
        try FileManager.default.removeItem(atPath: "\(nvm)/lib/node_modules/typescript")
        let gone = await NpmEnumerator().resolve(identity, context)
        XCTAssertNil(gone)
    }
}
