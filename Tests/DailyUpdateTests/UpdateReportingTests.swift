import XCTest
@testable import DailyUpdate

/// M2.1 (B1-B5): an update must be reported correctly end to end. Fixtures only: every command here is a
/// `touch` or an `echo` in a temp folder, and no test starts a package manager.
@MainActor
final class UpdateReportingTests: XCTestCase {
    func withFixture(_ body: (URL, UserSettingsStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateReporting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigLoader.setAppSupportDirectoryForTesting(root)
        defer {
            ConfigLoader.setAppSupportDirectoryForTesting(TestAppSupport.root)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(root, UserSettingsStore())
    }

    func customItem(id: String, category: ItemCategory, update: String, version: String = "echo 1.0.0", check: String = "echo UPDATE") -> DetectorConfig {
        DetectorConfig(
            id: id, name: id, category: category, description: nil, source: .user,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: version, checkCommand: check, installCommand: nil, updateCommand: update, workingDirectory: nil)
    }

    func testProbeWhichCustomUpdatesWriteHistory() async throws {
        try await withFixture { root, store in
            let markers = ["cli", "repo", "library"].map { root.appendingPathComponent("m-\($0)") }
            store.settings.customItems = [
                customItem(id: "cli", category: .cli, update: "touch \(ShellEscaping.quote(markers[0].path))"),
                customItem(id: "lib", category: .library, update: "touch \(ShellEscaping.quote(markers[2].path))"),
            ]
            let state = AppState(settingsStore: store, discoversOnLaunch: false)
            state.notificationsEnabled = false
            for id in ["cli", "lib"] { state.markCommandReviewed(id: id) }
            await state.recheckItems(ids: ["cli", "lib"])
            for id in ["cli", "lib"] {
                XCTAssertEqual(state.items.first { $0.id == id }?.status, .updateAvailable, id)
                state.setSelection(for: id, selected: true)
            }
            await state.updateSelected(skipDryRun: true, explicitTargetIDs: ["cli", "lib"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: markers[0].path))
            XCTAssertEqual(Set(UpdateHistoryStore.load().map(\.itemID)), ["cli", "lib"], "history: \(UpdateHistoryStore.load().map(\.itemID))")
        }
    }

    // MARK: - B1: a Homebrew upgrade changes the Cellar version folder

    /// A real directory tree with a fake `brew` that behaves like Homebrew for one formula: `info --json=v2`
    /// reports the linked keg and the stable version, and `upgrade --formula` creates the new keg, relinks
    /// `bin/<name>` and removes the old keg (so the versioned Cellar path changes under the owner).
    struct FakeBrew {
        let prefix: URL
        let layout: EcosystemLayout
        var commandPath: String { prefix.appendingPathComponent("bin/gh").path }
        var lookup: CommandPathLookup { CommandPathLookup(candidatesByName: ["gh": [commandPath]], layout: layout) }

        static func make(installed: String, latest: String, keepOldKeg: Bool = false) throws -> FakeBrew {
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            let prefix = home.appendingPathComponent("dailyupdate-test-brew-\(UUID().uuidString)", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try fm.createDirectory(at: prefix.appendingPathComponent("Cellar/gh/\(installed)/bin"), withIntermediateDirectories: true)
            for version in [installed] {
                let exe = prefix.appendingPathComponent("Cellar/gh/\(version)/bin/gh")
                try "#!/bin/sh\necho \"gh version \(version)\"\n".write(to: exe, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            }
            try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("bin/gh").path, withDestinationPath: "../Cellar/gh/\(installed)/bin/gh")
            try latest.write(to: prefix.appendingPathComponent(".latest"), atomically: true, encoding: .utf8)
            let script = """
            #!/bin/bash
            P="$(cd "$(dirname "$0")/.." && pwd -P)"
            echo "$*" >> "$P/calls.log"
            linked() { readlink "$P/bin/gh" | sed -E 's#.*/Cellar/gh/([^/]+)/.*#\\1#'; }
            if [ "$1" = "info" ] && [ "$2" = "--json=v2" ]; then
              echo "{\\"formulae\\":[{\\"name\\":\\"gh\\",\\"versions\\":{\\"stable\\":\\"$(cat "$P/.latest")\\"},\\"revision\\":0,\\"pinned\\":false,\\"linked_keg\\":\\"$(linked)\\"}]}"
              exit 0
            fi
            if [ "$1" = "upgrade" ]; then
              old="$(linked)"; new="$(cat "$P/.latest")"
              mkdir -p "$P/Cellar/gh/$new/bin"
              printf '#!/bin/sh\\necho "gh version %s"\\n' "$new" > "$P/Cellar/gh/$new/bin/gh"; chmod 755 "$P/Cellar/gh/$new/bin/gh"
              ln -sfn "../Cellar/gh/$new/bin/gh" "$P/bin/gh"
              \(keepOldKeg ? ":" : "rm -rf \"$P/Cellar/gh/$old\"")
              exit 0
            fi
            echo "unexpected: $*" >&2; exit 1
            """
            let brew = prefix.appendingPathComponent("bin/brew")
            try script.write(to: brew, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
            let h = home.path
            let layout = EcosystemLayout(
                homeDirectory: h, brewPrefixes: [prefix.path], brewCellars: ["\(prefix.path)/Cellar"], brewCaskrooms: ["\(prefix.path)/Caskroom"],
                claudeNativeRoot: "\(h)/.local/share/claude/versions", opencodeNativeRoot: "\(h)/.opencode/bin",
                cursorAgentNativeRoot: "\(h)/.local/share/cursor-agent/versions", uvToolRoots: ["\(h)/.local/share/uv/tools"],
                pipxVenvRoots: ["\(h)/.local/pipx/venvs"], npmGlobalRoots: ["\(h)/.npm-global"], npmSystemPrefixes: [],
                nvmVersionsRoot: "\(h)/.nvm/versions/node", voltaRoot: "\(h)/.volta", fnmRoots: ["\(h)/.fnm"])
            return FakeBrew(prefix: prefix, layout: layout)
        }
    }

    func brewConfig() -> DetectorConfig {
        DetectorConfig(
            id: "gh-fixture", name: "GitHub CLI", category: .cli, description: nil, schemaVersion: 2, source: .bundled, command: "gh",
            packages: PackageIdentifiers(brew: "gh", brewCask: nil, npm: nil, pipx: nil, uv: nil, cargo: nil),
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil)
    }

    /// The same formula as a DISCOVERED row (what M2 lists), including a catalog entry that discovery joined
    /// to its install (source `.inventory`, with the catalog's `command`): such a row is planned by identity.
    func discoveredBrewConfig(prefix: URL, version: String, joinedToCatalog: Bool) -> DetectorConfig {
        var config = brewConfig()
        if !joinedToCatalog { config = DetectorConfig(id: "inv-brew-gh", name: "gh", category: .cli, description: nil, source: .inventory,
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil) }
        config.source = .inventory
        config.inventory = InventoryIdentity(ecosystem: .brew, packageID: "gh", rootPath: prefix.path,
                                             packageDirectory: prefix.appendingPathComponent("Cellar/gh/\(version)").path)
        return config
    }

    /// The fixture really behaves like a Homebrew upgrade, through the real executor and the real planner.
    func testAHomebrewUpgradeThatMovesTheCellarFolderIsReportedAsUpdated() async throws {
        for joined in [false, true] {
            try await assertBrewUpgradeIsReportedAsUpdated(discovered: true, joinedToCatalog: joined)
        }
        try await assertBrewUpgradeIsReportedAsUpdated(discovered: false, joinedToCatalog: false)
    }

    func assertBrewUpgradeIsReportedAsUpdated(discovered: Bool, joinedToCatalog: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fake = try FakeBrew.make(installed: "1.0.0", latest: "2.0.0")
        defer { try? FileManager.default.removeItem(at: fake.prefix) }
        let config = discovered ? discoveredBrewConfig(prefix: fake.prefix, version: "1.0.0", joinedToCatalog: joinedToCatalog) : brewConfig()
        let label = "discovered=\(discovered) joined=\(joinedToCatalog)"
        var item = config.toUpdateItem()
        item.isInstalled = true
        item.status = .updateAvailable
        let planned = await StrategyPlanner.plannedCommand(config: config, targetVersion: "2.0.0", pathLookup: fake.lookup)
        XCTAssertEqual(planned?.commandSpec.arguments, ["upgrade", "--formula", "gh"], "the planner builds the upgrade for the fixture (\(label))", file: file, line: line)
        item.plannedUpdateCommandSpec = planned?.commandSpec
        item.ownerFingerprint = planned?.fingerprint
        let lookup = fake.lookup
        let runner = UpdateExecutor.Runner(
            runCommand: { _, _, _ in ShellRunner.Result(exitCode: 1, stdout: "", stderr: "not used") },
            runSpec: { spec, timeout in await ShellRunner.run(spec, timeout: timeout) },
            lookupCommand: { _ in lookup })
        let result = await UpdateExecutor.update(item, runner: runner, config: config, pathLookup: lookup)
        XCTAssertEqual(result.status, .updated, "\(label): \(result.status) \(result.message ?? "")", file: file, line: line)
        XCTAssertNil(result.message, label, file: file, line: line)
    }

    // MARK: - CLI fixtures

    /// The real `AppState` behind the CLI protocol, recording which checks the CLI asked for.
    @MainActor
    final class SpyState: CLIRunnerState {
        let state: AppState
        var checkAllCalls = 0
        var checkedIDs: [[String]] = []
        init(_ state: AppState) { self.state = state }
        var items: [UpdateItem] { state.items }
        var confirmBeforeUpdate: Bool { state.confirmBeforeUpdate }
        var selectedActionableItems: [UpdateItem] { state.selectedActionableItems }
        var lastActionOutcomes: [String: ActionOutcome] { state.lastActionOutcomes }
        func checkAll() async { checkAllCalls += 1; await state.recheckItems(ids: state.items.map(\.id)) }
        func checkItems(ids: [String]) async { checkedIDs.append(ids); await state.recheckItems(ids: ids) }
        func selectAllInstallable() { state.selectAllInstallable() }
        func selectAllUpdates(limitTo ids: [String]?) { state.selectAllUpdates(limitTo: ids) }
        func deselectAll(limitTo ids: [String]?) { state.deselectAll(limitTo: ids) }
        func setSelection(for id: String, selected: Bool) { state.setSelection(for: id, selected: selected) }
        func updateSelected(skipDryRun: Bool, explicitTargetIDs: [String]?) async {
            await state.updateSelected(skipDryRun: skipDryRun, explicitTargetIDs: explicitTargetIDs)
        }
    }

    /// A custom item whose version lives in a file, so an update really changes what the check reads.
    func versionedItem(id: String, root: URL, update: String? = nil, category: ItemCategory = .cli, workingDirectory: String? = nil) -> (DetectorConfig, URL) {
        let file = root.appendingPathComponent("version-\(id)")
        try? "1.0.0".write(to: file, atomically: true, encoding: .utf8)
        let q = ShellEscaping.quote(file.path)
        let config = DetectorConfig(
            id: id, name: id, category: category, description: nil, source: .user,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "cat \(q)",
            checkCommand: "[ \"$(cat \(q))\" = \"1.0.0\" ] && echo UPDATE || echo OK",
            installCommand: nil, updateCommand: update ?? "printf 2.0.0 > \(q)", workingDirectory: workingDirectory)
        return (config, file)
    }

    func runUpdate(_ ids: [String], store: UserSettingsStore) async -> (SpyState, [(Int32, [String])]) {
        let state = AppState(settingsStore: store, discoversOnLaunch: false)
        state.notificationsEnabled = false
        for id in ids { state.markCommandReviewed(id: id) }
        let spy = SpyState(state)
        var results: [(Int32, [String])] = []
        for id in ids {
            var output: [String] = []
            let code = await CLIRunner.run(arguments: ["DailyUpdate", "--update", id, "--yes"], state: spy, output: { output.append($0) })
            results.append((code, output))
        }
        return (spy, results)
    }

    // MARK: - B2: --update says what it did

    func testUpdatePrintsThePlanProgressAndTheVerifiedOutcomeAndExitsZero() async throws {
        try await withFixture { root, store in
            let (item, file) = versionedItem(id: "ok", root: root)
            store.settings.customItems = [item]
            let (spy, results) = await runUpdate(["ok"], store: store)
            let (code, output) = try XCTUnwrap(results.first)
            XCTAssertEqual(code, 0, "\(output)")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "2.0.0", "the update really ran")
            XCTAssertEqual(output.first, "Dry-run plan:", "the plan comes first: \(output)")
            XCTAssertTrue(output.contains("Running…"), "\(output)")
            XCTAssertTrue(output.last?.hasPrefix("✓ Updated ok (ok): 1.0.0 → 2.0.0 (verified)") == true, "\(output)")
            XCTAssertEqual(spy.state.lastActionOutcomes["ok"]?.kind, .updated)
        }
    }

    func testAFailingUpdateIsReportedAsFailedAndExitsOne() async throws {
        try await withFixture { root, store in
            let (item, _) = versionedItem(id: "bad", root: root, update: "echo boom >&2; exit 3")
            store.settings.customItems = [item]
            let (_, results) = await runUpdate(["bad"], store: store)
            let (code, output) = try XCTUnwrap(results.first)
            XCTAssertEqual(code, 1, "\(output)")
            XCTAssertTrue(output.last?.hasPrefix("✗ Failed bad (bad): boom") == true, "\(output)")
        }
    }

    func testAnUpdateThatRanButDidNotChangeTheVersionIsNotReportedAsUpdated() async throws {
        try await withFixture { root, store in
            let (item, _) = versionedItem(id: "noop", root: root, update: "true")
            store.settings.customItems = [item]
            let (_, results) = await runUpdate(["noop"], store: store)
            let (code, output) = try XCTUnwrap(results.first)
            XCTAssertEqual(code, 1, "\(output)")
            XCTAssertTrue(output.last?.hasPrefix("✗ Ran, but could not verify noop (noop)") == true, "\(output)")
            XCTAssertFalse(output.contains { $0.hasPrefix("✓") })
        }
    }

    // MARK: - B4: a handoff is not a success

    func testAHandoffToTheAppsUpdaterIsDistinctFromASuccess() async throws {
        try await withFixture { root, store in
            let (item, _) = versionedItem(id: "sparkle", root: root, update: "echo 'IN_APP_UPDATE: Opened Sparkle.app so its built-in updater can finish'")
            store.settings.customItems = [item]
            let (spy, results) = await runUpdate(["sparkle"], store: store)
            let (code, output) = try XCTUnwrap(results.first)
            XCTAssertEqual(code, 3, "handed off is its own exit code: \(output)")
            XCTAssertTrue(output.last?.hasPrefix("↪ Handed off sparkle (sparkle)") == true, "\(output)")
            XCTAssertTrue(output.last?.contains("Nothing is installed yet") == true)
            XCTAssertEqual(spy.state.lastActionOutcomes["sparkle"]?.kind, .handedOff)
            let entry = try XCTUnwrap(UpdateHistoryStore.load().first { $0.itemID == "sparkle" })
            XCTAssertFalse(entry.success, "a handoff is not counted as a success")
            XCTAssertEqual(entry.outcome, "handedOff")
            XCTAssertEqual(entry.fromVersion, entry.toVersion, "nothing changed yet")
        }
    }

    func testExitCodesFollowTheOutcomes() {
        func o(_ kind: ActionOutcomeKind) -> ActionOutcome { ActionOutcome(itemID: "x", name: "x", kind: kind, from: nil, to: nil, message: nil, command: "") }
        XCTAssertEqual(CLIRunner.exitCode(for: [o(.updated)]), 0)
        XCTAssertEqual(CLIRunner.exitCode(for: [o(.updated), o(.handedOff)]), 3)
        XCTAssertEqual(CLIRunner.exitCode(for: [o(.handedOff), o(.failed)]), 1, "a failure wins over a handoff")
        for kind in [ActionOutcomeKind.failed, .failedVerification, .skipped] { XCTAssertEqual(CLIRunner.exitCode(for: [o(kind)]), 1, "\(kind)") }
        XCTAssertFalse(o(.handedOff).isSuccess)
        XCTAssertTrue(o(.updated).isSuccess)
    }

    func testOldHistoryEntriesWithoutAnOutcomeStillLoad() throws {
        let json = #"[{"id":"6C2E2A86-0C75-4A6B-9A63-2F1D9F8B3F11","itemID":"a","itemName":"A","fromVersion":"1","toVersion":"2","date":0,"success":true,"message":null,"command":"x"}]"#
        let entries = try JSONDecoder().decode([UpdateHistoryEntry].self, from: Data(json.utf8))
        XCTAssertNil(entries.first?.outcome)
        XCTAssertNil(entries.first?.outcomeKind)
        XCTAssertEqual(entries.first?.success, true)
    }

    // MARK: - B5: a single-item update checks only that item

    func testASingleItemUpdateChecksOnlyTheTarget() async throws {
        try await withFixture { root, store in
            let (target, _) = versionedItem(id: "target", root: root)
            let sentinel = root.appendingPathComponent("other-was-checked")
            var other = customItem(id: "other", category: .cli, update: "true",
                                   check: "touch \(ShellEscaping.quote(sentinel.path)); echo OK")
            other = DetectorConfig(id: other.id, name: other.name, category: other.category, description: nil, source: .user,
                                   detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                                   versionCommand: "echo 1.0.0", checkCommand: other.checkCommand, installCommand: nil,
                                   updateCommand: "true", workingDirectory: nil)
            store.settings.customItems = [target, other]
            let (spy, results) = await runUpdate(["target"], store: store)
            XCTAssertEqual(results.first?.0, 0, "\(results.first?.1 ?? [])")
            XCTAssertEqual(spy.checkAllCalls, 0, "no full check")
            XCTAssertEqual(spy.checkedIDs, [["target"]])
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path), "another item's check command must not run")
        }
    }

    func testAnUnknownItemIsStillReportedWithoutACheckOfEverything() async throws {
        try await withFixture { root, store in
            let (item, _) = versionedItem(id: "known", root: root)
            store.settings.customItems = [item]
            let state = AppState(settingsStore: store, discoversOnLaunch: false)
            let spy = SpyState(state)
            var output: [String] = []
            let code = await CLIRunner.run(arguments: ["DailyUpdate", "--update", "nope", "--yes"], state: spy, output: { output.append($0) })
            XCTAssertEqual(code, 1)
            XCTAssertTrue(output.first?.hasPrefix("Item ID not found: nope") == true, "\(output)")
            XCTAssertEqual(spy.checkAllCalls, 0)
        }
    }

    // MARK: - B3: the history has an entry for every kind of update

    func testEveryKindOfUpdateWritesAHistoryEntry() async throws {
        try await withFixture { root, store in
            let repo = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            func git(_ args: String...) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-C", repo.path, "-c", "user.email=t@t", "-c", "user.name=t"] + args
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
            }
            git("init", "-q"); git("commit", "-q", "--allow-empty", "-m", "init")
            let kinds: [(String, ItemCategory, String?)] = [("cli", .cli, nil), ("library", .library, nil), ("runtime", .runtime, nil), ("repo", .repo, repo.path)]
            var configs: [DetectorConfig] = []
            for (id, category, cwd) in kinds { configs.append(versionedItem(id: id, root: root, category: category, workingDirectory: cwd).0) }
            store.settings.customItems = configs
            let (_, results) = await runUpdate(kinds.map(\.0), store: store)
            for ((id, _, _), (code, output)) in zip(kinds, results) { XCTAssertEqual(code, 0, "\(id): \(output)") }
            let history = UpdateHistoryStore.load()
            XCTAssertEqual(Set(history.map(\.itemID)), Set(kinds.map(\.0)), "one entry per update: \(history.map(\.itemID))")
            XCTAssertTrue(history.allSatisfy { $0.success && $0.outcome == "updated" })
        }
    }

