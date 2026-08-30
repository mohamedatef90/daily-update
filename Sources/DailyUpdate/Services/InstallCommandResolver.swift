import Foundation

enum InstallCommandResolver {
    static func resolve(id: String, installCommand: String?, updateCommand: String) -> String {
        if let installCommand, !installCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return installCommand
        }
        if let derived = deriveFromUpdate(updateCommand) {
            return derived
        }
        if let known = defaults[id] {
            return known
        }
        return updateCommand
    }

    private static func deriveFromUpdate(_ command: String) -> String? {
        var derived = command
        let replacements: [(String, String)] = [
            ("brew upgrade --cask", "brew install --cask"),
            ("brew reinstall --cask", "brew install --cask"),
            ("brew upgrade", "brew install"),
            ("npm update -g", "npm install -g"),
            ("pnpm update -g", "pnpm add -g"),
            ("yarn global upgrade", "yarn global add"),
            ("gem update", "gem install"),
            ("composer self-update", "composer self-update"),
            ("rustup update", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"),
            ("flutter upgrade", "brew install --cask flutter"),
            ("npx skills update", "npx skills update")
        ]
        for (from, to) in replacements {
            derived = derived.replacingOccurrences(of: from, with: to)
        }
        guard derived != command else { return nil }
        return firstCommandSegment(derived)
    }

    private static func firstCommandSegment(_ command: String) -> String {
        command.components(separatedBy: "||").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? command
    }

    private static let defaults: [String: String] = [
        "cursor": "brew install --cask cursor",
        "codex-app": "brew install --cask codex",
        "claude-app": "brew install --cask claude",
        "chatgpt": "brew install --cask chatgpt",
        "chatgpt-atlas": "brew install --cask chatgpt-atlas",
        "chatgpt-classic": "brew install --cask chatgpt",
        "zcode": "brew install --cask zcode",
        "antigravity": "brew install --cask antigravity",
        "warp": "brew install --cask warp",
        "xcode": "open 'macappstore://apps.apple.com/app/id497799835'",
        "cursor-agent": "npm install -g @cursor/agent",
        "codex-cli": "npm install -g @openai/codex@latest",
        "claude-code": "curl -fsSL https://claude.ai/install.sh | bash",
        "gh-cli": "brew install gh",
        "swift": "xcode-select --install",
        "flutter": "brew install --cask flutter",
        "dart": "brew install dart",
        "cocoapods": "gem install cocoapods",
        "dotnet": "brew install dotnet",
        "java": "brew install openjdk",
        "go": "brew install go",
        "node": "brew install node",
        "npm": "brew install node",
        "pnpm": "npm install -g pnpm",
        "yarn": "npm install -g yarn",
        "bun": "brew install bun",
        "corepack": "npm install -g corepack && corepack enable",
        "python": "brew install python",
        "pip": "python3 -m ensurepip --upgrade",
        "angular-cli": "npm install -g @angular/cli",
        "brew": "echo 'Install Homebrew: /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"'",
        "mise": "brew install mise",
        "asdf": "brew install asdf",
        "rustup": "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y",
        "cargo": "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y",
        "gem": "brew install ruby",
        "composer": "brew install composer",
        "impeccable": "echo 'Clone your impeccable repo to ~/impeccable or add a custom path in Settings'",
        "agent-skills": "npx skills find",
        "global-npm": "echo 'Install tools with npm install -g <package>'",
        "global-pnpm": "echo 'Install tools with pnpm add -g <package>'",
        "global-yarn": "echo 'Install tools with yarn global add <package>'",
        "pip-packages": "echo 'Install Python packages with pip3 install <package>'"
    ]
}
