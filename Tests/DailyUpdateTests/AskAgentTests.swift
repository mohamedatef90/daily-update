import XCTest
@testable import DailyUpdate

/// AI-2 entry point: flag gating, the sheet's data, and the rules for "Save as custom item". No real agent runs.
@MainActor
final class AskAgentTests: HermeticTestCase {

    override func setUp() {
        super.setUp()
        resetStoredSettings()
    }

    override func tearDown() {
        resetStoredSettings()
        super.tearDown()
    }

    /// These tests save settings (custom items, the flags). The settings file is shared by the whole test run,
    /// so each test starts from, and leaves, the defaults.
    private func resetStoredSettings() {
        let store = UserSettingsStore()
        store.settings = .defaults
        store.save()
    }
    // MARK: - Fixtures

    nonisolated private func row() -> DetectorConfig {
        DetectorConfig(
            id: "inv-npm-widget", name: "widget", category: .cli, description: nil, source: .inventory,
            inventory: InventoryIdentity(ecosystem: .npm, packageID: "widget", rootPath: "/fixture/root", packageDirectory: "/fixture/root/lib/node_modules/widget"),
            handle: "npm:widget", detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil)
    }

    nonisolated private func environment() -> ProposalEnvironment {
        let known = ["widget": "/usr/local/bin/widget", "npm": "/usr/local/bin/npm", "sudo": "/usr/bin/sudo"]
        return ProposalEnvironment(resolveExecutable: { known[$0] ?? ($0.hasPrefix("/") ? $0 : nil) }, isTrustedExecutable: { _ in true },
                                   resolveOwner: { _ in nil }, homeDirectory: "/Users/tester")
    }

    nonisolated private func proposal(
        recommendation: ProposalRecommendation = .update, version: [String]? = ["widget", "--version"],
        update: [String]? = ["npm", "install", "-g", "widget@latest"], confidence: Double = 0.9
    ) -> AgentProposal {
        AgentProposal(
            ownerKind: .npm, versionCommand: version, versionPattern: #"(\\d+\\.\\d+\\.\\d+)"#, latestSource: .npmRegistry,
            updateCommand: update, verify: .versionMatchesLatest, confidence: confidence, evidence: [], notes: "n",
            recommendation: recommendation, recommendationReason: "because")
    }

    nonisolated private func result(_ proposal: AgentProposal) async -> AgentProposeCommand.Result {
        let context = AgentItemContext(id: "inv-npm-widget", name: "widget", ecosystem: "npm", root: "/fixture/root", commandName: "widget", packageID: "widget")
        let evaluation = await ProposalValidator.evaluate(proposal: proposal, context: context, environment: environment())
        return AgentProposeCommand.Result(
            context: context, backendID: "claude", backendVersion: "2.1.322", toolPolicy: ClaudeCodeBackend().toolPolicy,
            evidence: EvidenceBundle(items: [], notes: []), sentToAgent: "PROMPT", redactionLeaks: [],
            response: AgentResponse(outcome: .completed(Data()), latencyMs: 12_000, usage: AgentUsage(inputTokens: 5000, outputTokens: 900), agentCommands: [], reportedCostUSD: 0.05),
            evaluation: evaluation)
    }

    private func makeState(
        agentOn: Bool, status: ItemStatus = .checkFailed, evaluator: AgentEvaluatorBox = AgentEvaluatorBox()
    ) async -> AppState {
        let store = UserSettingsStore()
        store.settings.agentProposals = agentOn
        let widget = row()
        let state = AppState(settingsStore: store, discoverer: { _, _ in
            DiscoveryRunResult(results: [], lookup: CommandPathLookup(candidatesByName: [:], loginPath: .known([])),
                               assembly: RowBuilder.Output(rows: [widget], competing: [:], shadowedByUnownedFiles: [], inactiveInstalls: []), elapsedMs: 1)
        }, discoversOnLaunch: false)
        await state.runDiscovery()
        let index = try! XCTUnwrap(state.items.firstIndex { $0.id == "inv-npm-widget" })
        state.items[index].status = status
        state.items[index].isInstalled = true
        state.agentEvaluator = { context, choice in
            evaluator.calls.append((context, choice))
            return try await evaluator.make(context)
        }
        return state
    }

