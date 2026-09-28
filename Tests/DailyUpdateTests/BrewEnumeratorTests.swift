import XCTest
@testable import DailyUpdate

/// ADR-002 §9 P2-2 tasks 1 and 2: parsing the brew JSON, and the sandboxed enricher with its
/// filesystem fallback.
final class BrewEnumeratorTests: HermeticTestCase {
    // MARK: Task 1 — parsing

    func testParsesOnRequestDependencyLinkedPinnedAndKegOnly() throws {
        let parsed = try XCTUnwrap(BrewInstalledJSON.parse(Data(BrewFixtures.installedJSONWithRejectedName.utf8), prefix: "/p"))
        let formulae = parsed.info.formulae
        XCTAssertEqual(formulae.keys.sorted(), ["abseil", "bird", "gh", "jq", "node@22", "openssl@3", "python@3.12"])
        XCTAssertEqual(parsed.rejected, ["-rf"])

        let gh = try XCTUnwrap(formulae["gh"])
        XCTAssertEqual(gh.linkedVersion, "2.101.0")
        XCTAssertEqual(gh.latestVersion, "2.102.0")
        XCTAssertTrue(gh.installedOnRequest)
        XCTAssertFalse(gh.installedAsDependency)

        XCTAssertTrue(try XCTUnwrap(formulae["abseil"]).installedAsDependency)
        XCTAssertFalse(try XCTUnwrap(formulae["abseil"]).installedOnRequest)
        XCTAssertTrue(try XCTUnwrap(formulae["jq"]).pinned)

        let node = try XCTUnwrap(formulae["node@22"])
        XCTAssertTrue(node.kegOnly)
        XCTAssertEqual(node.linkedVersion, "22.22.2")
        // A non-zero revision is part of the latest version, as in Phase 1's parser.
        XCTAssertEqual(node.latestVersion, "22.22.2_1")

        let python = try XCTUnwrap(formulae["python@3.12"])
        XCTAssertNil(python.linkedVersion)
        XCTAssertEqual(python.currentVersion, "3.12.10")

        let openssl = try XCTUnwrap(formulae["openssl@3"])
        XCTAssertEqual(openssl.installedVersions, ["3.3.0", "3.4.0"])
        XCTAssertEqual(openssl.currentVersion, "3.4.0")
    }

    /// F7: a formula outside `homebrew/core` is upgraded by its `full_name`.
    func testThirdPartyTapFormulaUsesFullNameAsUpgradeToken() throws {
        let parsed = try XCTUnwrap(BrewInstalledJSON.parse(Data(BrewFixtures.installedJSON.utf8), prefix: "/p"))
        XCTAssertEqual(parsed.info.formulae["bird"]?.upgradeToken, "steipete/tap/bird")
        XCTAssertEqual(parsed.info.formulae["gh"]?.upgradeToken, "gh")
    }

    /// F7/§7.4: a tap-qualified name that fails the regex is dropped before it can reach argv.
    func testTapFormulaWithAnInvalidFullNameIsRejected() throws {
        let json = #"{"formulae": [{"name": "x", "full_name": "Evil Tap/--x/x", "tap": "Evil Tap/--x", "installed": [{"version": "1"}]}], "casks": []}"#
        let parsed = try XCTUnwrap(BrewInstalledJSON.parse(Data(json.utf8), prefix: "/p"))
        XCTAssertEqual(parsed.info.formulae, [:])
        XCTAssertEqual(parsed.rejected, ["x"])
    }

    func testCaskIndexBindsAppTargetsAndBinaries() throws {
        let parsed = try XCTUnwrap(BrewInstalledJSON.parse(Data(BrewFixtures.installedJSON.utf8), prefix: "/p"))
        let provider = BrewInfoProvider(prefixes: ["/p": parsed.info], cacheDirectory: "/c", cacheModifiedAt: nil)
        let cask = try XCTUnwrap(parsed.info.casks["openclaw"])
        XCTAssertEqual(cask.appTargets, ["/Applications/Clawdbot.app"])
        XCTAssertEqual(cask.binaries, ["openclaw"])
        XCTAssertEqual(cask.latestVersion, "2026.1.24")
        XCTAssertEqual(cask.installedVersion, "2026.1.23")
        XCTAssertTrue(cask.autoUpdates)
        XCTAssertEqual(cask.upgradeToken, "openclaw")
        XCTAssertEqual(provider.caskIndex.token(forAppBundle: "/Applications/Clawdbot.app"), "openclaw")
        XCTAssertNil(provider.caskIndex.token(forAppBundle: "/Applications/Clawdbot Beta.app"))
    }

