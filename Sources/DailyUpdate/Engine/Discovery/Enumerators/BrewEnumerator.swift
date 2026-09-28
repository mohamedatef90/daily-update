import Foundation

// MARK: - What Homebrew knows, per prefix

/// One installed formula, as `brew info --json=v2 --installed` (or, in the fallback, its Cellar
/// receipts) describes it.
struct BrewFormulaRecord: Hashable, Sendable {
    let name: String
    let fullName: String
    /// `nil` when neither source named one.
    let tap: String?
    /// Oldest → newest.
    let installedVersions: [String]
    let linkedVersion: String?
    /// `versions.stable`, with `_<revision>` appended when the revision isn't 0. `nil` in the
    /// filesystem fallback, which has no latest versions (§2).
    let latestVersion: String?
    let pinned: Bool
    let kegOnly: Bool
    let installedOnRequest: Bool
    let installedAsDependency: Bool

    /// F7: formulae outside `homebrew/core` are upgraded by `full_name`, which must match the
    /// tap-qualified regex. `nil` means no name passed validation, so no command may be built.
    var upgradeToken: String? {
        if tap == nil || tap == "homebrew/core" {
            return PackageNameRules.isValidBrewFormulaName(name) ? name : nil
        }
        return PackageNameRules.isValidTapQualifiedName(fullName) ? fullName : nil
    }

    var currentVersion: String? { linkedVersion ?? installedVersions.last }
}

struct BrewCaskRecord: Hashable, Sendable {
    let token: String
    let fullToken: String
    let tap: String?
    let installedVersion: String?
    /// The cask's `version` without its `,build` suffix; `nil` in the fallback.
    let latestVersion: String?
    let autoUpdates: Bool
    /// `artifacts[].app` targets as absolute paths (`/Applications/X.app` unless a target says
    /// otherwise). P2-6a binds these to canonical app bundles.
    let appTargets: [String]
    /// `artifacts[].binary` command names.
    let binaries: [String]

    /// F7, for casks: outside `homebrew/cask`, the `full_token` is used.
    var upgradeToken: String? {
        if tap == nil || tap == "homebrew/cask" {
            return PackageNameRules.isValidCaskToken(token) ? token : nil
        }
        return PackageNameRules.isValidTapQualifiedName(fullToken) ? fullToken : nil
    }
}

/// §2 "Homebrew cask (P2-2 index, P2-6a rows)": which installed cask owns which app target.
struct InstalledCaskIndex: Hashable, Sendable {
    let casks: [BrewCaskRecord]

    /// The token whose `app` artifact targets exactly this bundle path.
    func token(forAppBundle path: String) -> String? {
        let wanted = DiscoveryPaths.standardized(path)
        return casks.first { $0.appTargets.contains { DiscoveryPaths.standardized($0) == wanted } }?.token
    }
}

struct BrewPrefixInfo: Hashable, Sendable {
    enum Source: String, Hashable, Sendable { case enricher, filesystem }

    let prefix: String
    let source: Source
    let formulae: [String: BrewFormulaRecord]
    let casks: [String: BrewCaskRecord]
}

/// §1: the per-run Homebrew cache that `StrategyPlanner` reads instead of starting a `brew info`
/// per item (P2-2 task 3). Keyed by prefix, because an Intel and an Apple-silicon Homebrew can both
/// have a formula with the same name.
struct BrewInfoProvider: Hashable, Sendable {
    let prefixes: [String: BrewPrefixInfo]
    /// F5 (cache part): `HOMEBREW_CACHE` from the login snapshot, else `~/Library/Caches/Homebrew`.
    /// Never obtained by running brew.
    let cacheDirectory: String
    /// F11: the newest `*.jws.json` mtime under `<cache>/api/` and `<cache>/api/internal/`, which
    /// is when brew's local API data — the source of every latest version here — last refreshed.
    let cacheModifiedAt: Date?
    /// The prefix as the layout wrote it (`/usr/local`) → the canonical key in `prefixes`, so a
    /// caller that derives `<P>/bin/brew` from the layout finds the same entry.
    let prefixAliases: [String: String]

