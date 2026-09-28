import Foundation

/// ADR-002 §2 "cargo" (P2-3): `.crates2.json`'s `installs` map, keyed
/// `"<crate> <version> (<source>)"`. A registry install stays Blocked(`noStrategy`); a git or path
/// source becomes `manualOnly` (`StrategyPlanner.makeStrategy`'s `.cargo` arm reads the source off
/// the owner). Only `.crates.toml` (the old metadata format) present → `partial`, never read.
struct CargoEnumerator: Enumerator {
    let ecosystem: Ecosystem = .cargo

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        let rootPath = Self.root(context: context)
        let binDirectory = "\(rootPath)/bin"
        let activity = Self.activity(binDirectory: binDirectory, loginPath: context.loginPath)
        let installRoot = InstallRoot(ecosystem: .cargo, path: rootPath, label: "cargo", binDirectories: [binDirectory], activity: activity)

        guard context.fileSystem.stat(rootPath) != nil else {
            return EnumerationResult(ecosystem: .cargo, status: .complete, elapsed: clock.now - start)
        }
        guard PathTrust.isTrustedDirectory(rootPath) else {
            let issue = EnumerationIssue(kind: .untrustedRoot, rootPath: rootPath, message: "cargo root is not trusted")
            return EnumerationResult(ecosystem: .cargo, roots: [installRoot], status: .partial([issue]), elapsed: clock.now - start)
        }

        let manifestPath = "\(rootPath)/.crates2.json"
        guard context.fileSystem.stat(manifestPath) != nil else {
            if context.fileSystem.stat("\(rootPath)/.crates.toml") != nil {
                let issue = EnumerationIssue(kind: .malformed, rootPath: rootPath, message: "old metadata format not read")
                return EnumerationResult(ecosystem: .cargo, roots: [installRoot], status: .partial([issue]), elapsed: clock.now - start)
            }
            return EnumerationResult(ecosystem: .cargo, status: .complete, elapsed: clock.now - start)
        }

        guard let data = try? context.fileSystem.readFile(manifestPath, maxBytes: context.limits.maxBytesPerFile) else {
            let issue = EnumerationIssue(kind: .unreadable, rootPath: rootPath, message: "Could not read .crates2.json")
            return EnumerationResult(ecosystem: .cargo, roots: [installRoot], status: .partial([issue]), elapsed: clock.now - start)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installs = payload["installs"] as? [String: Any] else {
            let issue = EnumerationIssue(kind: .malformed, rootPath: rootPath, message: ".crates2.json is not the expected shape")
            return EnumerationResult(ecosystem: .cargo, roots: [installRoot], status: .partial([issue]), elapsed: clock.now - start)
        }

        var records: [InstalledPackage] = []
        var issues: [EnumerationIssue] = []
        for key in installs.keys.sorted() {
            guard let parsed = Self.parseInstallKey(key) else {
                issues.append(EnumerationIssue(kind: .malformed, rootPath: rootPath, message: "Could not parse install key: \(key)"))
                continue
            }
            guard PackageNameRules.isValidCrateName(parsed.crate) else { continue }
            let bins = ((installs[key] as? [String: Any])?["bins"] as? [String]) ?? []
            let executables = bins.sorted().compactMap { bin -> String? in
                let candidate = "\(binDirectory)/\(bin)"
                guard context.fileSystem.stat(candidate) != nil else { return nil }
                return context.fileSystem.realpath(candidate) ?? candidate
            }
            // D4: the executable's `FileID` identifies the record when there is one. Cargo installs
            // are flat — every crate shares one root directory, no per-crate folder — so the
            // fallback "package folder" identity would collide across crates unless the crate name
            // disambiguates it (`dispatchName`, the same field RC4's rustup proxies use for an
            // analogous "one inode, several distinct rows" case).
            let fileID: FileID?
            if let executablePath = executables.first {
                fileID = (context.fileSystem.realpath(executablePath).flatMap(context.fileSystem.stat) ?? context.fileSystem.stat(executablePath))?.fileID
            } else if let rootFileID = context.fileSystem.stat(rootPath)?.fileID {
                fileID = FileID(device: rootFileID.device, inode: rootFileID.inode, dispatchName: parsed.crate)
            } else {
                fileID = nil
            }
            guard let fileID else { continue }

            records.append(InstalledPackage(
                ecosystem: .cargo, packageID: parsed.crate, versionRaw: parsed.version, root: installRoot,
                packageDirectory: rootPath, executables: executables,
                owner: .cargo(root: rootPath, crate: parsed.crate, source: parsed.source),
                evidence: [Evidence(kind: ".crates2.json", path: manifestPath)], confidence: .proven,
                fileID: fileID
            ))
        }

        let status: EnumerationStatus = issues.isEmpty ? .complete : .partial(issues)
        return EnumerationResult(ecosystem: .cargo, roots: [installRoot], records: records, status: status, elapsed: clock.now - start)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .cargo else { return nil }
        let result = await enumerate(context)
        return result.records.first { $0.packageID == identity.packageID }
    }

    // MARK: - Root

    private static func root(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["CARGO_INSTALL_ROOT"], !override.isEmpty { return override }
        if let override = context.environmentSnapshot["CARGO_HOME"], !override.isEmpty { return override }
        return "\(context.layout.homeDirectory)/.cargo"
    }

    private static func activity(binDirectory: String, loginPath: LoginPath) -> RootActivity {
        switch loginPath {
        case .known(let entries): return entries.contains(binDirectory) ? .active : .inactive
        case .empty, .unknown: return .unknown
        }
    }

    // MARK: - Parsing

    private struct ParsedInstall {
        let crate: String
        let version: String
        let source: CargoSource
    }

    /// `"<crate> <version> (<source>)"`, e.g. `"ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)"`.
    private static func parseInstallKey(_ key: String) -> ParsedInstall? {
        guard let regex = try? NSRegularExpression(pattern: #"^(\S+) (\S+) \((.+)\)$"#) else { return nil }
        let range = NSRange(key.startIndex..., in: key)
        guard let result = regex.firstMatch(in: key, range: range),
              let crateRange = Range(result.range(at: 1), in: key),
              let versionRange = Range(result.range(at: 2), in: key),
              let sourceRange = Range(result.range(at: 3), in: key) else {
            return nil
        }
        let crate = String(key[crateRange])
        let version = String(key[versionRange])
        let sourceString = String(key[sourceRange])
        let source: CargoSource
        if sourceString.hasPrefix("git+") {
            source = .git
        } else if sourceString.hasPrefix("path+") {
            source = .path
        } else {
            source = .registry
        }
        return ParsedInstall(crate: crate, version: version, source: source)
    }
}
