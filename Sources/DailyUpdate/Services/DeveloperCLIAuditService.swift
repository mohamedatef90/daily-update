import Foundation

enum DeveloperCLIAuditService {
    static func auditAll() async -> [DeveloperCLIAudit] {
        var audits: [DeveloperCLIAudit] = []
        for strategy in DeveloperCLIStrategy.all {
            audits.append(await audit(strategy))
        }
        return audits
    }

    static func audit(_ strategy: DeveloperCLIStrategy) async -> DeveloperCLIAudit {
        let paths = await resolvePaths(strategy.binaryNames)
        guard let activePath = paths.first else {
            return DeveloperCLIAudit(
                cli: strategy.cli, name: strategy.displayName, activeBinaryPath: nil,
                competingPaths: [], currentVersion: nil, installOwner: .unknown, installMethod: .unknown,
                latestVersion: nil, shadowedPaths: [], orphanedPaths: [], statusMessage: "Not installed",
                risk: .safe, outcome: .notInstalled, verification: strategy.verification
            )
        }

        let inferredOwner = inferOwner(path: activePath)
        let owner = canonicalOwner(cli: strategy.cli, inferredOwner: inferredOwner)
        let method = inferMethod(owner: owner)
        let version = await runBinary(activePath, arguments: strategy.versionArguments)
        let current = firstVersion(version.stdout)
        let latestResult = await latestVersion(strategy: strategy, activePath: activePath, owner: owner)
        let latest = latestResult.version
        let competingPaths = competingPaths(activePath: activePath, allPaths: paths)
        let competing = classifyCompetingPaths(activeOwner: owner, paths: competingPaths)
        let shadowed = competing.shadowed
        let orphaned = competing.orphaned
        let risk: AuditRisk
        if let current, let latest, SemanticVersion(latest) != nil {
            risk = UpdateRiskGate.classifyVersionChange(current: current, latest: latest)
        } else {
            risk = .safe
        }

        let outcome = classifyOutcome(
            currentVersion: current,
            currentCheckSucceeded: version.succeeded,
            latestVersion: latest,
            latestCheckSucceeded: latestResult.succeeded,
            risk: risk,
            authoritativeUpdateAvailable: latestResult.updateAvailable
        )
        let message: String
        if !version.succeeded || current == nil {
            message = version.stderr.nilIfEmpty ?? version.stdout.nilIfEmpty ?? "Could not read the active CLI version"
        } else if !latestResult.succeeded {
            message = latestResult.message ?? "Latest-version check failed; no update is actionable"
        } else if outcome == .updateAvailable || outcome == .gated {
            message = shadowed.isEmpty ? "Active install has an update" : "Active install has an update; \(shadowed.count) shadowed copy/copies found"
        } else {
            message = shadowed.isEmpty ? "Active install is current" : "Active install is current; \(shadowed.count) shadowed copy/copies found"
        }

        return DeveloperCLIAudit(
            cli: strategy.cli,
            name: strategy.displayName,
            activeBinaryPath: activePath,
            competingPaths: competingPaths,
            currentVersion: current,
            installOwner: owner,
            installMethod: method,
            latestVersion: latest,
            shadowedPaths: shadowed,
            orphanedPaths: orphaned,
            statusMessage: message,
            risk: risk,
            outcome: outcome,
            verification: strategy.verification
        )
    }

