import Foundation

enum UpdateExecutor {
    static func update(_ item: UpdateItem, installing: Bool = false, stashRepos: Bool = true) async -> (ItemStatus, String?, String?) {
        var notes: [String] = []

        if stashRepos, item.category == .repo, !installing {
            let (safe, message) = await RepoSafetyService.preflight(item)
            if !safe, let message {
                return (.error, item.currentVersion, message)
            }
            if let stashNote = await RepoSafetyService.stashAndPull(item) {
                notes.append(stashNote)
            }
        }

        let requestedCommand = installing || !item.isInstalled ? item.installCommand : item.updateCommand
        guard let command = nonLaunchingCommand(from: requestedCommand) else {
            return (
                .error,
                item.currentVersion,
                "This update requires opening an app manually. Daily Update does not launch apps during updates."
            )
        }
        let cwd = item.workingDirectory?.expandingTilde
        let result = await ShellRunner.run(command, workingDirectory: cwd, timeout: 600)

        if result.succeeded {
            let version = await DetectionService.getVersion(DetectorConfig(
                id: item.id,
                name: item.name,
                category: item.category,
                description: item.description,
                source: item.source,
                detect: nil,
                versionCommand: item.versionCommand,
                checkCommand: item.checkCommand,
                installCommand: item.installCommand,
                updateCommand: item.updateCommand,
                workingDirectory: item.workingDirectory
            ))
            let note = notes.isEmpty ? nil : notes.joined(separator: "; ")
            return (.updated, version, note)
        }

        let action = installing || !item.isInstalled ? "Install" : "Update"
        let detail = result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty
        let message = detail.map { "\(action) failed (exit \(result.exitCode)): \($0)" }
            ?? "\(action) failed (exit \(result.exitCode))"
        return (.error, item.currentVersion, message)
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