    // MARK: - Flag gating

    func testAskAgentIsHiddenWhenTheFlagIsOffWhateverTheStatus() async {
        let state = await makeState(agentOn: false)
        let item = try! XCTUnwrap(state.items.first { $0.id == "inv-npm-widget" })
        XCTAssertFalse(UserSettings().agentProposals, "default Off")
        for status in [ItemStatus.unknown, .checkFailed, .failedVerification, .upToDate, .updateAvailable] {
            var copy = item
            copy.status = status
            XCTAssertFalse(state.canAskAgent(copy), "\(status) with the flag off")
        }
    }

    func testAskAgentAppearsOnlyForItemsTheEngineCouldNotDecideWhenTheFlagIsOn() async {
        let state = await makeState(agentOn: true)
        let item = try! XCTUnwrap(state.items.first { $0.id == "inv-npm-widget" })
        for status in [ItemStatus.unknown, .checkFailed, .failedVerification] {
            var copy = item
            copy.status = status
            XCTAssertTrue(state.canAskAgent(copy), "\(status)")
        }
        for status in [ItemStatus.upToDate, .updateAvailable, .blocked, .gated, .notInstalled, .checking] {
            var copy = item
            copy.status = status
            XCTAssertFalse(state.canAskAgent(copy), "\(status)")
        }
        var ignored = item
        ignored.permanentlyIgnored = true
        XCTAssertFalse(state.canAskAgent(ignored))
    }

    func testAskingWithTheFlagOffStartsNothing() async {
        let box = AgentEvaluatorBox()
        let state = await makeState(agentOn: false, evaluator: box)
        await state.askAgent(for: "inv-npm-widget")
        XCTAssertTrue(box.calls.isEmpty, "no agent is started")
        XCTAssertNil(state.agentSession)
    }

    func testAskingForAnItemThatIsUpToDateStartsNothingEvenWithTheFlagOn() async {
        let box = AgentEvaluatorBox()
        let state = await makeState(agentOn: true, status: .upToDate, evaluator: box)
        await state.askAgent(for: "inv-npm-widget")
        XCTAssertTrue(box.calls.isEmpty)
        XCTAssertNil(state.agentSession)
    }

    func testTurningTheFlagOffClosesTheSheet() async {
        let box = AgentEvaluatorBox()
        box.make = { _ in throw NSError(domain: "x", code: 1) }
        let state = await makeState(agentOn: true, evaluator: box)
        await state.askAgent(for: "inv-npm-widget")
        XCTAssertNotNil(state.agentSession)
        state.agentProposalsEnabled = false
        XCTAssertNil(state.agentSession)
    }

    func testTheSheetGetsTheItemsContextWithNoHomePath() async {
        let box = AgentEvaluatorBox()
        box.make = { _ in throw NSError(domain: "x", code: 1) }
        let state = await makeState(agentOn: true, evaluator: box)
        await state.askAgent(for: "inv-npm-widget")
        let context = try! XCTUnwrap(box.calls.first?.0)
        XCTAssertEqual(context.id, "inv-npm-widget")
        XCTAssertEqual(context.ecosystem, "npm")
        XCTAssertEqual(context.packageID, "widget")
        XCTAssertEqual(box.calls.first?.1, .claudeCode)
    }

