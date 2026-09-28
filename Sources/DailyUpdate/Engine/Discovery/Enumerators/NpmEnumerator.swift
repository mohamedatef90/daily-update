import Foundation

// MARK: - Reading one node_modules package (npm, pnpm, yarn classic, bun)

/// `node_modules/<name>/package.json` and `node_modules/@scope/<name>/package.json`, read the
/// same way for every Node package manager (§2, §7.3, §7.4).
enum NodePackageReader {
    struct Manifest {
        let name: String
        let version: String?
        /// `(command, path relative to the package folder)`, in manifest order.
        let bins: [(String, String)]
    }

    /// Every package name under `nodeModules`, scoped ones as `@scope/name`, sorted. Dot entries
    /// (`.bin`, `.package-lock.json`, `.staging`) aren't packages.
    static func packageNames(in nodeModules: String, root: String, scan: inout EnumerationScan) -> [String]? {
        guard let entries = scan.list(nodeModules, root: root) else { return nil }
        var names: [String] = []
        for entry in entries where !entry.hasPrefix(".") {
            if entry.hasPrefix("@") {
                for scoped in scan.list(DiscoveryPaths.join(nodeModules, entry), root: root) ?? [] where !scoped.hasPrefix(".") {
                    names.append("\(entry)/\(scoped)")
                }
            } else {
                names.append(entry)
            }
        }
        return names
    }

