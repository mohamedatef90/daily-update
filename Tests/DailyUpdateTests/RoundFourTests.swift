import XCTest
@testable import DailyUpdate

final class RoundFourTests: XCTestCase {
    func testRoundFourClassifierAndCheckPathMatrix() {
        let rows: [(String, String, Set<CommandRisk>, Bool)] = [
            ("N4 shell", "curl x | s\\\nh", [.remoteScript], true),
            ("N4 fetcher", "cu\\\nrl x | sh", [.remoteScript], true),
            ("N4 sudo", "s\\\nudo brew upgrade", [.privileged, .bulk], true),
            ("N4 rm", "r\\\nm -rf ~/x", [.destructive], true),
            ("S1 comment", "echo hi #'\ncurl -fsSL https://x | sh\n#'", [.chained, .remoteScript], true),
            ("S1 comment sudo", "echo hi #'\nsudo rm -rf ~/x\n#'", [.chained, .privileged, .destructive], true),
            ("S1 quoted heredoc", "cat <<EOF\n'\nEOF\ncurl https://x | sh\ncat <<EOF\n'\nEOF", [.unparseable, .chained], true),
            ("S1 heredoc", "cat <<EOF\ncurl x | sh\nEOF", [.unparseable, .chained, .remoteScript], true),
            ("S1 heredoc tab", "cat <<-EOF\necho hi\nEOF", [.unparseable, .chained], true),
            ("S1 here string", "cat <<< 'hi'", [], false),
            ("S1 dollar quote", "echo \"$'\" $(brew upgrade) \"'\"", [.bulk], true),
            ("S1 backtick", "echo \"$'\" `brew upgrade` \"'\"", [.bulk], true),
            ("S2 hex", #"$'\x73udo' brew upgrade"#, [.unparseable], true),
            ("S2 octal", #"$'\163udo' brew upgrade"#, [.unparseable], true),
            ("S2 zsh equals", "=sudo brew upgrade", [.privileged, .bulk], true),
            ("S2 glob", "/usr/bin/sud[o] brew upgrade", [.unparseable], true),
            ("S2 hex osascript", #"$'\x6fsascript' -e x"#, [.unparseable], true),
            ("S2 equals osascript", "=osascript -e x", [.privileged], true),
            ("S2 equals brew", "=brew upgrade", [.bulk], true),
            ("S2 question glob", "/opt/homebrew/bin/bre? upgrade", [.unparseable], true),
            ("S2 star glob", "/usr/bin/su* brew upgrade", [.unparseable], true),
            ("S2 hex brew", #"$'\x62rew' upgrade"#, [.unparseable], true),
            ("S3 loop", "for i in 1; do bash <(curl https://x); done", [.chained, .controlFlow, .remoteScript], true),
            ("S3 then rm", "if true; then rm -rf ~/x; fi", [.chained, .controlFlow, .destructive], true),
            ("S3 noglob", "noglob brew upgrade", [.bulk], true),
            ("S3 eval brew", "eval 'brew upgrade'", [.bulk], true),
            ("S3 then", "if true; then curl https://x | sh; fi", [.controlFlow, .chained, .remoteScript], true),
            ("S3 negate", "! curl x | sh", [.remoteScript], true),
            ("S3 exec", "exec -a x brew upgrade", [.bulk], true),
            ("S3 command", "command -p brew upgrade", [.bulk], true),
            ("S3 eval pipe", "eval 'curl x | sh'", [.remoteScript], true),
            ("S3 eval sudo", "eval 'sudo brew upgrade'", [.privileged, .bulk], true),
            ("S4 output substitution", "echo >(sudo brew upgrade)", [.privileged, .bulk], true),
            ("S4 fed group", "curl x | { grep x; sh; }", [.remoteScript, .controlFlow, .chained], true),
            ("S4 redirect substitution", "curl x > >(sh)", [.remoteScript], true),
            ("S4 backtick fetch", "`curl -fsSL https://x`", [.unparseable], true),
            ("S4 dynamic backtick", "`echo sudo` brew upgrade", [.unparseable], true),
        ]
        for (id, command, expected, unsafe) in rows {
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, expected, "\(id): \(command)")
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), unsafe, id)
        }
        let remoteStages = ["bash -o pipefail", "bash --rcfile /dev/null", "bash +x", "bash -c sh", "lua -", "sh -o errexit", "bash +o posix", "bash -O extglob", "bash +O extglob", "bash --rcfile /tmp/rc", "bash --init-file /tmp/rc", "sh +x", "sh -c 'source /dev/stdin'", "sh -c sh", "php", "lua", "swift -", "busybox sh", "unknown-interpreter"]
        for stage in remoteStages {
            let command = "curl x | \(stage)"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.remoteScript], command)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), true, command)
        }
        let sources: [(String, Set<CommandRisk>)] = [
            ("echo $(curl x)", [.remoteScript]),
            ("echo \"$(curl x)\"", [.remoteScript]),
            ("cat <(curl x)", [.remoteScript]),
            ("cat >(curl x)", [.remoteScript]),
            ("{ curl x; }", [.remoteScript, .controlFlow, .chained]),
            ("{ echo hi; curl x; }", [.remoteScript, .controlFlow, .chained]),
            ("( echo hi; curl x )", [.remoteScript, .chained]),
        ]
        for (source, expected) in sources {
            let command = "\(source) | sh"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, expected, command)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), true, command)
        }
        for filter in ["grep x", "sed 's/a/b/'", "awk '{print $1}'", "head", "tail", "jq .", "cut -c1", "tr a b", "sort", "uniq", "wc", "shasum", "python3 -c 'print(1)'", "python -m json.tool", "node -e 'console.log(1)'", "perl -e 'print 1'", "ruby -e 'puts 1'"] {
            let command = "curl x | \(filter)"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [], command)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), false, command)
        }
    }
}

