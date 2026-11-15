import Foundation

/// Claude Code adapter (verified against Claude Code 2.1.322 on this Mac).
///
/// Invocation:
///   claude -p "<prompt>" --output-format json --json-schema '<schema>' --tools= \
///     --disallowedTools "Bash Read Edit Write NotebookEdit WebFetch WebSearch Glob Grep Task TodoWrite" \
///     --strict-mcp-config --no-session-persistence --setting-sources ""
///
/// This is the backend with an ENFORCEABLE no-tools mode. `--tools=` (an empty list) removes every
/// built-in tool; `--strict-mcp-config` with no config loads no MCP server; `--setting-sources ""` loads no
/// user, project or local settings (so no hooks and no permission rules). With these flags the model's own
/// tool list is just `StructuredOutput`, the tool that returns the answer (checked by asking it, and by
/// the eval). `--disallowedTools` repeats the denial by name as a second layer.
/// The prompt comes first because `--tools` and `--disallowedTools` take a list of values.
/// The process runs through `BoundedProcessRunner` with an exact environment and an empty working
/// directory, so no project `CLAUDE.md` is read. `USER` and `LOGNAME` are needed for the keychain login.
struct ClaudeCodeBackend: AgentBackend {
    typealias Runner = (BoundedProcessSpec) async -> QueryOutcome

    let id = "claude"
    let toolPolicy = AgentToolPolicy(
        noToolsEnforced: true,
        mechanism: "--tools= (no built-in tool), --disallowedTools (second layer), --strict-mcp-config, --setting-sources \"\"; the model's own tool list is StructuredOutput only",
        gap: nil)
    static let deniedTools = "Bash Read Edit Write NotebookEdit WebFetch WebSearch Glob Grep Task TodoWrite"

    var locate: () -> String?
    var run: Runner
    var maxStdoutBytes = 512 * 1024

    init(locate: @escaping () -> String? = ClaudeCodeBackend.liveLocate, run: @escaping Runner = BoundedProcessRunner.run) {
        self.locate = locate
        self.run = run
    }

    static func liveLocate() -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let candidates = PathSearch.candidates(for: "claude", pathEntries: directories, fileSystem: LiveFileSystem())
        return candidates.first { PathTrust.isTrustedExecutable($0) }
    }

    static func environment(executable: String, tempDirectory: String) -> [String: String] {
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        return [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": [directory, "/usr/bin", "/bin"].joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "TMPDIR": tempDirectory,
        ]
    }

    /// One-line JSON for `--json-schema`.
    static func compactSchema(_ schema: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func arguments(prompt: String, compactSchema: String) -> [String] {
        [
            "-p", prompt,
            "--output-format", "json",
            "--json-schema", compactSchema,
            "--tools=",
            "--disallowedTools", deniedTools,
            "--strict-mcp-config",
            "--no-session-persistence",
            "--setting-sources", "",
        ]
    }

    func detect() async -> AgentDetection {
        guard let executable = locate() else { return .unavailable("claude was not found in a trusted location") }
        let outcome = await run(BoundedProcessSpec(
            executable: executable, arguments: ["--version"],
            environment: .exactly(Self.environment(executable: executable, tempDirectory: NSTemporaryDirectory())),
            timeout: 15, maxStdoutBytes: 4096))
        guard case .exited(0) = outcome.evidence.termination,
              let text = String(data: outcome.stdout, encoding: .utf8),
              let range = text.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else {
            return .unavailable("claude --version did not answer as expected")
        }
        return .available(executable: executable, version: String(text[range]))
    }

    func investigate(_ request: AgentRequest) async -> AgentResponse {
        let start = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        func failed(_ reason: String, usage: AgentUsage? = nil, cost: Double? = nil) -> AgentResponse {
            AgentResponse(outcome: .failed(reason), latencyMs: elapsed(), usage: usage, agentCommands: [], reportedCostUSD: cost)
        }
        guard let executable = locate() else { return failed("claude was not found") }
        guard let schema = Self.compactSchema(request.schemaJSON) else { return failed("the schema is not valid JSON") }

        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dailyupdate-agent-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return failed("could not prepare the temporary directory")
        }

        let outcome = await run(BoundedProcessSpec(
            executable: executable,
            arguments: Self.arguments(prompt: request.prompt, compactSchema: schema),
            environment: .exactly(Self.environment(executable: executable, tempDirectory: root.path)),
            timeout: min(request.timeout, 120),
            maxStdoutBytes: maxStdoutBytes,
            workingDirectory: root.path))

        switch outcome.evidence.termination {
        case .exited(0): break
        case .timedOut(let afterMs): return failed("timed out after \(afterMs) ms")
        case .outputCapExceeded: return failed("output cap exceeded")
        case .exited(let code): return failed("claude exited with status \(code)")
        case .signaled(let signal): return failed("claude was killed by signal \(signal)")
        case .launchFailed(let message): return failed("launch failed: \(message)")
        }

        guard let object = (try? JSONSerialization.jsonObject(with: outcome.stdout)) as? [String: Any] else {
            return failed("claude did not return a JSON result")
        }
        let usage = Self.usage(from: object)
        let cost = object["total_cost_usd"] as? Double
        if object["is_error"] as? Bool == true {
            return failed("claude reported an error: \(String((object["result"] as? String ?? "").prefix(120)))", usage: usage, cost: cost)
        }
        // Only the schema-enforced `structured_output` is accepted. Free text in `result` is ignored.
        guard let structured = object["structured_output"], JSONSerialization.isValidJSONObject(structured),
              let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) else {
            return failed("claude returned no structured output", usage: usage, cost: cost)
        }
        // A permission denial means the model tried a tool that is turned off: reported as a violation attempt.
        let denials = (object["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
        return AgentResponse(outcome: .completed(data), latencyMs: elapsed(), usage: usage,
                             agentCommands: denials.map { "denied tool call: \($0)" }, reportedCostUSD: cost)
    }

    static func usage(from object: [String: Any]) -> AgentUsage? {
        guard let raw = object["usage"] as? [String: Any] else { return nil }
        let input = (raw["input_tokens"] as? Int ?? 0) + (raw["cache_creation_input_tokens"] as? Int ?? 0) + (raw["cache_read_input_tokens"] as? Int ?? 0)
        return AgentUsage(inputTokens: input, cachedInputTokens: raw["cache_read_input_tokens"] as? Int,
                          outputTokens: raw["output_tokens"] as? Int, reasoningTokens: nil)
    }
}
