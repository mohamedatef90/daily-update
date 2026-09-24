import Foundation

enum DeveloperCLI: String, Codable, CaseIterable, Hashable {
    case claudeCode = "claude-code"
    case codex
    case cursorAgent = "cursor-agent"
    case openCode = "opencode"
    case gemini
    case pi
    case hermes
}

enum InstallMethod: String, Codable {
    case native, npm, homebrew, bun, source, unknown
}

enum InstallOwner: String, Codable {
    case tool, npm, homebrew, bun, user, system, unknown
}

enum AuditRisk: String, Codable, Equatable {
    case safe = "Safe"
    case gated = "Gated"
    case blocked = "Blocked"
}

enum AuditOutcome: String, Codable, Equatable {
    case current = "Current"
    case updateAvailable = "Update Available"
    case updated = "Updated"
    case gated = "Gated"
    case blocked = "Blocked"
    case failedVerification = "Failed Verification"
    case checkFailed = "Check Failed"
    case notInstalled = "Not Installed"
}

struct VerificationRecipe: Codable, Equatable {
    let helpArguments: [String]
    let requiresFreshShell: Bool
    let recheckLatest: Bool
}

struct DeveloperCLIAudit: Codable, Identifiable {
    var id: String { cli.rawValue }
    let cli: DeveloperCLI
    let name: String
    let activeBinaryPath: String?
    let competingPaths: [String]
    let currentVersion: String?
    let installOwner: InstallOwner
    let installMethod: InstallMethod
    let latestVersion: String?
    let shadowedPaths: [String]
    let orphanedPaths: [String]
    let statusMessage: String
    let risk: AuditRisk
    let outcome: AuditOutcome
    let verification: VerificationRecipe
}

struct DeveloperCLIStrategy: Equatable {
    let cli: DeveloperCLI
    let displayName: String
    let binaryNames: [String]
    let versionArguments: [String]
    let authoritativeCheckArguments: [String]?
    let npmPackage: String?
    let brewFormula: String?
    let officialGitHubRepository: String?
    /// Plain-text endpoint that returns the latest released version. Used for native/tool-owned
    /// installs whose own CLI does not report a latest version (Claude Code's `doctor` does not).
    let officialLatestVersionURL: String?
    let verification: VerificationRecipe

    static func strategy(for detectorID: String) -> DeveloperCLIStrategy? {
        let cli: DeveloperCLI?
        switch detectorID {
        case "claude-code": cli = .claudeCode
        case "codex-cli": cli = .codex
        case "cursor-agent": cli = .cursorAgent
        case "opencode": cli = .openCode
        case "gemini-cli": cli = .gemini
        case "pi-coding-agent": cli = .pi
        case "hermes-agent": cli = .hermes
        default: cli = nil
        }
        return cli.flatMap { wanted in all.first { $0.cli == wanted } }
    }

    static let all: [DeveloperCLIStrategy] = [
        .init(cli: .claudeCode, displayName: "Claude Code", binaryNames: ["claude"], versionArguments: ["--version"], authoritativeCheckArguments: ["doctor"], npmPackage: "@anthropic-ai/claude-code", brewFormula: nil, officialGitHubRepository: nil, officialLatestVersionURL: "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest", verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true)),
        .init(cli: .codex, displayName: "Codex CLI", binaryNames: ["codex"], versionArguments: ["--version"], authoritativeCheckArguments: nil, npmPackage: "@openai/codex", brewFormula: "codex", officialGitHubRepository: nil, officialLatestVersionURL: nil, verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true)),
        .init(cli: .cursorAgent, displayName: "Cursor Agent", binaryNames: ["agent", "cursor-agent"], versionArguments: ["--version"], authoritativeCheckArguments: ["about"], npmPackage: "@cursor/agent", brewFormula: "cursor-agent", officialGitHubRepository: nil, officialLatestVersionURL: nil, verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true)),
        .init(cli: .openCode, displayName: "OpenCode", binaryNames: ["opencode"], versionArguments: ["--version"], authoritativeCheckArguments: nil, npmPackage: "opencode-ai", brewFormula: "opencode", officialGitHubRepository: "anomalyco/opencode", officialLatestVersionURL: nil, verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true)),
        .init(cli: .gemini, displayName: "Gemini CLI", binaryNames: ["gemini"], versionArguments: ["--version"], authoritativeCheckArguments: nil, npmPackage: "@google/gemini-cli", brewFormula: nil, officialGitHubRepository: nil, officialLatestVersionURL: nil, verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true)),
        .init(cli: .pi, displayName: "Pi Coding Agent", binaryNames: ["pi"], versionArguments: ["--version"], authoritativeCheckArguments: nil, npmPackage: "@earendil-works/pi-coding-agent", brewFormula: nil, officialGitHubRepository: nil, officialLatestVersionURL: nil, verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true)),
        .init(cli: .hermes, displayName: "Hermes Agent", binaryNames: ["hermes"], versionArguments: ["--version"], authoritativeCheckArguments: ["update", "--check"], npmPackage: nil, brewFormula: nil, officialGitHubRepository: nil, officialLatestVersionURL: nil, verification: .init(helpArguments: ["--help"], requiresFreshShell: true, recheckLatest: true))
    ]
}

