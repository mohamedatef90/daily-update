import Foundation

/// ADR-002 §9 P2-3, and Amendment 1 F8 (required here because `specify-cli` on this Mac is a uv
/// tool installed from git): the current version comes from dist-info; the latest from a pinned
/// GET to PyPI's JSON API, skipping yanked releases and prereleases unless the installed version
/// is itself one. `uv tool upgrade <name>` honors the receipt's own constraints and can't pin an
/// exact version — a D4 exception, so the caller re-reads the version after running it instead of
/// trusting a target this strategy never named.
struct UvToolStrategy: Strategy {
    let name: String
    let uvExecutable: String
    let packageDirectory: String
    let environmentSnapshot: [String: String]
    let fetchRelease: StrategyPlanner.ReleaseFetcher

    let requiresLatestVersion = true
    let requiresTargetVersion = false

    func currentVersion() async -> String? {
        Self.installedVersion(packageDirectory: packageDirectory, name: name)
    }

    func latestVersion(currentVersion: String?) async -> LatestVersionOutcome {
        switch Self.validateReceipt(packageDirectory: packageDirectory, name: name, environmentSnapshot: environmentSnapshot) {
        case .blocked(let message):
            return LatestVersionOutcome(latestVersion: nil, blockReason: .manualOnly, failureMessage: message)
        case .ok:
            break
        }

        guard let body = await fetchRelease(Self.pypiRequest(for: name)) else {
            return LatestVersionOutcome(latestVersion: nil)
        }
        guard let best = Self.bestVersion(fromPyPIJSON: body, currentVersion: currentVersion) else {
            return LatestVersionOutcome(latestVersion: nil)
        }
        return LatestVersionOutcome(latestVersion: best)
    }

    /// Confirmed against `uv tool upgrade --help` on this Mac: `uv tool upgrade <NAME>...`. There
    /// is no version argument — the receipt's own constraints decide what lands.
    func updateCommand(targetVersion: String?) -> CommandSpec? {
        CommandSpec(executablePath: uvExecutable, arguments: ["tool", "upgrade", name])
    }

    // MARK: - PyPI "latest" (skip yanked, skip prereleases unless current is one)

    static func pypiRequest(for name: String) -> CommandSpec {
        let normalized = PackageNameRules.pep503Normalized(name)
        return CommandSpec(
            executablePath: "/usr/bin/curl",
            arguments: ["-q", "--proto", "=https", "--fail", "--silent", "--show-error", "--max-time", "20",
                        "https://pypi.org/pypi/\(normalized)/json"]
        )
    }

    static func bestVersion(fromPyPIJSON body: String, currentVersion: String?) -> String? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = root["releases"] as? [String: Any] else {
            return nil
        }
        let currentIsPrerelease = currentVersion.flatMap { Version($0) }?.prerelease.isEmpty == false

