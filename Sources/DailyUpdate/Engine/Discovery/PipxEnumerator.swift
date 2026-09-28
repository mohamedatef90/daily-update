import Foundation

/// ADR-002 §2 "pipx" (P2-3): `venvs/<name>/pipx_metadata.json` is the source of truth (`documented
/// ⚠️`: pipx isn't installed on this Mac, so this is built from pipx's own metadata format, not a
/// capture). Blocked(`noStrategy`) — pipx keeps no typed strategy in this phase.
struct PipxEnumerator: Enumerator {
    let ecosystem: Ecosystem = .pipx

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = DiscoveryDeadline(context.limits.perEnumeratorDeadline)
        let binDirectory = Self.binDirectory(context: context)
        let activity = Self.activity(binDirectory: binDirectory, loginPath: context.loginPath)

        var installRoots: [InstallRoot] = []
        var records: [InstalledPackage] = []
        var issues: [EnumerationIssue] = []

        for homeRoot in Self.homeRoots(context: context) {
            let venvsRoot = "\(homeRoot)/venvs"
            guard context.fileSystem.stat(venvsRoot) != nil else { continue }
            let root = InstallRoot(ecosystem: .pipx, path: venvsRoot, label: "pipx", binDirectories: [binDirectory], activity: activity)
            installRoots.append(root)

            guard PathTrust.isTrustedDirectory(venvsRoot) else {
                issues.append(EnumerationIssue(kind: .untrustedRoot, rootPath: venvsRoot, message: "pipx venvs root is not trusted"))
                continue
            }
            guard let listing = try? context.fileSystem.contentsOfDirectory(venvsRoot) else {
                issues.append(EnumerationIssue(kind: .unreadable, rootPath: venvsRoot, message: "Could not read the pipx venvs root"))
                continue
            }
            if listing.truncated {
                issues.append(EnumerationIssue(kind: .capReached, rootPath: venvsRoot, message: "More than \(context.limits.maxEntriesPerRoot) pipx venvs"))
            }

            for venvName in listing.entries.sorted() {
                if deadline.hasExpired() {
                    issues.append(EnumerationIssue(kind: .deadline, rootPath: venvsRoot, message: "pipx enumerator deadline reached"))
                    break
                }
                switch Self.record(venvName: venvName, root: root, binDirectory: binDirectory, context: context) {
                case .found(let record): records.append(record)
                case .missing: break
                case .issue(let issue): issues.append(issue)
                }
            }
        }

        let status: EnumerationStatus = issues.isEmpty ? .complete : .partial(issues)
        return EnumerationResult(ecosystem: .pipx, roots: installRoots, records: records, status: status, elapsed: clock.now - start)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .pipx else { return nil }
        let binDirectory = Self.binDirectory(context: context)
        let activity = Self.activity(binDirectory: binDirectory, loginPath: context.loginPath)
        let venvsRoot = URL(fileURLWithPath: identity.packageDirectory).deletingLastPathComponent().path
        let root = InstallRoot(ecosystem: .pipx, path: venvsRoot, label: "pipx", binDirectories: [binDirectory], activity: activity)
        guard case .found(let record) = Self.record(venvName: identity.packageID, root: root, binDirectory: binDirectory, context: context) else {
            return nil
        }
        return record
    }

    private enum VenvOutcome {
        case found(InstalledPackage)
        case missing
        case issue(EnumerationIssue)
    }

    // MARK: - Roots

    /// `PIPX_HOME`, taken alone, replaces every default; absent an override, every default that
    /// actually exists on disk is scanned (only one of them is ever real on a given install, but
    /// which one depends on how pipx itself was installed).
    private static func homeRoots(context: DiscoveryContext) -> [String] {
        if let override = context.environmentSnapshot["PIPX_HOME"], !override.isEmpty { return [override] }
        let home = context.layout.homeDirectory
        return ["\(home)/.local/pipx", "\(home)/.local/share/pipx", "\(home)/Library/Application Support/pipx"]
    }

    private static func binDirectory(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["PIPX_BIN_DIR"], !override.isEmpty { return override }
        return "\(context.layout.homeDirectory)/.local/bin"
    }

    private static func activity(binDirectory: String, loginPath: LoginPath) -> RootActivity {
        switch loginPath {
        case .known(let entries): return entries.contains(binDirectory) ? .active : .inactive
        case .empty, .unknown: return .unknown
        }
    }

    // MARK: - One venv

    private static func record(venvName: String, root: InstallRoot, binDirectory: String, context: DiscoveryContext) -> VenvOutcome {
        let venvDirectory = "\(root.path)/\(venvName)"
        guard context.fileSystem.stat(venvDirectory) != nil else { return .missing }

        let metadataPath = "\(venvDirectory)/pipx_metadata.json"
        guard let metadataData = try? context.fileSystem.readFile(metadataPath, maxBytes: context.limits.maxBytesPerFile) else {
            return .issue(EnumerationIssue(kind: .unreadable, rootPath: root.path, message: "\(venvName): could not read pipx_metadata.json"))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let mainPackage = payload["main_package"] as? [String: Any],
              let packageName = (mainPackage["package"] as? String)?.nilIfEmpty,
              PackageNameRules.isValidPyPIName(packageName) else {
            return .issue(EnumerationIssue(kind: .malformed, rootPath: root.path, message: "\(venvName): pipx_metadata.json is not the expected shape"))
        }
        let versionRaw = (mainPackage["package_version"] as? String)?.nilIfEmpty
        let apps = (mainPackage["apps"] as? [String]) ?? []

        let canonicalVenvDirectory = context.fileSystem.realpath(venvDirectory) ?? venvDirectory
        let prefix = "\(canonicalVenvDirectory)/bin/"
        var executables: [String] = []
        if let binListing = try? context.fileSystem.contentsOfDirectory(binDirectory) {
            for entry in binListing.entries.sorted() where apps.isEmpty || apps.contains(entry) {
                let candidate = "\(binDirectory)/\(entry)"
                guard let destination = context.fileSystem.realpath(candidate), destination.hasPrefix(prefix) else { continue }
                executables.append(destination)
            }
        }

        let identityPath = executables.first ?? venvDirectory
        guard let fileID = (context.fileSystem.realpath(identityPath).flatMap(context.fileSystem.stat) ?? context.fileSystem.stat(identityPath))?.fileID else {
            return .issue(EnumerationIssue(kind: .unreadable, rootPath: root.path, message: "\(venvName): could not stat \(identityPath)"))
        }

        return .found(InstalledPackage(
            ecosystem: .pipx, packageID: venvName, displayName: packageName, versionRaw: versionRaw, root: root,
            packageDirectory: venvDirectory, executables: executables, owner: .pipx(package: venvName),
            evidence: [Evidence(kind: "pipx_metadata.json", path: metadataPath)], confidence: .proven, fileID: fileID
        ))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
