# Daily Update

A native macOS app that detects your apps, CLIs, runtimes, libraries, and git repos — checks for updates automatically, and lets you choose what to update.

## Features

- **First-time setup** — pick your root folder (usually `/Users/yourname`) and add extra scan paths
- **Auto-discovery** — finds git repos inside your folders with tunable scan rules
- **Menu bar mode** — live in the menu bar with update count badge and quick actions
- **Launch at login** — start automatically when you log in
- **Apps detection** — via Applications folder **or** a custom terminal script
- **Custom update list** — add/remove apps, CLIs, and repos from the UI
- **Auto-check on launch** — scans for updates every time the app opens
- **Auto-update on launch** — optional: update everything that's available
- **Wake check** — re-checks when your Mac wakes from sleep
- **Selective updates** — checkbox each item, then click **Update Selected** or **Install Selected**
- **Install missing tools** — install commands derived automatically for apps, CLIs, and runtimes

## Quick Start

```bash
git clone https://github.com/mohamedatef90/daily-update.git
cd daily-update
./scripts/build-app.sh
open DailyUpdate.app
```

On first launch you'll be guided through folder setup. After that, updates are checked automatically.

## Setup for New Users

Anyone can clone the repo and run Daily Update on their own Mac. Each person gets a private local config — nothing is shared through GitHub.

### Requirements

- **macOS 13+**
- **Xcode Command Line Tools** (for `swift build`):

```bash
xcode-select --install
```

There is no pre-built release yet — build the app locally from source (see Quick Start above).

### Build and open

```bash
git clone https://github.com/mohamedatef90/daily-update.git
cd daily-update
./scripts/build-app.sh
open DailyUpdate.app
```

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

Bundled detectors cover common dev tools (Cursor, Claude, gh, Node, Homebrew, Flutter, agent skills, and more). The app will:

- **Detect** what is installed on your Mac
- **Check** for available updates
- **Install** missing tools when you select them and click **Install Selected**

You only see items relevant to your machine — no need to copy paths or config from someone else.

### Customization

| Need | Where |
|------|--------|
| Add a custom app, CLI, or repo | **+ Add Item** in the toolbar |
| Tune repo discovery | **Settings → Repo Scan** |
| Auto-discover developer apps | **Settings → App Discovery** |
| Scan agent skills folders | **Settings → Agent Skills Discovery** |
| Disable bundled items | **Settings → Update List** |

### CLI (optional)

```bash
DailyUpdate.app/Contents/MacOS/DailyUpdate --check
DailyUpdate.app/Contents/MacOS/DailyUpdate --update-all
DailyUpdate.app/Contents/MacOS/DailyUpdate --install-all
DailyUpdate.app/Contents/MacOS/DailyUpdate --help
```

## First-Time Setup

These are the same onboarding steps shown in the app on first launch:

1. **Root folder** — usually your home folder (`/Users/yourname`)
2. **Additional folders** — optional paths like external drives or `/opt`
3. **Applications folders** — where to look for `.app` bundles (default: `/Applications`, `~/Applications`)
4. **Review** — shows how many git repos were discovered

Change folders anytime in **Settings → Folders**.

## Adding Items to the Update List

Click **+ Add Item** in the toolbar (or **⌘N**), then choose:

| Category | Detection options |
|----------|-------------------|
| **App** | Applications Folder (e.g. `Cursor`) **or** Terminal Script |
| **CLI** | Command name (e.g. `codex`) **or** custom detect script |
| **Repo** | Browse to a git folder (commands auto-filled) |
| **Runtime / Library** | Custom detect + update scripts |

Manage custom items in **Settings → Update List**.

## Settings

| Option | Default | Description |
|--------|---------|-------------|
| Check on app launch | On | Auto-scan when app opens |
| Auto-update on launch | Off | Update all available items automatically |
| Check when Mac wakes | On | Re-scan after sleep |
| Rescan repos on launch | On | Find new git repos in your folders |
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

- **Apps:** Cursor, Codex, Claude, ChatGPT, Zcode, Antigravity, Warp, Xcode
- **AI agent CLIs:** Cursor Agent, Codex CLI, Claude Code, Hermes Agent, OpenClaw, Cline, Gemini CLI, Qwen Code, OpenCode
- **Other CLIs:** GitHub CLI
- **Runtimes:** Node.js, npm, pnpm, yarn, Bun, Python, pip, Go, Java, .NET, Flutter, Dart, Rust, Homebrew, mise, asdf
- **Libraries:** Agent skills, global npm/pnpm/yarn/pip packages, Impeccable (uses your root folder)

Paths like `{ROOT}` in bundled config expand to your chosen root folder.

## Project Structure

```
Sources/DailyUpdate/
├── DailyUpdateApp.swift
├── Models/          # UpdateItem, UserSettings, DetectorConfig
├── Services/        # Detection, scanning, config, shell runner
├── Views/           # Onboarding, Add Item, Settings, main UI
└── Resources/       # Bundled detectors.json
```

Settings are stored in `~/Library/Application Support/DailyUpdate/settings.json`.

## License

MIT
