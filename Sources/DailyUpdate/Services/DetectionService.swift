import Foundation

enum DetectionService {
    static func detect(_ config: DetectorConfig, applicationFolders: [String] = []) async -> (installed: Bool, message: String?) {
        guard let detect = config.detect else {
            return (true, nil)
        }

        switch detect.type {
        case .always:
            return (true, nil)

        case .app:
            if let appName = detect.appName {
                let folders = applicationFolders.isEmpty
                    ? ["/Applications", NSHomeDirectory() + "/Applications"]
                    : applicationFolders.map { $0.expandingTilde }
                let found = folders.contains { folder in
                    FileManager.default.fileExists(atPath: "\(folder)/\(appName).app")
                }
                return (found, found ? nil : "\(appName).app not found in Applications folders")
            }
            if let paths = detect.paths, !paths.isEmpty {
                let found = paths.contains { FileManager.default.fileExists(atPath: $0.expandingTilde) }
                return (found, found ? nil : "Not found at configured paths")
            }
            return (false, "No app name or paths configured")

        case .path:
            guard let paths = detect.paths, !paths.isEmpty else {
                return (false, "No paths configured")
            }
            let found = paths.contains { path in
                FileManager.default.fileExists(atPath: path.expandingTilde)
            }
            return (found, found ? nil : "Not found at configured paths")

        case .command:
            let command = detect.command ?? "false"
            let result = await ShellRunner.run(command)
            return (result.succeeded, result.succeeded ? nil : result.stderr.nilIfEmpty ?? result.stdout.nilIfEmpty)
        }
    }

    static func getVersion(_ config: DetectorConfig) async -> String? {
        guard let versionCommand = config.versionCommand else { return nil }
        let cwd = config.workingDirectory?.expandingTilde
        let result = await ShellRunner.run(versionCommand, workingDirectory: cwd)
        guard result.succeeded, !result.stdout.isEmpty else { return nil }
        return result.stdout.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces)
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
