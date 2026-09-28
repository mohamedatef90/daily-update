import Foundation

/// ADR-002 §2 "uv tool" (P2-3): one row per tool, keyed by the tool's folder name under the uv
/// tools root. The dist-info folder that matches the tool name (after PEP 503 normalization) is
/// the source of truth for the version; `uv-receipt.toml` is optional evidence only, never a
/// version source. Reads only; never runs `uv` or anything else.
struct UvToolEnumerator: Enumerator {
    let ecosystem: Ecosystem = .uv

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = DiscoveryDeadline(context.limits.perEnumeratorDeadline)
        let rootPath = Self.toolsRoot(context: context)
        let binDirectory = Self.binDirectory(context: context)
        let activity = Self.activity(binDirectory: binDirectory, loginPath: context.loginPath)
        let installRoot = InstallRoot(
            ecosystem: .uv, path: rootPath, label: "uv tools",
            binDirectories: [binDirectory], activity: activity
        )

        guard context.fileSystem.stat(rootPath) != nil else {
            return EnumerationResult(ecosystem: .uv, status: .complete, elapsed: clock.now - start)
        }
        guard PathTrust.isTrustedDirectory(rootPath) else {
            let issue = EnumerationIssue(kind: .untrustedRoot, rootPath: rootPath, message: "uv tools root is not trusted")
            return EnumerationResult(ecosystem: .uv, roots: [installRoot], status: .partial([issue]), elapsed: clock.now - start)
        }

        guard let listing = try? context.fileSystem.contentsOfDirectory(rootPath) else {
            let issue = EnumerationIssue(kind: .unreadable, rootPath: rootPath, message: "Could not read the uv tools root")
            return EnumerationResult(ecosystem: .uv, roots: [installRoot], status: .partial([issue]), elapsed: clock.now - start)
        }

        var records: [InstalledPackage] = []
        var issues: [EnumerationIssue] = []
        if listing.truncated {
            issues.append(EnumerationIssue(kind: .capReached, rootPath: rootPath, message: "More than \(context.limits.maxEntriesPerRoot) uv tools"))
        }

        for toolName in listing.entries.sorted() {
            if deadline.hasExpired() {
                issues.append(EnumerationIssue(kind: .deadline, rootPath: rootPath, message: "uv enumerator deadline reached"))
                break
            }
            guard PackageNameRules.isValidPyPIName(toolName) else { continue }
            switch Self.record(toolName: toolName, root: installRoot, binDirectory: binDirectory, context: context) {
            case .found(let record):
                records.append(record)
            case .missing:
                break
            case .issue(let issue):
                issues.append(issue)
            }
        }