        var best: Version?
        for (token, rawFiles) in releases {
            guard let files = rawFiles as? [[String: Any]], !files.isEmpty else { continue }
            let allYanked = files.allSatisfy { ($0["yanked"] as? Bool) == true }
            guard !allYanked, let version = Version(token) else { continue }
            guard currentIsPrerelease || version.prerelease.isEmpty else { continue }
            if best == nil || version > best! { best = version }
        }
        return best?.raw
    }

    // MARK: - F8: the uv receipt must describe a plain PyPI install with no custom index

    enum ReceiptValidation: Equatable {
        case ok
        case blocked(String)
    }

    static func validateReceipt(packageDirectory: String, name: String, environmentSnapshot: [String: String]) -> ReceiptValidation {
        let receiptPath = "\(packageDirectory)/uv-receipt.toml"
        guard let data = FileManager.default.contents(atPath: receiptPath),
              let text = String(data: data, encoding: .utf8) else {
            return .blocked("No uv receipt")
        }
        guard let requirementText = requirementEntry(forToolName: name, in: text) else {
            return .blocked("No uv receipt")
        }
        if requirementText.range(of: #"\bgit\s*="#, options: .regularExpression) != nil {
            return .blocked("Installed from git")
        }
        if requirementText.range(of: #"\burl\s*="#, options: .regularExpression) != nil {
            return .blocked("from a URL")
        }
        if requirementText.range(of: #"\b(path|editable)\s*="#, options: .regularExpression) != nil {
            return .blocked("from a local path")
        }
        let allowedKeys: Set<String> = ["name", "specifier", "extras", "marker"]
        let presentKeys = keys(in: requirementText)
        guard presentKeys.isSubset(of: allowedKeys) else {
            return .blocked("from a local path")
        }

        if hasCustomIndexConfigured(packageDirectory: packageDirectory, environmentSnapshot: environmentSnapshot) {
            return .blocked("Uses a custom package index")
        }
        return .ok
    }

    /// The `requirements = [...]` line is a single-line TOML array of inline tables; a value
    /// spread over several lines never matches this and fails the check (F8), same as a missing
    /// `requirements` key entirely. Only the entry whose `name` matches this tool is inspected —
    /// a `--with` dependency pulled in alongside it may have any shape without blocking the tool.
    private static func requirementEntry(forToolName name: String, in receiptText: String) -> String? {
        guard let lineMatch = receiptText.range(of: #"(?m)^requirements\s*=\s*\[(.*)\]\s*$"#, options: .regularExpression) else {
            return nil
        }
        let line = String(receiptText[lineMatch])
        let normalizedTool = PackageNameRules.pep503Normalized(name)
        guard let regex = try? NSRegularExpression(pattern: #"\{([^{}]*)\}"#) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        for match in regex.matches(in: line, range: range) {
            guard let groupRange = Range(match.range(at: 1), in: line) else { continue }
            let entry = String(line[groupRange])
            guard let nameMatch = entry.range(of: #"name\s*=\s*"([^"]*)""#, options: .regularExpression) else { continue }
            let nameSegment = String(entry[nameMatch])
            guard let quoted = nameSegment.range(of: #""([^"]*)""#, options: .regularExpression) else { continue }
            let entryName = String(nameSegment[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if PackageNameRules.pep503Normalized(entryName) == normalizedTool { return entry }
        }
        return nil
    }

    private static func keys(in requirementEntry: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"(\w[\w-]*)\s*="#) else { return [] }
        let range = NSRange(requirementEntry.startIndex..., in: requirementEntry)
        var found = Set<String>()
        for match in regex.matches(in: requirementEntry, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: requirementEntry) else { continue }
            found.insert(String(requirementEntry[keyRange]))
        }
        return found
    }

    private static func hasCustomIndexConfigured(packageDirectory: String, environmentSnapshot: [String: String]) -> Bool {
        let indexEnvironmentVariables = ["UV_INDEX_URL", "UV_DEFAULT_INDEX", "UV_INDEX", "UV_EXTRA_INDEX_URL"]
        if indexEnvironmentVariables.contains(where: { !(environmentSnapshot[$0] ?? "").isEmpty }) {
            return true
        }
        guard let data = FileManager.default.contents(atPath: "\(packageDirectory)/uv.toml"),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.range(of: #"(?m)^\s*(index|index-url|extra-index-url)\s*="#, options: .regularExpression) != nil
    }

    // MARK: - Package directory (derived from the resolved owner path, same root logic as `OwnerResolver.classify`)

    static func packageDirectory(resolvedPath: String, roots: [String]) -> String? {
        let normalizedPath = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
        for root in roots {
            let normalizedRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path
            guard normalizedPath.hasPrefix("\(normalizedRoot)/") else { continue }
            let relative = String(normalizedPath.dropFirst(normalizedRoot.count + 1))
            guard let first = relative.split(separator: "/").first else { continue }
            return "\(normalizedRoot)/\(first)"
        }
        return nil
    }

    // MARK: - dist-info (mirrors `UvToolEnumerator`; a live check reads via `FileManager` directly,
    // the same way every other strategy in this file does, rather than through the
    // Discovery-only `ReadOnlyFileSystem`)

    static func installedVersion(packageDirectory: String, name: String) -> String? {
        guard let libEntries = try? FileManager.default.contentsOfDirectory(atPath: "\(packageDirectory)/lib") else { return nil }
        guard let pythonDirectory = libEntries.sorted().first(where: { $0.hasPrefix("python") }) else { return nil }
        let sitePackages = "\(packageDirectory)/lib/\(pythonDirectory)/site-packages"
        guard let siteEntries = try? FileManager.default.contentsOfDirectory(atPath: sitePackages) else { return nil }

        let normalizedTool = PackageNameRules.pep503Normalized(name)
        guard let distInfo = siteEntries.first(where: { entry in
            guard let distName = distInfoName(entry) else { return false }
            return PackageNameRules.pep503Normalized(distName) == normalizedTool
        }) else {
            return nil
        }

        if let data = FileManager.default.contents(atPath: "\(sitePackages)/\(distInfo)/METADATA"),
           let text = String(data: data, encoding: .utf8),
           let version = metadataVersion(from: text) {
            return version
        }
        return versionFromDistInfoFolder(distInfo)
    }

    private static func distInfoName(_ folder: String) -> String? {
        guard folder.hasSuffix(".dist-info") else { return nil }
        let stem = String(folder.dropLast(".dist-info".count))
        guard let separator = stem.range(of: "-", options: .backwards) else { return nil }
        return String(stem[..<separator.lowerBound])
    }

    private static func versionFromDistInfoFolder(_ folder: String) -> String? {
        guard folder.hasSuffix(".dist-info") else { return nil }
        let stem = String(folder.dropLast(".dist-info".count))
        guard let separator = stem.range(of: "-", options: .backwards) else { return nil }
        let version = String(stem[separator.upperBound...])
        return version.isEmpty ? nil : version
    }

    private static func metadataVersion(from text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("Version:") {
            let value = String(line.dropFirst("Version:".count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