    init(prefixes: [String: BrewPrefixInfo], cacheDirectory: String, cacheModifiedAt: Date?, prefixAliases: [String: String] = [:]) {
        self.prefixes = prefixes
        self.cacheDirectory = cacheDirectory
        self.cacheModifiedAt = cacheModifiedAt
        self.prefixAliases = prefixAliases
    }

    /// F11: how old the latest versions may be. P2-5 shows it on the Homebrew row, with a
    /// warning past 7 days.
    func cacheAge(now: Date = Date()) -> TimeInterval? {
        cacheModifiedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    static let staleCacheAge: TimeInterval = 7 * 24 * 60 * 60

    /// `<P>/bin/brew` → `P`.
    static func prefix(forBrewExecutable brew: String) -> String {
        DiscoveryPaths.parent(DiscoveryPaths.parent(DiscoveryPaths.standardized(brew)))
    }

    func info(forBrewExecutable brew: String) -> BrewPrefixInfo? {
        let prefix = Self.prefix(forBrewExecutable: brew)
        return prefixes[prefixAliases[prefix] ?? prefix]
    }

    func formula(_ name: String, brewExecutable: String) -> BrewFormulaRecord? {
        info(forBrewExecutable: brewExecutable)?.formulae[name]
    }

    func cask(_ token: String, brewExecutable: String) -> BrewCaskRecord? {
        info(forBrewExecutable: brewExecutable)?.casks[token]
    }

    /// Every prefix's installed casks, sorted by prefix then token.
    var caskIndex: InstalledCaskIndex {
        InstalledCaskIndex(casks: prefixes.keys.sorted().flatMap { prefix in
            (prefixes[prefix]?.casks.values.sorted { $0.token < $1.token }) ?? []
        })
    }
}

// MARK: - Parsing

enum BrewInstalledJSON {
    /// Parses `brew info --json=v2 --installed`. Entries whose names fail §7.4 are dropped and
    /// named in `rejected`; they never become records or reach argv.
    static func parse(_ data: Data, prefix: String) -> (info: BrewPrefixInfo, rejected: [String])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = root["formulae"] as? [[String: Any]] else { return nil }
        var rejected: [String] = []
        var formulaRecords: [String: BrewFormulaRecord] = [:]
        for formula in formulae {
            guard let record = formulaRecord(formula) else {
                rejected.append(PackageNameRules.sanitize((formula["name"] as? String) ?? "?", maxLength: 80))
                continue
            }
            formulaRecords[record.name] = record
        }
        var caskRecords: [String: BrewCaskRecord] = [:]
        for cask in (root["casks"] as? [[String: Any]]) ?? [] {
            guard let record = caskRecord(cask) else {
                rejected.append(PackageNameRules.sanitize((cask["token"] as? String) ?? "?", maxLength: 80))
                continue
            }
            caskRecords[record.token] = record
        }
        return (BrewPrefixInfo(prefix: prefix, source: .enricher, formulae: formulaRecords, casks: caskRecords), rejected)
    }

    private static func formulaRecord(_ formula: [String: Any]) -> BrewFormulaRecord? {
        guard let name = formula["name"] as? String, PackageNameRules.isValidBrewFormulaName(name) else { return nil }
        let fullName = (formula["full_name"] as? String) ?? name
        let tap = (formula["tap"] as? String)?.nilIfBlank
        if tap != nil, tap != "homebrew/core", !PackageNameRules.isValidTapQualifiedName(fullName) { return nil }
        let installed = (formula["installed"] as? [[String: Any]]) ?? []
        let versions = installed.compactMap { ($0["version"] as? String)?.nilIfBlank }.filter(isPlainVersionFolder)
        let latest: String?
        if let stable = ((formula["versions"] as? [String: Any])?["stable"] as? String)?.nilIfBlank {
            let revision = (formula["revision"] as? Int) ?? 0
            latest = revision > 0 ? "\(stable)_\(revision)" : stable
        } else {
            latest = nil
        }
        let linked = (formula["linked_keg"] as? String)?.nilIfBlank
        return BrewFormulaRecord(
            name: name, fullName: fullName, tap: tap,
            installedVersions: DiscoveryPaths.numericallySorted(versions),
            linkedVersion: linked.flatMap { isPlainVersionFolder($0) ? $0 : nil },
            latestVersion: latest,
            pinned: (formula["pinned"] as? Bool) ?? false,
            kegOnly: (formula["keg_only"] as? Bool) ?? false,
            installedOnRequest: installed.contains { ($0["installed_on_request"] as? Bool) == true },
            installedAsDependency: installed.contains { ($0["installed_as_dependency"] as? Bool) == true }
        )
    }

