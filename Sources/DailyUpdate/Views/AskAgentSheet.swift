import SwiftUI
import AppKit

/// AI-2: what the agent proposed, what the engine decided, exactly what was sent, and what it cost.
/// Nothing here runs a command. The only action that writes anything is "Save as custom item", and it is
/// enabled only for an accepted proposal that recommends an update.
struct AskAgentSheet: View {
    @EnvironmentObject var appState: AppState
    let session: AgentSession
    @State private var showSent = false
    @State private var saveMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch session.phase {
                    case .running: running
                    case .failed(let message): failed(message)
                    case .finished(let result): finished(result)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 640)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask agent about \(session.itemName)").font(.headline)
                Text("The agent suggests. The engine checks. Nothing is run or saved unless you choose to save it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var running: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Asking \(session.backend == .claudeCode ? "Claude Code" : "Codex")… usually 10 to 20 seconds.")
        }
    }

    private func failed(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }

    @ViewBuilder
    private func finished(_ result: AgentProposeCommand.Result) -> some View {
        if case .failed(let reason) = result.response.outcome {
            failed("The agent did not answer: \(reason)")
        } else {
            verdictBanner(result)
            if let proposal = result.proposal {
                proposalSection(proposal, result: result)
            } else if let excerpt = result.discardedExcerpt {
                section("Answer discarded") {
                    Text("The answer did not match the required format, so it was thrown away, not repaired.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(excerpt).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let removal = result.evaluation?.removalSuggestion {
                section("Possible removal (never run by this app)") {
                    Text(removal.text).font(.caption)
                    if let command = removal.copyableCommand {
                        Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(removal.gate).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            sentSection(result)
            metricsSection(result)
        }
    }

    private func verdictBanner(_ result: AgentProposeCommand.Result) -> some View {
        let verdict = result.verdict
        let (color, icon, title): (Color, String, String) = {
            switch verdict {
            case .acceptedCandidate: return (.green, "checkmark.seal.fill", "Engine verdict: accepted candidate")
            case .gated: return (.orange, "exclamationmark.triangle.fill", "Engine verdict: needs a person (gated)")
            case .blocked: return (.red, "xmark.octagon.fill", "Engine verdict: blocked")
            case .invalid: return (.red, "questionmark.diamond.fill", "Engine verdict: invalid answer")
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            ForEach(verdict.reasons, id: \.self) { Text("• \($0)").font(.caption) }
            if verdict == .acceptedCandidate {
                Text("Accepted means it passed the safety checks. It has not been run.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func proposalSection(_ proposal: AgentProposal, result: AgentProposeCommand.Result) -> some View {
        section("Proposal") {
            row("Recommendation", proposal.recommendation.rawValue + " — " + proposal.recommendationReason)
            row("Owner", proposal.ownerKind.rawValue)
            row("Reads the version with", result.evaluation?.version?.display ?? "no version command proposed", mono: true)
            row("Updates with", result.evaluation?.update?.display ?? "no update command proposed", mono: true)
            row("Confidence", String(format: "%.2f (the agent's own number; treat it as a hint)", proposal.confidence))
            if !proposal.notes.isEmpty { row("Notes", proposal.notes) }
            if !proposal.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What it relied on").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(proposal.evidence.enumerated()), id: \.offset) { _, entry in
                        Text("• \(entry.target): \(entry.finding)").font(.caption)
                    }
                }
            }
        }
    }

    private func sentSection(_ result: AgentProposeCommand.Result) -> some View {
        section("Exactly what was sent") {
            Text(result.redactionLeaks.isEmpty
                 ? "Your home folder and account name were replaced (~ and <user>) before sending."
                 : "Warning: \(result.redactionLeaks.joined(separator: ", ")) may still appear in what was sent.")
                .font(.caption).foregroundStyle(result.redactionLeaks.isEmpty ? Color.secondary : Color.orange)
            DisclosureGroup("Show the full text (\(result.sentToAgent.count) characters)", isExpanded: $showSent) {
                Text(result.sentToAgent)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    private func metricsSection(_ result: AgentProposeCommand.Result) -> some View {
        section("Agent and cost") {
            row("Agent", "\(result.backendID) \(result.backendVersion)")
            row("Time", String(format: "%.1f s", Double(result.response.latencyMs) / 1000))
            if let usage = result.response.usage {
                row("Tokens", "\(usage.inputTokens ?? 0) in, \(usage.outputTokens ?? 0) out")
            } else {
                row("Tokens", "not reported")
            }
            row("Cost", result.response.reportedCostUSD.map { String(format: "$%.3f (as reported by the agent's own tool)", $0) } ?? "not reported")
            if let probe = result.evidence.probe {
                row("Version probe", probe.outcome.rawValue + (probe.detail.isEmpty ? "" : " — \(probe.detail)"))
            }
            if !result.toolPolicy.noToolsEnforced, let gap = result.toolPolicy.gap {
                Label("This agent cannot be fully stopped from using tools. \(gap)", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !result.response.agentCommands.isEmpty {
                Label("The agent tried to use a tool: \(result.response.agentCommands.joined(separator: "; "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if case .finished(let result) = session.phase {
                let decision = appState.agentSaveDecision(for: result)
                Button("Copy") { copy(result) }
                Button("Save as custom item") {
                    if case .notAllowed(let reason) = appState.saveAgentProposalAsCustomItem() { saveMessage = reason }
                }
                .disabled(!decision.isAllowed)
                .help(decision.isAllowed ? "Adds this to your list. It will ask for your review before it runs anything." : disabledReason(decision))
                if let saved = session.savedItemName {
                    Label("Saved \(saved). Review it before it runs.", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if case .notAllowed(let reason) = decision {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button("Close") { appState.closeAgentSession() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func disabledReason(_ decision: AgentSaveDecision) -> String {
        if case .notAllowed(let reason) = decision { return reason }
        return ""
    }

    private func copy(_ result: AgentProposeCommand.Result) {
        var lines: [String] = []
        if let proposal = result.proposal {
            lines.append("Recommendation: \(proposal.recommendation.rawValue) — \(proposal.recommendationReason)")
            if let version = result.evaluation?.version?.display { lines.append("Version: \(version)") }
            if let update = result.evaluation?.update?.display { lines.append("Update: \(update)") }
        }
        if let removal = result.evaluation?.removalSuggestion?.copyableCommand { lines.append("Removal (your decision): \(removal)") }
        lines.append("Engine verdict: \(result.verdict.name) \(result.verdict.reasons.joined(separator: "; "))")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
