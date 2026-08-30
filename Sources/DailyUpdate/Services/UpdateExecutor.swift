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

        let command = installing || !item.isInstalled ? item.installCommand : item.updateCommand
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
        let message = result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty ?? "\(action) failed (exit \(result.exitCode))"
        return (.error, item.currentVersion, message)
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
