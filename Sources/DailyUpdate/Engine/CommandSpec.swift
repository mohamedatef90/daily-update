import Foundation

enum CommandKind: String, Codable, Hashable {
    case single
}

struct CommandSpec: Codable, Hashable {
    let executablePath: String
    let arguments: [String]
    var environment: [String: String]
    var kind: CommandKind
    var workingDirectory: String?

    init(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:],
        kind: CommandKind = .single,
        workingDirectory: String? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.kind = kind
        self.workingDirectory = workingDirectory
    }

    var isSingle: Bool {
        kind == .single
    }

    var displayString: String {
        let envPrefix = environment.keys.sorted().compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(ShellEscaping.quote(value))"
        }
        let commandTokens = [executablePath] + arguments
        let quotedCommand = commandTokens.map(ShellEscaping.quote)
        return (envPrefix + quotedCommand).joined(separator: " ")
    }
}
