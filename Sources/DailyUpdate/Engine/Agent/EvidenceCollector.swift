import Foundation

/// One fact about the item, collected by the engine (never by the agent).
struct EvidenceItem: Codable, Equatable {
    var kind: String
    var source: String
    var text: String
    var truncated: Bool
}

struct EvidenceBundle: Equatable {
    var items: [EvidenceItem]
    /// Why something was not collected (shown to the agent as a fact, and in the CLI report).
    var notes: [String]

    var combinedText: String { (items.map(\.text) + notes).joined(separator: "\n") }
}

/// AI-1 "evidence in, no tools": the engine gathers a single item's facts deterministically through
/// read-only paths, and the agent only ever sees this text. Everything here is:
/// - read-only: `readFile` through `ReadOnlyFileSystem`, `PathSearch` for `which -a`, and at most two
///   processes (`<tool> --version`, `brew info --json=v2`) started only through `BoundedProcessRunner`
///   with an exact environment, a timeout and an output cap;
/// - gated: every command passes `CommandShapeClassifier` and `PathTrust` before it starts;
/// - scoped: only the item's own paths (its command on PATH, its own package folder, its own `.app`);
///   no directory listing;
/// - capped: per item and in total, with `truncated` set when something was cut;
/// - redacted: the home directory and account name become `~` and `<user>`.
struct EvidenceCollector {
    typealias Runner = (BoundedProcessSpec) async -> QueryOutcome

    static let maxItemCharacters = 3000
    static let maxTotalCharacters = 12000
    static let maxManifestBytes = 64 * 1024
    static let maxPlistBytes = 256 * 1024
    static let maxFieldCharacters = 300
    static let versionTimeout: TimeInterval = 10
    static let brewTimeout: TimeInterval = 20

    var run: Runner = BoundedProcessRunner.run
    var fileSystem: ReadOnlyFileSystem = LiveFileSystem()
    var home: String = NSHomeDirectory()
    var user: String = NSUserName()
    var pathEntries: () -> [String] = {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }
    var isTrustedExecutable: (String) -> Bool = { PathTrust.isTrustedExecutable($0) }

