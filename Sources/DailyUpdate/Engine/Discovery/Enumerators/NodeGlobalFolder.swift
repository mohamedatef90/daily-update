import Foundation

extension NodePackageReader {
    /// pnpm, yarn classic and bun keep globals the same way: a `package.json` whose
    /// `dependencies` name the global packages, plus `node_modules/<name>/package.json`. Only the
    /// listed dependencies are records (never their transitive packages). A global folder
    /// without a readable `package.json` is a `malformed` issue, never "nothing installed" (D3).
    static func readGlobalFolder(
        _ globalFolder: String,
        root: InstallRoot,
        label: String,
        owner: (String) -> ResolvedOwner,
        commands: (Manifest, String, EnumerationScan) -> (commands: [String], executables: [String]),
        only: String? = nil,
        scan: inout EnumerationScan
    ) -> [InstalledPackage] {
        let manifestPath = DiscoveryPaths.join(globalFolder, "package.json")
        guard let manifest = scan.readJSONObject(manifestPath, maxBytes: EnumerationScan.metadataByteCap, root: globalFolder, required: true) else {
            return []
        }
        let dependencies = (manifest["dependencies"] as? [String: Any]) ?? [:]
        var records: [InstalledPackage] = []
        for name in dependencies.keys.sorted() {
            guard !scan.deadlinePassed() else { break }
            if let only, name != only { continue }
            guard PackageNameRules.isValidNpmName(name) else {
                scan.report(.malformed, root: globalFolder, message: "\(label): skipped a dependency whose name isn't a valid npm name")
                continue
            }
            let folder = DiscoveryPaths.join(globalFolder, "node_modules", name)
            guard let canonicalFolder = scan.canonical(folder) else {
                if scan.fileSystem.lstat(folder) == nil {
                    scan.report(.unreadable, root: folder, message: "\(label): \(name) is listed but not installed")
                } else {
                    _ = scan.read(DiscoveryPaths.join(folder, "package.json"), maxBytes: EnumerationScan.manifestByteCap,
                        root: folder, required: true)
                }
                continue
            }
            guard let packageManifest = readManifest(folder: canonicalFolder, expectedName: name, label: label, scan: &scan),
                  let folderID = scan.fileID(of: canonicalFolder) else { continue }
            let (names, executables) = commands(packageManifest, canonicalFolder, scan)
            records.append(InstalledPackage(
                ecosystem: root.ecosystem, packageID: name, versionRaw: packageManifest.version, root: root,
                packageDirectory: canonicalFolder, executables: executables, commands: names, owner: owner(name),
                evidence: [Evidence(kind: "package.json", path: DiscoveryPaths.join(canonicalFolder, "package.json"))],
                confidence: .proven,
                fileID: executables.first.flatMap { scan.fileID(of: $0) } ?? folderID
            ))
        }
        return records
    }

    /// Whether `command` is on the known login PATH (`PathSearch`, never a process).
    static func isOnLoginPath(_ command: String, scan: EnumerationScan) -> Bool {
        !PathSearch.candidates(for: command, pathEntries: scan.context.loginPath.entries, fileSystem: scan.fileSystem).isEmpty
    }
}
