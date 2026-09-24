import Foundation

struct DetectionOutcome {
    let installed: Bool
    let message: String?
    let blockReason: BlockReason?
}

struct VersionReadOutcome {
    let value: String?
    let blockReason: BlockReason?
}

enum DetectionService {
    static func detect(_ config: DetectorConfig, applicationFolders: [String] = []) async -> DetectionOutcome {
        guard let detect = config.detect else {
            return DetectionOutcome(installed: true, message: nil, blockReason: nil)
        }

        switch detect.type {
        case .always:
            return DetectionOutcome(installed: true, message: nil, blockReason: nil)

        case .app:
            if let appName = detect.appName {
                let folders = applicationFolders.isEmpty
                    ? ["/Applications", NSHomeDirectory() + "/Applications"]
                    : applicationFolders.map { $0.expandingTilde }
                let found = folders.contains { folder in
                    FileManager.default.fileExists(atPath: "\(folder)/\(appName).app")
                }
                return DetectionOutcome(
                    installed: found,
                    message: found ? nil : "\(appName).app not found in Applications folders",
                    blockReason: nil
                )
            }
            if let paths = detect.paths, !paths.isEmpty {
                let found = paths.contains { FileManager.default.fileExists(atPath: $0.expandingTilde) }
                return DetectionOutcome(
                    installed: found,
                    message: found ? nil : "Not found at configured paths",
                    blockReason: nil
                )
            }
            return DetectionOutcome(installed: false, message: "No app name or paths configured", blockReason: nil)

        case .path:
            guard let paths = detect.paths, !paths.isEmpty else {
                return DetectionOutcome(installed: false, message: "No paths configured", blockReason: nil)
            }
            let found = paths.contains { path in
                FileManager.default.fileExists(atPath: path.expandingTilde)
            }
            return DetectionOutcome(
                installed: found,
                message: found ? nil : "Not found at configured paths",
                blockReason: nil
            )

        case .command:
            let command = detect.command ?? "false"
            if GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: config.updateCommand) {
                return DetectionOutcome(
                    installed: true,
                    message: "Blocked unsafe detect command",
                    blockReason: .unsafeCheckCommand
                )
            }
            let cwd = config.workingDirectory?.expandingTilde
            let result = await ShellRunner.run(command, workingDirectory: cwd)
            return DetectionOutcome(
                installed: result.succeeded,
                message: result.succeeded ? nil : result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty,
                blockReason: nil
            )
        }
    }

    static func getVersion(_ config: DetectorConfig) async -> String? {
        await getVersionOutcome(config).value
    }

    static func getVersionOutcome(_ config: DetectorConfig) async -> VersionReadOutcome {
        guard let versionCommand = config.versionCommand else {
            return VersionReadOutcome(value: nil, blockReason: nil)
        }
        if GatePolicy.isUnsafeCheckPathCommand(checkCommand: versionCommand, updateCommand: config.updateCommand) {
            return VersionReadOutcome(value: nil, blockReason: .unsafeCheckCommand)
        }
        let cwd = config.workingDirectory?.expandingTilde
        let result = await ShellRunner.run(versionCommand, workingDirectory: cwd)
        guard result.succeeded, !result.stdout.isEmpty else {
            return VersionReadOutcome(value: nil, blockReason: nil)
        }
        let version = result.stdout.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces)
        return VersionReadOutcome(value: version, blockReason: nil)
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
