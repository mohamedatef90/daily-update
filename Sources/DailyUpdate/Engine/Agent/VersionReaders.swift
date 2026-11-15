import Foundation

/// A reviewed, fixed list of ways to read a tool's version when `<tool> --version` does not work (AI-2 / M2.1).
///
/// Why it exists: the evidence probe asks every tool for `--version`. The probe diagnosis showed the most common
/// failure is a tool that does not understand that flag (Angular's `ng` wants `ng version`, Java wants `-version`).
/// A fixed table fixes that deterministically, without asking an agent and without trying flags at random.
///
/// Rules, enforced by tests and by the collector (a failing rule is a failing test, not a silent skip):
/// - an entry is only ever used when the tool's own executable is already the one being probed, and only after
///   `--version` failed;
/// - every entry passes `CommandShapeClassifier` with no risk and `PathTrust` like any other probe, runs through
///   the bounded process runner with an exact environment, a timeout and an output cap (the evidence
///   collector is the only file here that starts anything);
/// - every entry is READ-ONLY by review: it prints a version and changes nothing. `npm version`, `yarn version`,
///   `pnpm version`, `cargo`, `git`, `brew` and every package manager are NEVER here, because `version` is a WRITE
///   command for some of them (it edits package.json and creates a git tag);
/// - adding an entry means adding it here, reading the tool's own documentation, and extending the test list.
enum VersionReaders {
    /// executable name -> the arguments that print its version.
    static let table: [String: [String]] = [
        "ng": ["version"],            // Angular CLI: `ng --version` is an error ("specify a command")
        "java": ["-version"],         // prints to stderr
        "javac": ["-version"],        // prints to stderr
        "go": ["version"],
        "ssh": ["-V"],                // prints to stderr
        "tmux": ["-V"],
        "ffmpeg": ["-version"],
        "ffprobe": ["-version"],
        "nginx": ["-v"],              // prints to stderr
    ]

    /// Names that must never have an entry: package managers and tools where a "version" word writes something.
    static let neverAllowed: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "npx", "corepack", "pip", "pip3", "pipx", "uv", "cargo", "rustup", "gem", "bundle",
        "brew", "mas", "mise", "asdf", "git", "sudo", "sh", "bash", "zsh", "dash", "curl", "wget", "node", "python", "python3",
        "ruby", "perl", "rm", "mv", "cp", "dd",
    ]

    /// Words that mean "change something". No entry's arguments may contain one.
    static let mutatingWords: Set<String> = [
        "install", "uninstall", "update", "upgrade", "remove", "delete", "add", "link", "unlink", "publish", "login", "logout",
        "run", "exec", "init", "new", "generate", "build", "serve", "config", "set", "write", "create", "start", "stop",
    ]

    static func arguments(forExecutableNamed name: String) -> [String]? {
        table[name]
    }

    /// The check the tests run over the whole table. Returns one message per violation (empty means clean).
    static func violations(in table: [String: [String]] = VersionReaders.table) -> [String] {
        var found: [String] = []
        for (name, arguments) in table.sorted(by: { $0.key < $1.key }) {
            if neverAllowed.contains(name) { found.append("\(name) is a package manager or a write-capable tool") }
            if arguments.isEmpty || arguments.count > 2 { found.append("\(name): 1 or 2 arguments expected") }
            for argument in arguments {
                if argument.range(of: #"^[A-Za-z0-9-]{1,16}$"#, options: .regularExpression) == nil {
                    found.append("\(name): argument \(argument) is not a plain word or flag")
                }
                if mutatingWords.contains(argument.lowercased()) { found.append("\(name): \(argument) is a mutating word") }
            }
            let spec = CommandSpec(executablePath: "/usr/bin/\(name)", arguments: arguments)
            let risks = CommandShapeClassifier.classify(spec.displayString).risks
            if !risks.isEmpty { found.append("\(name): classifier flags \(risks.map(\.rawValue).sorted())") }
        }
        return found
    }
}
