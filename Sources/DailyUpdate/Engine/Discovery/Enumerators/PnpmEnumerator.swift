import Foundation

/// ADR-002 §2, P2-2: pnpm globals. `PNPM_HOME` → `~/Library/pnpm`. Packages are the dependencies of
/// `<home>/global/<layout>/package.json`, where `<layout>` is pnpm's global-layout folder (`5` on
/// current pnpm; `v5`-style names are accepted too ⚠️ documented, not installed here) and the
/// newest one wins. A `global` folder with no such layout is `failed`. pnpm present with no `global`
/// folder is `complete` with 0 packages (D12). Shims in `PNPM_HOME` are read as text, never run,
/// looking for the target package's path. Listed only (D7).
struct PnpmEnumerator: Enumerator {
    let ecosystem: Ecosystem = .pnpm

    static func home(_ context: DiscoveryContext) -> String {
        context.overridePath("PNPM_HOME") ?? DiscoveryPaths.join(context.homeDirectory, "Library", "pnpm")
    }

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        var scan = EnumerationScan(ecosystem: .pnpm, context: context)
        return Self.read(context, scan: &scan)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .pnpm else { return nil }
        var scan = EnumerationScan(ecosystem: .pnpm, context: context)
        return Self.read(context, only: identity.packageID, scan: &scan).records.first { $0.packageID == identity.packageID }
    }

    private static func read(_ context: DiscoveryContext, only: String? = nil, scan: inout EnumerationScan) -> EnumerationResult {
        let home = scan.canonical(home(context)) ?? home(context)
        let global = DiscoveryPaths.join(home, "global")
        guard scan.isDirectory(global) else {
            if scan.isDirectory(home) || NodePackageReader.isOnLoginPath("pnpm", scan: scan) {
                return scan.result(roots: [], records: [])
            }
            return scan.nothingFound("pnpm isn't installed")
        }

        let layouts = (scan.list(global, root: home) ?? []).filter {
            $0.range(of: #"^v?[0-9]+$"#, options: .regularExpression) != nil &&
                scan.exists(DiscoveryPaths.join(global, $0, "package.json"))
        }
        guard let layout = DiscoveryPaths.numericallySorted(layouts.map(DiscoveryPaths.withoutLeadingV)).last,
              let folderName = layouts.first(where: { DiscoveryPaths.withoutLeadingV($0) == layout }) else {
            return EnumerationResult(ecosystem: .pnpm, status: .failed(EnumerationIssue(
                kind: .malformed, rootPath: global, message: "pnpm (\(home)): the global folder has a layout Daily Update doesn't know"
            )))
        }
        let globalFolder = DiscoveryPaths.join(global, folderName)
        let root = InstallRoot(
            ecosystem: .pnpm, path: globalFolder, label: "pnpm", binDirectories: [home],
            activity: context.activity(ofBinDirectories: [home])
        )
        let shims = readShims(home: home, scan: &scan)
        let records = NodePackageReader.readGlobalFolder(
            globalFolder, root: root, label: "pnpm (\(home))",
            owner: { .pnpm(home: home, package: $0) },
            commands: { manifest, _, _ in
                let marker = "/global/\(folderName)/node_modules/\(manifest.name)/"
                let matches = shims.filter { $0.text.contains(marker) }
                return (matches.map(\.name), matches.map(\.path))
            },
            only: only, scan: &scan
        )
        return scan.result(roots: [root], records: records)
    }

    private struct Shim {
        let name: String
        let path: String
        let text: String
    }

    /// Every regular file directly in `PNPM_HOME`, read as text with a 64 KB cap.
    private static func readShims(home: String, scan: inout EnumerationScan) -> [Shim] {
        var shims: [Shim] = []
        for entry in scan.list(home, root: home) ?? [] where BrewEnumerator.isValidCommandName(entry) {
            let path = DiscoveryPaths.join(home, entry)
            guard scan.fileSystem.lstat(path)?.isRegularFile == true,
                  let text = scan.readText(path, maxBytes: 64 * 1024, root: home) else { continue }
            shims.append(Shim(name: entry, path: path, text: text))
        }
        return shims
    }
}
