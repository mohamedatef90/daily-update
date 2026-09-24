import XCTest
@testable import DailyUpdate

/// Regressions for typed self-updaters, verification diagnostics, npm engine preflight,
/// and the command recorded in update history.
final class TypedUpdateSafetyTests: XCTestCase {
    // MARK: - Claude: ~/.local/bin/claude -> ~/.local/share/claude/versions/<version>

    func testToolOwnedSelfUpdateRunsTheStableAliasNotTheVersionNamedTarget() throws {
        let root = try makeTemporaryDirectory()
        let alias = try makeVersionedSymlink(root: root, aliasName: "claude", version: "2.1.281")

        let strategy = DeveloperCLIStrategy.strategy(for: "claude-code")!
        let audit = makeAudit(cli: .claudeCode, path: alias.path, owner: .tool, outcome: .updateAvailable)
        let command = UpdateExecutor.typedMutationCommand(
            strategy: strategy,
            audit: audit,
            installing: false,
            packageManagerPath: nil
        )

        XCTAssertEqual(command, "'\(alias.path)' 'update'")
        XCTAssertEqual(command.map(UpdateRiskGate.classify(command:)), .safe)
    }

    func testEveryToolOwnedTypedCommandPassesTheRiskGateThroughItsAlias() throws {
        let root = try makeTemporaryDirectory()
        for cli in [DeveloperCLI.claudeCode, .cursorAgent, .openCode, .hermes] {
            let strategy = DeveloperCLIStrategy.all.first { $0.cli == cli }!
            let alias = try makeVersionedSymlink(root: root.appendingPathComponent(cli.rawValue), aliasName: strategy.binaryNames[0], version: "2026.09.23")
            let audit = makeAudit(cli: cli, path: alias.path, owner: .tool, outcome: .updateAvailable)
            let command = try XCTUnwrap(UpdateExecutor.typedMutationCommand(
                strategy: strategy, audit: audit, installing: false, packageManagerPath: nil
            ), "\(cli)")
            XCTAssertTrue(command.hasPrefix("'\(alias.path)' "), command)
            XCTAssertEqual(UpdateRiskGate.classify(command: command), .safe, command)
        }
    }

    func testTypedToolMutationRefusesAnAuditedPathThatIsNotAStrategyBinary() {
        let strategy = DeveloperCLIStrategy.strategy(for: "claude-code")!
        let audit = makeAudit(
            cli: .claudeCode,
            path: "/Users/test/.local/share/claude/versions/2.1.281",
            owner: .tool,
            outcome: .updateAvailable
        )
        XCTAssertNil(UpdateExecutor.typedMutationCommand(
            strategy: strategy, audit: audit, installing: false, packageManagerPath: nil
        ))
    }

    func testRiskGateStillGatesArbitraryVersionNamedExecutables() {
        XCTAssertEqual(UpdateRiskGate.classify(command: "'/Users/test/.local/share/claude/versions/2.1.281' 'update'"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "/opt/tools/2.1.281 update"), .gated)
    }

    func testCanonicalPathAcceptsASelfUpdateThatRetargetsTheVersionedAlias() throws {
        let root = try makeTemporaryDirectory()
        let alias = try makeVersionedSymlink(root: root, aliasName: "claude", version: "2.1.280")
        let pre = makeAudit(cli: .claudeCode, path: alias.path, owner: .tool, outcome: .updateAvailable, current: "2.1.280", latest: "2.1.281")

        let newTarget = root.appendingPathComponent("versions/2.1.281")
        FileManager.default.createFile(atPath: newTarget.path, contents: Data())
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: newTarget)
        let post = makeAudit(cli: .claudeCode, path: alias.path, owner: .tool, outcome: .current, current: "2.1.281", latest: "2.1.281")

        let verification = UpdateExecutor.typedVerification(
            preAudit: pre, postAudit: post, installing: false, helpSucceeded: true, freshShellMatches: true
        )
        XCTAssertTrue(verification.canonicalPathMatches)
        XCTAssertEqual(verification.outcome, .updated)

