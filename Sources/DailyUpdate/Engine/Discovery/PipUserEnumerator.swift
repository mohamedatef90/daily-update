import Foundation

/// ADR-002 §2 "pip (user)" (P2-3): `PYTHONUSERBASE`, or each `~/Library/Python/<X.Y>` version
/// folder captured on this Mac. Rows only for dists that carry a `REQUESTED` marker (installed
/// directly, not pulled in as someone else's dependency) — a bare `pip install --user X` leaves
/// `REQUESTED` in `X`'s own dist-info but never in the dists `X` depends on. Blocked(`noStrategy`);
/// Homebrew and python.org site-packages are out of scope (FU5).
struct PipUserEnumerator: Enumerator {
    let ecosystem: Ecosystem = .pip

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = DiscoveryDeadline(context.limits.perEnumeratorDeadline)

        var installRoots: [InstallRoot] = []
        var records: [InstalledPackage] = []
        var issues: [EnumerationIssue] = []

        for versionRoot in Self.versionRoots(context: context) {
            let sitePackages = "\(versionRoot)/lib/python/site-packages"
            guard context.fileSystem.stat(sitePackages) != nil else { continue }
            let binDirectory = "\(versionRoot)/bin"
            let activity = Self.activity(binDirectory: binDirectory, loginPath: context.loginPath)
            let root = InstallRoot(ecosystem: .pip, path: sitePackages, label: "pip (user, \(versionRoot.split(separator: "/").last ?? ""))", binDirectories: [binDirectory], activity: activity)
            installRoots.append(root)

            guard PathTrust.isTrustedDirectory(sitePackages) else {
                issues.append(EnumerationIssue(kind: .untrustedRoot, rootPath: sitePackages, message: "pip user site-packages is not trusted"))
                continue
            }
            guard let listing = try? context.fileSystem.contentsOfDirectory(sitePackages) else {
                issues.append(EnumerationIssue(kind: .unreadable, rootPath: sitePackages, message: "Could not read the pip user site-packages"))
                continue
            }
            if listing.truncated {
                issues.append(EnumerationIssue(kind: .capReached, rootPath: sitePackages, message: "More than \(context.limits.maxEntriesPerRoot) entries"))
            }

            for entry in listing.entries.sorted() where entry.hasSuffix(".dist-info") {
                if deadline.hasExpired() {
                    issues.append(EnumerationIssue(kind: .deadline, rootPath: sitePackages, message: "pip user enumerator deadline reached"))
                    break
                }
                switch Self.record(distInfoFolder: entry, root: root, binDirectory: binDirectory, context: context) {
                case .found(let record): records.append(record)
                case .skippedNotRequested, .missing: break
                case .issue(let issue): issues.append(issue)
                }
            }
        }

