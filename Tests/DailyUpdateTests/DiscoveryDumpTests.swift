import XCTest
@testable import DailyUpdate

/// ADR-002 §9 P2-1: "the discovery dump is introduced, for the fake ecosystem only." A golden
/// tree of `FakeEnumerator` records run through the exact same `DiscoveryCoordinator` ->
/// `RowBuilder` pipeline `--discover` uses, dumped one line per row so a future change is as easy
/// to diff as `BundledCommandDumpTests`' bundled-command dump. Runs only when
/// `DAILY_UPDATE_DISCOVERY_DUMP` names an output file.
final class DiscoveryDumpTests: HermeticTestCase {
    /// A small, deterministic tree: one plain package, one shadowed-by-PATH-order duplicate, one
    /// dependency (no row), one inactive-root install (no row), and one partial-enumeration issue
    /// (its own Check Failed row).
    private func goldenTreeResult() -> EnumerationResult {
        let activeRoot = InstallRoot(
            ecosystem: .fake, path: "/golden/active", label: "golden active",
            binDirectories: ["/golden/active/bin"], activity: .active
        )
        let shadowedRoot = InstallRoot(
            ecosystem: .fake, path: "/golden/shadowed", label: "golden shadowed",
            binDirectories: ["/golden/shadowed/bin"], activity: .active
        )
        let inactiveRoot = InstallRoot(
            ecosystem: .fake, path: "/golden/inactive", label: "golden inactive",
            binDirectories: ["/golden/inactive/bin"], activity: .inactive
        )

        func package(_ id: String, root: InstallRoot, inode: UInt64, flags: Set<PackageFlag> = []) -> InstalledPackage {
            InstalledPackage(
                ecosystem: .fake, packageID: id, versionRaw: "1.0.0", root: root,
                packageDirectory: "\(root.path)/\(id)", executables: ["\(root.binDirectories[0])/\(id)"],
                owner: .unknown, flags: flags, confidence: .proven, fileID: FileID(device: 1, inode: inode)
            )
        }

        let records = [
            package("widget", root: activeRoot, inode: 1),
            package("widget", root: shadowedRoot, inode: 2),
            package("libwidget", root: activeRoot, inode: 3, flags: [.dependency]),
            package("old-widget", root: inactiveRoot, inode: 4),
        ]
        let issue = EnumerationIssue(kind: .malformed, rootPath: "/golden/active/broken-widget", message: "malformed manifest")
        return EnumerationResult(ecosystem: .fake, roots: [activeRoot, shadowedRoot, inactiveRoot], records: records, status: .partial([issue]))
    }