    private static func caskRecord(_ cask: [String: Any]) -> BrewCaskRecord? {
        guard let token = cask["token"] as? String, PackageNameRules.isValidCaskToken(token) else { return nil }
        let fullToken = (cask["full_token"] as? String) ?? token
        let tap = (cask["tap"] as? String)?.nilIfBlank
        if tap != nil, tap != "homebrew/cask", !PackageNameRules.isValidTapQualifiedName(fullToken) { return nil }
        var appTargets: [String] = []
        var binaries: [String] = []
        for artifact in (cask["artifacts"] as? [[String: Any]]) ?? [] {
            if let apps = artifact["app"] as? [Any] {
                appTargets += appTargetPaths(apps)
            }
            if let binary = artifact["binary"] as? [Any], let name = binaryName(binary) {
                binaries.append(name)
            }
        }
        let latest = (cask["version"] as? String)?.components(separatedBy: ",").first?.nilIfBlank
        return BrewCaskRecord(
            token: token, fullToken: fullToken, tap: tap,
            installedVersion: (cask["installed"] as? String)?.nilIfBlank,
            latestVersion: latest,
            autoUpdates: (cask["auto_updates"] as? Bool) ?? false,
            appTargets: appTargets, binaries: binaries
        )
    }

    /// `["X.app"]` or `["X.app", {"target": "Y.app"}]`. A relative target lands in `/Applications`.
    private static func appTargetPaths(_ values: [Any]) -> [String] {
        guard let source = values.first as? String else { return [] }
        let target = values.dropFirst().compactMap { ($0 as? [String: Any])?["target"] as? String }.first
        let name = target ?? DiscoveryPaths.lastComponent(source)
        guard !name.isEmpty, !name.contains("\0") else { return [] }
        return [name.hasPrefix("/") ? DiscoveryPaths.standardized(name) : DiscoveryPaths.join("/Applications", name)]
    }

    /// `["{{appdir}}/X.app/Contents/bin/x"]` or `[source, {"target": "x"}]` → the command name.
    private static func binaryName(_ values: [Any]) -> String? {
        let target = values.dropFirst().compactMap { ($0 as? [String: Any])?["target"] as? String }.first
        let name = DiscoveryPaths.lastComponent(target ?? (values.first as? String) ?? "")
        return BrewEnumerator.isValidCommandName(name) ? name : nil
    }

    /// A Cellar version folder name: no separators, no leading dot or dash.
    static func isPlainVersionFolder(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix(".") && !value.hasPrefix("-") && !value.contains("/") && !value.contains("\0")
    }
}

// MARK: - The enumerator

/// ADR-002 §2, P2-2: Homebrew formulae. The enricher is `brew info --json=v2 --installed` under
/// the sandbox (RC1, F1). When it can't run — the sandbox is missing or refuses the profile, brew
/// isn't a trusted executable, or brew itself fails — the Cellar and Caskroom are read instead,
/// and the result is `partial` ("latest versions unavailable"). Brew never runs unsandboxed, and
/// discovery never runs `brew --prefix` or `brew --cache` (F5).
struct BrewEnumerator: Enumerator {
    typealias Enricher = @Sendable (_ brew: String) async -> ReadOnlyQueries.EnricherOutcome

    let ecosystem: Ecosystem = .brew
    let enricher: Enricher

