import Foundation

struct UpdateActionResult {
    let status: ItemStatus
    let version: String?
    let message: String?
    /// The typed mutation command Daily Update built for this action (credentials redacted), or
    /// nil when it stopped before building one. Set for gated preflights too, so the history
    /// shows what would have run.
    let command: String?
}

enum UpdateExecutor {
    static func update(_ item: UpdateItem, installing: Bool = false, stashRepos: Bool = true) async -> UpdateActionResult {
        func finish(_ status: ItemStatus, _ version: String?, _ message: String?, command: String? = nil) -> UpdateActionResult {
            UpdateActionResult(status: status, version: version, message: message, command: command.map(redactedCommand))
        }

        // Only typed, owner-aware strategies are ever mutated. Legacy/config-driven items stop
        // here before any command is resolved, so a direct call cannot run a detector command.
        guard let typedStrategy = DeveloperCLIStrategy.strategy(for: item.id) else {
            return finish(
                .gated,
                item.currentVersion,
                "Gated: this legacy item has no typed owner-aware update strategy and independent verification."
            )
        }

        var notes: [String] = []
        let preAudit = await DeveloperCLIAuditService.audit(typedStrategy)
        if preAudit.outcome == .checkFailed {
            return finish(.error, item.currentVersion, "Check failed: \(preAudit.statusMessage)")
        }
        if preAudit.outcome == .blocked {
            return finish(.blocked, item.currentVersion, "Blocked: \(preAudit.statusMessage)")
        }
        if preAudit.risk == .gated || preAudit.outcome == .gated {
            return finish(.gated, item.currentVersion, "Gated: \(preAudit.statusMessage)")
        }

        if stashRepos, item.category == .repo, !installing {
            let (safe, message) = await RepoSafetyService.preflight(item)
            if !safe, let message {
                return finish(.error, item.currentVersion, message)
            }
            if let stashNote = await RepoSafetyService.stashAndPull(item) {
                notes.append(stashNote)
            }
        }

        let packageManagerPath = await mutationPackageManagerPath(audit: preAudit, installing: installing)
        guard let command = typedMutationCommand(
            strategy: typedStrategy,
            audit: preAudit,
            installing: installing,
            packageManagerPath: packageManagerPath
        ) else {
            return finish(
                .error,
                item.currentVersion,
                "This action is Blocked: no safe, non-interactive update command is available."
            )
        }
        let risk = UpdateRiskGate.classify(command: command)
        guard risk == .safe else {
            return finish(risk == .blocked ? .blocked : .gated, item.currentVersion, "\(risk.rawValue): Daily Update will not auto-run this command", command: command)
        }

        // npm refuses (npm itself) or silently mis-installs (everything else) a release whose
        // `engines.node` excludes the Node that runs this npm. Check before mutating anything.
        if usesNpm(audit: preAudit, installing: installing),
           let package = typedStrategy.npmPackage,
           let packageManagerPath {
            switch await NpmEngineCompatibility.preflight(packageManagerPath: packageManagerPath, package: package) {
            case .compatible:
                break
            case .gated(let reason):
                return finish(.gated, item.currentVersion, "Gated: \(reason)", command: command)
            case .checkFailed(let reason):
                return finish(.error, item.currentVersion, "Check failed: \(reason)", command: command)
            }
        }

        let cwd = item.workingDirectory?.expandingTilde
        let result = await ShellRunner.run(command, workingDirectory: cwd, timeout: 600)

        guard result.succeeded else {
            let action = installing || !item.isInstalled ? "Install" : "Update"
            let detail = result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty
            let reason = result.timedOut ? "timed out" : "exit \(result.exitCode)"
            let message = detail.map { "\(action) failed (\(reason)): \($0)" }
                ?? "\(action) failed (\(reason))"
            return finish(.error, item.currentVersion, message, command: command)
        }

        var outcome = await verifyTypedUpdate(strategy: typedStrategy, preAudit: preAudit, installing: installing)

        // npm silently skips optional dependencies whose download fails, which leaves
        // platform-binary packages (Codex, for example) installed but unable to start.
        // A clean reinstall of the same package is the vendor-documented remedy.
        if outcome.verification.outcome != .updated,
           usesNpm(audit: preAudit, installing: installing),
           let package = typedStrategy.npmPackage,
           let packageManagerPath,
           !outcome.verification.helpSucceeded || outcome.postAudit.currentVersion == nil {
            var repaired = true
            for repairCommand in npmRepairCommands(packageManagerPath: packageManagerPath, package: package) {
                guard await ShellRunner.run(repairCommand, timeout: 600).succeeded else { repaired = false; break }
            }
            if repaired {
                notes.append("Repaired with a clean npm reinstall after the in-place upgrade left the binary unusable")
                outcome = await verifyTypedUpdate(strategy: typedStrategy, preAudit: preAudit, installing: installing)
            }
        }

        guard outcome.verification.outcome == .updated else {
            let reason = verificationFailureMessage(
                verification: outcome.verification,
                preAudit: preAudit,
                postAudit: outcome.postAudit,
                installing: installing,
                helpFailureDetail: outcome.helpFailureDetail,
                freshShellPath: outcome.freshShellPath
            )
            let message = notes.isEmpty ? reason : "\(reason) (\(notes.joined(separator: "; ")))"
            return finish(.failedVerification, outcome.postAudit.currentVersion ?? item.currentVersion, message, command: command)
        }
        let note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        return finish(.updated, outcome.postAudit.currentVersion, note, command: command)
    }

