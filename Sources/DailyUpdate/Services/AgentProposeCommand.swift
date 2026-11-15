import Foundation

/// ADR-003 / AI-1 CLI: `--propose <itemID> [--agent claude|codex] [--json]` and
/// `--propose-fixture <file.json>`.
///
/// It is available only when the `agentProposals` setting is on (default Off). It collects the item's
/// facts itself (`EvidenceCollector`), gives the agent ONLY that evidence plus the schema, validates the
/// proposal, and PRINTS both. It never executes the proposed commands (not even as a dry run), never saves
/// anything, and never writes to settings or the catalog. The only process the engine starts for the agent
/// is the agent CLI itself, with its tools turned off as far as the CLI allows (see `AgentToolPolicy`).
enum AgentProposeCommand {
    /// For one run, without changing the settings file (used by the eval and CI).
    static let environmentOverride = "DAILY_UPDATE_AGENT_PROPOSALS"

    static func isEnabled(settings: UserSettings, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        settings.agentProposals || environment[environmentOverride] == "1"
    }

    static var disabledMessage: String {
        let path = ConfigLoader.appSupportDirectory.appendingPathComponent("settings.json").path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return "Agent proposals are off (the default). To turn them on, set \"agentProposals\" to true in \(path), "
            + "or for a single run set \(environmentOverride)=1. Nothing a proposal contains is ever executed or saved."
    }

    static func backend(for choice: AgentBackendChoice) -> AgentBackend {
        switch choice {
        case .claudeCode: return ClaudeCodeBackend()
        case .codex: return CodexBackend()
        }
    }

    /// Builds the context for a live item: the catalog row from `--check`, plus what discovery knows
    /// (the owner root, the package, the competing installs that shadow it).
    @MainActor
    static func context(forItemID itemID: String, state: any CLIRunnerState) async -> AgentItemContext? {
        await state.checkAll()
        let settings = UserSettingsStore().settings
        let catalog = ConfigLoader.loadConfigs(settings: settings)
        let discovery = await DiscoveryRunner.run(catalog: catalog, settings: settings)
        let row = discovery.rows.first { $0.id == itemID }
        let item = state.items.first { $0.id == itemID }
        guard item != nil || row != nil else { return nil }

        let competing = (discovery.assembly.competing[itemID] ?? []).map {
            AgentItemContext.Competing(
                path: $0.path, version: $0.record.versionRaw,
                ecosystem: $0.record.ecosystem.rawValue, packageID: $0.record.packageID)
        }
        let planned = item.map { $0.plannedUpdateCommandSpec?.displayString ?? $0.updateCommand }
        return AgentItemContext(
            id: itemID,
            name: item?.name ?? row?.name ?? itemID,
            category: item?.category.rawValue ?? row?.category.rawValue,
            ecosystem: row?.inventory?.ecosystem.rawValue,
            handle: row?.handle,
            root: row?.inventory?.rootPath,
            commandName: item?.command ?? row?.command,
            packageID: row?.inventory?.packageID,
            appPath: appPath(detected: item?.detectedPaths ?? [], planned: planned),
            status: item?.status.rawValue ?? "listed",
            observedVersion: item?.currentVersionRaw,
            currentPlannedCommand: planned.map(trimmedCommand),
            competing: competing,
            description: item?.description ?? row?.description)
    }

    /// The item's own `.app`, from its detected paths or from the planned update command.
    static func appPath(detected: [String], planned: String?) -> String? {
        if let path = detected.first(where: { $0.hasSuffix(".app") }) { return path }
        guard let planned,
              let range = planned.range(of: #"/[^'"]+\.app"#, options: .regularExpression) else { return nil }
        return String(planned[range])
    }

    /// The planned command shown to the agent: without the long login PATH prefix, and capped.
    static func trimmedCommand(_ command: String) -> String {
        let stripped = command.replacingOccurrences(of: #"^PATH='[^']*' "#, with: "", options: .regularExpression)
        return String(stripped.prefix(300))
    }

    static func loadFixture(path: String) -> AgentItemContext? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        struct Wrapper: Decodable { let context: AgentItemContext }
        // Eval fixtures wrap the context with a kind and a reason; a bare context also works.
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) { return wrapped.context }
        return try? JSONDecoder().decode(AgentItemContext.self, from: data)
    }

