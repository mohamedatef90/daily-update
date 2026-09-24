import XCTest
@testable import DailyUpdate

final class CLIAuditTests: XCTestCase {
    @MainActor
    func testBlockingCLIWaitAllowsWorkToHopToMainActor() {
        let value: Int = CLIRunner.blockingWait {
            await MainActor.run { 42 }
        }
        XCTAssertEqual(value, 42)
    }

    func testCommandLineRuntimeSkipsDiscoveryAndBackgroundServices() {
        XCTAssertFalse(AppStateRuntime.commandLine.performsDiscovery)
        XCTAssertFalse(AppStateRuntime.commandLine.startsBackgroundServices)
        XCTAssertTrue(AppStateRuntime.application.performsDiscovery)
        XCTAssertTrue(AppStateRuntime.application.startsBackgroundServices)
    }

    func testCoreStrategiesExistAndUseTypedOwnership() {
        let expected: Set<DeveloperCLI> = [.claudeCode, .codex, .cursorAgent, .openCode, .gemini, .pi, .hermes]
        XCTAssertEqual(Set(DeveloperCLIStrategy.all.map(\.cli)), expected)
        XCTAssertTrue(DeveloperCLIStrategy.all.allSatisfy { !$0.binaryNames.isEmpty })
        XCTAssertTrue(DeveloperCLIStrategy.all.allSatisfy { !$0.verification.helpArguments.isEmpty })
    }

    func testPiUsesActiveEarendilPackageEverywhere() {
        let strategy = DeveloperCLIStrategy.strategy(for: "pi-coding-agent")
        XCTAssertEqual(strategy?.npmPackage, "@earendil-works/pi-coding-agent")

        let config = ConfigLoader.loadConfigs(settings: .defaults).first { $0.id == "pi-coding-agent" }
        XCTAssertTrue(config?.checkCommand?.contains("@earendil-works/pi-coding-agent") == true)
        XCTAssertTrue(config?.installCommand?.contains("@earendil-works/pi-coding-agent") == true)
        XCTAssertTrue(config?.updateCommand.contains("@earendil-works/pi-coding-agent") == true)
        XCTAssertFalse(config?.checkCommand?.contains("@mariozechner/pi-coding-agent") == true)
    }

    func testCursorAboutParsesLatestRowInsteadOfCurrentCLIVersion() {
        let strategy = DeveloperCLIStrategy.strategy(for: "cursor-agent")
        XCTAssertEqual(strategy?.authoritativeCheckArguments, ["about"])
        let output = """
        Cursor Agent
        CLI Version 2026.09.20
        Latest      2026.09.23 (update available: run cursor-agent update)
        """
        XCTAssertEqual(DeveloperCLIAuditService.parseAuthoritativeLatest(cli: .cursorAgent, output: output), "2026.09.23")
    }

    func testClaudeDoctorRunningVersionIsNotAnAuthoritativeLatestResult() {
        let output = """
        Claude Code Doctor
        Version: 2.1.7
        Installation: native
        Health: OK
        """
        XCTAssertNil(DeveloperCLIAuditService.parseAuthoritativeLatest(cli: .claudeCode, output: output))
    }

    func testMissingCurrentVersionCannotBeReportedAsCurrent() {
        XCTAssertEqual(
            DeveloperCLIAuditService.classifyOutcome(
                currentVersion: nil,
                currentCheckSucceeded: false,
                latestVersion: "2.0.0",
                latestCheckSucceeded: true,
                risk: .safe
            ),
            .checkFailed
        )
    }

    func testOpenCodeUsesReadOnlyOfficialReleaseSource() {
        let strategy = DeveloperCLIStrategy.strategy(for: "opencode")
        XCTAssertNil(strategy?.authoritativeCheckArguments)
        XCTAssertEqual(strategy?.officialGitHubRepository, "anomalyco/opencode")
    }

    func testKnownNativeCLIPathsUseToolOwnedSelfUpdater() {
        XCTAssertEqual(
            DeveloperCLIAuditService.canonicalOwner(
                cli: .openCode,
                inferredOwner: .user
            ),
            .tool
        )
        XCTAssertEqual(
            DeveloperCLIAuditService.canonicalOwner(
                cli: .codex,
                inferredOwner: .user
            ),
            .user
        )
    }

