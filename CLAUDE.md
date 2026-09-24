# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Read `AGENTS.md` too: it holds the repository's structure, style, testing, and commit conventions and takes precedence where the two overlap.

## What this is

Daily Update is a SwiftPM macOS 13+ app (SwiftUI + AppKit, single executable target `DailyUpdate`) that detects installed apps/CLIs/runtimes/git repos, checks them for updates, and runs verified updates one at a time. The same binary is both the GUI app and a CLI (`--check`, `--audit`, `--health`, `--update-all`, `--install-all`, always with optional `--json`).

## Commands

```bash
swift build                      # debug build
swift build -c release           # release binary in .build/release
swift test                       # all XCTest targets (Tests/DailyUpdateTests)
swift test --filter CLIAuditTests                                   # one test class
swift test --filter CLIAuditTests/testCoreStrategiesExistAndUseTypedOwnership  # one test
./scripts/build-app.sh           # release build + icon + DailyUpdate.app bundle
./scripts/smoke-app.sh           # asserts the bundle contains the exe, detectors.json, and the check script
open DailyUpdate.app
DailyUpdate.app/Contents/MacOS/DailyUpdate --check --json
swift run DailyUpdate --audit    # run the CLI without bundling
```

There is no linter configured. Before submitting: `swift test`, then `swift build`.

`.build/`, `DailyUpdate.app/`, and `Assets/AppIcon/AppIcon.iconset/` are generated and gitignored. Resources live in `Sources/DailyUpdate/Resources` and are accessed via `Bundle.module`; `build-app.sh` also copies `detectors.json` and `scripts/check-app-update.sh` into `Contents/Resources` and the bundle must keep the check script executable (that is what `smoke-app.sh` verifies).

## Architecture

### Entry point and runtime modes

`DailyUpdateApp.swift` inspects `CommandLine.arguments`: any argument starting with `-` routes to `CLIRunner.runSync` and exits; otherwise the SwiftUI `App` launches. `AppState` is the single `@MainActor ObservableObject` for the whole app and is constructed with an `AppStateRuntime` (`.application` or `.commandLine`). The command-line mode skips repo/app/skill discovery and background services (scheduler, wake observer, status bar). `CLIRunner.blockingWait` pumps the main `RunLoop` so `@MainActor` work still progresses while the synchronous `main` waits.

### Item pipeline: config → detect → check → act → verify

1. **Config assembly** (`ConfigLoader.loadConfigs`): merges, keyed by `id` and in this precedence order, bundled `Resources/detectors.json`, the legacy user file at `~/Library/Application Support/DailyUpdate/detectors.json`, `settings.customItems`, then discovered repos/apps/skills. Placeholders `{HOME}`, `{ROOT}`, `~`, and `{CHECK_SCRIPT}` are expanded here; `{CHECK_SCRIPT}` becomes the quoted path to the bundled `check-app-update.sh`. Items in `settings.disabledItemIDs` are dropped.
2. **Detection** (`DetectionService.detect`): `DetectRule.type` is `app` (Info.plist in the configured Applications folders), `command`, `path`, or `always`. Uninstalled items get `.notInstalled` and no check runs.
3. **Check** (`UpdateCheckService.check`): if `DeveloperCLIStrategy.strategy(for: id)` returns a typed strategy, the result comes entirely from `DeveloperCLIAuditService.audit`. Otherwise the detector's `checkCommand` runs and its stdout is pattern-matched (`OK`, `UPDATE`, `CHECK_FAILED`, `broken`). A legacy `UPDATE` becomes `.updateAvailable` only if the item's own `updateCommand` passes the risk gate (`UpdateCheckService.legacyUpdateStatus`); otherwise it is `.gated` with a reason.
4. **Action** (`UpdateExecutor.update`): typed strategies build their command from the audit's `InstallOwner` (`typedMutationCommand`: npm/homebrew/bun/tool self-updater). Non-typed items use `commandToRun`, which strips `open …` and no-op fallbacks from the detector command. Every command then passes `UpdateRiskGate.classify`: each `&&`/`||`/`;` segment must be individually safe (single named brew formula or cask, pinned `npm`/`pnpm`/`bun` global install, `gem update <one>`, `git pull --ff-only`, a non-package-manager tool's own `update`/`upgrade`); pipelines, bare bulk upgrades, sudo, login/OAuth, services, and `open` are gated or blocked. `AppState.updateSelected` runs targets strictly one at a time. Tool-owned self-updaters run the audited PATH alias (`~/.local/bin/claude`), never its resolved version-named target. npm-owned typed actions first pass `NpmEngineCompatibility.preflight` (read-only `npm view --json <pkg>@latest version engines` + `npm version --json`); an excluded or unevaluable `engines.node` range gates, an unreadable one is `.error`. History records the executed typed command via `UpdateExecutor.reportedCommand` (credentials redacted).
5. **Verification**: after a zero exit code, a typed item's post-audit must pass all six `UpdateVerification` checks (canonical path, exact version == latest, `--help` succeeds, fresh-shell resolution matches, latest re-check succeeded, no longer outdated) or the item becomes `.failedVerification` with the failed checks named. npm-owned typed items get one automatic clean reinstall if the in-place upgrade left the binary unable to start. Non-typed items are verified by re-running their version and check commands. Exit code alone is never success.