    func testABackendThatIsNotAvailableShowsAMessageNotACrash() async {
        let box = AgentEvaluatorBox()
        box.make = { _ in throw AgentProposeCommand.Unavailable.backend(id: "claude", reason: "claude was not found") }
        let state = await makeState(agentOn: true, evaluator: box)
        await state.askAgent(for: "inv-npm-widget")
        guard case .failed(let message)? = state.agentSession?.phase else { return XCTFail("\(String(describing: state.agentSession))") }
        XCTAssertTrue(message.contains("not available"))
    }

    // MARK: - Save rules

    func testAnAcceptedUpdateProposalCanBeSaved() async {
        let state = await makeState(agentOn: true)
        let r = await result(proposal())
        XCTAssertEqual(r.verdict, .acceptedCandidate, "\(r.verdict)")
        XCTAssertEqual(state.agentSaveDecision(for: r), .allowed)
    }

    func testNothingElseCanBeSaved() async {
        let state = await makeState(agentOn: true)
        // gated: low confidence
        let gated = await result(proposal(confidence: 0.1))
        XCTAssertEqual(gated.verdict.name, "gated")
        XCTAssertFalse(state.agentSaveDecision(for: gated).isAllowed)
        // blocked: sudo
        let blocked = await result(proposal(update: ["sudo", "npm", "install", "-g", "widget"]))
        XCTAssertEqual(blocked.verdict.name, "blocked")
        XCTAssertFalse(state.agentSaveDecision(for: blocked).isAllowed)
        // accepted, but not an update recommendation
        for kind in [ProposalRecommendation.ignore, .investigate, .suggestRemoval] {
            let other = await result(proposal(recommendation: kind, update: nil))
            XCTAssertFalse(state.agentSaveDecision(for: other).isAllowed, "\(kind)")
        }
        // update with no commands at all
        let none = await result(proposal(version: nil, update: nil))
        XCTAssertFalse(state.agentSaveDecision(for: none).isAllowed)
        // invalid answer
        var invalid = await result(proposal())
        invalid.evaluation = nil
        XCTAssertFalse(state.agentSaveDecision(for: invalid).isAllowed)
    }

    func testSavingWritesACustomItemThatNeedsReviewAndRunsNothing() async {
        let box = AgentEvaluatorBox()
        box.make = { _ in await self.result(self.proposal()) }
        let state = await makeState(agentOn: true, evaluator: box)
        await state.askAgent(for: "inv-npm-widget")
        guard case .finished(let r)? = state.agentSession?.phase else { return XCTFail("not finished") }
        XCTAssertEqual(r.verdict, .acceptedCandidate, "\(r.verdict)")
        let before = state.settingsStore.settings.customItems.count
        XCTAssertEqual(state.saveAgentProposalAsCustomItem(), .allowed)
        XCTAssertEqual(state.settingsStore.settings.customItems.count, before + 1)
        let saved = try! XCTUnwrap(state.settingsStore.settings.customItems.last)
        XCTAssertEqual(saved.id, "agent-inv-npm-widget")
        XCTAssertEqual(saved.needsReview, true, "it must be reviewed before anything runs")
        XCTAssertEqual(saved.source, .user)
        XCTAssertTrue(saved.requiresReviewBeforeAutomation)
        XCTAssertEqual(saved.versionCommand, r.evaluation?.version?.spec?.displayString, "the validated command, verbatim")
        XCTAssertEqual(saved.updateCommand, r.evaluation?.update?.spec?.displayString, "the validated command, verbatim")
        XCTAssertEqual(saved.versionPattern, r.proposal?.versionPattern)
        XCTAssertEqual(saved.detect?.type, .path)
        XCTAssertEqual(state.agentSession?.savedItemName, "widget")
        // The saved item is gated until reviewed: the engine will not run it on its own.
        XCTAssertFalse(GatePolicy.isReviewSatisfied(for: saved, reviewedHash: nil))
        XCTAssertTrue(state.logLines.joined().contains("needs your review"))
    }