    private static let commandNameRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._+-]+$"#) // swiftlint:disable:this force_try

    func collect(for context: AgentItemContext) async -> EvidenceBundle {
        var items: [EvidenceItem] = []
        var notes: [String] = []

        if let name = context.commandName, Self.isValidCommandName(name) {
            let candidates = PathSearch.candidates(for: name, pathEntries: pathEntries(), fileSystem: fileSystem)
            if candidates.isEmpty {
                notes.append("`which -a \(name)`: no executable named \(name) on PATH")
            } else {
                let lines = candidates.map { candidate -> String in
                    let real = fileSystem.realpath(candidate)
                    return real == nil || real == candidate ? candidate : "\(candidate) -> \(real!)"
                }
                items.append(makeItem(kind: "which", source: "which -a \(name)", text: lines.joined(separator: "\n")))
                if let active = candidates.first {
                    if let version = await versionEvidence(executable: active, name: name) {
                        items.append(version)
                    } else {
                        notes.append("version probe for \(name) was skipped (untrusted location or gated command)")
                    }
                }
            }
        } else {
            notes.append("no command name is known for this item, so no version probe or PATH lookup ran")
        }

        if let brew = await brewEvidence(for: context) {
            items.append(brew)
        }
        if let manifest = manifestEvidence(for: context) {
            items.append(manifest)
        } else if context.ecosystem == "npm" {
            notes.append("the package manifest was not found under the item's own root")
        }
        if let plist = plistEvidence(for: context) {
            items.append(plist)
        }

        // Total cap: later items are dropped (and noted) rather than silently cut.
        var kept: [EvidenceItem] = []
        var total = 0
        for item in items {
            if total + item.text.count > Self.maxTotalCharacters {
                notes.append("evidence '\(item.kind)' was dropped: total evidence cap reached")
                continue
            }
            total += item.text.count
            kept.append(item)
        }
        return EvidenceBundle(items: kept, notes: notes.map { AgentRedaction.redact($0, home: home, user: user) })
    }

    // MARK: - `<tool> --version`

    private func versionEvidence(executable: String, name: String) async -> EvidenceItem? {
        let spec = CommandSpec(executablePath: executable, arguments: ["--version"])
        // The classifier gate: a command with any risk is never started.
        guard CommandShapeClassifier.classify(spec.displayString).risks.isEmpty,
              isTrustedExecutable(executable) else { return nil }
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let outcome = await run(BoundedProcessSpec(
            executable: executable, arguments: ["--version"],
            environment: .exactly([
                "HOME": home, "PATH": [directory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":"),
                "LANG": "en_US.UTF-8", "NO_COLOR": "1",
            ]),
            timeout: Self.versionTimeout, maxStdoutBytes: 4096, maxStderrBytes: 2048,
            workingDirectory: NSTemporaryDirectory()))
        var text: String
        switch outcome.evidence.termination {
        case .exited(let code):
            let out = String(decoding: outcome.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let err = outcome.evidence.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            text = "exit \(code)\n" + [out, err.isEmpty ? "" : "stderr: " + err].filter { !$0.isEmpty }.joined(separator: "\n")
        case .timedOut: text = "timed out"
        case .outputCapExceeded: text = "output cap exceeded"
        case .signaled(let signal): text = "killed by signal \(signal)"
        case .launchFailed: text = "could not start"
        }
        return makeItem(kind: "version", source: "\(name) --version", text: text)
    }

    // MARK: - brew info

    private func brewEvidence(for context: AgentItemContext) async -> EvidenceItem? {
        guard context.ecosystem == "brew" || context.handle?.hasPrefix("brew:") == true || context.handle?.hasPrefix("cask:") == true,
              let package = context.packageID ?? context.handle?.split(separator: ":", maxSplits: 1).last.map(String.init),
              PackageNameRules.isValidBrewFormulaName(package) || PackageNameRules.isValidCaskToken(package) || PackageNameRules.isValidTapQualifiedName(package),
              let brew = PathSearch.candidates(for: "brew", pathEntries: pathEntries(), fileSystem: fileSystem).first,
              isTrustedExecutable(brew),
              fileSystem.stat(ReadOnlyQueries.sandboxExecutable) != nil else { return nil }
        let arguments = ["info", "--json=v2", package]
        guard CommandShapeClassifier.classify(CommandSpec(executablePath: brew, arguments: arguments).displayString).risks.isEmpty else { return nil }
        // The same network-denied, write-denied sandbox profile discovery uses for `brew info`.
        let outcome = await run(BoundedProcessSpec(
            executable: ReadOnlyQueries.sandboxExecutable,
            arguments: ["-p", ReadOnlyQueries.sandboxProfile, brew] + arguments,
            environment: .exactly(ReadOnlyQueries.enricherEnvironment()),
            timeout: Self.brewTimeout, maxStdoutBytes: 512 * 1024, maxStderrBytes: 2048,
            workingDirectory: NSTemporaryDirectory()))
        guard case .exited(0) = outcome.evidence.termination,
              let object = try? JSONSerialization.jsonObject(with: outcome.stdout) as? [String: Any] else { return nil }
        var summary: [String: Any] = [:]
        if let formula = (object["formulae"] as? [[String: Any]])?.first {
            summary = pick(formula, ["name", "full_name", "desc", "homepage", "deprecated", "disabled", "keg_only"])
            summary["stableVersion"] = (formula["versions"] as? [String: Any])?["stable"]
            summary["installedVersions"] = (formula["installed"] as? [[String: Any]])?.compactMap { $0["version"] }
        } else if let cask = (object["casks"] as? [[String: Any]])?.first {
            summary = pick(cask, ["token", "desc", "homepage", "version", "auto_updates", "deprecated", "disabled"])
        }
        guard !summary.isEmpty else { return nil }
        return makeItem(kind: "brew", source: "brew info --json=v2 \(package)", text: compactJSON(summary))
    }

    // MARK: - package manifest (npm)

    private func manifestEvidence(for context: AgentItemContext) -> EvidenceItem? {
        guard context.ecosystem == "npm", let root = context.root, !root.isEmpty,
              let package = context.packageID, PackageNameRules.isValidNpmName(package) else { return nil }
        let expandedRoot = root.hasPrefix("~") ? home + root.dropFirst() : root
        // Only this package's own manifest, under this item's own root.
        let path = expandedRoot + "/lib/node_modules/" + package + "/package.json"
        guard let data = try? fileSystem.readFile(path, maxBytes: Self.maxManifestBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var summary = pick(object, ["name", "version", "description", "homepage", "license", "engines"])
        if let bin = object["bin"] as? [String: Any] { summary["binNames"] = Array(bin.keys.sorted().prefix(10)) }
        else if object["bin"] is String { summary["binNames"] = [package.split(separator: "/").last.map(String.init) ?? package] }
        if let repository = object["repository"] as? [String: Any] { summary["repository"] = repository["url"] }
        else if let repository = object["repository"] as? String { summary["repository"] = repository }
        // Script NAMES only (a postinstall hook is a fact worth knowing); the commands themselves are not copied.
        if let scripts = object["scripts"] as? [String: Any] { summary["scriptNames"] = Array(scripts.keys.sorted().prefix(15)) }
        return makeItem(kind: "manifest", source: "\(package)/package.json", text: compactJSON(summary))
    }

    // MARK: - app bundle Info.plist

    private func plistEvidence(for context: AgentItemContext) -> EvidenceItem? {
        guard let rawPath = context.appPath else { return nil }
        let appPath = rawPath.hasPrefix("~") ? home + rawPath.dropFirst() : rawPath
        guard appPath.hasSuffix(".app"), !appPath.contains(".."),
              appPath.hasPrefix("/Applications/") || appPath.hasPrefix(home + "/Applications/") else { return nil }
        guard let data = try? fileSystem.readFile(appPath + "/Contents/Info.plist", maxBytes: Self.maxPlistBytes),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        let summary = pick(object, ["CFBundleName", "CFBundleDisplayName", "CFBundleIdentifier", "CFBundleShortVersionString",
                                    "CFBundleVersion", "LSMinimumSystemVersion", "SUFeedURL", "SUPublicEDKey"])
        guard !summary.isEmpty else { return nil }
        return makeItem(kind: "infoPlist", source: URL(fileURLWithPath: appPath).lastPathComponent + "/Contents/Info.plist", text: compactJSON(summary))
    }

    // MARK: - helpers

    static func isValidCommandName(_ name: String) -> Bool {
        let range = NSRange(location: 0, length: name.utf16.count)
        return name.count <= 64 && commandNameRegex.firstMatch(in: name, range: range) != nil
    }

    private func pick(_ object: [String: Any], _ keys: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in keys {
            guard let value = object[key], !(value is NSNull) else { continue }
            result[key] = limited(value)
        }
        return result
    }

    private func limited(_ value: Any) -> Any {
        if let string = value as? String { return String(string.prefix(Self.maxFieldCharacters)) }
        if let array = value as? [Any] { return array.prefix(20).map(limited) }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(limited) }
        return value
    }

    private func compactJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func makeItem(kind: String, source: String, text: String) -> EvidenceItem {
        let redacted = AgentRedaction.redact(text, home: home, user: user)
        let truncated = redacted.count > Self.maxItemCharacters
        return EvidenceItem(kind: kind, source: AgentRedaction.redact(source, home: home, user: user),
                            text: String(redacted.prefix(Self.maxItemCharacters)), truncated: truncated)
    }
}