    // MARK: - B1: what "the same owner" means

    func testSameOwnerIgnoresAMovingPathOnlyForDiscoveredRows() {
        let before = OwnerCandidate(commandPath: "/p/Cellar/gh/1.0.0", resolvedPath: "/p/Cellar/gh/1.0.0/bin/gh", owner: .brewFormula("gh"))
        let after = OwnerCandidate(commandPath: "/p/Cellar/gh/2.0.0", resolvedPath: "/p/Cellar/gh/2.0.0/bin/gh", owner: .brewFormula("gh"))
        var discovered = brewConfig()
        discovered.source = .inventory
        XCTAssertTrue(StrategyPlanner.isSameOwner(config: discovered, before: before, after: after))
        XCTAssertFalse(StrategyPlanner.isSameOwner(config: brewConfig(), before: before, after: after),
                       "a catalog row still requires the same command path")
        let samePath = OwnerCandidate(commandPath: "/p/bin/gh", resolvedPath: "/p/Cellar/gh/2.0.0/bin/gh", owner: .brewFormula("gh"))
        XCTAssertTrue(StrategyPlanner.isSameOwner(config: brewConfig(), before: samePath, after: samePath))
    }

    func testAChangedOwnerStillFailsVerificationForEveryKindOfRow() {
        let brew = OwnerCandidate(commandPath: "/p/bin/gh", resolvedPath: "/p/Cellar/gh/1/bin/gh", owner: .brewFormula("gh"))
        let npm = OwnerCandidate(commandPath: "/p/bin/gh", resolvedPath: "/n/lib/node_modules/gh/bin/gh", owner: .npm(prefix: "/n", package: "gh"))
        let otherFormula = OwnerCandidate(commandPath: "/p/bin/gh", resolvedPath: "/p/Cellar/other/1/bin/gh", owner: .brewFormula("other"))
        var discovered = brewConfig()
        discovered.source = .inventory
        for config in [brewConfig(), discovered] {
            XCTAssertFalse(StrategyPlanner.isSameOwner(config: config, before: brew, after: npm), "another package manager")
            XCTAssertFalse(StrategyPlanner.isSameOwner(config: config, before: brew, after: otherFormula), "another formula")
        }
    }

