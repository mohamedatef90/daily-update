# ADR-003 notes: agent-proposed strategies (spike, then AI-1 hardening)

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


---

# AI-1 hardening (behind the `agentProposals` flag, default Off)

Still nothing is executed, dry-run or saved, and there is no GUI. Saving a proposal as a custom item comes with
the GUI in M2.

## Evidence in, no tools
The engine now collects a single item's facts itself (`EvidenceCollector`); the agent gets only that evidence and
the schema.
- `which -a <command>` and the real path chain (through `PathSearch`, no process);
- `<command> --version` (through `BoundedProcessRunner`, exact environment, 10 s, 4 KB, the command passes
  `CommandShapeClassifier` and `PathTrust` first);
- `brew info --json=v2 <name>` for a brew formula or cask, inside the network-denied, write-denied sandbox profile
  that discovery already uses;
- the package's own `package.json` (npm; field values capped, script NAMES only), read through
  `ReadOnlyFileSystem` from `<root>/lib/node_modules/<package>/` only;
- the app's own `Contents/Info.plist` (only under `/Applications` or `~/Applications`; listed keys only).
Caps: 3,000 characters per item, 12,000 in total, 64 KB manifest, 256 KB plist, 300 characters per field. No
directory listing. Everything is redacted (`~`, `<user>`) and sits inside the untrusted block.
A lint test checks that `EvidenceCollector` uses only `BoundedProcessRunner`, with the classifier gate and
`PathTrust`, and none of `Process()`, `ShellRunner`, `FileManager`, `popen`, `system`.

## Which backend can really run with no tools (verified, not assumed)
Method: ask the model for its own tool list, and try to make it run a command, then read the event stream.
- **Claude Code 2.1.322: enforceable.** `--tools=` (empty list) + `--strict-mcp-config` + `--setting-sources ""`
  (+ `--disallowedTools` by name as a second layer). The model's own tool list is `StructuredOutput` only. Needs
  `USER` and `LOGNAME` in the environment for the keychain login. `-p "<prompt>"` must come first because `--tools`
  and `--disallowedTools` take lists.
- **Codex 0.167.0: not enforceable, a gap.** There is no switch that removes every tool. With the default config
  the model lists a shell (`exec_command`), code mode (`functions.exec`), web, `apply_patch`, `view_image`, MCP
  resource tools, sub-agent tools, goals, image generation. `--disable shell_tool` removes only the shell. The set
  in `CodexBackend.disabledFeatures` plus `-c web_search="disabled"` removes the shell, code mode (it fails
  closed when its host is disabled), web, sub-agents, goals, image generation, apps, plugins, the browser and
  hooks. **Still available to the model:** `apply_patch`, `view_image`, the MCP resource tools and the
  collaboration tools. Two config keys I tried (`include_apply_patch_tool`, `tools.view_image`) do not exist in
  this version. What still limits the agent: the read-only sandbox, an empty working directory, no config and no
  rules loaded, and an evidence-only prompt. `CodexBackend.toolPolicy.noToolsEnforced` is `false` and the CLI says
  so; the doc does not claim it is enforced.
- `AgentBackend.toolPolicy` carries this in code. The default backend setting is Claude Code.

## Taint check
Any argv token, URL or domain in a proposal that appears in the untrusted text but NOT in the structured identity
makes the verdict `gated(taint)`. A token that appears nowhere is the agent's own knowledge and is allowed.
**Untrusted** (after review R1): the item's description, the extra text the app supplies, and the free text of
the evidence, even though the engine collected it: a package `description`, `keywords`, `homepage`, `repository`,
`publishConfig`, the script names, a brew `desc`, `homepage` and `caveats`, a plist display name and feed URL, and
the free-form output of `--version`.
**Trusted** (`EvidenceItem.trusted`, never sent to the agent): package `name`, `version` and `bin` names and
paths; the resolved paths from `which -a`; the brew formula or cask token, its tap and its versions; the bundle id
and the two bundle versions, the names of those three plist keys and the plist's own path; the parsed version
token (the first `1.2.3`-like token of `--version`), and the item's identity fields. A package `name@version` is judged by its
name. Ordinary vocabulary (package managers, verbs, flags, versions) is ignored. Blocking rules still win:
`blocked` beats `gated`, and a blocked verdict lists only its blocking reasons (the findings are in `taint`).

## `versionCommand` may be null (review R2)
Null means "no version reader is proposed": the evidence does not show one (for example `--version` failed). It is
allowed only with recommendation `investigate`, so the agent never has to invent a placeholder command; the
parser rejects any other combination, and `versionPattern` is not evaluated when the command is null. Before
this, Codex wrote placeholders such as `unknown` for items without evidence (3 of 15 hold-out items).

## A fetcher as a version reader
`curl`, `wget` and similar are blocked as commands, except as a plain version query (`wget --version`): an item
that IS curl or wget needs a version reader and a bare version flag fetches nothing. Any URL or other argument,
and any use as an update command, stays blocked. (Found by a test of the brew-caveats case.)

## `recommendation`
`update | ignore | suggestRemoval | investigate`, plus a reason. Only `update` may carry a command (the parser
rejects `updateCommand` with any other recommendation). `suggestRemoval` is always `gated` ("destructive, needs a
person"), and the removal text is built by the engine from the item's validated identity (for example
`npm uninstall -g --prefix <root> <package>`), never taken from the agent.

## The flag
`UserSettings.agentProposals` (default `false`) and `agentBackend` (default `claudeCode`). Both decode leniently,
so an older `settings.json` still loads. `--propose` and `--propose-fixture` print how to turn it on and exit `3`
when it is off. `DAILY_UPDATE_AGENT_PROPOSALS=1` turns it on for one process (used by the eval) without editing the
settings file.

## One engine change outside Agent/
`BoundedProcessSpec` has an optional `workingDirectory` (default nil: every existing caller is unchanged), so the
agents start in an empty temporary directory and never read a project file.