    func testNonJSONOutputDoesNotParse() {
        XCTAssertNil(BrewInstalledJSON.parse(Data("Error: no".utf8), prefix: "/p"))
    }

    // MARK: Task 1 — records from the enricher

    func testEnricherRecordsAreExact() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let calls = CallRecorder()
        let enumerator = BrewEnumerator(enricher: { brew in calls.record(brew); return BrewFixtures.ranOutcome() })

        let result = await enumerator.enumerate(BrewFixtures.context(fixture))

        XCTAssertEqual(calls.calls, ["\(prefix)/bin/brew"])
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.roots.map(\.path), [prefix])
        XCTAssertEqual(result.roots.first?.activity, .active)
        XCTAssertEqual(result.roots.first?.toolPath, "\(prefix)/bin/brew")

        let byID = Dictionary(uniqueKeysWithValues: result.records.map { ($0.packageID, $0) })
        XCTAssertEqual(byID.keys.sorted(), ["abseil", "bird", "gh", "jq", "node@22", "openssl@3", "python@3.12"])

        let gh = try XCTUnwrap(byID["gh"])
        XCTAssertEqual(gh.versionRaw, "2.101.0")
        XCTAssertEqual(gh.commands, ["gh"])
        XCTAssertEqual(gh.executables, ["\(prefix)/Cellar/gh/2.101.0/bin/gh"])
        XCTAssertEqual(gh.packageDirectory, "\(prefix)/Cellar/gh/2.101.0")
        XCTAssertEqual(gh.owner, .brewFormula("gh"))
        XCTAssertEqual(gh.flags, [.onRequest])
        XCTAssertEqual(gh.confidence, .proven)
        XCTAssertEqual(gh.fileID, fixture.fileSystem.stat("\(prefix)/Cellar/gh/2.101.0/bin/gh")?.fileID)

        XCTAssertEqual(byID["abseil"]?.flags, [.dependency])
        XCTAssertEqual(byID["abseil"]?.commands, [])
        XCTAssertEqual(byID["jq"]?.flags, [.onRequest, .pinned])
        XCTAssertEqual(byID["node@22"]?.flags, [.onRequest, .kegOnly])
        XCTAssertEqual(byID["node@22"]?.commands, ["node", "npm"])
        XCTAssertEqual(byID["bird"]?.displayName, "steipete/tap/bird")
        XCTAssertEqual(byID["openssl@3"]?.versionRaw, "3.4.0")
        XCTAssertEqual(byID["openssl@3"]?.flags, [.dependency, .kegOnly])

        // D8: keg-only, on request, no linked commands → keyed by the keg folder.
        let python = try XCTUnwrap(byID["python@3.12"])
        XCTAssertEqual(python.commands, [])
        XCTAssertEqual(python.executables, [])
        XCTAssertEqual(python.fileID, fixture.fileSystem.stat("\(prefix)/Cellar/python@3.12/3.12.10")?.fileID)

        let provider = try XCTUnwrap(result.brewInfo)
        XCTAssertEqual(provider.prefixes[prefix]?.source, .enricher)
        XCTAssertEqual(provider.formula("gh", brewExecutable: "\(prefix)/bin/brew")?.latestVersion, "2.102.0")
    }

    /// §7.4: the rejected name becomes a `malformed` issue, never a record.
    func testRejectedNameIsReportedAsMalformed() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let result = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome(BrewFixtures.installedJSONWithRejectedName) })
            .enumerate(BrewFixtures.context(fixture))
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .malformed, rootPath: prefix,
            message: "Homebrew (\(prefix)): skipped -rf: the name isn't a valid Homebrew name"
        )]))
        XCTAssertFalse(result.records.contains { $0.packageID == "-rf" })
    }

    // MARK: Task 2 — sandbox runner and the filesystem fallback

    private func assertFallbackRecords(_ result: EnumerationResult, prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        let byID = Dictionary(uniqueKeysWithValues: result.records.map { ($0.packageID, $0) })
        XCTAssertEqual(byID.keys.sorted(), ["abseil", "bird", "gh", "jq", "node@22", "openssl@3", "python@3.12"], file: file, line: line)
        XCTAssertEqual(byID["gh"]?.versionRaw, "2.101.0", file: file, line: line)
        XCTAssertEqual(byID["gh"]?.commands, ["gh"], file: file, line: line)
        XCTAssertEqual(byID["gh"]?.confidence, .strong, file: file, line: line)
        XCTAssertEqual(byID["abseil"]?.flags, [.dependency], file: file, line: line)
        XCTAssertEqual(byID["jq"]?.flags, [.onRequest, .pinned], file: file, line: line)
        // The receipt names the tap, so the fallback still knows bird's full name (F7).
        XCTAssertEqual(byID["bird"]?.displayName, "steipete/tap/bird", file: file, line: line)
        XCTAssertEqual(byID["python@3.12"]?.commands, [], file: file, line: line)
        XCTAssertEqual(byID["openssl@3"]?.versionRaw, "3.4.0", file: file, line: line)

        let info = result.brewInfo?.prefixes[prefix]
        XCTAssertEqual(info?.source, .filesystem, file: file, line: line)
        XCTAssertNil(info?.formulae["gh"]?.latestVersion, file: file, line: line)
        XCTAssertEqual(info?.formulae["bird"]?.upgradeToken, "steipete/tap/bird", file: file, line: line)
        XCTAssertEqual(info?.casks["openclaw"]?.appTargets, ["/Applications/Clawdbot.app"], file: file, line: line)
        XCTAssertEqual(info?.casks["openclaw"]?.installedVersion, "2026.1.23", file: file, line: line)
    }

    /// E7 at the enumerator: no `sandbox-exec` → brew never runs, and the Cellar gives `partial`.
    func testSandboxUnavailableFallsBackToTheCellar() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let result = await BrewEnumerator(enricher: { _ in .sandboxUnavailable }).enumerate(BrewFixtures.context(fixture))
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .sandboxUnavailable, rootPath: prefix,
            message: "Homebrew (\(prefix)): latest versions unavailable: sandbox-exec isn't available, so brew wasn't run"
        )]))
        assertFallbackRecords(result, prefix: prefix)
    }

    /// E6 at the enumerator: a refused profile keeps the preflight's evidence.
    func testSandboxRefusedKeepsThePreflightEvidence() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let preflight = ProcessEvidence(executable: "/usr/bin/sandbox-exec", arguments: ["-p", "x", "/usr/bin/true"],
            termination: .exited(65), stderr: "sandbox-exec: invalid profile", stderrTruncated: false, elapsedMs: 11)
        let result = await BrewEnumerator(enricher: { _ in .sandboxRefused(preflight) }).enumerate(BrewFixtures.context(fixture))
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .sandboxRefused, rootPath: prefix,
            message: "Homebrew (\(prefix)): latest versions unavailable: sandbox-exec refused the profile, so brew wasn't run",
            process: preflight
        )]))
        assertFallbackRecords(result, prefix: prefix)
    }

    /// RC1: brew's own failure is `enricherFailed`, with its exit status and stderr.
    func testBrewExitingNonZeroIsEnricherFailedWithEvidence() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let outcome = BrewFixtures.ranOutcome("", termination: .exited(1), stderr: "Error: Operation not permitted @ dir_s_mkdir")
        let result = await BrewEnumerator(enricher: { _ in outcome }).enumerate(BrewFixtures.context(fixture))
        guard case .ran(let query) = outcome else { return XCTFail("fixture") }
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .enricherFailed, rootPath: prefix,
            message: "Homebrew (\(prefix)): latest versions unavailable: brew info exited 1",
            process: query.evidence
        )]))
        assertFallbackRecords(result, prefix: prefix)
    }

    func testBrewTimingOutIsEnricherFailed() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let result = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome("", termination: .timedOut(afterMs: 12000)) })
            .enumerate(BrewFixtures.context(fixture))
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertEqual(issues.map(\.kind), [.enricherFailed])
        XCTAssertEqual(issues.map(\.message), ["Homebrew (\(prefix)): latest versions unavailable: brew info timed out after 12000 ms"])
    }

    /// §7.1: an untrusted (here: missing) brew never reaches the enricher at all.
    func testMissingBrewNeverCallsTheEnricher() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        try FileManager.default.removeItem(atPath: "\(prefix)/bin/brew")
        let calls = CallRecorder()
        let result = await BrewEnumerator(enricher: { brew in calls.record(brew); return BrewFixtures.ranOutcome() })
            .enumerate(BrewFixtures.context(fixture))
        XCTAssertEqual(calls.calls, [])
        XCTAssertNil(result.roots.first?.toolPath)
        XCTAssertEqual(result.status, .partial([EnumerationIssue(
            kind: .untrustedRoot, rootPath: prefix,
            message: "Homebrew (\(prefix)): latest versions unavailable: \(prefix)/bin/brew is missing or not a trusted executable"
        )]))
        assertFallbackRecords(result, prefix: prefix)
    }

    /// §7.2/D16: a world-writable prefix never runs the enricher, and its records are flagged.
    func testWorldWritablePrefixIsUntrustedAndNeverEnriched() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        fixture.chmod(prefix, 0o777)
        let calls = CallRecorder()
        let result = await BrewEnumerator(enricher: { brew in calls.record(brew); return BrewFixtures.ranOutcome() })
            .enumerate(BrewFixtures.context(fixture))
        XCTAssertEqual(calls.calls, [])
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertEqual(issues.map(\.kind), [.untrustedRoot])
        XCTAssertTrue(result.records.allSatisfy { $0.flags.contains(.untrustedRoot) })
        XCTAssertEqual(result.records.count, 7)
    }

    /// D3/RC2: no Cellar at all is `unavailable` only when the login PATH is known.
    func testNoCellarIsUnavailableOnlyWithAKnownPath() async {
        let fixture = FixtureFileSystem()
        let known = await BrewEnumerator(enricher: { _ in .sandboxUnavailable }).enumerate(BrewFixtures.context(fixture))
        XCTAssertEqual(known.status, .unavailable("No Homebrew Cellar found"))
        let unknown = await BrewEnumerator(enricher: { _ in .sandboxUnavailable })
            .enumerate(BrewFixtures.context(fixture, loginPath: .unknown("timed out")))
        XCTAssertEqual(unknown.status, .partial([EnumerationIssue(
            kind: .loginEnvironmentUnknown, message: "No Homebrew Cellar found, and the login PATH is unknown"
        )]))
    }

    func testRootActivityFollowsTheLoginPath() async {
        let fixture = FixtureFileSystem()
        BrewFixtures.makeTree(fixture)
        let inactive = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() })
            .enumerate(BrewFixtures.context(fixture, loginPath: .known(["/usr/bin"])))
        XCTAssertEqual(inactive.roots.map(\.activity), [.inactive])
        let unknown = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() })
            .enumerate(BrewFixtures.context(fixture, loginPath: .empty))
        XCTAssertEqual(unknown.roots.map(\.activity), [.unknown])
    }

    /// Check time / L3: `resolve` re-reads one formula from the Cellar and never calls brew.
    func testResolveReadsTheCellarWithoutTheEnricher() async throws {
        let fixture = FixtureFileSystem()
        let prefix = BrewFixtures.makeTree(fixture)
        let calls = CallRecorder()
        let enumerator = BrewEnumerator(enricher: { brew in calls.record(brew); return BrewFixtures.ranOutcome() })
        let identity = InventoryIdentity(ecosystem: .brew, packageID: "gh", rootPath: prefix,
            packageDirectory: "\(prefix)/Cellar/gh/2.101.0", toolPath: "\(prefix)/bin/brew")
        let record = await enumerator.resolve(identity, BrewFixtures.context(fixture))
        XCTAssertEqual(calls.calls, [])
        XCTAssertEqual(record?.versionRaw, "2.101.0")
        XCTAssertEqual(record?.commands, ["gh"])
        // L2: once the formula is gone, resolve finds nothing.
        try FileManager.default.removeItem(atPath: "\(prefix)/Cellar/gh")
        let gone = await enumerator.resolve(identity, BrewFixtures.context(fixture))
        XCTAssertNil(gone)
    }

    // MARK: F5 / F11 — the cache, found without running brew

    func testCacheAgeIsTheNewestAPIFile() async throws {
        let fixture = FixtureFileSystem()
        BrewFixtures.makeTree(fixture)
        let older = fixture.makeFile(at: "Library/Caches/Homebrew/api/formula.jws.json", contents: "{}")
        let newer = fixture.makeFile(at: "Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json", contents: "{}")
        let ignored = fixture.makeFile(at: "Library/Caches/Homebrew/api/formula_names.txt", contents: "")
        let olderDate = Date(timeIntervalSince1970: 1_790_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_790_050_000)
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: older)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_799_000_000)], ofItemAtPath: ignored)

        let result = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() }).enumerate(BrewFixtures.context(fixture))
        let provider = try XCTUnwrap(result.brewInfo)
        XCTAssertEqual(provider.cacheDirectory, fixture.path("Library/Caches/Homebrew"))
        XCTAssertEqual(provider.cacheModifiedAt, newerDate)
        XCTAssertEqual(provider.cacheAge(now: newerDate.addingTimeInterval(90)), 90)
    }

    /// F5/F4: `HOMEBREW_CACHE` from the login snapshot beats the process environment; a missing
    /// cache is no error, just no age.
    func testCacheDirectoryPrecedence() async throws {
        let fixture = FixtureFileSystem()
        BrewFixtures.makeTree(fixture)
        let fromLogin = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() }).enumerate(BrewFixtures.context(
            fixture, snapshot: ["HOMEBREW_CACHE": "/login/cache"], processEnvironment: ["HOMEBREW_CACHE": "/process/cache"]))
        XCTAssertEqual(fromLogin.brewInfo?.cacheDirectory, "/login/cache")
        XCTAssertNil(fromLogin.brewInfo?.cacheModifiedAt)
        XCTAssertEqual(fromLogin.status, .complete)
        let fromProcess = await BrewEnumerator(enricher: { _ in BrewFixtures.ranOutcome() }).enumerate(BrewFixtures.context(
            fixture, processEnvironment: ["HOMEBREW_CACHE": "/process/cache"]))
        XCTAssertEqual(fromProcess.brewInfo?.cacheDirectory, "/process/cache")
    }
}