    // MARK: - M2.1: the Homebrew snapshot in checks

    func brewCalls(_ fake: FakeBrew) -> [String] {
        ((try? String(contentsOf: fake.prefix.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func snapshot(for fake: FakeBrew, installed: String, latest: String) -> BrewInfoProvider {
        let record = BrewFormulaRecord(
            name: "gh", fullName: "gh", tap: "homebrew/core", installedVersions: [installed], linkedVersion: installed, latestVersion: latest,
            pinned: false, kegOnly: false, installedOnRequest: true, installedAsDependency: false)
        let info = BrewPrefixInfo(prefix: fake.prefix.path, source: .enricher, formulae: ["gh": record], casks: [:])
        return BrewInfoProvider(prefixes: [fake.prefix.path: info], cacheDirectory: "/c", cacheModifiedAt: nil)
    }

    func testACheckWithTheDiscoverySnapshotDoesNotStartBrew() async throws {
        let fake = try FakeBrew.make(installed: "1.0.0", latest: "2.0.0")
        defer { try? FileManager.default.removeItem(at: fake.prefix) }
        let withSnapshot = await UpdateCheckService.check(
            brewConfig(), installed: true, pathLookup: fake.lookup, brewInfo: snapshot(for: fake, installed: "1.0.0", latest: "2.0.0"))
        XCTAssertEqual(withSnapshot.status, .updateAvailable)
        XCTAssertEqual(withSnapshot.latestVersion, "2.0.0")
        XCTAssertEqual(brewCalls(fake), [], "no `brew info` per item when the snapshot has the formula")
        let without = await UpdateCheckService.check(brewConfig(), installed: true, pathLookup: fake.lookup)
        XCTAssertEqual(without.status, .updateAvailable)
        XCTAssertTrue(brewCalls(fake).contains { $0.hasPrefix("info --json=v2") }, "without it brew is asked, as before")
    }

    /// A snapshot is old the moment something is updated. The verification after an update never reads it.
    func testTheVerificationAfterAnUpdateIgnoresTheSnapshot() async throws {
        let fake = try FakeBrew.make(installed: "1.0.0", latest: "2.0.0")
        defer { try? FileManager.default.removeItem(at: fake.prefix) }
        // A stale snapshot that still says 1.0.0 is installed and 2.0.0 is the latest.
        let stale = snapshot(for: fake, installed: "1.0.0", latest: "2.0.0")
        let config = discoveredBrewConfig(prefix: fake.prefix, version: "1.0.0", joinedToCatalog: false)
        var item = config.toUpdateItem()
        item.isInstalled = true
        item.status = .updateAvailable
        let planned = await StrategyPlanner.plannedCommand(config: config, targetVersion: "2.0.0", pathLookup: fake.lookup, services: .live(brewInfo: stale))
        item.plannedUpdateCommandSpec = planned?.commandSpec
        let lookup = fake.lookup
        let runner = UpdateExecutor.Runner(
            runCommand: { _, _, _ in ShellRunner.Result(exitCode: 1, stdout: "", stderr: "") },
            runSpec: { spec, timeout in await ShellRunner.run(spec, timeout: timeout) }, lookupCommand: { _ in lookup })
        let result = await UpdateExecutor.update(item, runner: runner, config: config, pathLookup: lookup)
        XCTAssertEqual(result.status, .updated, "\(result.status) \(result.message ?? "")")
        XCTAssertTrue(brewCalls(fake).contains { $0.hasPrefix("info --json=v2") }, "the verification asked brew, not a snapshot")
    }

    func testTheSnapshotIsUsedOnlyWhileFreshAndDroppedAfterAnUpdate() async throws {
        let provider = BrewInfoProvider(prefixes: [:], cacheDirectory: "/c", cacheModifiedAt: nil)
        let store = UserSettingsStore()
        let state = AppState(settingsStore: store, discoverer: { _, _ in
            DiscoveryRunResult(
                results: [EnumerationResult(ecosystem: .brew, status: .complete, brewInfo: provider)],
                lookup: CommandPathLookup(candidatesByName: [:], loginPath: .known([])),
                assembly: RowBuilder.Output(rows: [], competing: [:], shadowedByUnownedFiles: [], inactiveInstalls: []), elapsedMs: 1)
        }, discoversOnLaunch: false)
        XCTAssertNil(state.freshBrewSnapshot(), "no discovery yet")
        await state.runDiscovery()
        XCTAssertEqual(state.freshBrewSnapshot(), provider)
        state.invalidateDiscoverySnapshot()
        XCTAssertNil(state.freshBrewSnapshot(), "an update makes the snapshot old")
        await state.runDiscovery()
        state.settingsStore.settings.discoverInstalledTools = false
        XCTAssertNil(state.freshBrewSnapshot(), "with discovery off nothing is reused")
    }

    // MARK: - Review additions

    /// `ResolvedOwner.brewFormula` holds only the formula name: the prefix has to be compared separately.
    func testTheSameFormulaUnderAnotherHomebrewPrefixIsNotTheSameOwner() {
        func candidate(_ prefix: String, _ version: String, cask: Bool = false) -> OwnerCandidate {
            let path = "\(prefix)/\(cask ? "Caskroom" : "Cellar")/gh/\(version)/bin/gh"
            return OwnerCandidate(commandPath: path, resolvedPath: path, owner: cask ? .brewCask("gh") : .brewFormula("gh"))
        }
        var discovered = brewConfig()
        discovered.source = .inventory
        for config in [brewConfig(), discovered] {
            XCTAssertFalse(StrategyPlanner.isSameOwner(config: config, before: candidate("/opt/homebrew", "1"), after: candidate("/usr/local", "2")),
                           "another prefix: \(config.source.map { "\($0)" } ?? "")")
            XCTAssertFalse(StrategyPlanner.isSameOwner(config: config, before: candidate("/opt/homebrew", "1", cask: true), after: candidate("/usr/local", "1", cask: true)))
        }
        XCTAssertTrue(StrategyPlanner.isSameOwner(config: discovered, before: candidate("/opt/homebrew", "1"), after: candidate("/opt/homebrew", "2")),
                      "the same prefix, a new version folder")
        XCTAssertEqual(StrategyPlanner.brewPrefix(of: "/opt/homebrew/Cellar/gh/2.1/bin/gh"), "/opt/homebrew")
        XCTAssertNil(StrategyPlanner.brewPrefix(of: "/usr/bin/gh"))
    }

    func testAFailedSingleItemUpdateHintsAtCheck() async throws {
        try await withFixture { root, store in
            let (item, _) = versionedItem(id: "known", root: root)
            store.settings.customItems = [item]
            let state = AppState(settingsStore: store, discoversOnLaunch: false)
            state.markCommandReviewed(id: "known")
            let spy = SpyState(state)
            var missing: [String] = []
            _ = await CLIRunner.run(arguments: ["DailyUpdate", "--update", "nope", "--yes"], state: spy, output: { missing.append($0) })
            XCTAssertEqual(missing.last, "Run --check to list all item IDs.", "\(missing)")
            // An item that exists but has no update is "not available": same hint.
            var notAvailable: [String] = []
            _ = await CLIRunner.run(arguments: ["DailyUpdate", "--install", "known", "--yes"], state: spy, output: { notAvailable.append($0) })
            XCTAssertEqual(notAvailable.last, "Run --check to list all item IDs.", "\(notAvailable)")
        }
    }

    /// pip's version command prints `pip 26.3 from /Library/... (python 3.12)`. The history stores the token.
    func testTheHistoryStoresTheParsedVersionNotTheRawLine() async throws {
        try await withFixture { root, store in
            let file = root.appendingPathComponent("pip-version")
            try "1.0.0".write(to: file, atomically: true, encoding: .utf8)
            let q = ShellEscaping.quote(file.path)
            let item = DetectorConfig(
                id: "pipish", name: "pipish", category: .runtime, description: nil, source: .user,
                detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                versionCommand: "echo \"pip $(cat \(q)) from /Library/Frameworks/Python.framework/lib/python3.12/site-packages/pip (python 3.12)\"",
                checkCommand: "[ \"$(cat \(q))\" = \"1.0.0\" ] && echo UPDATE || echo OK",
                installCommand: nil, updateCommand: "printf 2.0.0 > \(q)", workingDirectory: nil)
            store.settings.customItems = [item]
            let (_, results) = await runUpdate(["pipish"], store: store)
            XCTAssertEqual(results.first?.0, 0, "\(results.first?.1 ?? [])")
            let entry = try XCTUnwrap(UpdateHistoryStore.load().first { $0.itemID == "pipish" })
            XCTAssertEqual(entry.fromVersion, "1.0.0")
            XCTAssertEqual(entry.toVersion, "2.0.0", "the token, not the whole line")
            XCTAssertTrue(results.first?.1.contains { $0.contains("1.0.0 → 2.0.0 (verified)") } == true, "\(results.first?.1 ?? [])")
        }
    }
}