    func testSavingTwiceIsRefusedAndSavingWithTheFlagOffIsRefused() async {
        let box = AgentEvaluatorBox()
        box.make = { _ in await self.result(self.proposal()) }
        let state = await makeState(agentOn: true, evaluator: box)
        await state.askAgent(for: "inv-npm-widget")
        guard case .finished(let r)? = state.agentSession?.phase, state.agentSaveDecision(for: r).isAllowed else { return XCTFail("setup") }
        XCTAssertEqual(state.saveAgentProposalAsCustomItem(), .allowed)
        let count = state.settingsStore.settings.customItems.count
        XCTAssertFalse(state.saveAgentProposalAsCustomItem().isAllowed, "already saved")
        XCTAssertEqual(state.settingsStore.settings.customItems.count, count)
        state.settingsStore.settings.agentProposals = false
        XCTAssertFalse(state.saveAgentProposalAsCustomItem().isAllowed)
    }

    /// Found by the probe diagnosis: a discovered row has no catalog `command`, so no `--version` probe ran for it.
    func testADiscoveredRowGetsItsCommandNameFromItsOwnInstall() async {
        let root = InstallRoot(ecosystem: .npm, path: "/fixture/root", label: "fixture", binDirectories: ["/fixture/root/bin"], activity: .active)
        let record = InstalledPackage(
            ecosystem: .npm, packageID: "@angular/cli", versionRaw: "17.1.2", root: root,
            packageDirectory: "/fixture/root/lib/node_modules/@angular/cli", executables: ["/fixture/root/bin/ng"], commands: ["ng"],
            owner: .npm(prefix: "/fixture/root", package: "@angular/cli"), confidence: .proven, fileID: FileID(device: 1, inode: 5))
        XCTAssertEqual(AppState.primaryCommand(of: record), "ng")
        let hostile = InstalledPackage(
            ecosystem: .npm, packageID: "x", versionRaw: nil, root: root, packageDirectory: "/x", executables: ["/fixture/root/bin/a b; rm"],
            commands: ["a b; rm -rf"], owner: .unknown, confidence: .proven, fileID: FileID(device: 1, inode: 6))
        XCTAssertNil(AppState.primaryCommand(of: hostile), "only a plain command name is ever used")

        var angular = row()
        angular.inventory = InventoryIdentity(ecosystem: .npm, packageID: "@angular/cli", rootPath: root.path, packageDirectory: record.packageDirectory)
        let store = UserSettingsStore()
        store.settings.agentProposals = true
        let state = AppState(settingsStore: store, discoverer: { _, _ in
            DiscoveryRunResult(results: [EnumerationResult(ecosystem: .npm, records: [record], status: .complete)],
                               lookup: CommandPathLookup(candidatesByName: [:], loginPath: .known([])),
                               assembly: RowBuilder.Output(rows: [angular], competing: [:], shadowedByUnownedFiles: [], inactiveInstalls: []), elapsedMs: 1)
        }, discoversOnLaunch: false)
        await state.runDiscovery()
        let item = try! XCTUnwrap(state.items.first { $0.id == angular.id })
        XCTAssertEqual(state.discoveryDetails[angular.id]?.primaryCommand, "ng")
        XCTAssertEqual(state.agentContext(for: item).commandName, "ng")
    }

    func testTheSheetCodeNeverRunsACommand() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/DailyUpdate/Services/AppState+Agent.swift", "Sources/DailyUpdate/Views/AskAgentSheet.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["ShellRunner", "Process()", "UpdateExecutor", "runSpec", "runCommand", "BoundedProcessRunner", "requestUpdateSelected", "updateSelected"] {
                XCTAssertFalse(text.contains(forbidden), "\(file) must not run commands: \(forbidden)")
            }
        }
    }
}

private final class AgentEvaluatorBox: @unchecked Sendable {
    var calls: [(AgentItemContext, AgentBackendChoice)] = []
    var make: (AgentItemContext) async throws -> AgentProposeCommand.Result = { _ in throw NSError(domain: "unset", code: 1) }
}