    func testDumpDiscoveryGoldenTree() async throws {
        guard let path = ProcessInfo.processInfo.environment["DAILY_UPDATE_DISCOVERY_DUMP"], !path.isEmpty else {
            throw XCTSkip("Set DAILY_UPDATE_DISCOVERY_DUMP=<file> to write the discovery dump")
        }
        let lookup = CommandPathLookup(
            candidatesByName: [:],
            loginPath: .known(["/golden/active/bin", "/golden/shadowed/bin"])
        )
        let rows = RowBuilder.build(input: .init(results: [goldenTreeResult()], lookup: lookup))
            .sorted { $0.id < $1.id }

        var lines: [String] = []
        for row in rows {
            lines.append([
                row.id, row.handle ?? "", row.name, row.source?.rawValue ?? "",
                row.inventory.map { "\($0.ecosystem.rawValue):\($0.packageID)@\($0.rootPath)" } ?? "",
                row.description ?? "",
            ].joined(separator: "\t"))
        }

        // P2-2: the golden tree of real enumerators, at a fixed root so row IDs are stable; paths
        // are printed with that root as `{ROOT}`, and IDs are re-derived from the redacted paths.
        let fixture = FixtureFileSystem(fixedRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyUpdate-discovery-golden", isDirectory: true))
        let golden = await GoldenTree.build(fixture)
        lines += GoldenTree.dumpLines(golden, fixture: fixture)
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The real golden tree's rows, exactly (P2-2 task list: "adds the brew, npm, pnpm, yarn, bun
    /// and nvm rows of the golden tree").
    func testRealGoldenTreeRowsAreExact() async throws {
        let fixture = FixtureFileSystem()
        let golden = await GoldenTree.build(fixture)
        let output = golden.output
        func key(_ row: DetectorConfig) -> String {
            guard let inventory = row.inventory else { return row.id }
            return inventory.isErrorMarker ? "error:\(inventory.ecosystem.rawValue)" : "\(inventory.ecosystem.rawValue):\(inventory.packageID)"
        }
        XCTAssertEqual(output.rows.map(key).sorted(), [
            "brew:bird", "brew:gh", "brew:jq", "brew:python@3.12", "bun:cowsay", "error:npm",
            "npm:@google/gemini-cli", "npm:npm", "npm:typescript", "nvm:node", "pnpm:serve", "yarn:create-react-app",
        ])
        XCTAssertEqual(output.rows.first { $0.inventory?.packageID == "gh" }?.id, "gh-cli")

        let nodeRow = try XCTUnwrap(output.rows.first { $0.inventory?.ecosystem == .nvm }).id
        XCTAssertEqual(output.competing[nodeRow]?.map { "\($0.record.ecosystem.rawValue):\($0.record.packageID)" }, ["brew:node@22"])
        let geminiRow = try XCTUnwrap(output.rows.first { $0.inventory?.packageID == "@google/gemini-cli" }).id
        XCTAssertEqual(output.competing[geminiRow]?.map(\.record.versionRaw), ["0.8.0"])
        XCTAssertEqual(output.inactiveInstalls.map { "\($0.record.ecosystem.rawValue):\($0.record.packageID)" }, ["npm:clawdbot", "nvm:node"])
        XCTAssertEqual(output.inactiveInstalls.map(\.rowID), [nodeRow, nodeRow])
        XCTAssertEqual(output.shadowedByUnownedFiles.map(\.record.packageID), ["@anthropic-ai/claude-code"])
    }

    /// Runs the same golden tree end-to-end through `DiscoveryCoordinator` (not just `RowBuilder`
    /// directly), so this also proves the fake ecosystem survives the coordinator's ceiling and
    /// in-flight registry the way a real one will once P2-2/3/4 register their enumerators.
    func testGoldenTreeThroughTheCoordinatorMatchesDirectRowBuilding() async {
        let fake = FakeEnumerator(ecosystem: .fake, behavior: .immediate(goldenTreeResult()))
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .known(["/golden/active/bin", "/golden/shadowed/bin"]))
        let context = DiscoveryContext(loginPath: lookup.loginPath)
        let coordinatorResults = await DiscoveryCoordinator.run(
            enumerators: [fake], context: context, registry: DiscoveryInFlightRegistry()
        )
        let coordinatorRows = RowBuilder.build(input: .init(results: coordinatorResults, lookup: lookup))
        let directRows = RowBuilder.build(input: .init(results: [goldenTreeResult()], lookup: lookup))
        XCTAssertEqual(coordinatorRows.map(\.id).sorted(), directRows.map(\.id).sorted())
    }

    func testGoldenTreeProducesExpectedRowShape() {
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .known(["/golden/active/bin", "/golden/shadowed/bin"]))
        let rows = RowBuilder.build(input: .init(results: [goldenTreeResult()], lookup: lookup))

        // widget: P2-2 decides R2 by what the login PATH runs (command → PathSearch → FileID).
        // The fake records have no commands and no files, so nothing on PATH shadows either copy:
        // both roots are active, so these are two installs and two rows, never merged by name.
        // The real R2 cases (brew node behind nvm node, a later-PATH npm copy) are in the golden
        // tree of real enumerators below and in `RowBuilderPathRankingTests`.
        let widgetRows = rows.filter { $0.inventory?.packageID == "widget" }
        XCTAssertEqual(widgetRows.map(\.inventory?.rootPath), ["/golden/active", "/golden/shadowed"])

        // libwidget is a dependency: no row.
        XCTAssertFalse(rows.contains { $0.inventory?.packageID == "libwidget" })

        // old-widget is in an inactive root: no row.
        XCTAssertFalse(rows.contains { $0.inventory?.packageID == "old-widget" })

        // The malformed-manifest issue becomes its own Check Failed row.
        XCTAssertTrue(rows.contains { $0.inventory?.isErrorMarker == true && $0.description == "malformed manifest" })

        // Exactly 3 rows total: two widget rows + the one error row.
        XCTAssertEqual(rows.count, 3)
    }
}

