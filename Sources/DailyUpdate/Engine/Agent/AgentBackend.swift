import Foundation

struct AgentUsage: Equatable, Codable {
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
}

enum AgentDetection: Equatable {
    case available(executable: String, version: String)
    case unavailable(String)
}

struct AgentRequest {
    var prompt: String
    var schemaJSON: String
    var timeout: TimeInterval = 120
}

enum AgentOutcome: Equatable {
    /// The raw final message the agent wrote. It is NOT trusted: it still has to pass `ProposalParser`.
    case completed(Data)
    case failed(String)
}

struct AgentResponse {
    var outcome: AgentOutcome
    var latencyMs: Int
    /// Nil when the backend did not report usage ("unknown" in the eval report).
    var usage: AgentUsage?
    /// Tool calls the agent made while answering. Under "evidence in, no tools" this must be empty; any
    /// entry is reported as a violation.
    var agentCommands: [String]
    /// The cost the CLI itself reported, when it reports one (Claude Code does, Codex does not).
    var reportedCostUSD: Double? = nil
}

/// What the adapter can and cannot guarantee about the agent's tools. Reported, never assumed.
struct AgentToolPolicy: Equatable {
    /// True only when the CLI has a documented switch that leaves the model with no tool but the
    /// structured answer, and the adapter uses it.
    var noToolsEnforced: Bool
    var mechanism: String
    /// What is NOT covered, in plain words. Nil when nothing is known to be left.
    var gap: String?
}

/// ADR-003: an agent is a read-only reasoning backend. It returns structured data, never a command to
/// run. The spike has one adapter (Codex); Claude Code and Ollama come later.
protocol AgentBackend {
    var id: String { get }
    var toolPolicy: AgentToolPolicy { get }
    func detect() async -> AgentDetection
    func investigate(_ request: AgentRequest) async -> AgentResponse
}