    func testRiskGateBlocksUnsafeAndAmbiguousActions() {
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew upgrade"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "npm update -g"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "gem update"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "gem update --system; gem update"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "yarn global upgrade"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "pip3 list --outdated --format=freeze | cut -d= -f1 | xargs -n1 pip3 install -U"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "sudo rm -f /usr/local/bin/tool"), .blocked)
        XCTAssertEqual(UpdateRiskGate.classify(command: "tool login"), .blocked)
        XCTAssertEqual(UpdateRiskGate.classify(command: "launchctl enable gui/501/tool"), .blocked)
        XCTAssertEqual(UpdateRiskGate.classify(command: "npm install"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew update && brew upgrade"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew upgrade 2>/dev/null"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "npm update -g 2>/dev/null"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "echo ready; pnpm update -g"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew upgrade gh"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "npm install -g @openai/codex@1.2.3"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "rustup update"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "mise upgrade"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "npx skills update"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "git pull --ff-only"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew services restart postgresql"), .blocked)
        XCTAssertEqual(UpdateRiskGate.classify(command: "corepack enable"), .blocked)
    }

    func testRiskGateClassifiesVersionJumps() {
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "1.9.0", latest: "2.0.0"), .gated)
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "0.2.0", latest: "0.8.0"), .gated)
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "1.9.0", latest: "1.10.0"), .safe)
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "1.10.0", latest: "1.11.0-beta.1"), .gated)
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "1.11.0-beta.1", latest: "1.11.0-rc.1"), .gated)
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "1.11.0-beta.1", latest: "1.11.0"), .gated)
    }

    func testRiskyBundledCommandsAreNonActionableBeforeSelection() {
        XCTAssertFalse(makeItem(status: .updateAvailable, updateCommand: "gem update").canUpdate)
        XCTAssertFalse(makeItem(status: .updateAvailable, updateCommand: "yarn global upgrade").canUpdate)
        XCTAssertFalse(makeItem(status: .updateAvailable, updateCommand: "pip3 list --outdated | xargs pip3 install -U").canUpdate)
        XCTAssertFalse(makeItem(status: .updateAvailable, updateCommand: "brew upgrade gh").canUpdate)
    }

    func testOnlyTypedItemsAreActionableEvenWhenLegacyCommandLooksSafe() {
        XCTAssertFalse(makeItem(id: "legacy-tool", status: .updateAvailable, updateCommand: "brew upgrade gh").canUpdate)
        XCTAssertFalse(makeItem(id: "legacy-tool", status: .updateAvailable, updateCommand: "brew upgrade").canUpdate)
        XCTAssertTrue(makeItem(id: "codex-cli", status: .updateAvailable, updateCommand: "ignored legacy command").canUpdate)
    }

    func testCompetingPathsFromAnotherOwnerAreOrphaned() {
        let classified = DeveloperCLIAuditService.classifyCompetingPaths(
            activeOwner: .npm,
            paths: ["/opt/homebrew/bin/codex", "/Users/test/.nvm/versions/node/v1/bin/codex"]
        )
        XCTAssertEqual(classified.shadowed.count, 2)
        XCTAssertEqual(classified.orphaned, ["/opt/homebrew/bin/codex"])
    }

    func testAuditPathOrderingSelectsFirstDirectoryInEffectivePathAcrossAliases() {
        let ordered = DeveloperCLIAuditService.orderPathsByEffectivePath(
            ["/fallback/bin/agent", "/preferred/bin/agent", "/preferred/bin/cursor-agent"],
            effectivePath: "/preferred/bin:/fallback/bin"
        )

        XCTAssertEqual(ordered.first, "/preferred/bin/agent")
        XCTAssertEqual(ordered, ["/preferred/bin/agent", "/preferred/bin/cursor-agent", "/fallback/bin/agent"])
    }

    func testAuditPathOrderingToleratesDuplicatePATHDirectories() {
        let ordered = DeveloperCLIAuditService.orderPathsByEffectivePath(
            ["/nvm/bin/gemini", "/usr/local/bin/gemini"],
            effectivePath: "/nvm/bin:/usr/local/bin:/nvm/bin"
        )
        XCTAssertEqual(ordered.first, "/nvm/bin/gemini")
    }

    func testAuditPreservesLoginShellResolutionOrderInsteadOfStaleProcessPATH() {
        let shellResolvedPaths = [
            "/Users/test/.nvm/versions/node/v24/bin/gemini",
            "/usr/local/bin/gemini"
        ]

        XCTAssertEqual(
            DeveloperCLIAuditService.preserveShellResolutionOrder(shellResolvedPaths),
            shellResolvedPaths
        )
    }

    func testCrossAliasResolutionUsesLoginShellPATHGlobally() {
        let paths = [
            "/fallback/bin/agent",
            "/preferred/bin/cursor-agent"
        ]
        XCTAssertEqual(
            DeveloperCLIAuditService.orderedResolvedPaths(
                paths,
                loginShellPath: "/preferred/bin:/fallback/bin"
            ).first,
            "/preferred/bin/cursor-agent"
        )
    }

    func testCompetingPathsExcludeActivePath() {
        XCTAssertEqual(
            DeveloperCLIAuditService.competingPaths(
                activePath: "/usr/local/bin/tool",
                allPaths: ["/usr/local/bin/tool", "/opt/homebrew/bin/tool", "/usr/local/bin/tool"]
            ),
            ["/opt/homebrew/bin/tool"]
        )
    }

    func testCompetingPathsDeduplicateAliasesToTheSameBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let binary = root.appendingPathComponent("versions/1.0/tool")
        let firstAlias = root.appendingPathComponent("bin/agent")
        let secondAlias = root.appendingPathComponent("bin/cursor-agent")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstAlias.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: binary)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: binary)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            DeveloperCLIAuditService.competingPaths(
                activePath: firstAlias.path,
                allPaths: [firstAlias.path, secondAlias.path]
            ),
            []
        )
    }

    func testOwnerInferenceUsesSymlinkResolvedTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let packageBin = root.appendingPathComponent("lib/node_modules/pkg/bin/tool")
        let link = root.appendingPathComponent("usr/local/bin/tool")
        try FileManager.default.createDirectory(at: packageBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: packageBin.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: packageBin)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(DeveloperCLIAuditService.inferOwner(path: link.path), .npm)
    }

    func testVersionOrderingDoesNotTreatNewerInstalledPrereleaseAsOutdated() {
        XCTAssertFalse(DeveloperCLIAuditService.isRemoteNewer(current: "0.85.1", latest: "0.73.1"))
        XCTAssertTrue(DeveloperCLIAuditService.isRemoteNewer(current: "0.85.1", latest: "0.86.0"))
    }

    func testSemVerOrderingTreatsStableAsNewerThanSameCorePrerelease() {
        XCTAssertTrue(DeveloperCLIAuditService.isRemoteNewer(current: "1.2.3-beta.9", latest: "1.2.3"))
        XCTAssertFalse(DeveloperCLIAuditService.isRemoteNewer(current: "1.2.3", latest: "1.2.3-beta.9"))
    }

    func testSemVerPrereleaseNumericIdentifiersCompareNumerically() {
        XCTAssertTrue(DeveloperCLIAuditService.isRemoteNewer(current: "1.2.3-beta.2", latest: "1.2.3-beta.10"))
        XCTAssertFalse(DeveloperCLIAuditService.isRemoteNewer(current: "1.2.3-beta.10", latest: "1.2.3-beta.2"))
    }

    func testCheckFailuresAndGatedItemsAreNotActionable() {
        XCTAssertFalse(makeItem(status: .error).canUpdate)
        XCTAssertFalse(makeItem(status: .gated).canUpdate)
        XCTAssertFalse(makeItem(status: .blocked).canUpdate)
        XCTAssertFalse(makeItem(status: .failedVerification).canUpdate)
        XCTAssertTrue(makeItem(id: "codex-cli", status: .updateAvailable).canUpdate)
    }

    func testGatedAuditMapsToNonActionableItemStatus() {
        XCTAssertEqual(UpdateCheckService.itemStatus(for: .gated), .gated)
        XCTAssertNotEqual(UpdateCheckService.itemStatus(for: .gated), .updateAvailable)
    }

    func testFreshShellVerificationUsesResolverAndCanonicalizesPaths() async {
        var requestedBinary: String?
        let matches = await UpdateExecutor.freshShellPathMatches(
            binaryName: "agent",
            canonicalPath: "/usr/local/bin/agent",
            resolver: { binary in
                requestedBinary = binary
                return "/opt/homebrew/bin/agent"
            }
        )
        XCTAssertEqual(requestedBinary, "agent")
        XCTAssertFalse(matches)
    }

    func testVerificationUsesTheActiveAliasForFreshShellLookup() {
        let strategy = DeveloperCLIStrategy.strategy(for: "cursor-agent")!
        XCTAssertEqual(
            UpdateExecutor.verificationBinaryName(
                strategy: strategy,
                activePath: "/Users/test/.local/bin/cursor-agent"
            ),
            "cursor-agent"
        )
    }

    func testVerificationRequiresEveryIndependentCheck() {
        let failed = UpdateVerification(
            canonicalPathMatches: true,
            exactVersionMatches: true,
            helpSucceeded: true,
            freshShellPathMatches: false,
            latestRecheckSucceeded: true,
            noLongerOutdated: true
        )
        XCTAssertEqual(failed.outcome, .failedVerification)

        let passed = UpdateVerification(
            canonicalPathMatches: true,
            exactVersionMatches: true,
            helpSucceeded: true,
            freshShellPathMatches: true,
            latestRecheckSucceeded: true,
            noLongerOutdated: true
        )
        XCTAssertEqual(passed.outcome, .updated)
    }

    func testFirstInstallVerificationUsesPostAuditPathAndAuthoritativeLatest() {
        let pre = makeAudit(
            cli: .pi,
            path: nil,
            owner: .unknown,
            outcome: .notInstalled,
            current: nil,
            latest: nil
        )
        let post = makeAudit(
            cli: .pi,
            path: "/Users/test/.nvm/versions/node/v22/bin/pi",
            owner: .npm,
            outcome: .current,
            current: "1.2.3",
            latest: "1.2.3"
        )

        let verification = UpdateExecutor.typedVerification(
            preAudit: pre,
            postAudit: post,
            installing: true,
            helpSucceeded: true,
            freshShellMatches: true
        )

        XCTAssertEqual(verification.outcome, .updated)
    }

    func testExistingUpdateVerificationStillRequiresSameCanonicalActivePath() {
        let pre = makeAudit(cli: .codex, path: "/first/bin/codex", owner: .npm, outcome: .updateAvailable)
        let post = makeAudit(cli: .codex, path: "/other/bin/codex", owner: .npm, outcome: .current, current: "2.0.0", latest: "2.0.0")

        let verification = UpdateExecutor.typedVerification(
            preAudit: pre,
            postAudit: post,
            installing: false,
            helpSucceeded: true,
            freshShellMatches: true
        )

        XCTAssertEqual(verification.outcome, .failedVerification)
    }

    func testTypedMutationUsesAuditedNpmOwnerInsteadOfDetectorCommand() {
        let strategy = DeveloperCLIStrategy.strategy(for: "codex-cli")!
        let audit = makeAudit(
            cli: .codex,
            path: "/Users/test/.nvm/versions/node/v22/bin/codex",
            owner: .npm,
            outcome: .updateAvailable
        )

        XCTAssertEqual(
            UpdateExecutor.typedMutationCommand(
                strategy: strategy,
                audit: audit,
                installing: false,
                packageManagerPath: "/Users/test/.nvm/versions/node/v22/bin/npm"
            ),
            "'/Users/test/.nvm/versions/node/v22/bin/npm' install -g '@openai/codex@latest'"
        )
        XCTAssertNil(
            UpdateExecutor.typedMutationCommand(
                strategy: strategy,
                audit: audit,
                installing: false,
                packageManagerPath: nil
            )
        )
    }

    func testTypedMutationUsesResolvedHomebrewOwnerAndTargetedFormula() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cellarBinary = root.appendingPathComponent("homebrew/Cellar/codex/1.0/bin/codex")
        let link = root.appendingPathComponent("usr/local/bin/codex")
        try FileManager.default.createDirectory(at: cellarBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cellarBinary.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cellarBinary)
        defer { try? FileManager.default.removeItem(at: root) }

        let strategy = DeveloperCLIStrategy.strategy(for: "codex-cli")!
        let owner = DeveloperCLIAuditService.inferOwner(path: link.path)
        let audit = makeAudit(cli: .codex, path: link.path, owner: owner, outcome: .updateAvailable)

        XCTAssertEqual(owner, .homebrew)
        XCTAssertEqual(
            UpdateExecutor.typedMutationCommand(
                strategy: strategy,
                audit: audit,
                installing: false,
                packageManagerPath: "/usr/local/bin/brew"
            ),
            "'/usr/local/bin/brew' upgrade 'codex'"
        )
    }

    func testTypedMutationBlocksUnsupportedOrAmbiguousOwner() {
        let strategy = DeveloperCLIStrategy.strategy(for: "cursor-agent")!
        for owner in [InstallOwner.user, .system, .unknown] {
            let audit = makeAudit(cli: .cursorAgent, path: "/custom/bin/agent", owner: owner, outcome: .updateAvailable)
            XCTAssertNil(
                UpdateExecutor.typedMutationCommand(
                    strategy: strategy,
                    audit: audit,
                    installing: false,
                    packageManagerPath: nil
                )
            )
        }

        let nativeAudit = makeAudit(cli: .cursorAgent, path: "/custom/bin/agent", owner: .tool, outcome: .updateAvailable)
        XCTAssertEqual(
            UpdateExecutor.typedMutationCommand(
                strategy: strategy,
                audit: nativeAudit,
                installing: false,
                packageManagerPath: nil
            ),
            "'/custom/bin/agent' 'update'"
        )
    }

    func testFirstInstallUsesExplicitPreferredNpmSource() {
        let strategy = DeveloperCLIStrategy.strategy(for: "pi-coding-agent")!
        let audit = makeAudit(cli: .pi, path: nil, owner: .unknown, outcome: .notInstalled)

        XCTAssertEqual(
            UpdateExecutor.typedMutationCommand(
                strategy: strategy,
                audit: audit,
                installing: true,
                packageManagerPath: "/Users/test/.nvm/versions/node/v22/bin/npm"
            ),
            "'/Users/test/.nvm/versions/node/v22/bin/npm' install -g '@earendil-works/pi-coding-agent@latest'"
        )
    }

    func testCLIActionExitCodesRejectNoOpAndFailedVerification() {
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 0, statuses: []), 3)
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 1, statuses: [.updated]), 0)
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 1, statuses: [.upToDate]), 0)
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 1, statuses: [.failedVerification]), 1)
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 1, statuses: [.gated]), 1)
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 1, statuses: [.blocked]), 1)
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 1, statuses: [.updateAvailable]), 1)
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 1, statuses: [.notInstalled]), 1)
        XCTAssertEqual(CLIRunner.actionExitCode(attemptedCount: 2, statuses: [.updated]), 1)
    }

    func testEchoFallbackCannotBeTreatedAsUpdateSuccess() {
        XCTAssertNil(UpdateExecutor.validatedCommand(from: "npm install -g tool || echo 'manual update'"))
        XCTAssertNil(UpdateExecutor.validatedCommand(from: "echo updated"))
        XCTAssertEqual(UpdateExecutor.validatedCommand(from: "npm install -g tool@2.0.0"), "npm install -g tool@2.0.0")
    }

    private func makeAudit(
        cli: DeveloperCLI,
        path: String?,
        owner: InstallOwner,
        outcome: AuditOutcome,
        current: String? = "1.0.0",
        latest: String? = "2.0.0"
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
            statusMessage: outcome.rawValue,
            risk: .safe,
            outcome: outcome,
            verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true)
        )
    }

    private func makeItem(
        id: String = "test",
        status: ItemStatus,
        updateCommand: String = "npm install -g test@2.0.0"
    ) -> UpdateItem {
        UpdateItem(
            id: id, name: "Test", category: .cli, description: nil,
            currentVersion: "1.0.0", latestVersion: "2.0.0", status: status,
            statusMessage: nil, isInstalled: true, isSelected: false, isUserDefined: false,
            source: .bundled, iconPath: nil, detectCommand: nil, versionCommand: "test --version",
            checkCommand: nil, installCommand: "npm install -g test@2.0.0",
            updateCommand: updateCommand, workingDirectory: nil
        )
    }
}