    private static func resolvePaths(_ names: [String]) async -> [String] {
        var results: [String] = []
        for name in names {
            let result = await ShellRunner.run("which -a \(shellQuote(name))", timeout: 5)
            if result.succeeded {
                results.append(contentsOf: result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty })
            }
        }
        let uniquePaths = preserveShellResolutionOrder(results)
        let pathResult = await ShellRunner.run("print -r -- $PATH", timeout: 5)
        return orderedResolvedPaths(
            uniquePaths,
            loginShellPath: pathResult.succeeded ? pathResult.stdout : nil
        )
    }

    static func preserveShellResolutionOrder(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let standardized = standardizedPath(path)
            guard seen.insert(pathIdentity(standardized)).inserted else { return nil }
            return standardized
        }
    }

    static func orderedResolvedPaths(_ paths: [String], loginShellPath: String?) -> [String] {
        guard let loginShellPath, !loginShellPath.isEmpty else {
            return preserveShellResolutionOrder(paths)
        }
        return orderPathsByEffectivePath(
            preserveShellResolutionOrder(paths),
            effectivePath: loginShellPath
        )
    }

    static func classifyOutcome(
        currentVersion: String?,
        currentCheckSucceeded: Bool,
        latestVersion: String?,
        latestCheckSucceeded: Bool,
        risk: AuditRisk,
        authoritativeUpdateAvailable: Bool? = nil
    ) -> AuditOutcome {
        guard currentCheckSucceeded, let currentVersion,
              latestCheckSucceeded, let latestVersion else { return .checkFailed }
        let hasUpdate: Bool
        if let authoritativeUpdateAvailable {
            hasUpdate = authoritativeUpdateAvailable
        } else {
            hasUpdate = isRemoteNewer(current: currentVersion, latest: latestVersion)
        }
        guard hasUpdate else { return .current }
        return risk == .safe ? .updateAvailable : .gated
    }

    static func orderPathsByEffectivePath(_ paths: [String], effectivePath: String) -> [String] {
        let directories = effectivePath.split(separator: ":").map { standardizedPath(String($0)) }
        var ranks: [String: Int] = [:]
        for (index, directory) in directories.enumerated() where ranks[directory] == nil {
            ranks[directory] = index
        }
        return paths.enumerated().sorted { lhs, rhs in
            let leftDirectory = standardizedPath(URL(fileURLWithPath: lhs.element).deletingLastPathComponent().path)
            let rightDirectory = standardizedPath(URL(fileURLWithPath: rhs.element).deletingLastPathComponent().path)
            let leftRank = ranks[leftDirectory] ?? Int.max
            let rightRank = ranks[rightDirectory] ?? Int.max
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }.map(\.element)
    }

    static func competingPaths(activePath: String, allPaths: [String]) -> [String] {
        let active = standardizedPath(activePath)
        let activeIdentity = pathIdentity(active)
        var seen = Set<String>()
        return allPaths.compactMap { path in
            let standardized = standardizedPath(path)
            let identity = pathIdentity(standardized)
            guard identity != activeIdentity, seen.insert(identity).inserted else { return nil }
            return standardized
        }
    }

    static func classifyCompetingPaths(activeOwner: InstallOwner, paths: [String]) -> (shadowed: [String], orphaned: [String]) {
        (paths, paths.filter { inferOwner(path: $0) != activeOwner })
    }

    static func inferOwner(path: String) -> InstallOwner {
        let original = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let candidates = [resolved, original]
        if candidates.contains(where: { $0.contains("homebrew") || $0.hasPrefix("/usr/local/cellar/") }) { return .homebrew }
        if candidates.contains(where: { $0.contains("node_modules") || $0.contains("npm") || $0.contains("nvm") }) { return .npm }
        if candidates.contains(where: { $0.contains(".bun/") }) { return .bun }
        if candidates.contains(where: { $0.contains(".local/bin") || $0.hasPrefix(NSHomeDirectory().lowercased()) }) { return .user }
        if candidates.contains(where: { $0.hasPrefix("/usr/bin/") || $0.hasPrefix("/bin/") }) { return .system }
        return .tool
    }

    static func canonicalOwner(cli: DeveloperCLI, inferredOwner: InstallOwner) -> InstallOwner {
        guard inferredOwner == .user else { return inferredOwner }
        switch cli {
        case .claudeCode, .cursorAgent, .openCode, .hermes:
            return .tool
        case .codex, .gemini, .pi:
            return inferredOwner
        }
    }

    private static func inferMethod(owner: InstallOwner) -> InstallMethod {
        switch owner {
        case .homebrew: return .homebrew
        case .npm: return .npm
        case .bun: return .bun
        case .tool, .user: return .native
        case .system, .unknown: return .unknown
        }
    }

    struct LatestVersionResult {
        let version: String?
        let succeeded: Bool
        let message: String?
        /// Set when the tool's own check answered "update available"/"up to date" directly,
        /// which is authoritative even when no comparable version string exists (Hermes is
        /// git-tracked and reports commits behind, not a version).
        var updateAvailable: Bool? = nil
    }

    /// Tool-run checks such as `hermes update --check` perform a real git fetch; observed
    /// durations on the same machine ranged from 3 s to 35 s, so 20 s produced flaky failures.
    static let authoritativeCheckTimeout: TimeInterval = 90

    private static func latestVersion(strategy: DeveloperCLIStrategy, activePath: String, owner: InstallOwner) async -> LatestVersionResult {
        var diagnosticMessage: String?
        if let args = strategy.authoritativeCheckArguments {
            let result = await runBinary(activePath, arguments: args, timeout: authoritativeCheckTimeout)
            let combined = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            diagnosticMessage = diagnostics(cli: strategy.cli, output: combined)
            if result.succeeded {
                if let version = parseAuthoritativeLatest(cli: strategy.cli, output: combined) {
                    return LatestVersionResult(version: version, succeeded: true, message: diagnosticMessage)
                }
                if let available = parseAuthoritativeUpdateAvailability(cli: strategy.cli, output: combined) {
                    let currentResult = await runBinary(activePath, arguments: strategy.versionArguments)
                    let current = firstVersion(currentResult.stdout)
                    let latest = available ? (hermesLatestMarker(output: combined) ?? "newer") : current
                    return LatestVersionResult(version: latest, succeeded: current != nil, message: diagnosticMessage, updateAvailable: available)
                }
            }
            if strategy.cli == .cursorAgent || strategy.cli == .hermes {
                let fallback = result.timedOut
                    ? "Authoritative latest-version check timed out after \(Int(authoritativeCheckTimeout)) s"
                    : "Authoritative latest-version check did not provide a Latest value"
                return LatestVersionResult(version: nil, succeeded: false, message: diagnosticMessage ?? result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty ?? fallback)
            }
        }

        if owner == .npm, let package = strategy.npmPackage {
            let result = await ShellRunner.run("npm view --prefer-online \(shellQuote(package)) version", timeout: 20)
            return result.succeeded && !result.stdout.isEmpty
                ? LatestVersionResult(version: firstVersion(result.stdout), succeeded: true, message: diagnosticMessage)
                : LatestVersionResult(version: nil, succeeded: false, message: result.stderr.nilIfEmpty ?? diagnosticMessage ?? "npm registry check failed")
        }
        if owner == .homebrew, let formula = strategy.brewFormula {
            let result = await ShellRunner.run("brew info --json=v2 \(shellQuote(formula))", timeout: 20)
            guard result.succeeded,
                  let data = result.stdout.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return LatestVersionResult(version: nil, succeeded: false, message: result.stderr.nilIfEmpty ?? diagnosticMessage ?? "Homebrew metadata check failed")
            }
            let collections = ((object["formulae"] as? [[String: Any]]) ?? []) + ((object["casks"] as? [[String: Any]]) ?? [])
            let versions = collections.first?["versions"] as? [String: Any]
            guard let latest = (versions?["stable"] as? String) ?? (collections.first?["version"] as? String) else {
                return LatestVersionResult(version: nil, succeeded: false, message: diagnosticMessage ?? "Homebrew metadata did not include a stable version")
            }
            return LatestVersionResult(version: latest, succeeded: true, message: diagnosticMessage)
        }
        if let repository = strategy.officialGitHubRepository {
            let result = await ShellRunner.run(
                "curl -fsSL --connect-timeout 5 -A 'DailyUpdate/1.0' -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' https://api.github.com/repos/\(repository)/releases/latest",
                timeout: 20
            )
            if result.succeeded,
               let data = result.stdout.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = object["tag_name"] as? String,
               let version = firstVersion(tag) {
                return LatestVersionResult(version: version, succeeded: true, message: diagnosticMessage)
            }
            // Anonymous GitHub API calls are rate-limited (HTTP 403 after 60/hour). The npm
            // registry publishes the same release versions and is a read-only fallback; the
            // active installation owner is untouched because this only reads a version.
            if let package = strategy.npmPackage {
                let registry = await ShellRunner.run("npm view --prefer-online \(shellQuote(package)) version", timeout: 20)
                if registry.succeeded, let version = firstVersion(registry.stdout) {
                    return LatestVersionResult(version: version, succeeded: true, message: diagnosticMessage)
                }
            }
            return LatestVersionResult(version: nil, succeeded: false, message: result.stderr.nilIfEmpty ?? "Official GitHub releases check failed")
        }
        if let url = strategy.officialLatestVersionURL {
            let result = await ShellRunner.run(
                "curl -fsSL --connect-timeout 5 -A 'DailyUpdate/1.0' -H 'Cache-Control: no-cache' \(shellQuote(url))",
                timeout: 20
            )
            guard result.succeeded, let version = firstVersion(result.stdout) else {
                return LatestVersionResult(version: nil, succeeded: false, message: result.stderr.nilIfEmpty ?? "Official release channel check failed")
            }
            return LatestVersionResult(version: version, succeeded: true, message: diagnosticMessage)
        }
        return LatestVersionResult(version: nil, succeeded: false, message: diagnosticMessage ?? "No authoritative latest-version source for the active installation owner")
    }

    /// Reads a direct "update available" / "up to date" verdict from a tool's own check.
    static func parseAuthoritativeUpdateAvailability(cli: DeveloperCLI, output: String) -> Bool? {
        let lower = output.lowercased()
        if lower.contains("update available") || lower.contains("commits behind") { return true }
        if lower.contains("up to date") || lower.contains("up-to-date") { return false }
        return nil
    }

    /// Hermes reports "N commits behind origin/main" rather than a version; keep that visible.
    static func hermesLatestMarker(output: String) -> String? {
        let pattern = #"([0-9]+)\s+commits?\s+behind\s+([^\s.,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let countRange = Range(match.range(at: 1), in: output),
              let refRange = Range(match.range(at: 2), in: output) else { return nil }
        return "\(output[refRange]) (+\(output[countRange]) commits)"
    }

    static func parseAuthoritativeLatest(cli: DeveloperCLI, output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        switch cli {
        case .cursorAgent:
            guard let latestLine = lines.first(where: {
                $0.range(of: #"^\s*Latest\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            }) else { return nil }
            return firstVersion(latestLine)
        case .claudeCode:
            // `claude doctor` prints "Auto-update channel: latest" and "Last update attempt: … → x.y.z";
            // neither is a latest-version statement. Require an explicit remote-version phrase.
            let remoteLine = lines.first(where: {
                let lower = $0.lowercased()
                let mentionsRemote = lower.contains("latest version") || lower.contains("update available") || lower.contains("new version")
                return mentionsRemote && firstVersion($0) != nil
            })
            return remoteLine.flatMap(firstVersion)
        default:
            guard let remoteLine = lines.first(where: {
                let lower = $0.lowercased()
                return lower.contains("latest") || lower.contains("update available") || lower.contains("behind")
            }) else { return nil }
            return firstVersion(remoteLine)
        }
    }

    static func resolveInFreshShell(binaryName: String) async -> String? {
        let lookup = "command -v -- \(shellQuote(binaryName))"
        let result = await ShellRunner.run("/bin/zsh -fc \(shellQuote(lookup))", timeout: 10)
        return result.succeeded ? result.stdout.components(separatedBy: .newlines).first?.nilIfEmpty : nil
    }

    private static func diagnostics(cli: DeveloperCLI, output: String) -> String? {
        guard cli == .claudeCode else { return nil }
        let diagnosticLines = output.components(separatedBy: .newlines).filter {
            let lower = $0.lowercased()
            return lower.contains("multiple install") || lower.contains("duplicate") || lower.contains("orphan")
        }
        return diagnosticLines.isEmpty ? nil : diagnosticLines.joined(separator: "; ")
    }

    private static func runBinary(_ path: String, arguments: [String], timeout: TimeInterval = 10) async -> ShellRunner.Result {
        let command = ([shellQuote(path)] + arguments.map(shellQuote)).joined(separator: " ")
        return await ShellRunner.run(command, timeout: timeout)
    }

    private static func firstVersion(_ text: String) -> String? {
        let pattern = #"(?<![0-9])v?([0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func isRemoteNewer(current: String, latest: String) -> Bool {
        guard let currentVersion = SemanticVersion(current), let latestVersion = SemanticVersion(latest) else { return false }
        return currentVersion < latestVersion
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func pathIdentity(_ path: String) -> String {
        URL(fileURLWithPath: standardizedPath(path))
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct SemanticVersion: Comparable {
    let core: [Int]
    let prerelease: [String]?

    init?(_ raw: String) {
        let withoutBuild = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = pieces[0].split(separator: ".").compactMap { Int($0) }
        guard core.count >= 2 else { return nil }
        self.core = core
        self.prerelease = pieces.count == 2 ? pieces[1].split(separator: ".").map(String.init) : nil
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in 0..<max(lhs.core.count, rhs.core.count) {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?):
            for index in 0..<max(left.count, right.count) {
                if index >= left.count { return true }
                if index >= right.count { return false }
                let l = left[index]
                let r = right[index]
                if l == r { continue }
                switch (Int(l), Int(r)) {
                case let (ln?, rn?): return ln < rn
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return l < r
                }
            }
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