    /// Names every failed `UpdateVerification` check, in `failedChecks` order, with the
    /// evidence that failed it.
    static func verificationFailureMessage(
        verification: UpdateVerification,
        preAudit: DeveloperCLIAudit,
        postAudit: DeveloperCLIAudit,
        installing: Bool,
        helpFailureDetail: String?,
        freshShellPath: String?
    ) -> String {
        let postPath = postAudit.activeBinaryPath ?? "no active binary"
        var details: [String] = []
        if !verification.canonicalPathMatches {
            if installing {
                details.append("canonical path (no active binary found after install)")
            } else {
                let prePath = preAudit.activeBinaryPath ?? "no active binary"
                let owners = preAudit.installOwner == postAudit.installOwner
                    ? ""
                    : ", owner \(preAudit.installOwner.rawValue) → \(postAudit.installOwner.rawValue)"
                details.append("canonical path (before \(prePath), after \(postPath)\(owners))")
            }
        }
        if !verification.exactVersionMatches {
            details.append("exact version (installed \(postAudit.currentVersion ?? "unknown"), latest \(postAudit.latestVersion ?? "unknown"))")
        }
        if !verification.helpSucceeded {
            details.append("help invocation (\(helpFailureDetail ?? "--help did not succeed"))")
        }
        if !verification.freshShellPathMatches {
            details.append("fresh-shell resolution (fresh shell resolved \(freshShellPath ?? "nothing"), expected \(postPath))")
        }
        if !verification.latestRecheckSucceeded {
            details.append("latest re-check (\(postAudit.statusMessage))")
        }
        if !verification.noLongerOutdated {
            details.append("still outdated (post-update audit: \(postAudit.outcome.rawValue))")
        }
        return "Failed Verification: " + details.joined(separator: "; ")
    }

    /// The command to store in history and reports: the executed typed command when one was
    /// built, otherwise the caller's description. Credentials are always redacted.
    static func reportedCommand(executed: String?, fallback: String) -> String {
        redactedCommand(executed ?? fallback)
    }