/// The P2-2 golden tree: one of each shape the P2-2 enumerators read, run through the real
/// enumerators and `RowBuilder.assemble`.
enum GoldenTree {
    struct Built {
        let results: [EnumerationResult]
        let output: RowBuilder.Output
    }

    static func build(_ fixture: FixtureFileSystem) async -> Built {
        let brew = BrewFixtures.makeTree(fixture)
        let v24 = NodeFixtures.makeNvmVersion(fixture, "24.13.0")
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "typescript", version: "5.4.0", bins: ["tsc": "bin/tsc"])
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "@google/gemini-cli", version: "0.9.0",
            bins: ["gemini": "dist/index.js"])
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v24.13.0", name: "npm", version: "11.6.2", bins: ["npx": "bin/npx-cli.js"])
        NodeFixtures.makeNvmVersion(fixture, "20.19.0")
        NodeFixtures.addPackage(fixture, prefix: ".nvm/versions/node/v20.19.0", name: "clawdbot", version: "2026.1.23", bins: ["clawdbot": "bin/cli.js"])
        fixture.makeFile(at: ".nvm/alias/default", contents: "24.13.0\n")

        let usrLocal = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "@google/gemini-cli", version: "0.8.0", bins: ["gemini": "dist/index.js"])
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: "@anthropic-ai/claude-code", version: "2.0.0", bins: ["claude": "cli.js"])
        fixture.makeFile(at: "usr/local/lib/node_modules/broken/package.json", contents: #"{"name": "broken", "vers"#)
        fixture.chmod(fixture.makeFile(at: "native/bin/claude", contents: "#!/bin/sh\n"), 0o755)

        fixture.makeFile(at: "Library/pnpm/global/5/package.json", contents: #"{"dependencies": {"serve": "^14.2.4"}}"#)
        NodeFixtures.writeManifest(fixture, folder: "Library/pnpm/global/5/node_modules/serve", name: "serve", version: "14.2.4")
        fixture.makeFile(at: ".config/yarn/global/package.json", contents: #"{"dependencies": {"create-react-app": "^5.0.1"}}"#)
        NodeFixtures.writeManifest(fixture, folder: ".config/yarn/global/node_modules/create-react-app", name: "create-react-app",
            version: "5.0.1", bins: ["create-react-app": "index.js"])
        fixture.chmod(fixture.makeFile(at: ".config/yarn/global/node_modules/create-react-app/index.js", contents: ""), 0o755)
        fixture.makeSymlink(at: ".yarn/bin/create-react-app", relativeTarget: "../../.config/yarn/global/node_modules/create-react-app/index.js")
        fixture.makeFile(at: ".bun/install/global/package.json", contents: #"{"dependencies": {"cowsay": "^1.6.0"}}"#)
        NodeFixtures.writeManifest(fixture, folder: ".bun/install/global/node_modules/cowsay", name: "cowsay", version: "1.6.0",
            bins: ["cowsay": "cli.js"])
        fixture.chmod(fixture.makeFile(at: ".bun/install/global/node_modules/cowsay/cli.js", contents: ""), 0o755)
        fixture.makeSymlink(at: ".bun/bin/cowsay", relativeTarget: "../install/global/node_modules/cowsay/cli.js")

        let canonical = { (relative: String) in NodeFixtures.canonical(fixture, relative) }
        let loginPath = LoginPath.known([
            "\(v24)/bin", canonical("native/bin"), "\(brew)/bin", "\(usrLocal)/bin", canonical("Library/pnpm"),
            canonical(".yarn/bin"), canonical(".bun/bin"), "/usr/bin", "/bin",
        ])
        let context = DiscoveryContext(loginPath: loginPath, layout: .fixture(home: fixture.root.path))
        let enumerators: [Enumerator] = [
            BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() }), NpmEnumerator(), PnpmEnumerator(),
            YarnClassicEnumerator(), BunEnumerator(), NodeRuntimeEnumerator.nvm, NodeRuntimeEnumerator.fnm,
        ]
        var results: [EnumerationResult] = []
        for enumerator in enumerators { results.append(await enumerator.enumerate(context)) }
        let catalog = [DetectorConfig(
            id: "gh-cli", name: "GitHub CLI", category: .cli, description: nil, command: "gh",
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil
        )]
        let lookup = CommandPathLookup(candidatesByName: ["gh": ["\(brew)/bin/gh"]], loginPath: loginPath)
        return Built(results: results, output: RowBuilder.assemble(input: .init(results: results, lookup: lookup), catalog: catalog))
    }

    /// One line per row, then one per competing, inactive and shadowed install, then one per
    /// enumerator status. Paths under the fixture root print as `{ROOT}`, and inventory row IDs are
    /// re-derived from those redacted paths, so the dump is the same on every Mac.
    static func dumpLines(_ built: Built, fixture: FixtureFileSystem) -> [String] {
        let roots = [fixture.fileSystem.realpath(fixture.root.path) ?? fixture.root.path, fixture.root.path]
        func redact(_ text: String) -> String {
            roots.reduce(text) { $0.replacingOccurrences(of: $1, with: "{ROOT}") }
        }
        var printedID: [String: String] = [:]
        for row in built.output.rows {
            guard let inventory = row.inventory else { printedID[row.id] = row.id; continue }
            let eco = inventory.ecosystem.rawValue
            if inventory.isErrorMarker, row.id == ItemBuilder.stableID(prefix: "inv-error-\(eco)", path: inventory.rootPath) {
                printedID[row.id] = ItemBuilder.stableID(prefix: "inv-error-\(eco)", path: redact(inventory.rootPath))
            } else if row.id == ItemBuilder.stableID(prefix: "inv-\(eco)", path: "\(inventory.rootPath)\u{0}\(inventory.packageID)") {
                printedID[row.id] = ItemBuilder.stableID(prefix: "inv-\(eco)", path: "\(redact(inventory.rootPath))\u{0}\(inventory.packageID)")
            } else {
                printedID[row.id] = row.id
            }
        }
        func record(_ record: InstalledPackage) -> String {
            "\(record.ecosystem.rawValue):\(record.packageID)@\(redact(record.root.path))"
        }

        var lines: [String] = []
        for row in built.output.rows.sorted(by: { (printedID[$0.id] ?? $0.id) < (printedID[$1.id] ?? $1.id) }) {
            lines.append([
                printedID[row.id] ?? row.id, redact(row.handle ?? ""), redact(row.name), row.source?.rawValue ?? "",
                row.inventory.map { "\($0.ecosystem.rawValue):\($0.packageID)@\(redact($0.rootPath))" } ?? "",
                redact(row.description ?? ""),
            ].joined(separator: "\t"))
        }
        for rowID in built.output.competing.keys.sorted(by: { (printedID[$0] ?? $0) < (printedID[$1] ?? $1) }) {
            for install in built.output.competing[rowID] ?? [] {
                lines.append(["competing", printedID[rowID] ?? rowID, record(install.record), install.record.versionRaw ?? "",
                    install.command, redact(install.path)].joined(separator: "\t"))
            }
        }
        for install in built.output.inactiveInstalls {
            lines.append(["inactive", install.rowID.map { printedID[$0] ?? $0 } ?? "-", record(install.record),
                install.record.versionRaw ?? ""].joined(separator: "\t"))
        }
        for shadowed in built.output.shadowedByUnownedFiles {
            lines.append(["shadowed", record(shadowed.record), shadowed.command, redact(shadowed.path), redact(shadowed.activePath)]
                .joined(separator: "\t"))
        }
        for result in built.results {
            let status: String
            switch result.status {
            case .complete: status = "complete"
            case .partial(let issues): status = "partial(" + issues.map(\.kind.rawValue).joined(separator: ",") + ")"
            case .unavailable(let reason): status = "unavailable(\(reason))"
            case .failed(let issue): status = "failed(\(issue.kind.rawValue))"
            }
            lines.append(["status", result.ecosystem.rawValue, status, "roots=\(result.roots.count)", "records=\(result.records.count)"]
                .joined(separator: "\t"))
        }
        return lines
    }
}