    /// D15: the manifest's `name` must equal the folder name and pass the npm regex; otherwise
    /// the package is a `malformed` issue on its own folder and never becomes a record.
    static func readManifest(folder: String, expectedName: String, label: String, scan: inout EnumerationScan) -> Manifest? {
        let path = DiscoveryPaths.join(folder, "package.json")
        guard let json = scan.readJSONObject(path, maxBytes: EnumerationScan.manifestByteCap, root: folder, required: true) else { return nil }
        guard let name = json["name"] as? String, name == expectedName, PackageNameRules.isValidNpmName(name) else {
            scan.report(.malformed, root: folder,
                message: "\(label): \(expectedName)'s package.json names a different package, or no valid one")
            return nil
        }
        var bins: [(String, String)] = []
        if let single = json["bin"] as? String {
            bins = [(String(name.split(separator: "/").last ?? Substring(name)), single)]
        } else if let map = json["bin"] as? [String: Any] {
            bins = map.keys.sorted().compactMap { key in (map[key] as? String).map { (key, $0) } }
        }
        let version = (json["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Manifest(name: name, version: version, bins: bins)
    }

    /// §7.2: a command is attributed only when the manifest's `bin` target stays inside the
    /// package folder and `<binDirectory>/<command>` resolves to that same file.
    static func commands(
        _ manifest: Manifest,
        canonicalFolder: String,
        binDirectory: String,
        scan: EnumerationScan
    ) -> (commands: [String], executables: [String]) {
        var commands: [String] = []
        var executables: [String] = []
        for (command, relative) in manifest.bins {
            guard BrewEnumerator.isValidCommandName(command), !relative.hasPrefix("/"),
                  let target = scan.canonical(DiscoveryPaths.join(canonicalFolder, relative)),
                  DiscoveryPaths.isPath(target, within: canonicalFolder),
                  scan.fileSystem.stat(target)?.isRegularFile == true,
                  scan.canonical(DiscoveryPaths.join(binDirectory, command)) == target,
                  !commands.contains(command) else { continue }
            commands.append(command)
            executables.append(target)
        }
        return (commands, executables)
    }
}

// MARK: - npm

/// ADR-002 §2, P2-2: global npm packages. A prefix `P` is a root only when `<P>/lib/node_modules`
/// and `<P>/bin/node` both exist. Roots: `NPM_CONFIG_PREFIX`/`npm_config_prefix`, the Homebrew
/// prefixes, every nvm/fnm/volta Node version, `/usr/local`, `~/.npm-global` and `~/.local`
/// (the last three from `EcosystemLayout`).
/// Discovery never runs npm.
struct NpmEnumerator: Enumerator {
    let ecosystem: Ecosystem = .npm

    struct Root: Hashable, Sendable {
        let path: String
        let label: String
    }

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        var scan = EnumerationScan(ecosystem: .npm, context: context)
        let roots = Self.candidateRoots(context, scan: &scan)
        guard !roots.isEmpty else { return scan.nothingFound("No npm global folder found") }

        var installRoots: [InstallRoot] = []
        var records: [InstalledPackage] = []
        for root in roots {
            guard !scan.deadlinePassed() else { break }
            let (installRoot, rootRecords) = Self.read(root, context: context, scan: &scan)
            installRoots.append(installRoot)
            records += rootRecords
        }
        return scan.result(roots: installRoots, records: records)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .npm else { return nil }
        var scan = EnumerationScan(ecosystem: .npm, context: context)
        guard Self.isRoot(identity.rootPath, scan: scan) else { return nil }
        let label = Self.candidateRoots(context, scan: &scan).first { $0.path == identity.rootPath }?.label ?? identity.rootPath
        return Self.read(Root(path: identity.rootPath, label: label), only: identity.packageID, context: context, scan: &scan)
            .1.first { $0.packageID == identity.packageID }
    }

    // MARK: Roots

    static func candidateRoots(_ context: DiscoveryContext, scan: inout EnumerationScan) -> [Root] {
        var candidates: [Root] = []
        for name in ["NPM_CONFIG_PREFIX", "npm_config_prefix"] {
            if let prefix = context.overridePath(name) { candidates.append(Root(path: prefix, label: "npm prefix \(prefix)")) }
        }
        // `/usr/local` is also a default Homebrew prefix; it's only labeled Homebrew when it has
        // a Cellar (on Apple silicon it's usually the nodejs.org installer's prefix instead).
        candidates += context.layout.brewPrefixes.map { prefix in
            Root(path: prefix, label: scan.isDirectory(DiscoveryPaths.join(prefix, "Cellar"))
                ? BrewEnumerator.label(for: prefix) : homeRelative(prefix, home: context.homeDirectory))
        }
        for folder in NodeVersionManagers.nvmVersions(context, scan: &scan) + NodeVersionManagers.fnmVersions(context, scan: &scan)
            + NodeVersionManagers.voltaVersions(context, scan: &scan) {
            candidates.append(Root(path: folder.prefix, label: folder.label))
        }
        for prefix in context.layout.npmSystemPrefixes + context.layout.npmGlobalRoots {
            candidates.append(Root(path: prefix, label: homeRelative(prefix, home: context.homeDirectory)))
        }

        var seen = Set<String>()
        var roots: [Root] = []
        for candidate in candidates {
            guard isRoot(candidate.path, scan: scan), let canonical = scan.canonical(candidate.path),
                  seen.insert(canonical).inserted else { continue }
            roots.append(Root(path: canonical, label: candidate.label))
        }
        return roots
    }

    static func homeRelative(_ path: String, home: String) -> String {
        DiscoveryPaths.isPath(path, within: home) ? "~" + String(path.dropFirst(home.count)) : path
    }

    static func isRoot(_ prefix: String, scan: EnumerationScan) -> Bool {
        scan.isDirectory(DiscoveryPaths.join(prefix, "lib", "node_modules")) && scan.exists(DiscoveryPaths.join(prefix, "bin", "node"))
    }

    // MARK: Records

    static func read(_ root: Root, only: String? = nil, context: DiscoveryContext, scan: inout EnumerationScan) -> (InstallRoot, [InstalledPackage]) {
        let prefix = root.path
        let npm = DiscoveryPaths.join(prefix, "bin", "npm")
        let bin = DiscoveryPaths.join(prefix, "bin")
        let installRoot = InstallRoot(
            ecosystem: .npm, path: prefix, label: root.label, binDirectories: [bin],
            activity: context.activity(ofBinDirectories: [bin]),
            toolPath: scan.exists(npm) && PathTrust.isTrustedExecutable(npm) ? npm : nil
        )
        let trusted = PathTrust.isTrustedDirectory(prefix)
        if !trusted, only == nil {
            scan.report(.untrustedRoot, root: prefix, message: "npm (\(root.label)): the folder or one of its parents can be written by other users")
        }

        let nodeModules = DiscoveryPaths.join(prefix, "lib", "node_modules")
        guard let names = NodePackageReader.packageNames(in: nodeModules, root: prefix, scan: &scan) else { return (installRoot, []) }
        var records: [InstalledPackage] = []
        for name in names {
            guard !scan.deadlinePassed() else { break }
            if let only, name != only { continue }
            guard PackageNameRules.isValidNpmName(name) else {
                scan.report(.malformed, root: prefix, message: "npm (\(root.label)): skipped a folder whose name isn't a valid npm name")
                continue
            }
            let folder = DiscoveryPaths.join(nodeModules, name)
            guard let canonicalFolder = scan.canonical(folder) else {
                scan.report(.unreadable, root: folder, message: "npm (\(root.label)): couldn't resolve \(name)")
                continue
            }
            guard let manifest = NodePackageReader.readManifest(folder: canonicalFolder, expectedName: name, label: "npm (\(root.label))", scan: &scan) else {
                continue
            }

            // D10: a package folder that is a symlink out of the prefix is an `npm link`.
            var flags: Set<PackageFlag> = []
            var evidence = [Evidence(kind: "package.json", path: DiscoveryPaths.join(canonicalFolder, "package.json"))]
            if scan.fileSystem.lstat(folder)?.isSymbolicLink == true, !DiscoveryPaths.isPath(canonicalFolder, within: prefix) {
                flags.insert(.linked)
                evidence.append(Evidence(kind: "npm-link", path: canonicalFolder))
            }
            if !trusted { flags.insert(.untrustedRoot) }
            let (commands, executables) = NodePackageReader.commands(manifest, canonicalFolder: canonicalFolder, binDirectory: bin, scan: scan)
            guard let folderID = scan.fileID(of: canonicalFolder) else { continue }
            records.append(InstalledPackage(
                ecosystem: .npm, packageID: name, versionRaw: manifest.version, root: installRoot,
                packageDirectory: canonicalFolder, executables: executables, commands: commands,
                owner: .npm(prefix: prefix, package: name), flags: flags, evidence: evidence, confidence: .proven,
                fileID: executables.first.flatMap { scan.fileID(of: $0) } ?? folderID
            ))
        }
        return (installRoot, records)
    }
}
