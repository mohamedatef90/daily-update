import Foundation

/// ADR-002 §2, P2-2: bun globals ⚠️ documented, not installed here. `BUN_INSTALL` → `~/.bun`.
/// Packages are the dependencies of `install/global/package.json`; commands are the links in
/// `<root>/bin`. `bun pm ls -g` is never run (Stage 1 found it unreliable). bun present with no
/// global folder is `complete` with 0 packages (D12). Listed only (D7).
struct BunEnumerator: Enumerator {
    let ecosystem: Ecosystem = .bun

    static func root(_ context: DiscoveryContext) -> String {
        context.overridePath("BUN_INSTALL") ?? DiscoveryPaths.join(context.homeDirectory, ".bun")
    }

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        var scan = EnumerationScan(ecosystem: .bun, context: context)
        return Self.read(context, scan: &scan)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .bun else { return nil }
        var scan = EnumerationScan(ecosystem: .bun, context: context)
        return Self.read(context, only: identity.packageID, scan: &scan).records.first { $0.packageID == identity.packageID }
    }

    private static func read(_ context: DiscoveryContext, only: String? = nil, scan: inout EnumerationScan) -> EnumerationResult {
        let bunRoot = scan.canonical(root(context)) ?? root(context)
        let global = DiscoveryPaths.join(bunRoot, "install", "global")
        let bin = DiscoveryPaths.join(bunRoot, "bin")
        guard scan.isDirectory(global) else {
            if scan.isDirectory(bunRoot) || NodePackageReader.isOnLoginPath("bun", scan: scan) {
                return scan.result(roots: [], records: [])
            }
            return scan.nothingFound("bun isn't installed")
        }
        let root = InstallRoot(
            ecosystem: .bun, path: global, label: "bun global", binDirectories: [bin],
            activity: context.activity(ofBinDirectories: [bin])
        )
        let records = NodePackageReader.readGlobalFolder(
            global, root: root, label: "bun (\(bunRoot))",
            owner: { .bun(root: bunRoot, package: $0) },
            commands: { manifest, folder, scan in
                NodePackageReader.commands(manifest, canonicalFolder: folder, binDirectory: bin, scan: scan)
            },
            only: only, scan: &scan
        )
        return scan.result(roots: [root], records: records)
    }
}
