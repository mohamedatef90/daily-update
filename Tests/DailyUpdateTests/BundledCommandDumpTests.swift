import XCTest
@testable import DailyUpdate

/// Writes one line per bundled command (raw risks, the check-path unsafe flag and
/// `isRemoteScriptInstaller`), plus each item's gate reasons and typed identity, so a
/// change can be diffed row by row. Runs only when `DAILY_UPDATE_DUMP` names an output file.
final class BundledCommandDumpTests: HermeticTestCase {
    func testDumpBundledCommands() throws {
        guard let path = ProcessInfo.processInfo.environment["DAILY_UPDATE_DUMP"], !path.isEmpty else {
            throw XCTSkip("Set DAILY_UPDATE_DUMP=<file> to write the bundled-command dump")
        }
        let bundled = ConfigLoader.loadConfigs(settings: .defaults)
            .filter { $0.source == .bundled }
            .sorted { $0.id < $1.id }
        var lines: [String] = []
        for config in bundled {
            let commands: [(String, String?)] = [
                ("detect", config.detect?.command), ("version", config.versionCommand),
                ("check", config.checkCommand), ("update", config.updateCommand), ("install", config.installCommand),
            ]
            for (field, command) in commands {
                guard let command, !command.isEmpty else { continue }
                let risks = CommandShapeClassifier.classify(command).risks.map(\.rawValue).sorted()
                let unsafe = GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: config.updateCommand)
                let remote = ActionCommandPolicy.isRemoteScriptInstaller(command)
                lines.append([config.id, field, normalized(command), "[\(risks.joined(separator: ","))]",
                    "checkUnsafe=\(unsafe)", "remote=\(remote)"].joined(separator: "\t"))
            }
            let reasons = GatePolicy.updateGateReasons(for: config, reviewedHash: nil).map(\.rawValue)
            lines.append([config.id, "gate", "[\(reasons.joined(separator: ","))]"].joined(separator: "\t"))
            if config.hasTypedEngineFields {
                let packages = config.packages.map { p in
                    [("brew", p.brew), ("brewCask", p.brewCask), ("npm", p.npm), ("pipx", p.pipx), ("uv", p.uv)]
                        .compactMap { key, value in value.map { "\(key)=\($0)" } }.joined(separator: ",")
                } ?? ""
                lines.append([config.id, "typed", "schema=\(config.schemaVersion ?? 1)", "command=\(config.command ?? "")",
                    "packages=\(packages)", "selfUpdater=\(config.selfUpdater ?? "")",
                    "autoUpdates=\(config.autoUpdates.map(String.init) ?? "")"].joined(separator: "\t"))
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The bundled scripts live under the build directory, which differs per checkout.
    private func normalized(_ command: String) -> String {
        command.replacingOccurrences(of: #"/[^ '"]*/DailyUpdate_DailyUpdate\.bundle"#, with: "<bundle>",
            options: .regularExpression)
    }
}
