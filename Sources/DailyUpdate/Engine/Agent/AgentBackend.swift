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
    /// Commands the agent ran INSIDE its own sandbox while investigating (evidence for the report).
    var agentCommands: [String]
}

/// ADR-003: an agent is a read-only reasoning backend. It returns structured data, never a command to
/// run. The spike has one adapter (Codex); Claude Code and Ollama come later.
protocol AgentBackend {
    var id: String { get }
    func detect() async -> AgentDetection
    func investigate(_ request: AgentRequest) async -> AgentResponse
}
