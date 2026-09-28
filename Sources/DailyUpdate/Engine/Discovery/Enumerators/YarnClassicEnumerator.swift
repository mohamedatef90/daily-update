import Foundation

/// ADR-002 §2, P2-2: Yarn classic (1.x) globals ⚠️ documented, not installed here. The global folder
/// is `global-folder` from `~/.yarnrc` (one line, read as text), else `~/.config/yarn/global`;
/// commands are the links in `<yarnrc prefix>/bin`, else `~/.yarn/bin`. Yarn 2+ has no globals, so
/// a home with only a `.yarnrc.yml` is `unavailable`. Listed only (D7).
struct YarnClassicEnumerator: Enumerator {
    let ecosystem: Ecosystem = .yarn

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        var scan = EnumerationScan(ecosystem: .yarn, context: context)
        return Self.read(context, scan: &scan)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .yarn else { return nil }
        var scan = EnumerationScan(ecosystem: .yarn, context: context)
        return Self.read(context, only: identity.packageID, scan: &scan).records.first { $0.packageID == identity.packageID }
    }

    /// `global-folder "/path"`, `global-folder /path`, `--global-folder /path`; the value must be
    /// absolute. Anything else on the line is ignored; nothing is evaluated.
    static func yarnrcValue(_ key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let pattern = #"^\s*(?:--)?"# + key + #"\s+"?(/[^"\s]*)"?\s*$"#
            guard let range = line.range(of: pattern, options: .regularExpression) else { continue }
            let match = String(line[range])
            if let value = match.range(of: #"/[^"\s]*"#, options: .regularExpression) {
                return String(match[value])
            }
        }
        return nil
    }

    private static func read(_ context: DiscoveryContext, only: String? = nil, scan: inout EnumerationScan) -> EnumerationResult {
        let home = context.homeDirectory
        let yarnrc = scan.readText(DiscoveryPaths.join(home, ".yarnrc"), maxBytes: 64 * 1024, root: home) ?? ""
        let globalFolder = yarnrcValue("global-folder", in: yarnrc) ?? DiscoveryPaths.join(home, ".config", "yarn", "global")
        let bin = yarnrcValue("prefix", in: yarnrc).map { DiscoveryPaths.join($0, "bin") } ?? DiscoveryPaths.join(home, ".yarn", "bin")

        guard scan.isDirectory(globalFolder), let canonicalGlobal = scan.canonical(globalFolder) else {
            if scan.exists(DiscoveryPaths.join(home, ".yarnrc.yml")) {
                return EnumerationResult(ecosystem: .yarn, status: .unavailable("Yarn 2+ has no global packages"))
            }
            if NodePackageReader.isOnLoginPath("yarn", scan: scan) {
                return scan.result(roots: [], records: [])
            }
            return scan.nothingFound("Yarn classic isn't installed")
        }
        let root = InstallRoot(
            ecosystem: .yarn, path: canonicalGlobal, label: "yarn global", binDirectories: [bin],
            activity: context.activity(ofBinDirectories: [bin])
        )
        let records = NodePackageReader.readGlobalFolder(
            canonicalGlobal, root: root, label: "yarn (\(canonicalGlobal))",
            owner: { .yarnClassic(globalDir: canonicalGlobal, package: $0) },
            commands: { manifest, folder, scan in
                NodePackageReader.commands(manifest, canonicalFolder: folder, binDirectory: bin, scan: scan)
            },
            only: only, scan: &scan
        )
        return scan.result(roots: [root], records: records)
    }
}
