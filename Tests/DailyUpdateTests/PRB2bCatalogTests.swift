import XCTest
@testable import DailyUpdate

/// PR-B2b: the catalog and strategy items deferred from Phase 1 (TIF-10 items 12 and 13).
/// Only stubs run: a stub `brew`, a stub `opencode` and a stub `cursor-agent`, and the
/// release lookups are a planner input, so nothing is fetched and nothing is upgraded.
final class PRB2bCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".dailyupdate-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var layout: EcosystemLayout { .fixture(home: root.path) }

    private func write(_ contents: String, to url: URL, mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func config(id: String, command: String, packages: PackageIdentifiers?, selfUpdater: String? = nil) -> DetectorConfig {
        DetectorConfig(id: id, name: id, category: .cli, description: nil, schemaVersion: 2, source: .bundled,
            command: command, packages: packages, selfUpdater: selfUpdater,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo legacy", checkCommand: "echo OK", installCommand: nil,
            updateCommand: "echo legacy-update", workingDirectory: nil)
    }

    // MARK: - Item 12: G3, casks that update themselves

    /// A cask app in `Caskroom/<token>/<recorded>/<name>.app`, a bundle version, and a stub `brew`
    /// whose `info --json=v2 --cask` reports `version` and `auto_updates`. Returns the binary.
    private func makeCask(token: String, recorded: String, bundle: String?, latest: String, autoUpdates: Bool) throws -> URL {
        let brewPrefix = root.appendingPathComponent("opt/homebrew")
        let app = brewPrefix.appendingPathComponent("Caskroom/\(token)/\(recorded)/Tool.app")
        let binary = app.appendingPathComponent("Contents/MacOS/tool")
        try write("#!/bin/sh\nexit 0\n", to: binary)
        if let bundle {
            let plist: NSDictionary = ["CFBundleShortVersionString": bundle]
            plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        }
        let json = #"{"casks":[{"token":"\#(token)","version":"\#(latest)","auto_updates":\#(autoUpdates)}]}"#
        let log = root.appendingPathComponent("brew-calls")
        try write("""
        #!/bin/sh
        echo "$*" >> \(ShellEscaping.quote(log.path))
        if [ "$1" = info ]; then printf '%s' \(ShellEscaping.quote(json)); exit 0; fi
        exit 2
        """, to: brewPrefix.appendingPathComponent("bin/brew"))
        return binary
    }

    private func caskCheck(token: String, binary: URL) async -> CheckResult {
        let config = config(id: "cask-\(token)", command: "tool", packages: PackageIdentifiers(brewCask: token))
        let lookup = CommandPathLookup(candidatesByName: ["tool": [binary.path]], layout: layout)
        return await UpdateCheckService.check(config, installed: true, pathLookup: lookup)
    }

    private func brewCalls() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("brew-calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func testParsesCaskVersionAndAutoUpdates() {
        let info = StrategyPlanner.parseBrewCaskInfo(from: #"{"casks":[{"version":"2.0.0,99","auto_updates":true}]}"#)
        XCTAssertEqual(info?.version, "2.0.0")
        XCTAssertEqual(info?.autoUpdates, true)
        let plain = StrategyPlanner.parseBrewCaskInfo(from: #"{"casks":[{"version":"1.8.0","auto_updates":null}]}"#)
        XCTAssertEqual(plain?.version, "1.8.0")
        XCTAssertEqual(plain?.autoUpdates, false)
        XCTAssertNil(StrategyPlanner.parseBrewCaskInfo(from: #"{"casks":[]}"#))
    }

    /// The app updated itself past what brew recorded: the bundle is what runs, so it is current.
    func testSelfUpdatedCaskAppIsUpToDate() async throws {
        let binary = try makeCask(token: "tool", recorded: "1.0.0", bundle: "2.0.0", latest: "2.0.0", autoUpdates: true)
        let check = await caskCheck(token: "tool", binary: binary)
        XCTAssertEqual(check.status, .upToDate)
        XCTAssertEqual(check.currentVersion, "2.0.0")
        XCTAssertEqual(check.latestVersion, "2.0.0")
        XCTAssertEqual(try brewCalls(), ["info --json=v2 --cask tool"])
    }

    /// A self-updating cask that is behind still shows, as `brew outdated --greedy` would, and
    /// the plan is a named `brew upgrade --cask`, which Homebrew always evaluates greedily.
    func testSelfUpdatingCaskBehindLatestShowsWithANamedUpgrade() async throws {
        let binary = try makeCask(token: "tool", recorded: "1.0.0", bundle: "1.5.0", latest: "2.0.0", autoUpdates: true)
        let check = await caskCheck(token: "tool", binary: binary)
        XCTAssertEqual(check.status, .updateAvailable)
        XCTAssertEqual(check.currentVersion, "1.5.0")
        XCTAssertEqual(check.latestVersion, "2.0.0")
        XCTAssertEqual(check.plannedUpdateCommandSpec, CommandSpec(
            executablePath: root.appendingPathComponent("opt/homebrew/bin/brew").path, arguments: ["upgrade", "--cask", "tool"]))
        XCTAssertEqual(try brewCalls(), ["info --json=v2 --cask tool"])
    }

    /// For a self-updating cask, the Caskroom directory is what brew installed, not what runs.
    func testSelfUpdatingCaskWithoutABundleVersionFailsInsteadOfUsingTheCaskroomVersion() async throws {
        let binary = try makeCask(token: "tool", recorded: "1.0.0", bundle: nil, latest: "2.0.0", autoUpdates: true)
        let check = await caskCheck(token: "tool", binary: binary)
        XCTAssertEqual(check.status, .checkFailed)
        XCTAssertNil(check.currentVersion)
        XCTAssertEqual(check.message, "Could not read installed version")
        XCTAssertNil(check.plannedUpdateCommandSpec)
    }

    func testCaskThatDoesNotSelfUpdateStillUsesTheCaskroomVersion() async throws {
        let binary = try makeCask(token: "tool", recorded: "1.0.0", bundle: nil, latest: "2.0.0", autoUpdates: false)
        let check = await caskCheck(token: "tool", binary: binary)
        XCTAssertEqual(check.status, .updateAvailable)
        XCTAssertEqual(check.currentVersion, "1.0.0")
        XCTAssertEqual(check.latestVersion, "2.0.0")
        // One `brew info` per plan, although both the current and the latest version need it.
        XCTAssertEqual(try brewCalls(), ["info --json=v2 --cask tool"])
    }

    // MARK: - Item 13: opencode and cursor-agent

    private func recordingFetcher(_ payloads: [String: String?]) -> (StrategyPlanner.ReleaseFetcher, () -> [CommandSpec]) {
        var requests: [CommandSpec] = []
        let fetcher: StrategyPlanner.ReleaseFetcher = { spec in
            requests.append(spec)
            return payloads[spec.arguments.last ?? ""] ?? nil
        }
        return (fetcher, { requests })
    }

    private func makeOpenCode(version: String) throws -> (binary: URL, marker: URL) {
        let binary = root.appendingPathComponent(".opencode/bin/opencode")
        let marker = root.appendingPathComponent("opencode-ran")
        try write("""
        #!/bin/sh
        if [ "$1" = --version ]; then echo \(version); exit 0; fi
        /usr/bin/touch \(ShellEscaping.quote(marker.path))
        """, to: binary)
        return (binary, marker)
    }

    private var openCodeConfig: DetectorConfig {
        config(id: "opencode", command: "opencode", packages: PackageIdentifiers(brew: "opencode", npm: "opencode-ai"),
            selfUpdater: "opencode")
    }

    func testOpenCodeNativeInstallIsItsOwnOwner() throws {
        let (binary, _) = try makeOpenCode(version: "1.18.32")
        let resolution = OwnerResolver.resolve(commandName: "opencode", candidatePaths: [binary.path], layout: layout)
        XCTAssertEqual(resolution.active?.owner, .nativeInstaller(.opencode))
    }

    func testOpenCodeBehindLatestPlansAPinnedSelfUpgrade() async throws {
        let (binary, marker) = try makeOpenCode(version: "1.18.32")
        let url = StrategyPlanner.openCodeLatestReleaseRequest.arguments.last!
        let (fetcher, requests) = recordingFetcher([url: #"{"tag_name":"v1.18.33","name":"v1.18.33"}"#])
        let lookup = CommandPathLookup(candidatesByName: ["opencode": [binary.path]], layout: layout)
        let check = await UpdateCheckService.check(openCodeConfig, installed: true, pathLookup: lookup, fetchRelease: fetcher)
        XCTAssertEqual(check.status, .updateAvailable)
        XCTAssertEqual(check.currentVersion, "1.18.32")
        XCTAssertEqual(check.latestVersion, "1.18.33")
        XCTAssertEqual(check.plannedUpdateCommandSpec, CommandSpec(executablePath: binary.path,
            arguments: ["upgrade", "1.18.33", "--method", "curl"]))
        XCTAssertEqual(requests(), [StrategyPlanner.openCodeLatestReleaseRequest])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOpenCodeAtLatestIsUpToDate() async throws {
        let (binary, marker) = try makeOpenCode(version: "v1.18.33")
        let url = StrategyPlanner.openCodeLatestReleaseRequest.arguments.last!
        let (fetcher, _) = recordingFetcher([url: #"{"tag_name":"v1.18.33"}"#])
        let lookup = CommandPathLookup(candidatesByName: ["opencode": [binary.path]], layout: layout)
        let check = await UpdateCheckService.check(openCodeConfig, installed: true, pathLookup: lookup, fetchRelease: fetcher)
        XCTAssertEqual(check.status, .upToDate)
        XCTAssertEqual(check.currentVersion, "1.18.33")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOpenCodeReleaseThatIsNotStrictSemverFails() async throws {
        let (binary, _) = try makeOpenCode(version: "1.18.32")
        let url = StrategyPlanner.openCodeLatestReleaseRequest.arguments.last!
        let lookup = CommandPathLookup(candidatesByName: ["opencode": [binary.path]], layout: layout)
        let (nightly, _) = recordingFetcher([url: #"{"tag_name":"nightly"}"#])
        let bad = await UpdateCheckService.check(openCodeConfig, installed: true, pathLookup: lookup, fetchRelease: nightly)
        XCTAssertEqual(bad.status, .checkFailed)
        XCTAssertEqual(bad.message, "OpenCode release tag is not strict semver: nightly")
        let (offline, _) = recordingFetcher([:])
        let failed = await UpdateCheckService.check(openCodeConfig, installed: true, pathLookup: lookup, fetchRelease: offline)
        XCTAssertEqual(failed.status, .checkFailed)
        XCTAssertEqual(failed.message, "Could not determine latest version")
    }

    func testOpenCodeFromNpmUsesTheNpmStrategyAndOtherPackagesMismatch() throws {
        let prefix = root.appendingPathComponent(".nvm/versions/node/v24.0.0")
        try write("#!/bin/sh\n", to: prefix.appendingPathComponent("bin/node"))
        try write("#!/bin/sh\n", to: prefix.appendingPathComponent("bin/npm"))
        let package = prefix.appendingPathComponent("lib/node_modules/opencode-ai")
        try write(#"{"name":"opencode-ai","version":"1.18.32"}"#, to: package.appendingPathComponent("package.json"), mode: 0o644)
        try write("#!/bin/sh\n", to: package.appendingPathComponent("bin/opencode"))
        let resolution = OwnerResolver.resolve(commandName: "opencode",
            candidatePaths: [package.appendingPathComponent("bin/opencode").path], layout: layout)
        XCTAssertEqual(resolution.active?.owner, .npm(prefix: prefix.path, package: "opencode-ai"))
        XCTAssertEqual(StrategyPlanner.commandForResolvedOwner(config: openCodeConfig, resolution: resolution,
            targetVersion: "1.18.33", layout: layout)?.arguments,
            ["install", "-g", "--prefix", prefix.path, "opencode-ai@1.18.33"])
        var other = openCodeConfig
        other.packages = PackageIdentifiers(npm: "opencode")
        XCTAssertNil(StrategyPlanner.commandForResolvedOwner(config: other, resolution: resolution,
            targetVersion: "1.18.33", layout: layout))
    }

    private func makeCursorAgent(version: String) throws -> (link: URL, marker: URL) {
        let target = root.appendingPathComponent(".local/share/cursor-agent/versions/\(version)/cursor-agent")
        let marker = root.appendingPathComponent("cursor-ran")
        try write("#!/bin/sh\n/usr/bin/touch \(ShellEscaping.quote(marker.path))\n", to: target)
        let link = root.appendingPathComponent(".local/bin/cursor-agent")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        return (link, marker)
    }

    private var cursorConfig: DetectorConfig {
        config(id: "cursor-agent", command: "cursor-agent", packages: PackageIdentifiers(), selfUpdater: "cursorAgent")
    }

    private func installer(_ version: String) -> String {
        """
        FINAL_DIR="$HOME/.local/share/cursor-agent/versions/\(version)"
        DOWNLOAD_URL="https://downloads.cursor.com/lab/\(version)/${OS}/${ARCH}/agent-cli-package.tar.gz"
        """
    }

    func testCursorAgentNativeInstallIsItsOwnOwner() throws {
        let (link, _) = try makeCursorAgent(version: "2026.09.23-86fc751")
        let resolution = OwnerResolver.resolve(commandName: "cursor-agent", candidatePaths: [link.path], layout: layout)
        XCTAssertEqual(resolution.active?.owner, .nativeInstaller(.cursorAgent))
    }

    func testCursorAgentBehindLatestPlansItsOwnUpdate() async throws {
        let (link, marker) = try makeCursorAgent(version: "2026.09.23-86fc751")
        let url = StrategyPlanner.cursorAgentInstallerRequest.arguments.last!
        let (fetcher, requests) = recordingFetcher([url: installer("2026.09.25-1a2b3c4")])
        let lookup = CommandPathLookup(candidatesByName: ["cursor-agent": [link.path]], layout: layout)
        let check = await UpdateCheckService.check(cursorConfig, installed: true, pathLookup: lookup, fetchRelease: fetcher)
        XCTAssertEqual(check.status, .updateAvailable)
        XCTAssertEqual(check.currentVersion, "2026.09.23-86fc751")
        XCTAssertEqual(check.latestVersion, "2026.09.25-1a2b3c4")
        XCTAssertEqual(check.plannedUpdateCommandSpec, CommandSpec(executablePath: link.path, arguments: ["update"]))
        XCTAssertEqual(requests(), [StrategyPlanner.cursorAgentInstallerRequest])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCursorAgentAtLatestIsUpToDate() async throws {
        let (link, _) = try makeCursorAgent(version: "2026.09.23-86fc751")
        let url = StrategyPlanner.cursorAgentInstallerRequest.arguments.last!
        let (fetcher, _) = recordingFetcher([url: installer("2026.09.23-86fc751")])
        let lookup = CommandPathLookup(candidatesByName: ["cursor-agent": [link.path]], layout: layout)
        let check = await UpdateCheckService.check(cursorConfig, installed: true, pathLookup: lookup, fetchRelease: fetcher)
        XCTAssertEqual(check.status, .upToDate)
    }

    /// Two builds on the same date can't be ordered by their hashes, so the check fails closed.
    func testCursorAgentSameDateDifferentBuildFails() async throws {
        let (link, _) = try makeCursorAgent(version: "2026.09.23-86fc751")
        let url = StrategyPlanner.cursorAgentInstallerRequest.arguments.last!
        let lookup = CommandPathLookup(candidatesByName: ["cursor-agent": [link.path]], layout: layout)
        let (sameDate, _) = recordingFetcher([url: installer("2026.09.23-0000000")])
        let check = await UpdateCheckService.check(cursorConfig, installed: true, pathLookup: lookup, fetchRelease: sameDate)
        XCTAssertEqual(check.status, .checkFailed)
        XCTAssertEqual(check.message, "Cursor Agent build 2026.09.23-0000000 can't be ordered against 2026.09.23-86fc751")
        let (garbage, _) = recordingFetcher([url: "echo no version here"])
        let unknown = await UpdateCheckService.check(cursorConfig, installed: true, pathLookup: lookup, fetchRelease: garbage)
        XCTAssertEqual(unknown.status, .checkFailed)
        XCTAssertEqual(unknown.message, "Could not determine latest version")
    }

    /// The catalog lists no package for cursor-agent, so only its native installer is accepted.
    func testCursorAgentOnlyAcceptsItsNativeOwner() throws {
        let brewPrefix = root.appendingPathComponent("opt/homebrew")
        let binary = brewPrefix.appendingPathComponent("Cellar/cursor-agent/1.0.0/bin/cursor-agent")
        try write("#!/bin/sh\n", to: binary)
        try write("#!/bin/sh\n", to: brewPrefix.appendingPathComponent("bin/brew"))
        let resolution = OwnerResolver.resolve(commandName: "cursor-agent", candidatePaths: [binary.path], layout: layout)
        XCTAssertEqual(resolution.active?.owner, .brewFormula("cursor-agent"))
        XCTAssertNil(StrategyPlanner.commandForResolvedOwner(config: cursorConfig, resolution: resolution,
            targetVersion: nil, layout: layout))
    }

    func testNativeOwnerNeedsTheMatchingSelfUpdater() async throws {
        let (link, _) = try makeCursorAgent(version: "2026.09.23-86fc751")
        var wrong = cursorConfig
        wrong.selfUpdater = "opencode"
        let lookup = CommandPathLookup(candidatesByName: ["cursor-agent": [link.path]], layout: layout)
        let check = await UpdateCheckService.check(wrong, installed: true, pathLookup: lookup, fetchRelease: { _ in nil })
        XCTAssertEqual(check.status, .blocked)
        XCTAssertEqual(check.blockReason, .noStrategy)
        XCTAssertEqual(check.message, "Unsupported native self-updater")
    }

    func testRequestsArePinnedCurlWithExactArgv() {
        let common = ["-q", "--proto", "=https", "--fail", "--silent", "--show-error", "--max-time", "20"]
        XCTAssertEqual(StrategyPlanner.openCodeLatestReleaseRequest, CommandSpec(executablePath: "/usr/bin/curl",
            arguments: common + ["https://api.github.com/repos/anomalyco/opencode/releases/latest"]))
        XCTAssertEqual(StrategyPlanner.cursorAgentInstallerRequest, CommandSpec(executablePath: "/usr/bin/curl",
            arguments: common + ["https://cursor.com/install"]))
    }

    func testCatalogMigratesCursorAgentAndOpencode() throws {
        let bundled = ConfigLoader.loadConfigs(settings: .defaults).filter { $0.source == .bundled }
        XCTAssertEqual(Set(bundled.filter { $0.schemaVersion == 2 }.map(\.id)),
            ["codex-cli", "claude-code", "cline-cli", "gemini-cli", "qwen-code", "gh-cli", "cursor-agent", "opencode"])
        let cursor = try XCTUnwrap(bundled.first { $0.id == "cursor-agent" })
        XCTAssertEqual(cursor.command, "cursor-agent")
        XCTAssertEqual(cursor.selfUpdater, "cursorAgent")
        XCTAssertEqual(cursor.packages, PackageIdentifiers())
        let opencode = try XCTUnwrap(bundled.first { $0.id == "opencode" })
        XCTAssertEqual(opencode.command, "opencode")
        XCTAssertEqual(opencode.selfUpdater, "opencode")
        XCTAssertEqual(opencode.packages, PackageIdentifiers(brew: "opencode", npm: "opencode-ai"))
        XCTAssertEqual(ConfigLoader.validateBundledConfigs([cursor, opencode]).map(\.id), ["cursor-agent", "opencode"])
    }
}
