import Foundation

/// The "Ask agent" sheet's state (AI-2). One run: nothing the agent proposes is executed. The only write is the
/// explicit "Save as custom item", allowed only for an accepted candidate that recommends an update.
struct AgentSession: Identifiable {
    enum Phase {
        case running
        case finished(AgentProposeCommand.Result)
        case failed(String)
    }

    var id: String { itemID }
    var itemID: String
    var itemName: String
    var backend: AgentBackendChoice
    var phase: Phase = .running
    /// Set after a successful save, so the sheet can say so.
    var savedItemName: String?
}

enum AgentSaveDecision: Equatable {
    case allowed
    case notAllowed(String)

    var isAllowed: Bool { self == .allowed }
}

extension AppState {
    /// Statuses where the engine could not decide for itself, so an agent opinion can help.
    static let askAgentStatuses: Set<ItemStatus> = [.unknown, .checkFailed, .failedVerification]

    var agentProposalsEnabled: Bool {
        get { settingsStore.settings.agentProposals }
        set { settingsStore.settings.agentProposals = newValue; settingsStore.save(); if !newValue { agentSession = nil } }
    }

    var agentBackendChoice: AgentBackendChoice {
        get { settingsStore.settings.agentBackend }
        set { settingsStore.settings.agentBackend = newValue; settingsStore.save() }
    }

    /// "Ask agent" is visible only when the setting is On and the item is one the engine could not decide.
    func canAskAgent(_ item: UpdateItem) -> Bool {
        agentProposalsEnabled && Self.askAgentStatuses.contains(item.status) && !item.permanentlyIgnored
    }

    func agentContext(for item: UpdateItem) -> AgentItemContext {
        let config = configs.first { $0.id == item.id }
        let planned = item.plannedUpdateCommandSpec?.displayString ?? item.updateCommand
        let details = discoveryDetails[item.id]
        return AgentItemContext(
            id: item.id, name: item.name, category: item.category.rawValue,
            ecosystem: item.inventory?.ecosystem.rawValue, handle: config?.handle, root: item.inventory?.rootPath,
            commandName: item.command ?? config?.command ?? details?.primaryCommand, packageID: item.inventory?.packageID,
            appPath: AgentProposeCommand.appPath(detected: item.detectedPaths, planned: planned),
            status: item.status.rawValue, observedVersion: item.currentVersionRaw,
            currentPlannedCommand: planned.isEmpty ? nil : AgentProposeCommand.trimmedCommand(planned),
            competing: (details?.competing ?? []).map {
                AgentItemContext.Competing(path: $0.path, version: $0.version, ecosystem: $0.ecosystem, packageID: nil)
            },
            description: item.description)
    }

    /// Opens the sheet and runs the agent. Safe to call twice: a run in flight is not restarted.
    func askAgent(for itemID: String) async {
        guard agentProposalsEnabled, let item = items.first(where: { $0.id == itemID }), canAskAgent(item) else { return }
        if let session = agentSession, session.itemID == itemID, case .running = session.phase { return }
        let choice = agentBackendChoice
        agentSession = AgentSession(itemID: itemID, itemName: item.name, backend: choice)
        let context = agentContext(for: item)
        do {
            let result = try await agentEvaluator(context, choice)
            guard agentSession?.itemID == itemID else { return }   // closed or replaced while running
            agentSession?.phase = .finished(result)
        } catch AgentProposeCommand.Unavailable.backend(let id, let reason) {
            guard agentSession?.itemID == itemID else { return }
            agentSession?.phase = .failed("The agent (\(id)) is not available: \(reason)")
        } catch {
            guard agentSession?.itemID == itemID else { return }
            agentSession?.phase = .failed("Could not ask the agent: \(PackageNameRules.sanitize("\(error)", maxLength: 200))")
        }
    }

    func closeAgentSession() {
        agentSession = nil
    }

    // MARK: - Save as custom item

    /// Only `acceptedCandidate` with `recommendation == update`, a version reader and an update command the
    /// engine itself validated. Gated, blocked, invalid, ignore, investigate and suggestRemoval are copy-only.
    func agentSaveDecision(for result: AgentProposeCommand.Result) -> AgentSaveDecision {
        guard let evaluation = result.evaluation, let proposal = evaluation.proposal else {
            return .notAllowed("The agent's answer was not valid, so there is nothing to save.")
        }
        guard evaluation.verdict == .acceptedCandidate else {
            return .notAllowed("The engine did not accept this proposal (\(evaluation.verdict.name)), so it can only be copied.")
        }
        guard proposal.recommendation == .update else {
            return .notAllowed("Only an \"update\" recommendation can be saved. This one says \"\(proposal.recommendation.rawValue)\".")
        }
        guard let version = evaluation.version?.spec, let update = evaluation.update?.spec, proposal.updateCommand != nil else {
            return .notAllowed("The proposal has no complete version and update command.")
        }
        _ = version; _ = update
        let id = Self.customItemID(for: result.context.id)
        if settingsStore.settings.customItems.contains(where: { $0.id == id }) {
            return .notAllowed("This is already saved as a custom item.")
        }
        return .allowed
    }

    static func customItemID(for itemID: String) -> String {
        "agent-" + itemID.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }.joined()
    }

    /// The custom item exactly as the engine validated it: the commands are the validated specs' own display
    /// strings, and the item needs review before anything runs automatically.
    static func customItem(from result: AgentProposeCommand.Result, itemName: String, category: ItemCategory) -> DetectorConfig? {
        guard let evaluation = result.evaluation, let proposal = evaluation.proposal,
              let version = evaluation.version?.spec, let update = evaluation.update?.spec else { return nil }
        var config = DetectorConfig(
            id: customItemID(for: result.context.id), name: itemName, category: category,
            description: "Proposed by \(result.backendID) and accepted by the engine's checks; you reviewed it before saving.",
            source: .user, command: result.context.commandName,
            detect: DetectRule(type: .path, paths: [version.executablePath], command: nil, appName: nil),
            versionCommand: version.displayString, checkCommand: nil, installCommand: nil,
            updateCommand: update.displayString, workingDirectory: nil, needsReview: true)
        config.versionPattern = proposal.versionPattern
        return config
    }

    /// Writes the custom item. Nothing runs. Returns the reason when it is not allowed.
    @discardableResult
    func saveAgentProposalAsCustomItem() -> AgentSaveDecision {
        guard agentProposalsEnabled, let session = agentSession, case .finished(let result) = session.phase else {
            return .notAllowed("There is no proposal to save.")
        }
        let decision = agentSaveDecision(for: result)
        guard decision.isAllowed else { return decision }
        let category = items.first(where: { $0.id == session.itemID })?.category ?? .cli
        guard let config = Self.customItem(from: result, itemName: session.itemName, category: category) else {
            return .notAllowed("The proposal has no complete version and update command.")
        }
        settingsStore.addCustomItem(config)
        reloadConfigs()
        appendLog("Saved \(session.itemName) as a custom item from an agent proposal (needs your review before it runs)")
        agentSession?.savedItemName = session.itemName
        return .allowed
    }
}
