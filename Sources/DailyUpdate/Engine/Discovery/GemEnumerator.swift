import Foundation

/// ADR-002 §2 "gem" (P2-3): `specifications/*.gemspec`, keyed by file name
/// `<name>-<version>[-<platform>].gemspec` — the first `-`-separated segment (after the name) that
/// parses as a `Version` is the version; anything before it is the name, anything after is the
/// platform. `specifications/default/` (Ruby's own bundled gems) is a directory, so it's never
/// read as a gemspec by this scan. The Ruby interpreter is never evaluated; `s.executables` is
/// read out of the `.gemspec` source with a regex. System → Blocked(`systemOwned`); anything else
/// → Blocked(`noStrategy`) (existing `StrategyPlanner` arms; unchanged by this file).
struct GemEnumerator: Enumerator {
    let ecosystem: Ecosystem = .gem

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = DiscoveryDeadline(context.limits.perEnumeratorDeadline)

        var installRoots: [InstallRoot] = []
        var records: [InstalledPackage] = []
        var issues: [EnumerationIssue] = []

        for candidate in Self.roots(context: context) {
            let specifications = "\(candidate.path)/specifications"
            guard context.fileSystem.stat(specifications) != nil else { continue }
            let binDirectory = "\(candidate.path)/bin"
            let activity = Self.activity(binDirectory: binDirectory, loginPath: context.loginPath)
            let root = InstallRoot(ecosystem: .gem, path: candidate.path, label: candidate.systemOwned ? "gem (system)" : "gem", binDirectories: [binDirectory], activity: activity)
            installRoots.append(root)

            guard PathTrust.isTrustedDirectory(specifications) else {
                issues.append(EnumerationIssue(kind: .untrustedRoot, rootPath: specifications, message: "gem specifications root is not trusted"))
                continue
            }
            guard let listing = try? context.fileSystem.contentsOfDirectory(specifications) else {
                issues.append(EnumerationIssue(kind: .unreadable, rootPath: specifications, message: "Could not read gem specifications"))
                continue
            }
            if listing.truncated {
                issues.append(EnumerationIssue(kind: .capReached, rootPath: specifications, message: "More than \(context.limits.maxEntriesPerRoot) gemspecs"))
            }

            for entry in listing.entries.sorted() where entry.hasSuffix(".gemspec") {
                if deadline.hasExpired() {
                    issues.append(EnumerationIssue(kind: .deadline, rootPath: specifications, message: "gem enumerator deadline reached"))
                    break
                }
                switch Self.record(gemspecFile: entry, root: root, systemOwned: candidate.systemOwned, binDirectory: binDirectory, context: context) {
                case .found(let record): records.append(record)
                case .skipped: break
                case .issue(let issue): issues.append(issue)
                }
            }
        }

