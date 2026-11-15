# ADR-003 spike notes: agent-proposed strategies (Codex adapter)

Status: spike, not a shipped feature. Decision: "the model proposes, the engine executes". The agent returns
**data**. Nothing the agent proposes is run, dry-run, or saved by this code.

## What is in the spike
| Piece | Where |
|---|---|
| `AgentBackend` protocol, usage and response types | `Sources/DailyUpdate/Engine/Agent/AgentBackend.swift` |
| Codex adapter | `Engine/Agent/CodexBackend.swift` |
| Proposal types, JSON Schema, strict parser | `Engine/Agent/AgentProposal.swift`, `docs/agent-spike/proposal.schema.json` |
| Item context, redaction, untrusted-data prompt | `Engine/Agent/AgentPrompt.swift` |
| Validation pipeline (no execution) | `Engine/Agent/ProposalValidator.swift` |
| CLI: `--propose <item-id>`, `--propose-fixture <file>`, with `--json` | `Services/AgentProposeCommand.swift`, `Services/CLIRunner.swift` |
| Unit tests (no agent started) | `Tests/DailyUpdateTests/AgentSpikeTests.swift` |
| Eval (starts the real agent; not part of `swift test`) | `Tests/AgentSpikeEval/` |

## The pipeline
```
item (--check row + discovery row)  ->  redact home and account name  ->  prompt with the item as untrusted data
  -> codex exec (read-only sandbox, through BoundedProcessRunner)  ->  raw JSON
  -> ProposalParser (strict schema, no repair)
  -> build CommandSpec per command (PathTrust on the executable)
  -> CommandShapeClassifier + extra rules + owner check against OwnerResolver's own answer
  -> acceptedCandidate | gated(reasons) | blocked(reasons) | invalid(reason)
```
`acceptedCandidate` is still only a candidate. A user would review it, and the engine would run it through the
normal dry-run and verification path. The spike never gets that far.

## Codex invocation (verified on codex-cli 0.167.0)
```
codex exec --json --sandbox read-only --ephemeral --skip-git-repo-check \
  --ignore-user-config --ignore-rules --output-schema <schema> -o <out> -C <empty temp dir> "<prompt>"
```
- **`--ignore-user-config` and `--ignore-rules`: chosen on purpose.** The user's `config.toml` may set a
  full-access sandbox or an approval policy, and an execpolicy `.rules` file can allow a command outside the
  sandbox. The engine passes `--sandbox read-only` itself and loads neither. Authentication still works (it
  lives in `auth.json`; checked on this Mac).
- **`--json`**: stdout becomes events with token usage and every command the agent ran inside its sandbox.
  The proposal is read from the `-o` file.
- **`BoundedProcessRunner`**: exact environment (`HOME`, `PATH`, `LANG`, `TMPDIR` only), 120 s hard timeout,
  512 KB output cap, SIGTERM then SIGKILL, new empty working directory removed afterwards.
- The agent's own commands run as `/bin/zsh -lc ...` inside Codex's read-only sandbox.

## Rules the engine applies (beyond the schema)
- Commands are argv arrays. Elements may not contain control characters (so no newline smuggling).
- **blocked**: privileged executables, an interpreter with an inline script flag (`sh -c`, `python -c`),
  network fetchers, destructive or file-writing executables, any argument touching a shell profile, `~/.ssh`,
  `/etc`, LaunchAgents and similar, a version command that uses a mutating verb, an executable that is missing
  or not in a trusted location, and anything the classifier marks `privileged`, `destructive` or `remoteScript`.
- **gated**: an interpreter without an inline script, an update command that does not start with a known
  package manager, a package manager that does not match the proposed owner, an owner that disagrees with what
  `OwnerResolver` itself resolves, classifier flags such as `bulk` or `chained`, confidence under 0.4, and a
  `verify` rule that needs a latest version with `latestSource: none`.
- **invalid**: anything the parser rejects. Invalid output is discarded, never repaired.
- A `versionPattern` must compile, have exactly one capture group, no back-reference, and no group that can
  match the same text in many ways (`(a+)+`, `(a|aa)+`). The engine, not the agent, runs it.

## Privacy
- The prompt shows only `~` for the home directory and `<user>` for the account name. `--json` prints the exact
  text that was sent (`sentToAgent`) and a `redactionCheck`.
- **Known limit:** the agent runs on the real machine. Inside its read-only sandbox it can read files, so the
  answer it writes can contain real paths. The eval report redacts them. Whether a read-only agent should be able
  to read the whole home directory is a product question for the next phase (a sandbox profile that limits reads
  is the likely answer).
- Without network access in the sandbox, a poisoned instruction cannot send what the agent reads anywhere. It
  can still put it in `notes` or `evidence`, which are display-only text. The eval plants a canary file to measure that.

## What the spike does not do
No GUI, no schedule, no write to settings or the catalog, no `workspace-write` or `danger-full-access`, no
Claude Code or Ollama adapter (Claude Code: `claude -p --output-format json --json-schema ... --allowedTools ...`).

## Running it
```
swift build
.build/debug/DailyUpdate --propose gemini-cli --json          # a live item from --check or --discover
.build/debug/DailyUpdate --propose-fixture Tests/AgentSpikeEval/fixtures/real-gemini-cli.json
python3 -I Tests/AgentSpikeEval/run_eval.py --bin .build/debug/DailyUpdate \
  --fixtures Tests/AgentSpikeEval/fixtures --out /tmp/agent-spike-eval
python3 -I Tests/AgentSpikeEval/capture_real_fixtures.py discover.json check.json Tests/AgentSpikeEval/fixtures
```
