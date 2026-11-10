import XCTest
@testable import DailyUpdate

/// ADR-002 §9 P2-2 task 5: pnpm, yarn classic and bun, from their documented layouts, including
/// "tool present, root absent = `complete(0)`" versus `unavailable` (D12).
final class PnpmYarnBunEnumeratorTests: HermeticTestCase {
    private func context(_ fixture: FixtureFileSystem, loginPath: LoginPath = .known(["/usr/bin"]),
                         snapshot: [String: String] = [:]) -> DiscoveryContext {
        NodeFixtures.context(fixture, loginPath: loginPath, snapshot: snapshot)
    }

    /// A global folder: `package.json` listing `dependencies`, plus `node_modules/<name>`.
    private func makeGlobalFolder(_ fixture: FixtureFileSystem, _ folder: String, packages: [(String, String, [String: String])]) {
        let dependencies = packages.map { "\"\($0.0)\": \"^\($0.1)\"" }.joined(separator: ", ")
        fixture.makeFile(at: "\(folder)/package.json", contents: "{\"dependencies\": {\(dependencies)}}")
        for (name, version, bins) in packages {
            NodeFixtures.writeManifest(fixture, folder: "\(folder)/node_modules/\(name)", name: name, version: version, bins: bins)
            for (_, target) in bins {
                fixture.chmod(fixture.makeFile(at: "\(folder)/node_modules/\(name)/\(target)", contents: ""), 0o755)
            }
        }
        // A transitive package that isn't a listed dependency: never a record.
        NodeFixtures.writeManifest(fixture, folder: "\(folder)/node_modules/transitive", name: "transitive", version: "9.9.9")
    }

    // MARK: pnpm

    private func pnpmShim(_ fixture: FixtureFileSystem, command: String, layout: String, package: String, target: String) {
        let text = """
        #!/bin/sh
        basedir=$(dirname "$(echo "$0" | sed -e 's,\\\\,/,g')")
        exec node  "$basedir/global/\(layout)/node_modules/\(package)/\(target)" "$@"
        """
        fixture.chmod(fixture.makeFile(at: "Library/pnpm/\(command)", contents: text), 0o755)
    }