        let status: EnumerationStatus = issues.isEmpty ? .complete : .partial(issues)
        return EnumerationResult(ecosystem: .gem, roots: installRoots, records: records, status: status, elapsed: clock.now - start)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .gem else { return nil }
        let result = await enumerate(context)
        return result.records.first { $0.packageID == identity.packageID && $0.root.path == identity.rootPath }
    }

    private enum GemspecOutcome {
        case found(InstalledPackage)
        case skipped
        case issue(EnumerationIssue)
    }

    // MARK: - Roots

    private struct RootCandidate {
        let path: String
        let systemOwned: Bool
    }

    private static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/Library/Ruby/Gems") || path.hasPrefix("/System/Library/")
    }

    private static func roots(context: DiscoveryContext) -> [RootCandidate] {
        if let override = context.environmentSnapshot["GEM_HOME"], !override.isEmpty {
            return [RootCandidate(path: override, systemOwned: isSystemPath(override))]
        }
        if let override = context.environmentSnapshot["GEM_PATH"], !override.isEmpty {
            return override.split(separator: ":").map { RootCandidate(path: String($0), systemOwned: isSystemPath(String($0))) }
        }

        var candidates: [RootCandidate] = []
        let home = context.layout.homeDirectory
        for entry in Self.subdirectories("\(home)/.gem/ruby", context: context) {
            candidates.append(RootCandidate(path: entry, systemOwned: false))
        }
        for prefix in context.layout.brewPrefixes {
            for entry in Self.subdirectories("\(prefix)/lib/ruby/gems", context: context) {
                candidates.append(RootCandidate(path: entry, systemOwned: false))
            }
        }
        for entry in Self.subdirectories("/Library/Ruby/Gems", context: context) {
            candidates.append(RootCandidate(path: entry, systemOwned: true))
        }
        for versionDirectory in Self.subdirectories("/System/Library/Frameworks/Ruby.framework/Versions", context: context) {
            for entry in Self.subdirectories("\(versionDirectory)/usr/lib/ruby/gems", context: context) {
                candidates.append(RootCandidate(path: entry, systemOwned: true))
            }
        }
        return candidates
    }

    private static func subdirectories(_ path: String, context: DiscoveryContext) -> [String] {
        guard let listing = try? context.fileSystem.contentsOfDirectory(path) else { return [] }
        return listing.entries.sorted().compactMap { entry -> String? in
            let full = "\(path)/\(entry)"
            guard context.fileSystem.stat(full)?.isDirectory == true else { return nil }
            return full
        }
    }

    private static func activity(binDirectory: String, loginPath: LoginPath) -> RootActivity {
        switch loginPath {
        case .known(let entries): return entries.contains(binDirectory) ? .active : .inactive
        case .empty, .unknown: return .unknown
        }
    }

    // MARK: - One gemspec

    private static func record(
        gemspecFile: String, root: InstallRoot, systemOwned: Bool, binDirectory: String, context: DiscoveryContext
    ) -> GemspecOutcome {
        guard let parsed = Self.parseGemspecFileName(gemspecFile) else { return .skipped }
        guard PackageNameRules.isValidGemName(parsed.name) else { return .skipped }

        let gemspecPath = "\(root.path)/specifications/\(gemspecFile)"
        let stem = String(gemspecFile.dropLast(".gemspec".count))
        let gemDirectory = "\(root.path)/gems/\(stem)"
        let packageDirectory = context.fileSystem.stat(gemDirectory) != nil ? gemDirectory : root.path

        var executableNames: [String] = []
        if let data = try? context.fileSystem.readFile(gemspecPath, maxBytes: context.limits.maxBytesPerFile),
           let text = String(data: data, encoding: .utf8) {
            executableNames = Self.executableNames(from: text)
        }

        var executables: [String] = []
        for name in executableNames {
            let perGemCandidate = "\(gemDirectory)/bin/\(name)"
            let sharedCandidate = "\(binDirectory)/\(name)"
            if context.fileSystem.stat(sharedCandidate) != nil {
                executables.append(context.fileSystem.realpath(sharedCandidate) ?? sharedCandidate)
            } else if context.fileSystem.stat(perGemCandidate) != nil {
                executables.append(context.fileSystem.realpath(perGemCandidate) ?? perGemCandidate)
            }
        }

        let identityPath = executables.first ?? gemspecPath
        guard let fileID = (context.fileSystem.realpath(identityPath).flatMap(context.fileSystem.stat) ?? context.fileSystem.stat(identityPath))?.fileID else {
            return .issue(EnumerationIssue(kind: .unreadable, rootPath: root.path, message: "\(gemspecFile): could not stat \(identityPath)"))
        }

        return .found(InstalledPackage(
            ecosystem: .gem, packageID: parsed.name, versionRaw: parsed.version, root: root,
            packageDirectory: packageDirectory, executables: executables,
            owner: .gem(gemDir: root.path, name: parsed.name, systemOwned: systemOwned),
            evidence: [Evidence(kind: "gemspec", path: gemspecPath)], confidence: .proven, fileID: fileID
        ))
    }

    /// `<name>-<version>[-<platform>]`: scan segments from index 1 onward for the first one that
    /// parses as a `Version` (D9-style — a plain textual check, no execution). Everything before
    /// it is the name (rejoined with `-`), everything after is the platform.
    private static func parseGemspecFileName(_ fileName: String) -> (name: String, version: String, platform: String?)? {
        guard fileName.hasSuffix(".gemspec") else { return nil }
        let stem = String(fileName.dropLast(".gemspec".count))
        let segments = stem.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2 else { return nil }

        for index in 1..<segments.count where Version(segments[index]) != nil {
            let name = segments[0..<index].joined(separator: "-")
            guard !name.isEmpty else { return nil }
            let version = segments[index]
            let platform = segments.count > index + 1 ? segments[(index + 1)...].joined(separator: "-") : nil
            return (name, version, platform)
        }
        return nil
    }

    private static func executableNames(from gemspecText: String) -> [String] {
        guard let lineMatch = gemspecText.range(of: #"executables\s*=\s*\[(.*?)\]"#, options: .regularExpression) else {
            return []
        }
        let line = String(gemspecText[lineMatch])
        guard let regex = try? NSRegularExpression(pattern: #"["']([^"']+)["']"#) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match -> String? in
            guard let group = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[group])
        }
    }
}