        let status: EnumerationStatus = issues.isEmpty ? .complete : .partial(issues)
        return EnumerationResult(ecosystem: .pip, roots: installRoots, records: records, status: status, elapsed: clock.now - start)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .pip else { return nil }
        let sitePackages = identity.rootPath
        let versionRoot = URL(fileURLWithPath: sitePackages).deletingLastPathComponent().deletingLastPathComponent().path
        let binDirectory = "\(versionRoot)/bin"
        let activity = Self.activity(binDirectory: binDirectory, loginPath: context.loginPath)
        let root = InstallRoot(ecosystem: .pip, path: sitePackages, label: "pip (user)", binDirectories: [binDirectory], activity: activity)
        let distInfoFolder = (identity.packageDirectory as NSString).lastPathComponent
        guard case .found(let record) = Self.record(distInfoFolder: distInfoFolder, root: root, binDirectory: binDirectory, context: context) else {
            return nil
        }
        return record
    }

    private enum DistOutcome {
        case found(InstalledPackage)
        case skippedNotRequested
        case missing
        case issue(EnumerationIssue)
    }

    // MARK: - Roots

    /// `PYTHONUSERBASE` replaces every default outright. Absent an override, every
    /// `~/Library/Python/<X.Y>` folder that exists is its own version root (there can be more than
    /// one Python minor version installed at once).
    private static func versionRoots(context: DiscoveryContext) -> [String] {
        if let override = context.environmentSnapshot["PYTHONUSERBASE"], !override.isEmpty { return [override] }
        let base = "\(context.layout.homeDirectory)/Library/Python"
        guard let listing = try? context.fileSystem.contentsOfDirectory(base) else { return [] }
        return listing.entries
            .filter { $0.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil }
            .sorted()
            .map { "\(base)/\($0)" }
    }

    private static func activity(binDirectory: String, loginPath: LoginPath) -> RootActivity {
        switch loginPath {
        case .known(let entries): return entries.contains(binDirectory) ? .active : .inactive
        case .empty, .unknown: return .unknown
        }
    }

    // MARK: - One dist

    private static func record(distInfoFolder: String, root: InstallRoot, binDirectory: String, context: DiscoveryContext) -> DistOutcome {
        let distInfoPath = "\(root.path)/\(distInfoFolder)"
        guard context.fileSystem.stat(distInfoPath) != nil else { return .missing }
        guard context.fileSystem.stat("\(distInfoPath)/REQUESTED") != nil else { return .skippedNotRequested }

        guard let metadataData = try? context.fileSystem.readFile("\(distInfoPath)/METADATA", maxBytes: context.limits.maxBytesPerFile),
              let metadataText = String(data: metadataData, encoding: .utf8),
              let name = Self.metadataField("Name", in: metadataText),
              PackageNameRules.isValidPyPIName(name) else {
            return .issue(EnumerationIssue(kind: .malformed, rootPath: root.path, message: "\(distInfoFolder): METADATA is not the expected shape"))
        }
        let versionRaw = Self.metadataField("Version", in: metadataText)

        var evidence = [Evidence(kind: "dist-info", path: distInfoPath)]
        if context.fileSystem.stat("\(distInfoPath)/INSTALLER") != nil {
            evidence.append(Evidence(kind: "INSTALLER", path: "\(distInfoPath)/INSTALLER"))
        }

        let executables = Self.executables(distInfoPath: distInfoPath, binDirectory: binDirectory, context: context)
        let identityPath = executables.first ?? distInfoPath
        guard let fileID = (context.fileSystem.realpath(identityPath).flatMap(context.fileSystem.stat) ?? context.fileSystem.stat(identityPath))?.fileID else {
            return .issue(EnumerationIssue(kind: .unreadable, rootPath: root.path, message: "\(distInfoFolder): could not stat \(identityPath)"))
        }

        return .found(InstalledPackage(
            ecosystem: .pip, packageID: name, versionRaw: versionRaw, root: root,
            packageDirectory: distInfoPath, executables: executables,
            owner: .pipUser(site: root.path, distribution: name), flags: [.onRequest],
            evidence: evidence, confidence: .proven, fileID: fileID
        ))
    }

    /// `RECORD` lists every installed file relative to the dist-info folder; a console script it
    /// installed shows up as `../../../bin/<script>,...` (three levels up from
    /// `lib/python/site-packages/<dist>.dist-info` lands back at the version root).
    private static func executables(distInfoPath: String, binDirectory: String, context: DiscoveryContext) -> [String] {
        guard let recordData = try? context.fileSystem.readFile("\(distInfoPath)/RECORD", maxBytes: 5_000_000),
              let recordText = String(data: recordData, encoding: .utf8) else {
            return []
        }
        var found: [String] = []
        for line in recordText.split(separator: "\n") {
            guard let relativePath = line.split(separator: ",").first else { continue }
            guard relativePath.hasPrefix("../../../bin/") else { continue }
            let scriptName = relativePath.dropFirst("../../../bin/".count)
            guard !scriptName.isEmpty else { continue }
            let candidate = "\(binDirectory)/\(scriptName)"
            guard context.fileSystem.stat(candidate) != nil else { continue }
            found.append(context.fileSystem.realpath(candidate) ?? candidate)
        }
        return found
    }

    private static func metadataField(_ field: String, in text: String) -> String? {
        let prefix = "\(field):"
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix(prefix) {
            let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