    func testPnpmNewestLayoutWinsAndShimsNameCommands() async throws {
        let fixture = FixtureFileSystem()
        makeGlobalFolder(fixture, "Library/pnpm/global/4", packages: [("old-tool", "1.0.0", [:])])
        makeGlobalFolder(fixture, "Library/pnpm/global/5", packages: [("@vue/cli", "5.0.8", ["vue": "bin/vue.js"]), ("serve", "14.2.4", [:])])
        pnpmShim(fixture, command: "vue", layout: "5", package: "@vue/cli", target: "bin/vue.js")
        let home = NodeFixtures.canonical(fixture, "Library/pnpm")

        let result = await PnpmEnumerator().enumerate(context(fixture, loginPath: .known([home, "/usr/bin"])))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.roots.map(\.path), ["\(home)/global/5"])
        XCTAssertEqual(result.roots.map(\.activity), [.active])
        XCTAssertEqual(result.records.map(\.packageID), ["@vue/cli", "serve"])
        let vue = try XCTUnwrap(result.records.first)
        XCTAssertEqual(vue.versionRaw, "5.0.8")
        XCTAssertEqual(vue.commands, ["vue"])
        XCTAssertEqual(vue.executables, ["\(home)/vue"])
        XCTAssertEqual(vue.owner, .pnpm(home: home, package: "@vue/cli"))
        XCTAssertEqual(result.records.last?.commands, [])
    }

    /// D12: pnpm's home exists but has no `global` folder → `complete` with 0 packages.
    func testPnpmHomeWithoutGlobalIsCompleteZero() async {
        let fixture = FixtureFileSystem()
        fixture.makeDirectory("Library/pnpm/store")
        let result = await PnpmEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.records, [])
    }

    /// D12: no pnpm home and no pnpm on PATH → `unavailable`; with an unknown PATH it's partial.
    func testNoPnpmIsUnavailable() async {
        let fixture = FixtureFileSystem()
        let result = await PnpmEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.status, .unavailable("pnpm isn't installed"))
        let unknown = await PnpmEnumerator().enumerate(context(fixture, loginPath: .unknown("timed out")))
        XCTAssertEqual(unknown.status, .partial([EnumerationIssue(
            kind: .loginEnvironmentUnknown, message: "pnpm isn't installed, and the login PATH is unknown")]))
    }

    /// pnpm on the login PATH (a Homebrew pnpm, say) with no home at all is `complete(0)` too.
    func testPnpmOnPathWithoutAHomeIsCompleteZero() async {
        let fixture = FixtureFileSystem()
        fixture.chmod(fixture.makeFile(at: "tools/bin/pnpm", contents: "#!/bin/sh\n"), 0o755)
        let result = await PnpmEnumerator().enumerate(context(fixture, loginPath: .known([fixture.path("tools/bin")])))
        XCTAssertEqual(result.status, .complete)
    }

    /// An unknown layout (a `global` folder with no layout folder) is `failed`, never empty.
    func testPnpmUnknownLayoutIsFailed() async {
        let fixture = FixtureFileSystem()
        fixture.makeDirectory("Library/pnpm/global/something-else")
        let home = NodeFixtures.canonical(fixture, "Library/pnpm")
        let result = await PnpmEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.status, .failed(EnumerationIssue(
            kind: .malformed, rootPath: "\(home)/global",
            message: "pnpm (\(home)): the global folder has a layout Daily Update doesn't know")))
    }

    /// Drift: a `v5`-named layout folder (as the ADR describes it) is accepted too.
    func testPnpmVPrefixedLayoutIsAccepted() async {
        let fixture = FixtureFileSystem()
        makeGlobalFolder(fixture, "Library/pnpm/global/v5", packages: [("serve", "14.2.4", [:])])
        let result = await PnpmEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.records.map(\.packageID), ["serve"])
    }

    /// F4: `PNPM_HOME` from the login snapshot.
    func testPnpmHomeOverride() async {
        let fixture = FixtureFileSystem()
        makeGlobalFolder(fixture, "custom/pnpm/global/5", packages: [("serve", "14.2.4", [:])])
        let result = await PnpmEnumerator().enumerate(context(fixture, snapshot: ["PNPM_HOME": fixture.path("custom/pnpm")]))
        XCTAssertEqual(result.records.map(\.packageID), ["serve"])
    }

    // MARK: yarn classic

    func testYarnGlobalFolderRecordsAndLinks() async throws {
        let fixture = FixtureFileSystem()
        makeGlobalFolder(fixture, ".config/yarn/global", packages: [("create-react-app", "5.0.1", ["create-react-app": "index.js"])])
        fixture.makeSymlink(at: ".yarn/bin/create-react-app", relativeTarget: "../../.config/yarn/global/node_modules/create-react-app/index.js")
        let global = NodeFixtures.canonical(fixture, ".config/yarn/global")

        let result = await YarnClassicEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.roots.map(\.path), [global])
        XCTAssertEqual(result.records.map(\.packageID), ["create-react-app"])
        XCTAssertEqual(result.records.first?.commands, ["create-react-app"])
        XCTAssertEqual(result.records.first?.owner, .yarnClassic(globalDir: global, package: "create-react-app"))
    }

    /// `global-folder` and `prefix` come from `~/.yarnrc`, read as text.
    func testYarnrcGlobalFolderAndPrefix() async throws {
        let fixture = FixtureFileSystem()
        makeGlobalFolder(fixture, "yarn-data/global", packages: [("serve", "14.2.4", ["serve": "build/main.js"])])
        fixture.makeSymlink(at: "yarn-prefix/bin/serve", absoluteTarget: fixture.path("yarn-data/global/node_modules/serve/build/main.js"))
        fixture.makeFile(at: ".yarnrc", contents: """
        # yarn lockfile v1
        global-folder "\(fixture.path("yarn-data/global"))"
        prefix \(fixture.path("yarn-prefix"))
        lastUpdateCheck 1790000000000
        """)
        let result = await YarnClassicEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.records.map(\.packageID), ["serve"])
        XCTAssertEqual(result.records.first?.commands, ["serve"])
        XCTAssertEqual(result.roots.first?.binDirectories, ["\(fixture.path("yarn-prefix"))/bin"])
    }

    func testYarnrcValueNeedsAnAbsolutePath() {
        XCTAssertEqual(YarnClassicEnumerator.yarnrcValue("global-folder", in: "global-folder \"/a/b\"\n"), "/a/b")
        XCTAssertEqual(YarnClassicEnumerator.yarnrcValue("global-folder", in: "--global-folder /a/b\n"), "/a/b")
        XCTAssertNil(YarnClassicEnumerator.yarnrcValue("global-folder", in: "global-folder relative/b\n"))
        XCTAssertNil(YarnClassicEnumerator.yarnrcValue("global-folder", in: "global-folder \"$(id)\"\n"))
    }

    /// Yarn 2+ (a `.yarnrc.yml`, no classic global folder) has no globals → `unavailable`.
    func testYarnBerryIsUnavailable() async {
        let fixture = FixtureFileSystem()
        fixture.makeFile(at: ".yarnrc.yml", contents: "nodeLinker: node-modules\n")
        let result = await YarnClassicEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.status, .unavailable("Yarn 2+ has no global packages"))
    }

    /// D12: yarn on PATH but no global folder → `complete(0)`; neither → `unavailable`.
    func testYarnPresentWithoutGlobalsIsCompleteZero() async {
        let fixture = FixtureFileSystem()
        let none = await YarnClassicEnumerator().enumerate(context(fixture))
        XCTAssertEqual(none.status, .unavailable("Yarn classic isn't installed"))
        fixture.chmod(fixture.makeFile(at: "tools/bin/yarn", contents: "#!/bin/sh\n"), 0o755)
        let present = await YarnClassicEnumerator().enumerate(context(fixture, loginPath: .known([fixture.path("tools/bin")])))
        XCTAssertEqual(present.status, .complete)
        XCTAssertEqual(present.records, [])
    }

    // MARK: bun

    func testBunGlobalRecordsAndLinks() async throws {
        let fixture = FixtureFileSystem()
        makeGlobalFolder(fixture, ".bun/install/global", packages: [("cowsay", "1.6.0", ["cowsay": "cli.js"])])
        fixture.makeSymlink(at: ".bun/bin/cowsay", relativeTarget: "../install/global/node_modules/cowsay/cli.js")
        let bunRoot = NodeFixtures.canonical(fixture, ".bun")

        let result = await BunEnumerator().enumerate(context(fixture, loginPath: .known(["\(bunRoot)/bin"])))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.roots.map(\.activity), [.active])
        XCTAssertEqual(result.records.map(\.packageID), ["cowsay"])
        XCTAssertEqual(result.records.first?.commands, ["cowsay"])
        XCTAssertEqual(result.records.first?.owner, .bun(root: bunRoot, package: "cowsay"))
    }

    /// This Mac's shape: `~/.bun/install/cache` and no global folder → `complete(0)`.
    func testBunWithOnlyACacheIsCompleteZero() async {
        let fixture = FixtureFileSystem()
        fixture.makeDirectory(".bun/install/cache")
        let result = await BunEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.records, [])
        let none = await BunEnumerator().enumerate(context(FixtureFileSystem()))
        XCTAssertEqual(none.status, .unavailable("bun isn't installed"))
    }

    /// D3: a global folder without a `package.json` is `partial`, never "nothing installed".
    func testBunGlobalWithoutManifestIsPartial() async {
        let fixture = FixtureFileSystem()
        fixture.makeDirectory(".bun/install/global/node_modules")
        let global = NodeFixtures.canonical(fixture, ".bun") + "/install/global"
        let result = await BunEnumerator().enumerate(context(fixture))
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .unreadable, rootPath: global, message: "couldn't read \(global)/package.json")]))
    }

    /// Owners that are listed only (D7): pnpm, yarn and bun rows plan as Blocked(noStrategy).
    func testNodeManagerRowsAreListedOnly() async throws {
        let fixture = FixtureFileSystem()
        makeGlobalFolder(fixture, ".bun/install/global", packages: [("cowsay", "1.6.0", [:])])
        let loginPath = LoginPath.known([NodeFixtures.canonical(fixture, ".bun") + "/bin"])
        let result = await BunEnumerator().enumerate(context(fixture, loginPath: loginPath))
        let record = try XCTUnwrap(result.records.first)
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: loginPath)
        let row = try XCTUnwrap(RowBuilder.build(input: .init(results: [result], lookup: lookup)).first { $0.inventory?.packageID == "cowsay" })
        let plan = await StrategyPlanner.checkPlan(config: row, currentVersion: nil, resolve: { _ in record })
        XCTAssertEqual(plan?.blockReason, .noStrategy)
        XCTAssertEqual(plan?.failureMessage, "Listed only")
    }
}
