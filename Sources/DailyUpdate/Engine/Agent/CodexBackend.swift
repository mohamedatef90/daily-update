import Foundation

/// Codex adapter (verified against codex-cli 0.167.0 on this Mac).
///
/// Invocation:
///   codex exec --json --sandbox read-only --ephemeral --skip-git-repo-check \
///     --ignore-user-config --ignore-rules --output-schema <schema> -o <out> -C <empty dir> "<prompt>"
///
/// Decisions (also in docs/adr/ADR-003-spike-notes.md):
/// - `--ignore-user-config` and `--ignore-rules`: the user's `config.toml` may set a full-access
///   sandbox or an approval policy, and an execpolicy rule may allow a command outside the sandbox.
///   The engine passes `--sandbox read-only` itself and loads neither. Authentication still works,
///   because it lives in `auth.json`, not in the config file (checked on this Mac).
/// - `--json`: stdout becomes JSON events, which report token usage and every command the agent ran
///   inside its sandbox. The proposal itself is read from the `-o` file, not from the events.
/// - The process runs through `BoundedProcessRunner` with an exact environment (nothing inherited),
///   a hard timeout, and an output cap. The working directory is a new empty temporary directory.
struct CodexBackend: AgentBackend {
    typealias Runner = (BoundedProcessSpec) async -> QueryOutcome

    let id = "codex"