    /// The whole pipeline for one item. Returns the process exit code and prints one report.
    static func run(
        context: AgentItemContext,
        json: Bool,
        backend: AgentBackend,
        collector: EvidenceCollector = EvidenceCollector(),
        environment: ProposalEnvironment = .live(),
        output: (String) -> Void = { print($0) }
    ) async -> Int32 {
        let detection = await backend.detect()
        guard case .available(_, let backendVersion) = detection else {
            if case .unavailable(let reason) = detection {
                output(json ? jsonString(["item": context.id, "backend": backend.id, "error": reason, "executed": false, "saved": false])
                            : "Agent backend \(backend.id) is unavailable: \(reason)")
            }
            return 2
        }

        let evidence = await collector.collect(for: context)
        let prompt = AgentPrompt.build(for: context, evidence: evidence)
        let leaks = AgentRedaction.leaks(in: prompt)
        let response = await backend.investigate(AgentRequest(prompt: prompt, schemaJSON: ProposalSchema.json))

        var report: [String: Any] = [
            "item": context.id,
            "backend": backend.id,
            "backendVersion": backendVersion,
            "toolPolicy": ["noToolsEnforced": backend.toolPolicy.noToolsEnforced,
                           "mechanism": backend.toolPolicy.mechanism,
                           "gap": (backend.toolPolicy.gap as Any?) ?? NSNull()] as [String: Any],
            "evidence": evidence.items.map { ["kind": $0.kind, "source": $0.source, "chars": $0.text.count, "truncated": $0.truncated] as [String: Any] },
            "evidenceNotes": evidence.notes,
            "sentToAgent": prompt,
            "redactionCheck": ["passed": leaks.isEmpty, "leaks": leaks],
            "latencyMs": response.latencyMs,
            "usage": usageJSON(response.usage),
            "reportedCostUSD": response.reportedCostUSD ?? "unknown",
            "agentToolCalls": response.agentCommands.map { AgentRedaction.redact($0) },
            "executed": false,
            "saved": false,
        ]

        switch response.outcome {
        case .failed(let reason):
            report["outcome"] = "agentFailed"
            report["reason"] = reason
            report["verdict"] = ["name": "invalid", "reasons": [reason]]
            emit(report, json: json, output: output)
            return 2
        case .completed(let raw):
            let evaluation = await ProposalValidator.evaluate(raw: raw, context: context, evidence: evidence, environment: environment)
            report["outcome"] = "completed"
            report["schemaValid"] = evaluation.proposal != nil
            report["verdict"] = ["name": evaluation.verdict.name, "reasons": evaluation.verdict.reasons]
            report["ownerCheck"] = evaluation.ownerCheck
            report["taint"] = evaluation.taint.map { ["token": $0.token, "kind": $0.kind] }
            if let proposal = evaluation.proposal, let data = try? JSONEncoder().encode(proposal),
               let object = try? JSONSerialization.jsonObject(with: data) {
                report["proposal"] = object
                report["recommendation"] = proposal.recommendation.rawValue
            } else {
                // Invalid output is discarded, never repaired. Only a short redacted excerpt is kept.
                let excerpt = String(data: raw.prefix(400), encoding: .utf8) ?? "<binary>"
                report["discardedOutputExcerpt"] = AgentRedaction.redact(excerpt)
            }
            var commands: [String: Any] = [:]
            for assessment in [evaluation.version, evaluation.update].compactMap({ $0 }) {
                commands[assessment.role] = ["display": assessment.display, "risks": assessment.risks]
            }
            report["commands"] = commands
            if let removal = evaluation.removalSuggestion {
                // Built by the engine from the item's identity. Shown as text; never run.
                let command: Any = removal.copyableCommand ?? NSNull()
                report["removalSuggestion"] = ["text": removal.text, "copyableCommand": command, "gate": removal.gate] as [String: Any]
            }
            emit(report, json: json, output: output)
            return 0
        }
    }

    private static func usageJSON(_ usage: AgentUsage?) -> Any {
        guard let usage else { return "unknown" }
        var object: [String: Any] = [:]
        if let value = usage.inputTokens { object["inputTokens"] = value }
        if let value = usage.cachedInputTokens { object["cachedInputTokens"] = value }
        if let value = usage.outputTokens { object["outputTokens"] = value }
        if let value = usage.reasoningTokens { object["reasoningTokens"] = value }
        return object
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func emit(_ report: [String: Any], json: Bool, output: (String) -> Void) {
        if json {
            output(jsonString(report))
            return
        }
        let verdict = report["verdict"] as? [String: Any]
        output("Item: \(report["item"] ?? "?")")
        output("Backend: \(report["backend"] ?? "?") \(report["backendVersion"] ?? "")")
        if let policy = report["toolPolicy"] as? [String: Any], policy["noToolsEnforced"] as? Bool == false {
            output("Note: this backend cannot fully disable the agent's tools. \(policy["gap"] ?? "")")
        }
        output("Latency: \(report["latencyMs"] ?? "?") ms")
        if let recommendation = report["recommendation"] { output("Recommendation: \(recommendation)") }
        if let proposal = report["proposal"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: proposal, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            output("Proposal:\n\(text)")
        } else {
            output("Proposal: none (\(report["reason"] ?? "invalid output, discarded"))")
        }
        if let removal = report["removalSuggestion"] as? [String: Any] {
            output("Removal suggestion (not run): \(removal["text"] ?? "")")
            if let command = removal["copyableCommand"] as? String { output("  \(command)   [\(removal["gate"] ?? "")]") }
        }
        output("Verdict: \(verdict?["name"] ?? "?") \((verdict?["reasons"] as? [String])?.joined(separator: "; ") ?? "")")
        output("Nothing was executed and nothing was saved.")
    }
}