    static func redactedCommand(_ command: String) -> String {
        let rules: [(pattern: String, template: String)] = [
            // scheme://user:password@host
            (#"(://)[^/\s:@'"]+:[^/\s@'"]+@"#, "$1***@"),
            // --//registry/:_authToken=…, NAME_TOKEN=…, password=…
            (#"(?i)((?:_authtoken|_auth|token|password|passwd|secret|api[_-]?key)\s*[=:]\s*)[^\s'"]+"#, "$1***"),
            // --token value, --password value
            (#"(?i)(--(?:token|auth-token|password|secret|api-key|otp)\s+)[^\s'"]+"#, "$1***")
        ]
        return rules.reduce(command) { current, rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return current }
            return regex.stringByReplacingMatches(
                in: current,
                range: NSRange(current.startIndex..., in: current),
                withTemplate: rule.template
            )
        }
    }

    private static func usesNpm(audit: DeveloperCLIAudit, installing: Bool) -> Bool {
        installing || audit.installOwner == .npm
    }

    struct TypedVerificationOutcome {
        let postAudit: DeveloperCLIAudit
        let verification: UpdateVerification
        let helpFailureDetail: String?
        let freshShellPath: String?
    }

    private static func verifyTypedUpdate(
        strategy: DeveloperCLIStrategy,
        preAudit: DeveloperCLIAudit,
        installing: Bool
    ) async -> TypedVerificationOutcome {
        let postAudit = await DeveloperCLIAuditService.audit(strategy)
        var helpSucceeded = false
        var helpFailureDetail: String?
        if let path = postAudit.activeBinaryPath {
            let helpCommand = ([shellQuote(path)] + strategy.verification.helpArguments.map(shellQuote)).joined(separator: " ")
            let help = await ShellRunner.run(helpCommand, timeout: 15)
            helpSucceeded = help.succeeded
            if !help.succeeded {
                helpFailureDetail = (help.stderr.nilIfEmpty ?? help.stdout.nilIfEmpty)?
                    .components(separatedBy: .newlines)
                    .first(where: { $0.lowercased().contains("error") }) ?? "help exited \(help.exitCode)"
            }
        } else {
            helpFailureDetail = "binary not found after update"
        }
        let primaryBinaryName = verificationBinaryName(strategy: strategy, activePath: postAudit.activeBinaryPath)
        let freshShellPath = primaryBinaryName.isEmpty
            ? nil
            : await DeveloperCLIAuditService.resolveInFreshShell(binaryName: primaryBinaryName)
        let freshShellMatches = await freshShellPathMatches(
            binaryName: primaryBinaryName,
            canonicalPath: postAudit.activeBinaryPath,
            resolver: { _ in freshShellPath }
        )
        let verification = typedVerification(
            preAudit: preAudit,
            postAudit: postAudit,
            installing: installing,
            helpSucceeded: helpSucceeded,
            freshShellMatches: freshShellMatches
        )
        return TypedVerificationOutcome(
            postAudit: postAudit,
            verification: verification,
            helpFailureDetail: helpFailureDetail,
            freshShellPath: freshShellPath
        )
    }

    static func npmRepairCommands(packageManagerPath: String, package: String) -> [String] {
        [
            "\(shellQuote(packageManagerPath)) uninstall -g \(shellQuote(package))",
            "\(shellQuote(packageManagerPath)) install -g \(shellQuote(package + "@latest"))"
        ]
    }

    /// Risk of running a detector-supplied command, after stripping launch/no-op fallbacks.
    /// Nil means there is nothing runnable at all.
    static func legacyActionRisk(for command: String) -> AuditRisk? {
        guard let validated = validatedCommand(from: command) else { return nil }
        return UpdateRiskGate.classify(command: validated)
    }

    static func isSafeLegacyAction(_ command: String) -> Bool {
        legacyActionRisk(for: command) == .safe
    }

    static func commandToRun(for item: UpdateItem, installing: Bool = false) -> String? {
        guard DeveloperCLIStrategy.strategy(for: item.id) != nil else { return nil }
        let requestedCommand = installing || !item.isInstalled ? item.installCommand : item.updateCommand
        return validatedCommand(from: requestedCommand)
    }

    static func typedMutationCommand(
        strategy: DeveloperCLIStrategy,
        audit: DeveloperCLIAudit,
        installing: Bool,
        packageManagerPath: String?
    ) -> String? {
        if installing {
            guard audit.outcome == .notInstalled,
                  let package = strategy.npmPackage,
                  let packageManagerPath else { return nil }
            return "\(shellQuote(packageManagerPath)) install -g \(shellQuote(package + "@latest"))"
        }

        guard audit.outcome == .updateAvailable,
              let activePath = audit.activeBinaryPath else { return nil }
        switch audit.installOwner {
        case .npm:
            guard let package = strategy.npmPackage, let packageManagerPath else { return nil }
            return "\(shellQuote(packageManagerPath)) install -g \(shellQuote(package + "@latest"))"
        case .homebrew:
            guard let formula = strategy.brewFormula, let packageManagerPath else { return nil }
            return "\(shellQuote(packageManagerPath)) upgrade \(shellQuote(formula))"
        case .bun:
            guard let package = strategy.npmPackage, let packageManagerPath else { return nil }
            return "\(shellQuote(packageManagerPath)) add --global \(shellQuote(package + "@latest"))"
        case .tool:
            // Run the audited PATH alias (e.g. ~/.local/bin/claude), never its resolved target:
            // native installs point the alias at a version-named file such as
            // ~/.local/share/claude/versions/2.1.281, which is not the tool's own entry point
            // and which the risk gate rightly refuses to recognise as a self-updater.
            let aliasPath = URL(fileURLWithPath: activePath).standardizedFileURL.path
            guard strategy.binaryNames.contains(URL(fileURLWithPath: aliasPath).lastPathComponent) else { return nil }
            let arguments: [String]
            switch strategy.cli {
            case .claudeCode: arguments = ["update"]
            case .cursorAgent: arguments = ["update"]
            case .openCode: arguments = ["upgrade"]
            case .hermes: arguments = ["update", "--yes"]
            default: return nil
            }
            return ([shellQuote(aliasPath)] + arguments.map(shellQuote)).joined(separator: " ")
        case .user, .system, .unknown:
            return nil
        }
    }

    static func mutationPackageManagerPath(
        audit: DeveloperCLIAudit,
        installing: Bool
    ) async -> String? {
        let managerName: String
        if installing {
            managerName = "npm"
        } else {
            switch audit.installOwner {
            case .npm: managerName = "npm"
            case .homebrew: managerName = "brew"
            case .bun: managerName = "bun"
            case .tool, .user, .system, .unknown: return nil
            }
        }

        if let activePath = audit.activeBinaryPath {
            let sibling = URL(fileURLWithPath: activePath)
                .deletingLastPathComponent()
                .appendingPathComponent(managerName).path
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }

        guard installing else { return nil }
        return await DeveloperCLIAuditService.resolveInFreshShell(binaryName: managerName)
    }

    static func typedVerification(
        preAudit: DeveloperCLIAudit,
        postAudit: DeveloperCLIAudit,
        installing: Bool,
        helpSucceeded: Bool,
        freshShellMatches: Bool
    ) -> UpdateVerification {
        let canonicalPathMatches: Bool
        if installing {
            canonicalPathMatches = postAudit.activeBinaryPath != nil
        } else if let prePath = preAudit.activeBinaryPath, let postPath = postAudit.activeBinaryPath {
            // The same install must stay active under the same owner. A self-update may legitimately
            // retarget a versioned alias (~/.local/bin/claude -> versions/<new>), so the audited alias
            // or its resolved target may match, but the owner inferred from the target may not change.
            let samePath = standardizedPath(prePath) == standardizedPath(postPath)
                || resolvedStandardizedPath(prePath) == resolvedStandardizedPath(postPath)
            canonicalPathMatches = samePath && preAudit.installOwner == postAudit.installOwner
        } else {
            canonicalPathMatches = false
        }
        let exactVersionMatches = postAudit.currentVersion != nil
            && postAudit.currentVersion == postAudit.latestVersion
        return UpdateVerification(
            canonicalPathMatches: canonicalPathMatches,
            exactVersionMatches: exactVersionMatches,
            helpSucceeded: helpSucceeded,
            freshShellPathMatches: freshShellMatches,
            latestRecheckSucceeded: postAudit.outcome != .checkFailed && postAudit.latestVersion != nil,
            noLongerOutdated: postAudit.outcome == .current
        )
    }

    static func validatedCommand(from command: String) -> String? {
        let parts = command.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.contains(where: { isNonActionFallback($0) }) else { return nil }
        return nonLaunchingCommand(from: command)
    }

    static func freshShellPathMatches(
        binaryName: String,
        canonicalPath: String?,
        resolver: (String) async -> String?
    ) async -> Bool {
        guard !binaryName.isEmpty,
              let canonicalPath,
              let freshPath = await resolver(binaryName) else { return false }
        return resolvedStandardizedPath(freshPath) == resolvedStandardizedPath(canonicalPath)
    }

    static func verificationBinaryName(
        strategy: DeveloperCLIStrategy,
        activePath: String?
    ) -> String {
        if let activePath {
            let activeName = URL(fileURLWithPath: activePath).lastPathComponent
            if strategy.binaryNames.contains(activeName) { return activeName }
        }
        return strategy.binaryNames.first ?? ""
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func resolvedStandardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isNonActionFallback(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.hasPrefix("echo ") || lower.hasPrefix("printf ") || lower == "true" || lower.hasSuffix("|| true")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Removes `open` fallback commands so an update never launches an app or the App Store.
    private static func nonLaunchingCommand(from command: String) -> String? {
        let safeParts = command
            .components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { part in
                let lower = part.lowercased()
                return !lower.hasPrefix("open ") && !lower.hasPrefix("/usr/bin/open ")
            }
        let safeCommand = safeParts.joined(separator: " || ")
        return safeCommand.nilIfEmpty
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
