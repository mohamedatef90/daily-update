# Daily Update

A native macOS app that detects your apps, CLIs, runtimes, libraries, and git repos — checks for updates automatically, and lets you choose what to update or install.

## Features

- **First-time setup** — pick your root folder (usually `/Users/yourname`) and add extra scan paths
- **Installed-only list** — shows tools actually present on your Mac; bundled detectors for missing apps stay internal to the scan
- **Auto-discovery** — finds git repos, developer apps, and agent skills with tunable scan rules
- **Bundled detectors** — Cursor, Claude, Codex, ChatGPT, gh, Node, Homebrew, Flutter, agent CLIs, and more
- **Item icons** — app icons and category badges in the item list
- **Selective actions** — checkbox items, then **Update Selected**, **Install Selected**, or **Run Selected**
- **Install missing tools** — install commands derived automatically from update commands or built-in defaults
- **Dry-run preview** — optional confirmation sheet before running commands
- **In-app update handoff** — Sparkle/brew items that need manual steps show **Finish in app**
- **Dashboard & history** — overview stats, duplicate detection, and update history
- **Menu bar mode** — live update count badge and quick actions
- **Launch at login** — start automatically when you log in
- **Discovery** — read-only enumeration of installed tools from Homebrew, npm, pnpm, Yarn, Bun, Node version managers, pip, pipx, uv tools, Cargo, and RubyGems
- **CLI** — check, update, install, health, and discover commands for scripting

## Quick Start

```bash
git clone https://github.com/mohamedatef90/daily-update.git
cd daily-update
./scripts/build-app.sh
open DailyUpdate.app
```