struct UpdateVerification: Equatable {
    let canonicalPathMatches: Bool
    let exactVersionMatches: Bool
    let helpSucceeded: Bool
    let freshShellPathMatches: Bool
    let latestRecheckSucceeded: Bool
    let noLongerOutdated: Bool

    var outcome: AuditOutcome {
        failedChecks.isEmpty ? .updated : .failedVerification
    }

    var failedChecks: [String] {
        var failed: [String] = []
        if !canonicalPathMatches { failed.append("canonical path") }
        if !exactVersionMatches { failed.append("exact version") }
        if !helpSucceeded { failed.append("help invocation") }
        if !freshShellPathMatches { failed.append("fresh-shell resolution") }
        if !latestRecheckSucceeded { failed.append("latest re-check") }
        if !noLongerOutdated { failed.append("still outdated") }
        return failed
    }
}

enum UpdateRiskGate {
    static func classify(command: String) -> AuditRisk {
        let normalized = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let blockedFragments = [
            "sudo ", "doas ", " login", "oauth", "launchctl", "systemctl",
            "brew services", "corepack enable", "xcode-select --install", " open ",
            "osascript", "security authorizationdb"
        ]
        if blockedFragments.contains(where: { normalized.contains($0) }) ||
            normalized.hasPrefix("open ") || normalized.hasPrefix("/usr/bin/open ") {
            return .blocked
        }

        let range = NSRange(normalized.startIndex..., in: normalized)
        let segmented = try! NSRegularExpression(pattern: #"\s*(?:&&|\|\||;)\s*"#)
            .stringByReplacingMatches(in: normalized, range: range, withTemplate: "\n")
        let segments = segmented.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !segments.isEmpty else { return .gated }

        // A fallback chain (`a || b || c`) or a `cd dir && git pull` pair is only as safe as
        // its least safe segment. Pipelines are never auto-run.
        guard !segments.contains(where: { $0.contains("|") }) else { return .gated }
        return segments.allSatisfy { classifySegment($0) == .safe } ? .safe : .gated
    }

    private static let bulkPackageManagers: Set<String> = [
        "brew", "npm", "pnpm", "yarn", "gem", "pip", "pip3", "cargo", "conda", "port", "apt", "apt-get", "mas", "npx", "corepack"
    ]

    private static func classifySegment(_ segment: String) -> AuditRisk {
        let tokens = shellTokens(segment)
        guard let executable = tokens.first else { return .gated }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let arguments = Array(tokens.dropFirst())

        // `cd <dir>` is only meaningful as the prefix of a `cd dir && git pull` chain.
        if name == "cd", !arguments.isEmpty { return .safe }

        if name == "brew" {
            let action = arguments.first ?? ""
            guard ["upgrade", "reinstall", "install"].contains(action) else { return .gated }
            let rest = Array(arguments.dropFirst())
            if rest.count == 1, !rest[0].hasPrefix("-") { return .safe }
            if rest.count == 2, rest[0] == "--cask", !rest[1].hasPrefix("-") { return .safe }
            return .gated
        }
        if name == "npm", arguments.count == 3,
           arguments[0] == "install", ["-g", "--global"].contains(arguments[1]),
           isPinnedPackage(arguments[2]) {
            return .safe
        }
        if name == "pnpm", arguments.count == 3,
           arguments[0] == "add", ["-g", "--global"].contains(arguments[1]),
           isPinnedPackage(arguments[2]) {
            return .safe
        }
        if name == "bun", arguments.count == 3,
           arguments[0] == "add", ["-g", "--global"].contains(arguments[1]),
           isPinnedPackage(arguments[2]) {
            return .safe
        }
        if name == "gem", arguments.count == 2, arguments[0] == "update", !arguments[1].hasPrefix("-") {
            return .safe
        }
        if name == "git" {
            // `git pull --ff-only` (optionally scoped with `-C <dir>`) can never rewrite history.
            // `normalized` is lowercased, so the flag arrives as "-c".
            var rest = arguments
            if rest.count >= 2, rest[0] == "-c" { rest.removeFirst(2) }
            if rest == ["pull", "--ff-only"] { return .safe }
            return .gated
        }
        if ["claude", "agent", "cursor-agent", "opencode", "hermes"].contains(name), executable.contains("/"),
           (arguments == ["update"] || arguments == ["upgrade"] || arguments == ["update", "--yes"]) {
            return .safe
        }
        // A tool's own self-updater updates exactly one thing. Package managers are excluded
        // because their bare `update`/`upgrade` is a bulk operation.
        if !bulkPackageManagers.contains(name), !executable.contains("/"),
           ["update", "upgrade", "self-update"].contains(arguments.first ?? ""),
           arguments.count == 1 || arguments == ["update", "--yes"] || arguments == ["upgrade", "--yes"] {
            return .safe
        }
        return .gated
    }

    private static func shellTokens(_ segment: String) -> [String] {
        segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { !$0.hasPrefix(">") && !$0.hasPrefix("2>") && $0 != "2>&1" }
            .map { token in
                token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
    }

    private static func isPinnedPackage(_ package: String) -> Bool {
        guard let at = package.lastIndex(of: "@"), at != package.startIndex else { return false }
        return package.index(after: at) < package.endIndex
    }

    static func classifyVersionChange(current: String, latest: String) -> AuditRisk {
        let currentParts = numericParts(current)
        let latestParts = numericParts(latest)
        guard currentParts.count >= 2, latestParts.count >= 2 else { return .gated }
        if prereleaseChannel(current) != prereleaseChannel(latest) { return .gated }
        if latestParts[0] > currentParts[0] { return .gated }
        if currentParts[0] == 0 && latestParts[0] == 0 && latestParts[1] - currentParts[1] >= 3 { return .gated }
        return .safe
    }

    private static func prereleaseIdentifier(_ version: String) -> String? {
        let withoutBuild = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
        return withoutBuild.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
    }

    private static let prereleaseChannels: Set<String> = [
        "alpha", "beta", "rc", "pre", "prerelease", "preview", "dev", "nightly", "canary", "next", "insider", "insiders", "snapshot", "experimental"
    ]

    /// The release channel a `-suffix` denotes (`beta`, `rc`, …), or nil when the suffix is build
    /// metadata such as a commit hash (`2026.09.10-fd3934a`) or there is no suffix at all.
    static func prereleaseChannel(_ version: String) -> String? {
        guard let identifier = prereleaseIdentifier(version)?.lowercased(), !identifier.isEmpty else { return nil }
        let letters = String(identifier.prefix { $0.isLetter })
        if prereleaseChannels.contains(letters) { return letters }
        let isHashLike = identifier.count >= 6
            && identifier.allSatisfy { $0.isNumber || $0.isLetter }
            && identifier.contains { $0.isNumber }
        if isHashLike { return nil }
        return letters.isEmpty ? identifier : letters
    }

    private static func numericParts(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