        let status: EnumerationStatus = issues.isEmpty ? .complete : .partial(issues)
        return EnumerationResult(ecosystem: .uv, roots: [installRoot], records: records, status: status, elapsed: clock.now - start)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .uv else { return nil }
        let binDirectory = Self.binDirectory(context: context)
        let activity = Self.activity(binDirectory: binDirectory, loginPath: context.loginPath)
        let root = InstallRoot(
            ecosystem: .uv, path: identity.rootPath, label: "uv tools",
            binDirectories: [binDirectory], activity: activity
        )
        guard case .found(let record) = Self.record(toolName: identity.packageID, root: root, binDirectory: binDirectory, context: context) else {
            return nil
        }
        return record
    }

    private enum ToolOutcome {
        case found(InstalledPackage)
        case missing
        case issue(EnumerationIssue)
    }

    // MARK: - Roots

    static func toolsRoot(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["UV_TOOL_DIR"], !override.isEmpty { return override }
        if let xdg = context.environmentSnapshot["XDG_DATA_HOME"], !xdg.isEmpty { return "\(xdg)/uv/tools" }
        return "\(context.layout.homeDirectory)/.local/share/uv/tools"
    }

    static func binDirectory(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["UV_TOOL_BIN_DIR"], !override.isEmpty { return override }
        return "\(context.layout.homeDirectory)/.local/bin"
    }

    private static func activity(binDirectory: String, loginPath: LoginPath) -> RootActivity {
        switch loginPath {
        case .known(let entries): return entries.contains(binDirectory) ? .active : .inactive
        case .empty, .unknown: return .unknown
        }
    }

    // MARK: - One tool

    private static func record(
        toolName: String,
        root: InstallRoot,
        binDirectory: String,
        context: DiscoveryContext
    ) -> ToolOutcome {
        let toolDirectory = "\(root.path)/\(toolName)"
        guard context.fileSystem.stat(toolDirectory) != nil else { return .missing }

        guard let libListing = try? context.fileSystem.contentsOfDirectory("\(toolDirectory)/lib") else {
            return .issue(EnumerationIssue(kind: .unreadable, rootPath: root.path, message: "\(toolName): could not read lib/"))
        }
        guard let pythonDirectory = libListing.entries.sorted().first(where: { $0.hasPrefix("python") }) else {
            return .issue(EnumerationIssue(kind: .malformed, rootPath: root.path, message: "\(toolName): no python* folder under lib/"))
        }

        let sitePackages = "\(toolDirectory)/lib/\(pythonDirectory)/site-packages"
        guard let siteListing = try? context.fileSystem.contentsOfDirectory(sitePackages) else {
            return .issue(EnumerationIssue(kind: .unreadable, rootPath: root.path, message: "\(toolName): could not read site-packages"))
        }

        let normalizedTool = PackageNameRules.pep503Normalized(toolName)
        guard let distInfo = siteListing.entries.first(where: { entry in
            guard let name = Self.distInfoName(entry) else { return false }
            return PackageNameRules.pep503Normalized(name) == normalizedTool
        }) else {
            return .issue(EnumerationIssue(kind: .malformed, rootPath: root.path, message: "\(toolName): no matching dist-info in site-packages"))
        }

        let distInfoPath = "\(sitePackages)/\(distInfo)"
        var versionRaw = Self.versionFromDistInfoFolder(distInfo)
        var evidence = [Evidence(kind: "dist-info", path: distInfoPath)]

        if let metadataData = try? context.fileSystem.readFile("\(distInfoPath)/METADATA", maxBytes: context.limits.maxBytesPerFile),
           let metadataText = String(data: metadataData, encoding: .utf8),
           let metadataVersion = Self.metadataVersion(from: metadataText) {
            versionRaw = metadataVersion
        }

        if context.fileSystem.stat("\(toolDirectory)/uv-receipt.toml") != nil {
            evidence.append(Evidence(kind: "uv-receipt.toml", path: "\(toolDirectory)/uv-receipt.toml"))
        }

        let executables = Self.executables(toolName: toolName, toolDirectory: toolDirectory, binDirectory: binDirectory, context: context)
        let identityPath = executables.first ?? toolDirectory
        guard let fileID = (context.fileSystem.realpath(identityPath).flatMap(context.fileSystem.stat) ?? context.fileSystem.stat(identityPath))?.fileID else {
            return .issue(EnumerationIssue(kind: .unreadable, rootPath: root.path, message: "\(toolName): could not stat \(identityPath)"))
        }

        return .found(InstalledPackage(
            ecosystem: .uv, packageID: toolName, versionRaw: versionRaw, root: root,
            packageDirectory: toolDirectory, executables: executables, owner: .uvTool(name: toolName),
            evidence: evidence, confidence: .proven, fileID: fileID
        ))
    }

    private static func executables(toolName: String, toolDirectory: String, binDirectory: String, context: DiscoveryContext) -> [String] {
        guard let binListing = try? context.fileSystem.contentsOfDirectory(binDirectory) else { return [] }
        // The canonical form: on macOS a fixture (or a real `~`) temp path can itself sit behind a
        // symlinked ancestor (`/var` -> `/private/var`), and `realpath` on the candidate always
        // returns the fully resolved form, so the prefix it's compared against must match.
        let canonicalToolDirectory = context.fileSystem.realpath(toolDirectory) ?? toolDirectory
        let prefix = "\(canonicalToolDirectory)/bin/"
        var found: [String] = []
        for entry in binListing.entries.sorted() {
            let candidate = "\(binDirectory)/\(entry)"
            guard let destination = context.fileSystem.realpath(candidate), destination.hasPrefix(prefix) else { continue }
            found.append(candidate)
        }
        return found
    }

    /// `<name>-<version>.dist-info` — both parts are wheel-escaped, so neither contains a raw
    /// hyphen; splitting on the last one is safe.
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
        return String(stem[separator.upperBound...]).nilIfEmpty
    }

    private static func metadataVersion(from text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("Version:") {
                return String(line.dropFirst("Version:".count)).trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