To keep a copy in `~/Applications`, run `./scripts/install-app.sh` after building (see [Install to ~/Applications](#install-to-applications)).

On first launch you'll be guided through folder setup. After that, run **Check Updates** to populate the list.

## Setup for New Users

Anyone can clone the repo and run Daily Update on their own Mac. Each person gets a private local config — nothing is shared through GitHub.

### Requirements

- **macOS 13+**
- **Xcode Command Line Tools** (for `swift build`):

```bash
xcode-select --install
```

There is no pre-built release yet — build the app locally from source.

### First-time onboarding

On first launch, the app walks you through:

1. **Root folder** — usually your home folder (`/Users/yourname`)
2. **Extra scan folders** — optional (external drive, `/opt`, etc.)
3. **Applications folders** — where to look for `.app` files (defaults: `/Applications`, `~/Applications`)
4. **Review** — shows how many git repos were discovered

Settings are saved locally at:

`~/Library/Application Support/DailyUpdate/settings.json`

Change folders anytime in **Settings → Folders**.

### What works out of the box

After **Check Updates**, the app will:

- **Detect** what is installed on your Mac
- **Check** for available updates via Homebrew, Sparkle, npm, git, and custom scripts
- **Install or update** selected items from the toolbar or context menu

You only see installed items in the list — no need to copy paths or config from someone else.

### Selecting and running actions

| Action | How |
|--------|-----|
| Select one item | Click its checkbox |
| Select all updates | **Select All Updates** (current filtered view) |
| Deselect all | **Deselect All** (current filtered view) |
| Run selected | **Update Selected** / **Install Selected** / **Run Selected** in the toolbar |
| Single item | Right-click → **Update** or **Install** |
| Retry failed update | Right-click → **Retry Update** |

Filter by category or **Updates Available** in the sidebar before using **Select All Updates**.

### Customization

| Need | Where |
|------|--------|
| Add a custom app, CLI, or repo | **+ Add Item** in the toolbar (⌘N) |
| Tune repo discovery | **Settings → Repo Scan** |
| Auto-discover developer apps | **Settings → Folders → App Discovery** |
| Scan agent skills folders | **Settings → Folders → Agent Skills Discovery** |
| Disable bundled items | **Settings → Update List → Ignored Items** |
| Export/import config | **Settings → General → Import / Export** |

## Adding Items to the Update List

Click **+ Add Item** in the toolbar (or **⌘N**), then choose:

| Category | Detection options |
|----------|-------------------|
| **App** | Applications Folder (e.g. `Cursor`) **or** Terminal Script |
| **CLI** | Command name (e.g. `codex`) **or** custom detect script |
| **Repo** | Browse to a git folder (commands auto-filled) |
| **Runtime / Library** | Custom detect + update scripts |

Optional **Install command** fields are inferred from the update command when left blank.

Manage custom items in **Settings → Update List**.

## Settings

| Option | Default | Description |
|--------|---------|-------------|
| Check on app launch | On | Auto-scan when app opens |
| Auto-update on launch | Off | Update all available items automatically |
| Check when Mac wakes | On | Re-scan after sleep |
| Rescan repos on launch | On | Find new git repos in your folders |
| Rescan apps on launch | On | Discover new apps in Applications folders |
| Rescan agent skills on launch | On | Discover skills and plugin git repos |
| Show dashboard on launch | Off | Open dashboard instead of item list |
| Discover installed tools automatically | On | After the first screen appears, list what Homebrew, npm, pnpm, Yarn, Bun, uv, pipx, Cargo and RubyGems installed (read-only), with an **Ecosystems** section in the sidebar and an owner badge on each row. **Rescan** in Settings runs it again. Off: the app behaves as before |
| Agent proposals (experimental) | Off | Adds an **Ask Agent** action to items that could not be checked. It sends the tool's name, version output and paths (home folder and account name removed) to Claude Code or Codex. Nothing it proposes is run; you can save an accepted update proposal as a custom item, which still needs your review before it runs |
| Confirm before updating | On | Show dry-run preview of commands |
| Stash git repos before pull | On | `git stash` before repo updates |
| Notify when updates found | On | macOS notification after check |
| Daily scheduled check | Off | Background check at a set time |
| Show menu bar icon | On | Icon in top menu bar with update count |
| Menu bar only | Off | Hide Dock icon, run from menu bar |
| Launch at login | Off | Start when you log in |

## Installed tools (M2)

Discovery rows go through the same path as every other item: the planner builds the command, the safety checks run, you see the dry-run, the executor runs it and the result is verified. Discovery itself never installs or changes anything. If it fails or takes longer than 20 seconds, the usual list stays and a small banner says so.

The item info panel shows where a tool is installed: the owner, the file that runs, other installs it hides (for example an old copy in `/usr/local`), installs under another Node version, and files outside any package manager that run instead. This is display only; acting on those installs is planned for a later milestone.

## Menu Bar

Click the menu bar icon for:

- Update status (count or "Up to date")
- **Check for Updates** / **Update All Available**
- Open the main window, add items, or open Settings

Enable **Menu bar only** in Settings → Menu Bar to hide the Dock icon and run quietly in the background.

## Repo Scan Rules

Settings → **Repo Scan** controls how git repos are discovered:

| Setting | Default | Purpose |
|---------|---------|---------|
| Max folder depth | 4 | How deep to scan inside each folder |
| Skip hidden folders | On | Ignore `.something` directories |
| Limit root to subfolders | On | Only scan named folders inside your home folder |
| Subfolders | Projects, dev, 04_App_Coding, … | Which folders under root to scan |
| Skip directories | node_modules, Library, … | Folders never entered during scan |

Additional scan folders (Settings → Folders) are always scanned fully. Use **Reset to Defaults** to restore recommended rules for a dev Mac.

## Pre-configured Items

Bundled in `Sources/DailyUpdate/Resources/detectors.json`:

- **Apps:** Cursor, Codex, Claude, ChatGPT, ChatGPT Atlas, ChatGPT Classic, Zcode, Antigravity IDE, Warp, Xcode
- **AI agent and other CLIs:** Cursor Agent CLI, Codex CLI, Claude Code, Hermes Agent, OpenClaw, Cline CLI, Gemini CLI, Qwen Code, OpenCode, GitHub CLI
- **Runtimes and toolchains:** Swift, Flutter, Dart, CocoaPods, .NET SDK, Java (OpenJDK), Go, Node.js, npm, pnpm, Yarn, Bun, Corepack, Python, pip, Angular CLI, Homebrew, mise, asdf, rustup, Cargo, RubyGems, Composer
- **Libraries:** Impeccable, Agent Skills (global), global npm, pnpm, and Yarn packages, user pip packages

Paths like `{ROOT}` in bundled config expand to your chosen root folder.

## CLI

Run the app binary with a flag. Without a flag it opens the GUI: only arguments that start with `-` count as CLI flags, so `DailyUpdate check` (no dashes) opens the window.

```bash
# After ./scripts/build-app.sh (or ./scripts/install-app.sh, see below):
DD=DailyUpdate.app/Contents/MacOS/DailyUpdate   # or ~/Applications/DailyUpdate.app/Contents/MacOS/DailyUpdate

$DD --check                    # check every item and print its status
$DD --check --json             # same, as JSON
$DD --discover                 # read-only inventory of installed dev tools, runtimes and CLIs
$DD --discover --json          # same, as JSON
$DD --health                   # health checks (PATH, tools, folders)
$DD --propose <item-id>        # ask an agent for a strategy proposal (off by default, see below)
$DD --health --json
$DD --update <item-id> --yes   # update one item
$DD --install <item-id> --yes  # install one item
$DD --update-all               # update everything that has an update
$DD --install-all              # install everything that is missing
$DD --help                     # also -h
```

Each run accepts **one action command** (`--check`, `--discover`, `--health`, `--update`, `--install`, `--update-all`, `--install-all`) plus the modifiers `--json` and `--yes`. `--update` and `--install` also accept `--update=<item-id>` and `--install=<item-id>`.

| Flag | Behaviour |
|------|-----------|
| `--check` | Checks all items and lists each one's status. Exits `1` if any item's check failed, otherwise `0`. |
| `--discover` | Enumerates tools from Homebrew, npm, pnpm, Yarn, Bun, version managers, pip, pipx, uv, Cargo and RubyGems. Read-only. Exit `0`. |
| `--health` | Runs the health checks. Exit `0`. |
| `--propose <item-id>` | Asks an agent (Claude Code or Codex) for a typed strategy proposal for one item and prints it with the engine's verdict. **Off by default**: it needs `"agentProposals": true` in `settings.json` (or `DAILY_UPDATE_AGENT_PROPOSALS=1` for one run), otherwise it prints how to turn it on and exits `3`. Nothing it proposes is executed or saved. `--agent claude|codex` picks the backend (default: the `agentBackend` setting). Design and limits: `docs/adr/ADR-003-spike-notes.md`. |
| `--update <item-id>` | Runs a check, then updates that one item. |
| `--install <item-id>` | Runs a check, then installs that one item. |
| `--update-all` / `--install-all` | Runs a check, then acts on every matching item. |
| `--json` | Machine-readable output. It only changes `--check`, `--health` and `--discover`; other commands ignore it. |
| `--yes` | Confirms an action that would otherwise stop and ask. It does nothing for `--check`, `--discover` and `--health`. |

**JSON shapes**

- `--check --json`: an array of items with `id`, `name`, `category`, `status`, `currentVersion`, `currentVersionRaw`, `latestVersion`, `plannedCommand`, `blockReason` and `gateReasons`. `status` values seen include `upToDate`, `updateAvailable`, `checkFailed`, `notInstalled`, `gated`, `blocked` and `unknown`.
- `--health --json`: an array of `{ severity, title, detail }`.
- `--discover --json`: an object with `elapsedMs`, `homebrew`, `loginPath`, `rows`, `results`, `inactiveInstalls` and `shadowedByUnownedFiles`. Each row has `id`, `name`, `description`, `ecosystem`, `handle`, `packageID` and `root`.

**Item IDs.** Use the `id` field from `--check --json`. If the ID is unknown, or the item is not eligible for that action, the command prints `Item ID not found` or `is not available for update/install`, lists the IDs that are eligible, and exits `1`.

**Confirmation and safety**

- With **Confirm before updating** on (the default), `--update-all` and `--install-all` print a dry-run plan and exit `2` with `Confirmation required. Re-run with --yes` until you pass `--yes`.
- A single `--update <id>` stops with a dry-run plan and exit `2` when the item is gated or is a bulk operation, and `--update <id>` or `--install <id>` does the same when the item's command needs review, until you add `--yes`.
- A single `--update <id>` or `--install <id>` that would run a **remote script** is never run from the CLI, with or without `--yes`: it prints the plan and exits `2`, and you confirm it in the app. `--install-all` prints `skipped <id>` for such installs.
- `--update-all` exits `1` if any item's check failed.

**Exit codes:** `0` success, `1` failure (failed check, failed action, unknown item, or a bad command line), `2` waiting for confirmation, or the item must be handled in the app (also `--install-all` when it skipped remote-script installs and nothing else matched).

Bad command lines print the problem and the help text, then exit `1`: an unknown option (`Unknown option: --x`), a stray argument, a missing value (`--install` with no ID, or `--install=`), or more than one action command.

## Install to ~/Applications

```bash
./scripts/build-app.sh      # builds DailyUpdate.app in the repo folder
./scripts/install-app.sh    # copies it to ~/Applications/DailyUpdate.app
```

`install-app.sh` copies the bundle next to the destination under a temporary name first, so a failed copy never touches the installed app, then swaps it in and removes the old copy. It refuses to run if there is no built app. Quit Daily Update before installing a new version. If **Launch at login** is on, turn it off and on again in Settings after installing, so the login item points at the copy in `~/Applications`. Set `DAILY_UPDATE_INSTALL_DIR` to install somewhere else.

## Development

```bash
swift build              # debug build
swift build -c release   # release binary in .build/release
swift test               # run unit tests
./scripts/build-app.sh   # build DailyUpdate.app bundle
./scripts/install-app.sh  # copy the built app to ~/Applications
```

See [AGENTS.md](AGENTS.md) for project structure and contribution guidelines.

## Project Structure

```
Sources/DailyUpdate/
├── DailyUpdateApp.swift
├── Models/          # Settings, detector config, item categories, results
├── Engine/          # Pure update logic: discovery, command planning, ownership, versions
├── Services/        # Detection, scanning, config, shell runner, CLI, scheduler
├── Views/           # Onboarding, dashboard, settings, main UI
└── Resources/       # detectors.json, scripts/check-app-update.sh, scripts/update-app.sh

Tests/DailyUpdateTests/   # unit tests and fixtures
scripts/                  # build-app.sh, install-app.sh, generate-icon.sh, measure-discovery.sh
docs/adr/                 # architecture decision records
Assets/AppIcon/           # app icon
```

Bundled detector config: `Sources/DailyUpdate/Resources/detectors.json`