    /// Tests inject a stub enricher; the live one is the single `ReadOnlyQueries` entry point.
    init(enricher: @escaping Enricher = { brew in await ReadOnlyQueries.brewInfoInstalled(brew: brew) }) {
        self.enricher = enricher
    }

    static func isValidCommandName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix(".") &&
            name.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil
    }

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        var scan = EnumerationScan(ecosystem: .brew, context: context)
        let prefixes = candidatePrefixes(context, scan: scan)
        guard !prefixes.isEmpty else { return scan.nothingFound("No Homebrew Cellar found") }

        var roots: [InstallRoot] = []
        var records: [InstalledPackage] = []
        var infos: [String: BrewPrefixInfo] = [:]
        var aliases: [String: String] = [:]
        for (written, prefix) in prefixes {
            if written != prefix { aliases[DiscoveryPaths.standardized(written)] = prefix }
            guard !scan.deadlinePassed() else { break }
            let rootTrusted = PathTrust.isTrustedDirectory(prefix)
            let brew = DiscoveryPaths.join(prefix, "bin", "brew")
            let brewTrusted = scan.exists(brew) && PathTrust.isTrustedExecutable(brew)
            let root = InstallRoot(
                ecosystem: .brew, path: prefix, label: Self.label(for: prefix),
                binDirectories: [DiscoveryPaths.join(prefix, "bin"), DiscoveryPaths.join(prefix, "sbin")],
                activity: context.activity(ofBinDirectories: [DiscoveryPaths.join(prefix, "bin"), DiscoveryPaths.join(prefix, "sbin")]),
                toolPath: brewTrusted ? brew : nil
            )
            roots.append(root)

            let info: BrewPrefixInfo
            if !rootTrusted {
                scan.report(.untrustedRoot, root: prefix, message: "Homebrew (\(prefix)): the folder or one of its parents can be written by other users")
                info = Self.readFilesystem(prefix: prefix, scan: &scan)
            } else if !brewTrusted {
                scan.report(.untrustedRoot, root: prefix,
                    message: "Homebrew (\(prefix)): latest versions unavailable: \(brew) is missing or not a trusted executable")
                info = Self.readFilesystem(prefix: prefix, scan: &scan)
            } else {
                info = await enrich(prefix: prefix, brew: brew, scan: &scan)
            }
            infos[prefix] = info
            records += Self.records(from: info, root: root, rootTrusted: rootTrusted, scan: &scan)
        }

        let provider = BrewInfoProvider(
            prefixes: infos,
            cacheDirectory: Self.cacheDirectory(context),
            cacheModifiedAt: Self.newestAPICacheFile(in: Self.cacheDirectory(context), scan: &scan),
            prefixAliases: aliases
        )
        return scan.result(roots: roots, records: records, brewInfo: provider)
    }

    /// Re-reads one formula from the Cellar, without starting brew (check time and L3).
    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .brew else { return nil }
        var scan = EnumerationScan(ecosystem: .brew, context: context)
        let prefix = identity.rootPath
        guard scan.isDirectory(DiscoveryPaths.join(prefix, "Cellar")) else { return nil }
        let brew = DiscoveryPaths.join(prefix, "bin", "brew")
        let root = InstallRoot(
            ecosystem: .brew, path: prefix, label: Self.label(for: prefix),
            binDirectories: [DiscoveryPaths.join(prefix, "bin"), DiscoveryPaths.join(prefix, "sbin")],
            activity: context.activity(ofBinDirectories: [DiscoveryPaths.join(prefix, "bin"), DiscoveryPaths.join(prefix, "sbin")]),
            toolPath: scan.exists(brew) && PathTrust.isTrustedExecutable(brew) ? brew : nil
        )
        let info = Self.readFilesystem(prefix: prefix, only: identity.packageID, scan: &scan)
        return Self.records(from: info, root: root, rootTrusted: PathTrust.isTrustedDirectory(prefix), scan: &scan)
            .first { $0.packageID == identity.packageID }
    }

    // MARK: Roots

    /// `HOMEBREW_PREFIX` (via the layout the login snapshot built, F5), then the defaults. A
    /// prefix counts only when its `Cellar` exists. Returns (as written, canonical), de-duplicated
    /// by the canonical path.
    private func candidatePrefixes(_ context: DiscoveryContext, scan: EnumerationScan) -> [(String, String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for prefix in context.layout.brewPrefixes {
            guard scan.isDirectory(DiscoveryPaths.join(prefix, "Cellar")),
                  let canonical = scan.canonical(prefix),
                  seen.insert(canonical).inserted else { continue }
            result.append((prefix, canonical))
        }
        return result
    }

    static func label(for prefix: String) -> String {
        "Homebrew (\(prefix))"
    }

    static func cacheDirectory(_ context: DiscoveryContext) -> String {
        context.overridePath("HOMEBREW_CACHE") ?? DiscoveryPaths.join(context.homeDirectory, "Library", "Caches", "Homebrew")
    }

    /// F11: a missing cache folder is no error; it just means there's no age to show.
    static func newestAPICacheFile(in cache: String, scan: inout EnumerationScan) -> Date? {
        var newest: Date?
        for directory in [DiscoveryPaths.join(cache, "api"), DiscoveryPaths.join(cache, "api", "internal")] {
            for entry in scan.list(directory) ?? [] where entry.hasSuffix(".jws.json") {
                guard let info = scan.fileSystem.stat(DiscoveryPaths.join(directory, entry)), info.isRegularFile else { continue }
                if newest.map({ info.modificationDate > $0 }) ?? true { newest = info.modificationDate }
            }
        }
        return newest
    }

    // MARK: Enricher

    private func enrich(prefix: String, brew: String, scan: inout EnumerationScan) async -> BrewPrefixInfo {
        let reason: String
        let kind: IssueKind
        var evidence: ProcessEvidence?
        switch await enricher(brew) {
        case .ran(let outcome):
            if case .exited(0) = outcome.evidence.termination,
               let parsed = BrewInstalledJSON.parse(outcome.stdout, prefix: prefix) {
                for name in parsed.rejected {
                    scan.report(.malformed, root: prefix, message: "Homebrew (\(prefix)): skipped \(name): the name isn't a valid Homebrew name")
                }
                return parsed.info
            }
            evidence = outcome.evidence
            kind = .enricherFailed
            reason = Self.describe(outcome.evidence.termination)
        case .untrustedExecutable(let path):
            kind = .untrustedRoot
            reason = "\(path) isn't a trusted executable"
        case .sandboxUnavailable:
            kind = .sandboxUnavailable
            reason = "sandbox-exec isn't available, so brew wasn't run"
        case .sandboxRefused(let preflight):
            kind = .sandboxRefused
            evidence = preflight
            reason = "sandbox-exec refused the profile, so brew wasn't run"
        }
        scan.report(kind, root: prefix, message: "Homebrew (\(prefix)): latest versions unavailable: \(reason)", process: evidence)
        return Self.readFilesystem(prefix: prefix, scan: &scan)
    }

    private static func describe(_ termination: Termination) -> String {
        switch termination {
        case .exited(0): return "brew info returned JSON that couldn't be read"
        case .exited(let code): return "brew info exited \(code)"
        case .signaled(let signal): return "brew info was killed by signal \(signal)"
        case .timedOut(let ms): return "brew info timed out after \(ms) ms"
        case .outputCapExceeded: return "brew info printed more than the output cap"
        case .launchFailed(let why): return "brew info couldn't start: \(why)"
        }
    }

    // MARK: Filesystem fallback

    /// §2's fallback: `Cellar/<f>/<v>/INSTALL_RECEIPT.json` for on-request/dependency and the tap,
    /// `var/homebrew/linked/<f>` for the linked keg (`opt/<f>` exists for unlinked kegs too, so it
    /// can't say which keg is linked), `var/homebrew/pinned/<f>` for
    /// pins, and the Caskroom for casks. It has no latest versions.
    static func readFilesystem(prefix: String, only: String? = nil, scan: inout EnumerationScan) -> BrewPrefixInfo {
        let cellar = DiscoveryPaths.join(prefix, "Cellar")
        var formulae: [String: BrewFormulaRecord] = [:]
        for name in scan.list(cellar, root: prefix) ?? [] {
            guard !scan.deadlinePassed() else { break }
            if let only, name != only { continue }
            guard !name.hasPrefix(".") else { continue }
            guard PackageNameRules.isValidBrewFormulaName(name) else {
                scan.report(.malformed, root: prefix, message: "Homebrew (\(prefix)): skipped a Cellar folder whose name isn't a valid formula name")
                continue
            }
            let formulaDirectory = DiscoveryPaths.join(cellar, name)
            let versions = DiscoveryPaths.numericallySorted((scan.list(formulaDirectory, root: prefix) ?? [])
                .filter { BrewInstalledJSON.isPlainVersionFolder($0) && scan.isDirectory(DiscoveryPaths.join(formulaDirectory, $0)) })
            guard !versions.isEmpty else { continue }
            let linked = linkedVersion(prefix: prefix, name: name, scan: scan).flatMap { versions.contains($0) ? $0 : nil }
            let receiptVersion = linked ?? versions.last!
            let receipt = scan.readJSONObject(
                DiscoveryPaths.join(formulaDirectory, receiptVersion, "INSTALL_RECEIPT.json"),
                maxBytes: EnumerationScan.metadataByteCap, root: prefix
            )
            let tap = ((receipt?["source"] as? [String: Any])?["tap"] as? String)?.nilIfBlank
            let fullName = tap.map { $0 == "homebrew/core" ? name : "\($0)/\(name)" } ?? name
            if let tap, tap != "homebrew/core", !PackageNameRules.isValidTapQualifiedName(fullName) {
                scan.report(.malformed, root: prefix, message: "Homebrew (\(prefix)): skipped \(name): its tap name isn't valid")
                continue
            }
            formulae[name] = BrewFormulaRecord(
                name: name, fullName: fullName, tap: tap, installedVersions: versions, linkedVersion: linked,
                latestVersion: nil,
                pinned: scan.exists(DiscoveryPaths.join(prefix, "var", "homebrew", "pinned", name)),
                kegOnly: false,
                // A receipt that can't be read proves nothing either way, so the formula stays
                // visible (and the issue is on the Homebrew error row) rather than vanishing as a
                // dependency.
                installedOnRequest: receipt.map { ($0["installed_on_request"] as? Bool) == true } ?? true,
                installedAsDependency: (receipt?["installed_as_dependency"] as? Bool) == true
            )
        }
        return BrewPrefixInfo(prefix: prefix, source: .filesystem, formulae: formulae,
            casks: only == nil ? readCaskroom(prefix: prefix, scan: &scan) : [:])
    }

    private static func linkedVersion(prefix: String, name: String, scan: EnumerationScan) -> String? {
        let link = DiscoveryPaths.join(prefix, "var", "homebrew", "linked", name)
        guard scan.fileSystem.lstat(link)?.isSymbolicLink == true, let target = scan.canonical(link) else { return nil }
        return DiscoveryPaths.lastComponent(target)
    }

    private static func readCaskroom(prefix: String, scan: inout EnumerationScan) -> [String: BrewCaskRecord] {
        let caskroom = DiscoveryPaths.join(prefix, "Caskroom")
        var casks: [String: BrewCaskRecord] = [:]
        for token in scan.list(caskroom, root: prefix) ?? [] {
            guard !scan.deadlinePassed() else { break }
            guard !token.hasPrefix("."), PackageNameRules.isValidCaskToken(token) else { continue }
            let tokenDirectory = DiscoveryPaths.join(caskroom, token)
            let versions = DiscoveryPaths.numericallySorted((scan.list(tokenDirectory, root: prefix) ?? [])
                .filter { BrewInstalledJSON.isPlainVersionFolder($0) && scan.isDirectory(DiscoveryPaths.join(tokenDirectory, $0)) })
            guard let version = versions.last else { continue }
            let versionDirectory = DiscoveryPaths.join(tokenDirectory, version)
            let appTargets = (scan.list(versionDirectory, root: prefix) ?? []).compactMap { entry -> String? in
                let path = DiscoveryPaths.join(versionDirectory, entry)
                guard entry.hasSuffix(".app"), scan.fileSystem.lstat(path)?.isSymbolicLink == true,
                      let destination = scan.fileSystem.destinationOfSymlink(path), destination.hasPrefix("/") else { return nil }
                return DiscoveryPaths.standardized(destination)
            }
            casks[token] = BrewCaskRecord(
                token: token, fullToken: token, tap: nil, installedVersion: version, latestVersion: nil,
                autoUpdates: false, appTargets: appTargets, binaries: []
            )
        }
        return casks
    }

    // MARK: Records

    /// One record per installed formula. Dependencies are records too, flagged `.dependency`, so
    /// the Homebrew row can count them (D7); `RowBuilder` gives them no row of their own. Commands
    /// come from the linked keg's `bin`, and only when `<P>/bin/<cmd>` resolves to the same file
    /// (§7.2: a command is attributed only when the link proves it). A formula without linked
    /// commands is keyed by its keg folder (D8).
    static func records(from info: BrewPrefixInfo, root: InstallRoot, rootTrusted: Bool, scan: inout EnumerationScan) -> [InstalledPackage] {
        var records: [InstalledPackage] = []
        for name in info.formulae.keys.sorted() {
            guard !scan.deadlinePassed() else { break }
            guard let formula = info.formulae[name], let version = formula.currentVersion else { continue }
            let keg = DiscoveryPaths.join(info.prefix, "Cellar", name, version)
            guard let canonicalKeg = scan.canonical(keg), let kegID = scan.fileID(of: canonicalKeg) else {
                scan.report(.unreadable, root: info.prefix, message: "Homebrew (\(info.prefix)): \(name) \(version) is listed but its keg is missing")
                continue
            }

            var commands: [String] = []
            var executables: [String] = []
            if formula.linkedVersion != nil {
                for binFolder in ["bin", "sbin"] {
                    for command in scan.list(DiscoveryPaths.join(canonicalKeg, binFolder), root: info.prefix) ?? [] {
                        guard isValidCommandName(command),
                              let target = scan.canonical(DiscoveryPaths.join(canonicalKeg, binFolder, command)),
                              DiscoveryPaths.isPath(target, within: canonicalKeg),
                              scan.fileSystem.stat(target)?.isRegularFile == true,
                              scan.canonical(DiscoveryPaths.join(info.prefix, binFolder, command)) == target else { continue }
                        commands.append(command)
                        executables.append(target)
                    }
                }
            }

            var flags: Set<PackageFlag> = []
            // D8: "formulae not installed on request" get no row. Homebrew often leaves
            // `installed_as_dependency` unset (null) on receipts, so only `installed_on_request`
            // decides.
            if formula.installedOnRequest { flags.insert(.onRequest) } else { flags.insert(.dependency) }
            if formula.pinned { flags.insert(.pinned) }
            if formula.kegOnly { flags.insert(.kegOnly) }
            if !rootTrusted { flags.insert(.untrustedRoot) }

            records.append(InstalledPackage(
                ecosystem: .brew,
                packageID: name,
                displayName: formula.tap.flatMap { $0 == "homebrew/core" ? nil : formula.fullName },
                versionRaw: version,
                root: root,
                packageDirectory: canonicalKeg,
                executables: executables,
                commands: commands,
                owner: .brewFormula(name),
                flags: flags,
                evidence: [Evidence(kind: info.source == .enricher ? "brew-info" : "INSTALL_RECEIPT.json", path: canonicalKeg)],
                confidence: info.source == .enricher ? .proven : .strong,
                fileID: executables.first.flatMap { scan.fileID(of: $0) } ?? kegID
            ))
        }
        return records
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
