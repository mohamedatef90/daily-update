import Foundation

/// ADR-002 §2: where nvm, fnm and volta keep their Node versions. Each version folder is a Node
/// runtime (the nvm/fnm rows, task 6) and also an npm root (`NpmEnumerator`, task 4). Roots come
/// from the F4 overrides, else the documented defaults; nothing here runs nvm, fnm or volta.
enum NodeVersionManagers {
    struct VersionFolder: Hashable, Sendable {
        let kind: VersionManagerKind
        /// `NVM_DIR`, the fnm dir, or `VOLTA_HOME`.
        let managerRoot: String
        /// `v24.13.0` → `24.13.0`.
        let version: String
        /// The folder that holds `bin/node` and `lib/node_modules` (the npm prefix).
        let prefix: String

        var label: String {
            switch kind {
            case .volta: return "volta node \(version)"
            default: return "\(kind.rawValue) v\(version)"
            }
        }
    }

    // MARK: nvm

    static func nvmDirectory(_ context: DiscoveryContext) -> String {
        context.overridePath("NVM_DIR") ?? DiscoveryPaths.join(context.homeDirectory, ".nvm")
    }

    /// `$NVM_DIR/versions/node/v*`.
    static func nvmVersions(_ context: DiscoveryContext, scan: inout EnumerationScan) -> [VersionFolder] {
        let root = nvmDirectory(context)
        let versions = DiscoveryPaths.join(root, "versions", "node")
        return versionFolders(in: versions, kind: .nvm, managerRoot: root, scan: &scan) { $0 }
    }

    /// `$NVM_DIR/alias/default`, read as one line of text (never sourced).
    static func nvmDefaultAlias(_ context: DiscoveryContext, scan: inout EnumerationScan) -> String? {
        let path = DiscoveryPaths.join(nvmDirectory(context), "alias", "default")
        return scan.readText(path, maxBytes: 4096, root: nvmDirectory(context))?
            .split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : PackageNameRules.sanitize($0, maxLength: 64) }
    }

    // MARK: fnm

    /// `FNM_DIR`, else `~/.local/share/fnm`, then `~/Library/Application Support/fnm` ⚠️.
    static func fnmDirectories(_ context: DiscoveryContext) -> [String] {
        if let override = context.overridePath("FNM_DIR") { return [override] }
        return [
            DiscoveryPaths.join(context.homeDirectory, ".local", "share", "fnm"),
            DiscoveryPaths.join(context.homeDirectory, "Library", "Application Support", "fnm"),
        ]
    }

    /// `<fnm>/node-versions/v*/installation`.
    static func fnmVersions(_ context: DiscoveryContext, scan: inout EnumerationScan) -> [VersionFolder] {
        fnmDirectories(context).flatMap { root in
            versionFolders(in: DiscoveryPaths.join(root, "node-versions"), kind: .fnm, managerRoot: root, scan: &scan) {
                DiscoveryPaths.join($0, "installation")
            }
        }
    }

    // MARK: volta

    static func voltaDirectory(_ context: DiscoveryContext) -> String {
        context.overridePath("VOLTA_HOME") ?? DiscoveryPaths.join(context.homeDirectory, ".volta")
    }

    /// `$VOLTA_HOME/tools/image/node/<version>`. Volta's own shims in `$VOLTA_HOME/bin` are P2-4's
    /// dispatcher rule; these image folders are only npm roots here.
    static func voltaVersions(_ context: DiscoveryContext, scan: inout EnumerationScan) -> [VersionFolder] {
        let root = voltaDirectory(context)
        return versionFolders(in: DiscoveryPaths.join(root, "tools", "image", "node"), kind: .volta, managerRoot: root, scan: &scan) { $0 }
    }

    // MARK: Shared

    /// Folders named like a version (`v24.13.0` or `24.13.0`), oldest → newest. Symlinked alias
    /// folders (`latest`, `lts/*`, `default`) aren't version names, so they're skipped.
    private static func versionFolders(
        in directory: String,
        kind: VersionManagerKind,
        managerRoot: String,
        scan: inout EnumerationScan,
        prefix: (String) -> String
    ) -> [VersionFolder] {
        guard let entries = scan.list(directory, root: managerRoot) else { return [] }
        var folders: [VersionFolder] = []
        for entry in DiscoveryPaths.numericallySorted(entries) {
            let version = DiscoveryPaths.withoutLeadingV(entry)
            guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { continue }
            let folder = DiscoveryPaths.join(directory, entry)
            guard scan.fileSystem.lstat(folder)?.isDirectory == true else { continue }
            folders.append(VersionFolder(kind: kind, managerRoot: managerRoot, version: version, prefix: prefix(folder)))
        }
        return folders
    }
}