    /// Verified on codex-cli 0.167.0 by asking the model for its own tool list and by trying to make it
    /// run a command (see docs/adr/ADR-003-spike-notes.md). Codex has no single switch that removes every
    /// tool. These flags remove the shell, the code-mode exec tool, web search, image generation, goals,
    /// sub-agents, apps, plugins, the browser and computer use, and hooks. `apply_patch`, `view_image`, the
    /// MCP resource tools and the collaboration tools still exist, so this is NOT claimed as enforced.
    /// What still limits the agent: the read-only sandbox, an empty working directory, no config or rules
    /// loaded, and an evidence-only prompt.
    let toolPolicy = AgentToolPolicy(
        noToolsEnforced: false,
        mechanism: "--disable shell_tool,unified_exec,code_mode_host,multi_agent,goals,image_generation,apps,plugins,browser_use,computer_use,hooks and web_search=disabled; read-only sandbox; empty working directory",
        gap: "Codex has no switch that removes every tool: apply_patch, view_image, the MCP resource tools and the collaboration tools remain available to the model. Shell, code mode, web and sub-agents are disabled.")
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "code_mode_host", "multi_agent", "goals", "image_generation", "apps",
        "plugins", "browser_use", "computer_use", "hooks",
    ]
    var locate: () -> String?
    var run: Runner
    var maxStdoutBytes = 512 * 1024

    init(locate: @escaping () -> String? = CodexBackend.liveLocate, run: @escaping Runner = BoundedProcessRunner.run) {
        self.locate = locate
        self.run = run
    }

    /// Looks for `codex` on this process's PATH, then in the usual install folders (npm global under
    /// nvm, Homebrew, /usr/local). A path is used only if `PathTrust` accepts it.
    static func liveLocate() -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        let nvmRoot = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            directories += versions.sorted(by: >).map { nvmRoot + "/" + $0 + "/bin" }
        }
        let candidates = PathSearch.candidates(for: "codex", pathEntries: directories, fileSystem: LiveFileSystem())
        return candidates.first { PathTrust.isTrustedExecutable($0) }
    }

    /// Nothing is inherited. `PATH` carries the codex directory first (its launcher is a node script).
    static func environment(codexExecutable: String, tempDirectory: String) -> [String: String] {
        let codexDirectory = URL(fileURLWithPath: codexExecutable).deletingLastPathComponent().path
        return [
            "HOME": NSHomeDirectory(),
            "PATH": [codexDirectory, "/opt/homebrew/bin", "/usr/bin", "/bin"].joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "TMPDIR": tempDirectory,
        ]
    }

    static func arguments(schemaPath: String, outputPath: String, workDirectory: String, prompt: String) -> [String] {
        [
            "exec", "--json",
        ] + disabledFeatures.flatMap { ["--disable", $0] } + [
            "-c", "web_search=\"disabled\"",
            "--sandbox", "read-only",
            "--ephemeral", "--skip-git-repo-check",
            "--ignore-user-config", "--ignore-rules",
            "--output-schema", schemaPath,
            "-o", outputPath,
            "-C", workDirectory,
            prompt,
        ]
    }

    func detect() async -> AgentDetection {
        guard let executable = locate() else { return .unavailable("codex was not found in a trusted location") }
        let outcome = await run(BoundedProcessSpec(
            executable: executable, arguments: ["--version"],
            environment: .exactly(Self.environment(codexExecutable: executable, tempDirectory: NSTemporaryDirectory())),
            timeout: 15, maxStdoutBytes: 4096))
        guard case .exited(0) = outcome.evidence.termination,
              let text = String(data: outcome.stdout, encoding: .utf8),
              let range = text.range(of: #"codex-cli [0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else {
            return .unavailable("codex --version did not answer as expected")
        }
        return .available(executable: executable, version: String(text[range]).replacingOccurrences(of: "codex-cli ", with: ""))
    }

    func investigate(_ request: AgentRequest) async -> AgentResponse {
        let start = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        guard let executable = locate() else {
            return AgentResponse(outcome: .failed("codex was not found"), latencyMs: elapsed(), usage: nil, agentCommands: [])
        }

        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dailyupdate-agent-\(UUID().uuidString)")
        let workDirectory = root.appendingPathComponent("work")
        let schemaURL = root.appendingPathComponent("proposal.schema.json")
        let outputURL = root.appendingPathComponent("proposal.json")
        defer { try? fileManager.removeItem(at: root) }
        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(request.schemaJSON.utf8).write(to: schemaURL)
        } catch {
            return AgentResponse(outcome: .failed("could not prepare the temporary directory"), latencyMs: elapsed(), usage: nil, agentCommands: [])
        }

        let outcome = await run(BoundedProcessSpec(
            executable: executable,
            arguments: Self.arguments(schemaPath: schemaURL.path, outputPath: outputURL.path,
                                      workDirectory: workDirectory.path, prompt: request.prompt),
            environment: .exactly(Self.environment(codexExecutable: executable, tempDirectory: root.path)),
            timeout: min(request.timeout, 120),
            maxStdoutBytes: maxStdoutBytes,
            workingDirectory: workDirectory.path))

        let events = Self.parseEvents(outcome.stdout)
        switch outcome.evidence.termination {
        case .exited(0):
            break
        case .timedOut(let afterMs):
            return AgentResponse(outcome: .failed("timed out after \(afterMs) ms"), latencyMs: elapsed(), usage: events.usage, agentCommands: events.commands)
        case .outputCapExceeded:
            return AgentResponse(outcome: .failed("output cap exceeded"), latencyMs: elapsed(), usage: events.usage, agentCommands: events.commands)
        case .exited(let code):
            return AgentResponse(outcome: .failed("codex exited with status \(code)"), latencyMs: elapsed(), usage: events.usage, agentCommands: events.commands)
        case .signaled(let signal):
            return AgentResponse(outcome: .failed("codex was killed by signal \(signal)"), latencyMs: elapsed(), usage: events.usage, agentCommands: events.commands)
        case .launchFailed(let message):
            return AgentResponse(outcome: .failed("launch failed: \(message)"), latencyMs: elapsed(), usage: nil, agentCommands: [])
        }

        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            return AgentResponse(outcome: .failed("codex wrote no output file"), latencyMs: elapsed(), usage: events.usage, agentCommands: events.commands)
        }
        return AgentResponse(outcome: .completed(data), latencyMs: elapsed(), usage: events.usage, agentCommands: events.commands)
    }

    /// Reads the `--json` event stream. Anything unreadable is skipped: events are evidence for the
    /// report, never an input to the engine's decision.
    static func parseEvents(_ stdout: Data) -> (usage: AgentUsage?, commands: [String]) {
        var usage: AgentUsage?
        var commands: [String] = []
        guard let text = String(data: stdout, encoding: .utf8) else { return (nil, []) }
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "turn.completed", let raw = object["usage"] as? [String: Any] {
                usage = AgentUsage(
                    inputTokens: raw["input_tokens"] as? Int,
                    cachedInputTokens: raw["cached_input_tokens"] as? Int,
                    outputTokens: raw["output_tokens"] as? Int,
                    reasoningTokens: raw["reasoning_output_tokens"] as? Int)
            }
            if type == "item.started", let item = object["item"] as? [String: Any],
               item["type"] as? String == "command_execution", let command = item["command"] as? String {
                commands.append(String(command.prefix(300)))
            }
        }
        return (usage, commands)
    }
}