/// `--discover --json` (CR FU9): row `description`, the top-level `loginPath` state, and per
/// enumerator `elapsedMs`, plus the competing, inactive and Homebrew facts P2-2 adds.
final class DiscoverJSONTests: HermeticTestCase {
    func testDiscoverJSONCarriesDescriptionsLoginPathAndCompeting() async throws {
        let fixture = FixtureFileSystem()
        let golden = await GoldenTree.build(fixture)
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .known(["/a", "/b"]))
        let payload = CLIRunner.discoveryJSONPayload(DiscoveryRunResult(results: golden.results, lookup: lookup, assembly: golden.output, elapsedMs: 42))
        // Round-trip through JSON, as the CLI prints it.
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["elapsedMs"] as? Int, 42)
        XCTAssertEqual(json["loginPath"] as? [String: AnyHashable], ["state": "known", "entries": 2])

        let rows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        let errorRow = try XCTUnwrap(rows.first { ($0["id"] as? String)?.hasPrefix("inv-error-npm-") == true })
        XCTAssertEqual(errorRow["description"] as? String,
            "\(NodeFixtures.canonical(fixture, "usr/local"))/lib/node_modules/broken/package.json isn't a JSON object")
        let nodeRow = try XCTUnwrap(rows.first { $0["ecosystem"] as? String == "nvm" })
        let competing = try XCTUnwrap(nodeRow["competing"] as? [[String: Any]])
        XCTAssertEqual(competing.map { $0["packageID"] as? String }, ["node@22"])
        XCTAssertEqual(competing.map { $0["command"] as? String }, ["node"])

        let results = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["ecosystem"] as? String }, ["brew", "npm", "pnpm", "yarn", "bun", "nvm", "fnm"])
        XCTAssertTrue(results.allSatisfy { $0["elapsedMs"] is Int })
        XCTAssertEqual(results.first { $0["ecosystem"] as? String == "fnm" }?["reason"] as? String, "fnm isn't installed")

        let inactive = try XCTUnwrap(json["inactiveInstalls"] as? [[String: Any]])
        XCTAssertEqual(inactive.map { $0["listedUnder"] as? String }, [nodeRow["id"] as? String, nodeRow["id"] as? String])
        let homebrew = try XCTUnwrap(json["homebrew"] as? [String: Any])
        XCTAssertEqual((homebrew["prefixes"] as? [[String: String]])?.map { $0["source"] }, ["enricher"])
    }

    func testLoginPathStatesInJSON() throws {
        for (loginPath, expected) in [(LoginPath.empty, ["state": "empty"]), (.unknown("timed out"), ["state": "unknown", "reason": "timed out"])] {
            let lookup = CommandPathLookup(candidatesByName: [:], loginPath: loginPath)
            let output = RowBuilder.assemble(input: .init(results: [], lookup: lookup))
            let payload = CLIRunner.discoveryJSONPayload(DiscoveryRunResult(results: [], lookup: lookup, assembly: output, elapsedMs: 0))
            XCTAssertEqual(payload["loginPath"] as? [String: String], expected)
            let rows = try XCTUnwrap(payload["rows"] as? [[String: Any]])
            XCTAssertEqual(rows.map { $0["id"] as? String }, ["inv-error-login-path"])
        }
    }
}
