import Foundation

/// ADR-003 spike CLI: `--propose <itemID> [--json]` and `--propose-fixture <file.json> [--json]`.
///
/// It asks the agent for a proposal, validates it, and PRINTS both. It never executes the proposed
/// commands (not even as a dry run), never saves anything, and never writes to settings or the
/// catalog. The only process the engine starts is the agent itself, inside Codex's read-only sandbox.
enum AgentProposeCommand {
    /// Builds the context for a live item: the catalog row from `--check`, plus what discovery knows
    /// (the owner root, the competing installs that shadow it).
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
        return AgentItemContext(
            id: itemID,
            name: item?.name ?? row?.name ?? itemID,
            category: item?.category.rawValue ?? row?.category.rawValue,
            ecosystem: row?.inventory?.ecosystem.rawValue,
            handle: row?.handle,
            root: row?.inventory?.rootPath,
            commandName: item?.command ?? row?.command,
            status: item?.status.rawValue ?? "listed",
            observedVersion: item?.currentVersionRaw,
            currentPlannedCommand: item.map { Self.trimmedCommand($0.plannedUpdateCommandSpec?.displayString ?? $0.updateCommand) },
            competing: competing,
            description: item?.description ?? row?.description)
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

    /// The whole spike pipeline for one item. Returns the process exit code and prints one report.
    static func run(
        context: AgentItemContext,
        json: Bool,
        backend: AgentBackend = CodexBackend(),
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

        let prompt = AgentPrompt.build(for: context)
        let leaks = AgentRedaction.leaks(in: prompt)
        let response = await backend.investigate(AgentRequest(prompt: prompt, schemaJSON: ProposalSchema.json))

        var report: [String: Any] = [
            "item": context.id,
            "backend": backend.id,
            "backendVersion": backendVersion,
            "sentToAgent": prompt,
            "redactionCheck": ["passed": leaks.isEmpty, "leaks": leaks],
            "latencyMs": response.latencyMs,
            "usage": usageJSON(response.usage),
            "agentCommands": response.agentCommands.map { AgentRedaction.redact($0) },
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
            let evaluation = await ProposalValidator.evaluate(raw: raw, context: context, environment: environment)
            report["outcome"] = "completed"
            report["schemaValid"] = evaluation.proposal != nil
            report["verdict"] = ["name": evaluation.verdict.name, "reasons": evaluation.verdict.reasons]
            report["ownerCheck"] = evaluation.ownerCheck
            if let proposal = evaluation.proposal, let data = try? JSONEncoder().encode(proposal),
               let object = try? JSONSerialization.jsonObject(with: data) {
                report["proposal"] = object
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
        output("Latency: \(report["latencyMs"] ?? "?") ms")
        if let proposal = report["proposal"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: proposal, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            output("Proposal:\n\(text)")
        } else {
            output("Proposal: none (\(report["reason"] ?? "invalid output, discarded"))")
        }
        output("Verdict: \(verdict?["name"] ?? "?") \((verdict?["reasons"] as? [String])?.joined(separator: "; ") ?? "")")
        output("Nothing was executed and nothing was saved.")
    }
}
