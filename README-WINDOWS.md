# Daily Update - Windows Edition

A native Windows desktop app that detects git repos and winget packages, checks for updates, and lets you choose what to update.

## Features

- **Known apps & tools** — Detects Claude, Cursor, ChatGPT, Codex, Warp, Ollama, and common CLIs/runtimes
- **Git repository discovery** — Recursively scans a root folder for git repos with configurable depth
- **Update detection** — Checks git repositories and winget packages for available updates
- **Winget package management** — Lists and checks installed winget packages
- **Selective updates** — Checkbox each item and click "Update Selected"
- **Confirmation dialog** — Never updates automatically; always asks before executing
- **Settings persistence** — Saves your root folder and scan results locally

## Requirements

- **Windows 10/11**
- **Node.js 18+** (check with `node --version`)
- **Git** (check with `git --version`)
- **Winget** (optional, for package management)

## Quick Start

```bash
# Install dependencies
npm install

# Run the app
npm start
```

## Setup

1. **First launch** — Click "Add Item" to open setup
2. **Scan Apps & Tools** — Detects Claude, Cursor, ChatGPT, Codex, Warp, CLIs, and runtimes
3. **Scan for Repositories** — Browse to a root folder (e.g. `C:\Users\YourName\Projects`) and scan git repos
4. **Check updates** — Click "Check Updates"
5. **Select items** — Check what you want to update
6. **Update** — Click "Update Selected" and confirm

## Usage

### Apps & Tools

- **Scan Apps & Tools**: Detects known apps (Cursor, Claude, ChatGPT, etc.), CLIs, and runtimes
- Appears under the **Apps**, **CLIs**, and **Runtime/Library** sidebar categories
- Updates use winget when a package ID is known

### Git Repositories

- **Scan for Repositories**: Discovers all git repos under your root folder
- **Check Updates**: Runs `git fetch` and checks for commits behind origin
- **Update Selected**: Runs `git pull --ff-only` on checked repos after confirmation

### All Winget Packages

- **Scan All Winget**: Lists every installed winget package (broader than known detectors)
- **Check Updates** / **Update Selected**: Uses winget upgrade

## Settings

Settings are saved to: `C:\Users\YourName\.daily-update-windows\settings.json`

Includes:
- Root folder path
- Max scan depth
- Last discovered repositories
- Last scanned winget packages

## Repository Scanner Behavior

- **Max depth**: Default 4, configurable 1-10
- **Skipped directories**: `node_modules`, `.git`, `.build`, `dist`, `vendor`, `.venv`, `.cache`, and more
- **Hidden directories**: Skips folders starting with `.`
- **Git detection**: Looks for `.git` directory; does not scan inside git repos

## Testing

```bash
# Run tests
npm test
```

Tests cover repository scanning logic.

## Building

```bash
# Create a local build (dist folder, not installed)
npm run build

# Create a Windows installer
npm run package
```

The installer will be created in the `dist` folder.

## Project Structure

```
src/
├── main.js         # Electron main process
├── preload.js      # IPC bridge
├── renderer.js     # UI logic
├── index.html      # Main window
├── styles.css      # Styles
├── scanner.js      # Repository scanner
├── updater.js      # Git and winget update logic
└── settings.js     # Settings persistence
test/
└── scanner.test.js # Scanner tests
```

## Differences from macOS Version

The macOS version uses Swift and SwiftUI. This Windows port:
- Uses **Electron + HTML/CSS/JS** for cross-platform compatibility
- Replaces `defaults read` (macOS) with **winget** (Windows)
- Uses Node.js `child_process` instead of Swift `Process`
- Simplifies UI to essential features for MVP

## Troubleshooting

**"Git is not available"**
- Ensure Git is installed and in your PATH
- Run `git --version` in a terminal to verify

**"Winget is not available"**
- Winget comes with Windows 11 by default
- Windows 10 users: Install from Microsoft Store (App Installer)

**"No repositories found"**
- Verify your root folder contains git repos
- Increase max depth if repos are nested deeper
- Check that repo directories aren't in the skip list

## License

MIT