/// Task 2 at the query level: the single enricher entry point (CR FU5), the preflight (E6, E7),
/// the exit-71 rule, and F1's profile.
final class BrewEnricherQueryTests: HermeticTestCase {
    private func makeStub(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enricher-stub-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func recordingRunner(_ calls: CallRecorder, termination: @escaping @Sendable (BoundedProcessSpec) -> Termination,
                                 stderr: String = "") -> ReadOnlyQueries.Runner {
        return { spec in
            calls.record(spec.arguments.last ?? "")
            return QueryOutcome(
                evidence: ProcessEvidence(executable: spec.executable, arguments: spec.arguments, termination: termination(spec),
                    stderr: stderr, stderrTruncated: false, elapsedMs: 1),
                stdout: Data("{}".utf8)
            )
        }
    }

    func testUntrustedBrewStartsNoProcess() async throws {
        let calls = CallRecorder()
        let outcome = await ReadOnlyQueries.brewInfoInstalled(
            brew: "/opt/homebrew/bin/brew", sandboxExecPath: try makeStub("#!/bin/sh\nexit 0\n"),
            isTrustedExecutable: { _ in false }, run: recordingRunner(calls, termination: { _ in .exited(0) })
        )
        guard case .untrustedExecutable(let path) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(path, "/opt/homebrew/bin/brew")
        XCTAssertEqual(calls.calls, [])
    }

    /// E7: no `sandbox-exec` → `sandboxUnavailable`, and nothing runs.
    func testMissingSandboxExecStartsNoProcess() async {
        let calls = CallRecorder()
        let outcome = await ReadOnlyQueries.brewInfoInstalled(
            brew: "/opt/homebrew/bin/brew", sandboxExecPath: "/nonexistent/sandbox-exec",
            isTrustedExecutable: { _ in true }, run: recordingRunner(calls, termination: { _ in .exited(0) })
        )
        guard case .sandboxUnavailable = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(calls.calls, [])
    }

    /// E6: the preflight exits 65 → `sandboxRefused`; brew is never recorded.
    func testRefusedPreflightNeverRunsBrew() async throws {
        let calls = CallRecorder()
        let outcome = await ReadOnlyQueries.brewInfoInstalled(
            brew: "/opt/homebrew/bin/brew", sandboxExecPath: try makeStub("#!/bin/sh\nexit 65\n"),
            isTrustedExecutable: { _ in true }, run: recordingRunner(calls, termination: { _ in .exited(65) })
        )
        guard case .sandboxRefused(let evidence) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(evidence.termination, .exited(65))
        XCTAssertEqual(calls.calls, ["/usr/bin/true"])
    }

    /// After a clean preflight, the exact argv, the allowlisted environment and the caps.
    func testCleanPreflightRunsBrewSandboxedWithTheExactArgv() async throws {
        let sandbox = try makeStub("#!/bin/sh\nexit 0\n")
        let recorder = SpecRecorder()
        let outcome = await ReadOnlyQueries.brewInfoInstalled(
            brew: "/opt/homebrew/bin/brew", sandboxExecPath: sandbox, isTrustedExecutable: { _ in true },
            run: { spec in
                recorder.record(spec)
                return QueryOutcome(evidence: ProcessEvidence(executable: spec.executable, arguments: spec.arguments,
                    termination: .exited(0), stderr: "", stderrTruncated: false, elapsedMs: 1), stdout: Data("{}".utf8))
            }
        )
        guard case .ran = outcome else { return XCTFail("got \(outcome)") }
        let specs = recorder.specs
        XCTAssertEqual(specs.map(\.arguments), [
            ["-p", ReadOnlyQueries.sandboxProfile, "/usr/bin/true"],
            ["-p", ReadOnlyQueries.sandboxProfile, "/opt/homebrew/bin/brew", "info", "--json=v2", "--installed"],
        ])
        XCTAssertEqual(specs.map(\.executable), [sandbox, sandbox])
        XCTAssertEqual(specs.last?.environment, .exactly(ReadOnlyQueries.enricherEnvironment()))
        XCTAssertEqual(specs.last?.maxStdoutBytes, 64 * 1024 * 1024)
        XCTAssertEqual(specs.last?.timeout, 10)
    }

    /// RC1: exit 71 with `sandbox-exec: execvp…` is sandbox-exec failing to start brew.
    func testExit71FromSandboxExecIsLaunchFailed() async throws {
        let sandbox = try makeStub("#!/bin/sh\nexit 0\n")
        let calls = CallRecorder()
        let stderr = "sandbox-exec: execvp() of '/opt/homebrew/bin/brew' failed: Operation not permitted"
        let outcome = await ReadOnlyQueries.brewInfoInstalled(
            brew: "/opt/homebrew/bin/brew", sandboxExecPath: sandbox, isTrustedExecutable: { _ in true },
            run: recordingRunner(calls, termination: { spec in spec.arguments.last == "/usr/bin/true" ? .exited(0) : .exited(71) }, stderr: stderr)
        )
        guard case .ran(let query) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(query.evidence.termination, .launchFailed(stderr))
        XCTAssertEqual(query.stdout, Data())
    }

    /// Exit 71 from brew itself (anything else on stderr) stays brew's own status.
    func testExit71FromBrewStaysExited() async throws {
        let sandbox = try makeStub("#!/bin/sh\nexit 0\n")
        let calls = CallRecorder()
        let outcome = await ReadOnlyQueries.brewInfoInstalled(
            brew: "/opt/homebrew/bin/brew", sandboxExecPath: sandbox, isTrustedExecutable: { _ in true },
            run: recordingRunner(calls, termination: { spec in spec.arguments.last == "/usr/bin/true" ? .exited(0) : .exited(71) },
                stderr: "Error: something else")
        )
        guard case .ran(let query) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(query.evidence.termination, .exited(71))
    }

    /// F1: the profile denies `process-exec` of `/usr/bin/open` and `/usr/bin/osascript`.
    func testProfileDeniesOpenAndOsascript() {
        XCTAssertTrue(ReadOnlyQueries.sandboxProfile.hasSuffix(
            #"(deny process-exec (literal "/usr/bin/open") (literal "/usr/bin/osascript"))"#))
    }

    /// F1, live: under the real `sandbox-exec`, the profile still runs `/usr/bin/true` and refuses
    /// to exec `osascript`. Skipped when this process can't use `sandbox-exec` at all.
    func testProfileDeniesOsascriptUnderTheRealSandbox() async throws {
        let preflight = await ReadOnlyQueries.checkSandboxAvailability()
        guard preflight == .available else { throw XCTSkip("sandbox-exec isn't usable here: \(preflight)") }
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: ReadOnlyQueries.sandboxExecutable,
            arguments: ["-p", ReadOnlyQueries.sandboxProfile, "/usr/bin/osascript", "-e", "return 1"],
            environment: .exactly(ReadOnlyQueries.enricherEnvironment()), timeout: 10, maxStdoutBytes: 4096
        ))
        XCTAssertEqual(outcome.evidence.termination, .exited(71))
        XCTAssertTrue(outcome.evidence.stderr.hasPrefix("sandbox-exec: execvp()"), outcome.evidence.stderr)
        XCTAssertEqual(outcome.stdout, Data())
    }
}
