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
- **CLI** — check, update, install, and health commands for scripting

## Quick Start

```bash
git clone https://github.com/mohamedatef90/daily-update.git
cd daily-update
./scripts/build-app.sh
open DailyUpdate.app
```

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
| Auto-discover developer apps | **Settings → App Discovery** |
| Scan agent skills folders | **Settings → Agent Skills Discovery** |
| Disable bundled items | **Settings → Update List** |
| Export/import config | **Settings → Advanced** |

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
| Confirm before updating | On | Show dry-run preview of commands |
| Stash git repos before pull | On | `git stash` before repo updates |
| Notify when updates found | On | macOS notification after check |
| Daily scheduled check | Off | Background check at a set time |
| Show menu bar icon | On | Icon in top menu bar with update count |
| Menu bar only | Off | Hide Dock icon, run from menu bar |
| Launch at login | Off | Start when you log in |

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

- **Apps:** Cursor, Codex, Claude, ChatGPT, ChatGPT Atlas, Zcode, Antigravity, Warp, Xcode
- **AI agent CLIs:** Cursor Agent, Codex CLI, Claude Code, Hermes Agent, OpenClaw, Cline, Gemini CLI, Qwen Code, OpenCode
- **Other CLIs:** GitHub CLI
- **Runtimes:** Node.js, npm, pnpm, yarn, Bun, Python, pip, Go, Java, .NET, Flutter, Dart, Rust, Homebrew, mise, asdf
- **Libraries:** Agent skills (`npx skills`), global npm/pnpm/yarn/pip packages, Impeccable (uses your root folder)

Paths like `{ROOT}` in bundled config expand to your chosen root folder.

## CLI

```bash
DailyUpdate.app/Contents/MacOS/DailyUpdate --check
DailyUpdate.app/Contents/MacOS/DailyUpdate --update-all
DailyUpdate.app/Contents/MacOS/DailyUpdate --install-all
DailyUpdate.app/Contents/MacOS/DailyUpdate --health
DailyUpdate.app/Contents/MacOS/DailyUpdate --json    # with --check or --health
DailyUpdate.app/Contents/MacOS/DailyUpdate --help
```

`--update` and `--install` are aliases for `--update-all` and `--install-all`. CLI commands run a check first, then act on all matching items.

## Development

```bash
swift build              # debug build
swift build -c release   # release binary in .build/release
swift test               # run unit tests
./scripts/build-app.sh   # build DailyUpdate.app bundle
```

See [AGENTS.md](AGENTS.md) for project structure and contribution guidelines.

## Project Structure

```
Sources/DailyUpdate/
├── DailyUpdateApp.swift
├── Models/          # UpdateItem, UserSettings, DetectorConfig
├── Services/        # Detection, scanning, config, shell runner
├── Views/           # Onboarding, dashboard, settings, main UI
└── Resources/       # detectors.json, check-app-update.sh

Tests/DailyUpdateTests/
```

Bundled detector config: `Sources/DailyUpdate/Resources/detectors.json`

## License

MIT