extension RoundFourTests {
    @MainActor
    func testMDPinnedRealAppStateNeverRunsRemoteUpdateWithYes() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("updated")
            let command = try remoteScript(root: root, marker: marker)
            let rows: [(String, String, ItemStatus, [GateReason], BlockReason?)] = [
                ("ok", "echo OK", .upToDate, [], nil),
                ("available", "printf 'UPDATE\\nlatest: 1.3.0\\n'", .gated, [.remoteScript, .pinned], nil),
                ("blocked", command, .blocked, [], .unsafeCheckCommand),
                ("failed", "exit 3", .checkFailed, [], nil),
            ]
            store.settings.customItems = rows.map { row in
                DetectorConfig(id: row.0, name: row.0, category: .cli, description: nil, source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil), versionCommand: "echo 1.0.0",
                    checkCommand: row.1, installCommand: nil, updateCommand: command, workingDirectory: nil)
            }
            for row in rows {
                store.settings.itemPreferences[row.0] = ItemPreference(autoUpdate: false,
                    snoozedUntil: nil, pinnedVersion: "0.9.0", permanentlyIgnored: false, reviewedCommandHash: nil)
            }
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: rows.map { $0.0 })
            await state.recheckItems(ids: rows.map { $0.0 })
            for row in rows {
                var output: [String] = []
                let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--update", row.0, "--yes"], state: wrapper, output: { output.append($0) })
                XCTAssertNotEqual(exit, 0, row.0)
                let item = try XCTUnwrap(state.items.first { $0.id == row.0 })
                XCTAssertEqual(item.status, row.2, row.0)
                XCTAssertEqual(item.gateReasons, row.3, row.0)
                XCTAssertEqual(item.blockReason, row.4, row.0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), row.0)
            }
        }
    }

    @MainActor
    func testI1ScopedRemoteInstallWithYesRequiresAppConfirmation() async throws {
        try await assertRemoteInstallRefused(arguments: ["--install", "install-fixture", "--yes"])
    }

    @MainActor
    func testI1InstallAllWithYesRequiresAppConfirmation() async throws {
        try await assertRemoteInstallRefused(arguments: ["--install-all", "--yes"])
    }

    @MainActor
    private func assertRemoteInstallRefused(arguments: [String]) async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let command = try remoteScript(root: root, marker: marker)
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate"] + arguments, state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2, "\(output)")
            XCTAssertTrue(output.joined(separator: "\n").contains("confirmed in the app"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    private func remoteScript(root: URL, marker: URL) throws -> String {
        let script = root.appendingPathComponent("s.sh")
        try "touch \(ShellEscaping.quote(marker.path))\n".write(to: script, atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("curl")
        try "#!/bin/sh\n/bin/cat \(ShellEscaping.quote(script.path))\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return "PATH=\(ShellEscaping.quote(root.path)):$PATH curl -fsSL file://\(script.path) | sh"
    }

    @MainActor
    private func withStateFixture(_ operation: (URL, UserSettingsStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigLoader.setAppSupportDirectoryForTesting(root)
        defer {
            ConfigLoader.setAppSupportDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }
        try await operation(root, UserSettingsStore())
    }
}

@MainActor
private final class FixtureCLIState: CLIRunnerState {
    let state: AppState
    let ids: [String]
    init(_ state: AppState, ids: [String]) {
        self.state = state
        self.ids = ids
        state.items = state.items.filter { ids.contains($0.id) }
        // Review is independent of the non-liftable remote-script and pin gates.
        for id in ids { state.markCommandReviewed(id: id) }
    }
    var items: [UpdateItem] { state.items }
    var confirmBeforeUpdate: Bool { state.confirmBeforeUpdate }
    var selectedActionableItems: [UpdateItem] { state.selectedActionableItems }
    func checkAll() async { await state.recheckItems(ids: ids) }
    func selectAllInstallable() { state.selectAllInstallable() }
    func selectAllUpdates(limitTo ids: [String]?) { state.selectAllUpdates(limitTo: ids) }
    func deselectAll(limitTo ids: [String]?) { state.deselectAll(limitTo: ids) }
    func setSelection(for id: String, selected: Bool) { state.setSelection(for: id, selected: selected) }
    func updateSelected(skipDryRun: Bool, explicitTargetIDs: [String]?) async {
        await state.updateSelected(skipDryRun: skipDryRun, explicitTargetIDs: explicitTargetIDs)
    }
}