        let switchedOwner = makeAudit(cli: .claudeCode, path: alias.path, owner: .npm, outcome: .current, current: "2.1.281", latest: "2.1.281")
        XCTAssertFalse(UpdateExecutor.typedVerification(
            preAudit: pre, postAudit: switchedOwner, installing: false, helpSucceeded: true, freshShellMatches: true
        ).canonicalPathMatches)
    }

    // MARK: - Legacy items stay non-actionable even through direct executor calls

    func testDirectExecutorCallGatesLegacyItemWithoutRunningItsCommand() async throws {
        let root = try makeTemporaryDirectory()
        let marker = root.appendingPathComponent("ran")
        let item = UpdateItem(
            id: "legacy-tool", name: "Legacy", category: .cli, description: nil,
            currentVersion: "1.0.0", latestVersion: "2.0.0", status: .updateAvailable,
            statusMessage: nil, isInstalled: true, isSelected: true, isUserDefined: true,
            source: .user, iconPath: nil, detectCommand: nil, versionCommand: nil,
            checkCommand: nil, installCommand: "touch '\(marker.path)'",
            updateCommand: "touch '\(marker.path)'", workingDirectory: nil
        )

        let result = await UpdateExecutor.update(item)

        XCTAssertEqual(result.status, .gated)
        XCTAssertNil(result.command)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let installResult = await UpdateExecutor.update(item, installing: true)
        XCTAssertEqual(installResult.status, .gated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - Verification diagnostics name every failed check with its evidence

    func testVerificationFailureMessageNamesEachFailedCheckWithEvidence() {
        let pre = makeAudit(cli: .codex, path: "/a/bin/codex", owner: .npm, outcome: .updateAvailable, current: "1.0.0", latest: "2.0.0")
        let post = makeAudit(cli: .codex, path: "/b/bin/codex", owner: .npm, outcome: .checkFailed, current: "1.0.0", latest: nil, statusMessage: "npm registry check failed")
        let verification = UpdateVerification(
            canonicalPathMatches: false,
            exactVersionMatches: false,
            helpSucceeded: false,
            freshShellPathMatches: false,
            latestRecheckSucceeded: false,
            noLongerOutdated: false
        )

        let message = UpdateExecutor.verificationFailureMessage(
            verification: verification,
            preAudit: pre,
            postAudit: post,
            installing: false,
            helpFailureDetail: "Error: missing optional dependency",
            freshShellPath: "/opt/homebrew/bin/codex"
        )

        XCTAssertTrue(message.hasPrefix("Failed Verification: "), message)
        for check in verification.failedChecks {
            XCTAssertTrue(message.contains(check), "\(check) missing from: \(message)")
        }
        XCTAssertTrue(message.contains("/a/bin/codex") && message.contains("/b/bin/codex"), message)
        XCTAssertTrue(message.contains("installed 1.0.0"), message)
        XCTAssertTrue(message.contains("Error: missing optional dependency"), message)
        XCTAssertTrue(message.contains("/opt/homebrew/bin/codex"), message)
        XCTAssertTrue(message.contains("npm registry check failed"), message)
        XCTAssertFalse(message.contains("path/version/help/fresh-shell/latest"), message)
    }

    func testVerificationFailureMessageOnlyListsChecksThatFailed() {
        let pre = makeAudit(cli: .codex, path: "/a/bin/codex", owner: .npm, outcome: .updateAvailable)
        let post = makeAudit(cli: .codex, path: "/a/bin/codex", owner: .npm, outcome: .current, current: "2.0.0", latest: "2.0.0")
        let verification = UpdateVerification(
            canonicalPathMatches: true, exactVersionMatches: true, helpSucceeded: true,
            freshShellPathMatches: false, latestRecheckSucceeded: true, noLongerOutdated: true
        )
        let message = UpdateExecutor.verificationFailureMessage(
            verification: verification, preAudit: pre, postAudit: post, installing: false,
            helpFailureDetail: nil, freshShellPath: nil
        )
        XCTAssertTrue(message.contains("fresh-shell resolution"), message)
        for check in ["canonical path", "exact version", "help invocation", "latest re-check", "still outdated"] {
            XCTAssertFalse(message.contains(check), "\(check) unexpectedly in: \(message)")
        }
    }

    // MARK: - npm engine preflight (npm@12.1.0 needs ^22.22.2 || ^24.15.0 || >=26, Node was v24.13.0)

    func testNodeEngineRangeFromTheObservedNpmFailureRejectsNode24_13() {
        let range = "^22.22.2 || ^24.15.0 || >=26.0.0"
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v24.13.0", range: range), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v23.1.0", range: range), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v22.22.1", range: range), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v24.15.0", range: range), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "22.22.2", range: range), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v26.0.0", range: range), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v30.1.2", range: range), .compatible)
    }

    func testNodeEngineRangeSupportsStandardNpmRangeSyntax() {
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v20.11.0", range: ">=16"), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v18.20.0", range: ">=20"), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v18.17.0", range: "^18.17.0 || >=20.5.0"), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v19.0.0", range: "^18.17.0 || >=20.5.0"), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v20.4.9", range: ">= 20.5.0"), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v20.9.0", range: "~20.9"), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v20.10.0", range: "~20.9"), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v20.1.0", range: "20.x"), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v21.0.0", range: "20.x"), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v21.0.0", range: ">=18 <21"), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v20.99.0", range: ">=18 <21"), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v20.0.0", range: "18 - 20"), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v21.0.0", range: "18 - 20"), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v21.0.0", range: "*"), .compatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v0.9.0", range: "^0.8.1"), .incompatible)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v18.0.0", range: ">16 <=18"), .compatible)
    }

    func testUnparseableEngineRangesAreNotGuessed() {
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v24.0.0", range: ">=20.0.0-rc.1"), .unevaluable)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v24.0.0", range: "latest"), .unevaluable)
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v24.0.0-nightly", range: ">=20"), .unevaluable)
        // A satisfied alternative is decisive even when another alternative is exotic.
        XCTAssertEqual(NpmEngineCompatibility.evaluate(nodeVersion: "v24.0.0", range: ">=20 || banana"), .compatible)
    }

    func testEngineMetadataAndRuntimeVersionAreReadFromNpmJSON() {
        let metadata = NpmEngineCompatibility.parsePackageMetadata("""
        {
          "version": "12.1.0",
          "engines": { "node": "^22.22.2 || ^24.15.0 || >=26.0.0" }
        }
        """)
        XCTAssertEqual(metadata?.version, "12.1.0")
        XCTAssertEqual(metadata?.nodeRange, "^22.22.2 || ^24.15.0 || >=26.0.0")

        let noEngines = NpmEngineCompatibility.parsePackageMetadata(#"{"version": "1.0.0"}"#)
        XCTAssertEqual(noEngines?.version, "1.0.0")
        XCTAssertNil(noEngines?.nodeRange)
        XCTAssertNil(NpmEngineCompatibility.parsePackageMetadata("npm error code E404"))

        XCTAssertEqual(
            NpmEngineCompatibility.parseRuntimeNodeVersion(#"{"npm": "11.19.1", "node": "24.13.0", "v8": "12.4"}"#),
            "24.13.0"
        )
        XCTAssertNil(NpmEngineCompatibility.parseRuntimeNodeVersion("not json"))
    }

    func testEngineGateMessageExplainsRequiredAndCurrentNode() {
        let decision = NpmEngineCompatibility.decision(
            package: "npm",
            metadata: .init(version: "12.1.0", nodeRange: "^22.22.2 || ^24.15.0 || >=26.0.0"),
            nodeVersion: "24.13.0"
        )
        guard case .gated(let message) = decision else { return XCTFail("expected gate, got \(decision)") }
        XCTAssertTrue(message.contains("npm@12.1.0"), message)
        XCTAssertTrue(message.contains("^22.22.2 || ^24.15.0 || >=26.0.0"), message)
        XCTAssertTrue(message.contains("v24.13.0"), message)

        XCTAssertEqual(
            NpmEngineCompatibility.decision(package: "@openai/codex", metadata: .init(version: "0.156.1", nodeRange: ">=16"), nodeVersion: "24.13.0"),
            .compatible
        )
        XCTAssertEqual(
            NpmEngineCompatibility.decision(package: "@openai/codex", metadata: .init(version: "0.156.1", nodeRange: nil), nodeVersion: "24.13.0"),
            .compatible
        )
    }

    func testPreflightGatesTheObservedNpmFailureUsingOnlyReadOnlyNpmQueries() async throws {
        let root = try makeTemporaryDirectory()
        let npm = try makeFakeNpm(
            root: root,
            view: #"{"version": "12.1.0", "engines": {"node": "^22.22.2 || ^24.15.0 || >=26.0.0"}}"#,
            runtime: #"{"npm": "11.19.1", "node": "24.13.0"}"#
        )

        let preflight = await NpmEngineCompatibility.preflight(packageManagerPath: npm.path, package: "npm")

        guard case .gated(let message) = preflight else { return XCTFail("expected gate, got \(preflight)") }
        XCTAssertTrue(message.contains("npm@12.1.0 requires Node ^22.22.2 || ^24.15.0 || >=26.0.0"), message)
        XCTAssertTrue(message.contains("v24.13.0"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mutated").path))
    }

    func testPreflightAllowsCompatibleNodeAndFailsClosedWhenMetadataIsUnreadable() async throws {
        let root = try makeTemporaryDirectory()
        let compatible = try makeFakeNpm(
            root: root.appendingPathComponent("ok"),
            view: #"{"version": "0.156.1", "engines": {"node": ">=16"}}"#,
            runtime: #"{"npm": "11.19.1", "node": "24.13.0"}"#
        )
        let compatibleResult = await NpmEngineCompatibility.preflight(packageManagerPath: compatible.path, package: "@openai/codex")
        XCTAssertEqual(compatibleResult, .compatible)

        let broken = try makeFakeNpm(root: root.appendingPathComponent("broken"), view: nil, runtime: nil)
        let brokenResult = await NpmEngineCompatibility.preflight(packageManagerPath: broken.path, package: "@openai/codex")
        guard case .checkFailed(let message) = brokenResult else { return XCTFail("expected check failure, got \(brokenResult)") }
        XCTAssertTrue(message.contains("E404"), message)
    }

    // MARK: - History records the executed typed command, redacted

    func testReportedCommandPrefersTheExecutedTypedCommand() {
        XCTAssertEqual(
            UpdateExecutor.reportedCommand(executed: "'/Users/test/.local/bin/claude' 'update'", fallback: "claude update"),
            "'/Users/test/.local/bin/claude' 'update'"
        )
        XCTAssertEqual(UpdateExecutor.reportedCommand(executed: nil, fallback: "No safe automatic update command"), "No safe automatic update command")
    }

    func testReportedCommandRedactsCredentials() {
        let redacted = UpdateExecutor.reportedCommand(
            executed: "npm install -g pkg@1.0.0 --//registry.example.com/:_authToken=abc123 --registry https://user:hunter2@registry.example.com/ --token sekret GITHUB_TOKEN=ghp_xyz",
            fallback: ""
        )
        for secret in ["abc123", "hunter2", "sekret", "ghp_xyz"] {
            XCTAssertFalse(redacted.contains(secret), redacted)
        }
        XCTAssertTrue(redacted.contains("npm install -g pkg@1.0.0"), redacted)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A stand-in `npm` that answers the two read-only queries and records any other invocation.
    private func makeFakeNpm(root: URL, view: String?, runtime: String?) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let npm = root.appendingPathComponent("npm")
        let viewBranch = view.map { "echo '\($0)'" } ?? "echo 'npm error code E404' >&2; exit 1"
        let runtimeBranch = runtime.map { "echo '\($0)'" } ?? "exit 1"
        let script = """
        #!/bin/sh
        case "$1" in
          view) \(viewBranch) ;;
          version) \(runtimeBranch) ;;
          *) touch '\(root.deletingLastPathComponent().appendingPathComponent("mutated").path)'; exit 1 ;;
        esac
        """
        try script.write(to: npm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        return npm
    }

    /// `<root>/bin/<aliasName>` -> `<root>/versions/<version>`, the native Claude Code layout.
    private func makeVersionedSymlink(root: URL, aliasName: String, version: String) throws -> URL {
        let target = root.appendingPathComponent("versions/\(version)")
        let alias = root.appendingPathComponent("bin/\(aliasName)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        return alias
    }

    private func makeAudit(
        cli: DeveloperCLI,
        path: String?,
        owner: InstallOwner,
        outcome: AuditOutcome,
        current: String? = "1.0.0",
        latest: String? = "2.0.0",
        statusMessage: String? = nil
    ) -> DeveloperCLIAudit {
        DeveloperCLIAudit(
            cli: cli,
            name: cli.rawValue,
            activeBinaryPath: path,
            competingPaths: [],
            currentVersion: current,
            installOwner: owner,
            installMethod: .unknown,
            latestVersion: latest,
            shadowedPaths: [],
            orphanedPaths: [],
            statusMessage: statusMessage ?? outcome.rawValue,
            risk: .safe,
            outcome: outcome,
            verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true)
        )
    }
}