`AppState.checkAll` drives steps 2–3 through `BoundedAsyncMap` (max 6 concurrent) and preserves only explicit prior user selections; a scan must never auto-select items.

Repo/app/skill discovery (`AppState.refreshDiscovery`) runs on a global queue, never on the main thread, and `checkAll` does not wait for it; newly discovered items are checked when the scan lands. `RepoScanner` skips `Downloads`, `Documents`, and `Desktop` under the root folder because macOS privacy protection blocks `open()` on them until a consent prompt is answered, which froze the first window for minutes. Sample the process with `sample DailyUpdate 2` if the window ever fails to appear.

### Typed developer-CLI strategies

`Models/DeveloperCLIAudit.swift` defines `DeveloperCLIStrategy.all` (Claude Code, Codex, Cursor Agent, OpenCode, Gemini, Pi, Hermes) and the `detectorID → DeveloperCLI` mapping in `strategy(for:)`. `DeveloperCLIAuditService` resolves every binary on PATH, orders them by login-shell PATH, infers the install owner from the path, fetches the latest version from an owner-appropriate source (the tool's own check, npm registry, brew, GitHub releases, or `officialLatestVersionURL` for native installs), and classifies risk (`UpdateRiskGate.classifyVersionChange` gates major jumps, large pre-1.0 jumps, and prerelease channel changes; commit-hash suffixes like `2026.09.10-fd3934a` are build metadata, not channels). A tool's own "update available" / "up to date" verdict (`parseAuthoritativeUpdateAvailability`) overrides semantic comparison, which is how git-tracked Hermes works. Tool-run checks get `authoritativeCheckTimeout` (90 s) because they may fetch over the network. Adding a supported CLI means: add a `DeveloperCLI` case and strategy entry, map its detector `id` in `strategy(for:)`, add a self-update argument case in `UpdateExecutor.typedMutationCommand` if it is tool-owned, and cover it in `Tests/DailyUpdateTests/CLIAuditTests.swift` (that file is the regression suite for the whole safety policy).

### Shell execution

All process launches go through `ShellRunner.run`, which executes `/bin/zsh -lc` with a fixed `defaultPath`, its own process group, a timeout (default 120 s, updates use 600 s), and stdout/stderr draining. Views never call it directly; services do.

### Persistence

`UserSettingsStore` (`Models/UserSettings.swift`) owns `settings.json` under `~/Library/Application Support/DailyUpdate/`; custom items, disabled IDs, per-item preferences (snooze, pin, auto-update, ignore), scan rules, and discovery toggles all live there. `PersistenceStores.swift` holds update history and the widget snapshot. Tests should not touch that directory.

### Detector JSON schema

Each entry in `detectors.json`: `id`, `name`, `category` (`app|cli|runtime|library|repo`), optional `description`, `detect` (`type` + `paths`/`command`/`appName`), optional `versionCommand`, `checkCommand`, `installCommand`, `workingDirectory`, and required `updateCommand`. When `installCommand` is absent, `InstallCommandResolver` derives one from the update command or a hard-coded table. App check commands call `{CHECK_SCRIPT} <mode> ...` where mode is one of `brew-cask`, `sparkle-feed`, `sparkle-plist`, `brew-or-sparkle`, `auto` (see `Resources/scripts/check-app-update.sh`). `UpdateExecutor.validatedCommand` strips `open ...` fallbacks and rejects `echo`/`true` no-op fallbacks, so an `updateCommand` like `brew reinstall --cask X || open -a X` is fine in JSON but only the brew half can ever run.

## Safety invariants to preserve

- Never turn a check failure or network error into an actionable update; it stays `.error`.
- Never add bulk actions (`brew upgrade`, `npm update -g`) as runnable commands; they are intentionally disabled.
- Keep the active installation owner when building install/update commands; do not switch npm ↔ brew ↔ native.
- CLI exit codes: `--check` returns 0; `--audit` returns 2 if any audit is `checkFailed`; `--update-all`/`--install-all`/`--update <id>`/`--install <id>` return 3 for nothing to do, 1 for any non-success, 0 only when every attempted item ended `.updated` or `.upToDate`.
- Never post a `UNUserNotificationCenter` notification from command-line mode or an unbundled binary; it aborts the process. `AppStateRuntime.postsNotifications` and `NotificationService.isAvailable` guard this.
