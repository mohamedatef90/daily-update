import XCTest
@testable import DailyUpdate

/// Regressions found while auditing real update failures on a developer Mac.
final class UpdateFailureRegressionTests: XCTestCase {
    // MARK: - Cursor Agent: date + commit-hash versions were gated as "prerelease channel change"

    func testCommitHashSuffixesAreBuildMetadataNotPrereleaseChannels() {
        XCTAssertEqual(
            UpdateRiskGate.classifyVersionChange(current: "2026.09.10-fd3934a", latest: "2026.09.18-9a7762b"),
            .safe
        )
        XCTAssertEqual(
            UpdateRiskGate.classifyVersionChange(current: "1.2.3-abc1234", latest: "1.2.4-def5678"),
            .safe
        )
        // Real channel changes still gate.
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "1.10.0", latest: "1.11.0-beta.1"), .gated)
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "1.11.0-beta.1", latest: "1.11.0-rc.1"), .gated)
        XCTAssertEqual(UpdateRiskGate.classifyVersionChange(current: "1.11.0-beta.1", latest: "1.11.0-beta.2"), .safe)
    }

    // MARK: - Hermes: git-tracked, reports "N commits behind" instead of a version

    func testHermesUpdateCheckOutputIsParsedAsAvailability() {
        XCTAssertEqual(
            DeveloperCLIAuditService.parseAuthoritativeUpdateAvailability(
                cli: .hermes,
                output: "→ Fetching from origin...\n☤ Update available: 431 commits behind origin/main.\n  Run 'hermes update' to install."
            ),
            true
        )
        XCTAssertEqual(
            DeveloperCLIAuditService.parseAuthoritativeUpdateAvailability(cli: .hermes, output: "→ Fetching from origin...\nUp to date"),
            false
        )
        XCTAssertNil(DeveloperCLIAuditService.parseAuthoritativeUpdateAvailability(cli: .hermes, output: "error: could not fetch"))
    }

    func testHermesBehindCountBecomesDisplayableLatestMarker() {
        XCTAssertEqual(
            DeveloperCLIAuditService.hermesLatestMarker(output: "☤ Update available: 431 commits behind origin/main."),
            "origin/main (+431 commits)"
        )
    }

    func testAuthoritativeAvailabilityOverridesSemanticComparison() {
        XCTAssertEqual(
            DeveloperCLIAuditService.classifyOutcome(
                currentVersion: "0.21.4",
                currentCheckSucceeded: true,
                latestVersion: "origin/main (+431 commits)",
                latestCheckSucceeded: true,
                risk: .safe,
                authoritativeUpdateAvailable: true
            ),
            .updateAvailable
        )
        XCTAssertEqual(
            DeveloperCLIAuditService.classifyOutcome(
                currentVersion: "0.21.4",
                currentCheckSucceeded: true,
                latestVersion: "0.21.4",
                latestCheckSucceeded: true,
                risk: .safe,
                authoritativeUpdateAvailable: false
            ),
            .current
        )
    }

    // MARK: - Claude Code: native install had no latest-version source

    func testClaudeCodeHasAnOfficialLatestVersionSourceForNativeInstalls() {
        let strategy = DeveloperCLIStrategy.strategy(for: "claude-code")
        XCTAssertNotNil(strategy?.officialLatestVersionURL)
        XCTAssertTrue(strategy?.officialLatestVersionURL?.hasPrefix("https://") ?? false)
    }

    func testClaudeDoctorChannelAndLastAttemptLinesAreNotLatestVersions() {
        let output = """
        Claude Code doctor

        Running: native (2.1.280)
        Auto-updates: enabled
        Auto-update channel: latest
        Last update attempt: success → 2.1.280 (2026-09-23)
        No installation issues found.
        """
        XCTAssertNil(DeveloperCLIAuditService.parseAuthoritativeLatest(cli: .claudeCode, output: output))
    }

    // MARK: - Codex: npm upgrade left a broken binary and the report hid why

    func testVerificationFailureNamesTheChecksThatFailed() {
        let verification = UpdateVerification(
            canonicalPathMatches: true,
            exactVersionMatches: false,
            helpSucceeded: false,
            freshShellPathMatches: true,
            latestRecheckSucceeded: true,
            noLongerOutdated: false
        )
        XCTAssertEqual(verification.failedChecks, ["exact version", "help invocation", "still outdated"])
        XCTAssertEqual(verification.outcome, .failedVerification)
    }

    func testNpmRepairIsACleanReinstallOfTheSamePackage() {
        let commands = UpdateExecutor.npmRepairCommands(
            packageManagerPath: "/Users/me/.nvm/versions/node/v24.13.0/bin/npm",
            package: "@openai/codex"
        )
        XCTAssertEqual(commands, [
            "'/Users/me/.nvm/versions/node/v24.13.0/bin/npm' uninstall -g '@openai/codex'",
            "'/Users/me/.nvm/versions/node/v24.13.0/bin/npm' install -g '@openai/codex@latest'"
        ])
    }

    // MARK: - Apps, runtimes, repos: every non-typed item was Blocked

    func testSingleTargetLegacyCommandsAreSafeAndBulkOnesStayGated() {
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew reinstall --cask cursor 2>/dev/null"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew upgrade --cask warp"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew upgrade gh 2>/dev/null || brew install gh 2>/dev/null"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "git -C \"/Users/me/Projects/app\" pull --ff-only"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "cd \"/Users/me/Projects/app\" && git pull --ff-only"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "flutter upgrade"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "rustup update"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "pnpm add -g pnpm@latest 2>/dev/null || npm install -g pnpm@latest 2>/dev/null || brew upgrade pnpm"), .safe)
        XCTAssertEqual(UpdateRiskGate.classify(command: "gem update cocoapods 2>/dev/null || brew upgrade cocoapods"), .safe)

        XCTAssertEqual(UpdateRiskGate.classify(command: "brew upgrade"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew upgrade --cask"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "npm update -g"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "gem update"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "yarn global upgrade"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "git pull"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "git -C /x pull --rebase"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "brew update && brew upgrade"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "npx skills update"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "curl -fsSL https://example.com/install.sh | bash"), .gated)
        XCTAssertEqual(UpdateRiskGate.classify(command: "corepack enable"), .blocked)
        XCTAssertEqual(UpdateRiskGate.classify(command: "open -a Cursor"), .blocked)
    }

    func testLegacyCheckResultsRemainGatedWithoutTypedOwnerAwareVerification() {
        XCTAssertEqual(
            UpdateCheckService.legacyUpdateStatus(updateCommand: "brew reinstall --cask cursor 2>/dev/null || open -a Cursor"),
            .gated
        )
        XCTAssertEqual(UpdateCheckService.legacyUpdateStatus(updateCommand: "npm update -g @angular/cli"), .gated)
        XCTAssertEqual(UpdateCheckService.legacyUpdateStatus(updateCommand: "echo 'Gated: bulk Homebrew upgrades are audit-only'"), .gated)
        XCTAssertEqual(UpdateCheckService.legacyUpdateStatus(updateCommand: "open 'macappstore://apps.apple.com/app/id497799835'"), .gated)
    }

    func testNonTypedItemsAreNeverAutoActionable() {
        XCTAssertFalse(makeItem(id: "cursor", category: .app, status: .updateAvailable,
                                updateCommand: "brew reinstall --cask cursor 2>/dev/null || open -a Cursor").canUpdate)
        XCTAssertFalse(makeItem(id: "repo-1", category: .repo, status: .updateAvailable,
                                updateCommand: "git -C \"/Users/me/app\" pull --ff-only").canUpdate)
        XCTAssertFalse(makeItem(id: "global-npm", category: .library, status: .updateAvailable,
                                updateCommand: "echo 'Gated: bulk npm upgrades are audit-only'").canUpdate)
        XCTAssertFalse(makeItem(id: "xcode", category: .app, status: .updateAvailable,
                                updateCommand: "open 'macappstore://apps.apple.com/app/id497799835' || open -a 'App Store'").canUpdate)
        XCTAssertFalse(makeItem(id: "hermes-agent", category: .cli, status: .notInstalled,
                                installCommand: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash").canInstall)
        XCTAssertFalse(makeItem(id: "gh-cli", category: .cli, status: .notInstalled,
                                installCommand: "brew install gh").canInstall)
    }

    func testLegacyUpdateCommandIsNotReturnedWithoutTypedStrategy() {
        let item = makeItem(id: "cursor", category: .app, status: .updateAvailable,
                            updateCommand: "brew reinstall --cask cursor 2>/dev/null || open -a Cursor")
        XCTAssertNil(UpdateExecutor.commandToRun(for: item))
    }

    // MARK: - CLI mode crashed posting a user notification without an app bundle

    func testCommandLineRuntimeDoesNotPostUserNotifications() {
        XCTAssertFalse(AppStateRuntime.commandLine.postsNotifications)
        XCTAssertTrue(AppStateRuntime.application.postsNotifications)
    }

    // MARK: - CLI single-item selector

    func testSingleItemSelectorReadsTheValueAfterTheFlag() {
        XCTAssertEqual(CLIRunner.selectedItemID(arguments: ["--update", "opencode"], flag: "--update"), "opencode")
        XCTAssertEqual(CLIRunner.selectedItemID(arguments: ["--json", "--install", "gh-cli"], flag: "--install"), "gh-cli")
        XCTAssertNil(CLIRunner.selectedItemID(arguments: ["--update"], flag: "--update"))
        XCTAssertNil(CLIRunner.selectedItemID(arguments: ["--update", "--json"], flag: "--update"))
    }

    // MARK: - Startup: scanning ~/Downloads blocked on a macOS privacy prompt for minutes

    func testPrivacyProtectedHomeFoldersAreNotScannedByDefault() {
        XCTAssertEqual(
            RepoScanner.rootSubfoldersToScan(["Projects", "Downloads", "dev", "Documents", "Desktop", "src"]),
            ["Projects", "dev", "src"]
        )
        XCTAssertFalse(RepoScanSettings.defaultSubfolders.contains("Downloads"))
        XCTAssertFalse(RepoScanSettings.defaultSubfolders.contains("Documents"))
    }

    // MARK: - Helpers

    private func makeItem(
        id: String,
        category: ItemCategory,
        status: ItemStatus,
        installCommand: String = "",
        updateCommand: String = ""
    ) -> UpdateItem {
        UpdateItem(
            id: id, name: id, category: category, description: nil,
            currentVersion: "1.0.0", latestVersion: "2.0.0", status: status,
            statusMessage: nil, isInstalled: status != .notInstalled, isSelected: false, isUserDefined: false,
            source: .bundled, iconPath: nil, detectCommand: nil, versionCommand: nil,
            checkCommand: nil, installCommand: installCommand,
            updateCommand: updateCommand, workingDirectory: nil
        )
    }
}
