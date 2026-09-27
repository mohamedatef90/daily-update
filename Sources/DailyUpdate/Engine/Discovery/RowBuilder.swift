import Foundation

/// ADR-002 §1's row assembly: `RowBuilder.build` is deterministic — the same input always gives
/// the same output (D18) — and pure: it never touches the filesystem itself beyond the injected
/// `ReadOnlyFileSystem`, used only to resolve a catalog `command` to a `FileID` for the "join by
/// command" step.
enum RowBuilder {
    struct Input: Sendable {
        let results: [EnumerationResult]
        let lookup: CommandPathLookup

        /// A caller that hasn't run `whence` at all (most of this file's own tests) isn't in
        /// RC2's "we asked and it failed" state, so the default here is `.known([])`, not
        /// `CommandPathLookup`'s own `.unknown("Not queried")` default — that default exists for
        /// Phase 1 code paths that report a *lookup* failure, not discovery's login-PATH state.
        init(
            results: [EnumerationResult],
            lookup: CommandPathLookup = CommandPathLookup(candidatesByName: [:], loginPath: .known([]))
        ) {
            self.results = results
            self.lookup = lookup
        }
    }

    private struct PackageKey: Hashable {
        let ecosystem: Ecosystem
        let packageID: String
        var sortKey: String { "\(ecosystem.rawValue)\u{0}\(packageID)" }
    }

    static func build(
        input: Input,
        catalog: [DetectorConfig] = [],
        settings: UserSettings = .defaults,
        fileSystem: ReadOnlyFileSystem = LiveFileSystem()
    ) -> [DetectorConfig] {
        var rows = loginPathErrorRows(input.lookup.loginPath) + issueErrorRows(input.results)

        let customFileIDs = customItemFileIDs(settings.customItems, fileSystem: fileSystem)
        let loginPathKnown: Bool
        if case .known = input.lookup.loginPath { loginPathKnown = true } else { loginPathKnown = false }

        // R3: a record in an inactive root gets no row of its own (D3, D4) — but only once the
        // login PATH is actually known. S4/RC2 item 1: an unknown or empty PATH means no root may
        // ever be demoted (an `.inactive` root is treated as `.unknown` instead), so a record
        // under it still surfaces rather than silently disappearing (the G2 failure).
        let candidates = input.results.flatMap(\.records).filter { record in
            !record.flags.contains(.dependency) &&
                (loginPathKnown ? record.root.activity != .inactive : true) &&
                isSane(record.packageID)
        }

        let winners: [InstalledPackage]
        if loginPathKnown {
            var groups: [PackageKey: [InstalledPackage]] = [:]
            for record in candidates {
                groups[PackageKey(ecosystem: record.ecosystem, packageID: record.packageID), default: []].append(record)
            }
            winners = groups.keys.sorted(by: { $0.sortKey < $1.sortKey }).compactMap { key in
                guard !settings.inventory.hiddenEcosystems.contains(key.ecosystem) else { return nil }
                return rankByPathOrder(groups[key] ?? [], loginPath: input.lookup.loginPath).first
            }
        } else {
            // S4/RC2 items 2-3: with no PATH signal there is no ranking, so there is no winner to
            // collapse a group to — every surviving record gets its own row. R1 still merges exact
            // duplicates: two records naming the same file (device + inode) are the same row.
            var seenFileIDs = Set<FileID>()
            winners = candidates
                .filter { !settings.inventory.hiddenEcosystems.contains($0.ecosystem) }
                .sorted { recordSortKey($0) < recordSortKey($1) }
                .filter { seenFileIDs.insert($0.fileID).inserted }
        }

        var claimedCatalogIDs = Set<String>()
        for winner in winners {
            // D13: a custom item's file always wins; the inventory row is hidden entirely.
            guard !customFileIDs.contains(winner.fileID) else { continue }

            // S4/RC2 item 3: the command join trusts `whence`'s candidate paths, which is exactly
            // what an unknown or empty login PATH means discovery can't trust; skip it, but the
            // package-identifier join below doesn't depend on PATH at all, so it still runs.
            if let joined = joinCatalogEntry(
                for: winner, catalog: catalog, lookup: input.lookup, fileSystem: fileSystem,
                allowCommandJoin: loginPathKnown
            ), claimedCatalogIDs.insert(joined.id).inserted {
                rows.append(makeJoinedRow(catalogEntry: joined, record: winner))
            } else {
                rows.append(makeInventoryRow(record: winner))
            }
        }

        return assignHandles(rows)
    }

    /// A stable ordering for the unknown-PATH mode, where there's no PATH position to rank by.
    private static func recordSortKey(_ record: InstalledPackage) -> String {
        "\(record.ecosystem.rawValue)\u{0}\(record.packageID)\u{0}\(record.root.path)\u{0}" +
            "\(record.fileID.device)\u{0}\(record.fileID.inode)\u{0}\(record.fileID.dispatchName ?? "")"
    }

    // MARK: - Error rows

    /// RC2 item 4: exactly one Check Failed row when the login PATH itself is empty or unknown,
    /// never one per ecosystem.
    private static func loginPathErrorRows(_ loginPath: LoginPath) -> [DetectorConfig] {
        let message: String
        switch loginPath {
        case .known: return []
        case .empty: message = "Your login shell reported an empty PATH"
        case .unknown(let reason): message = "Couldn't read your login PATH: \(reason)"
        }
        let identity = InventoryIdentity.errorMarker(ecosystem: .system, rootPath: "login-path")
        return [DetectorConfig(
            id: "inv-error-login-path", name: "Login PATH", category: .cli, description: message,
            schemaVersion: nil, source: .inventory, command: nil, packages: nil, selfUpdater: nil,
            appcastURL: nil, autoUpdates: nil, inventory: identity, handle: nil, detect: nil,
            versionCommand: nil, versionPattern: nil, checkCommand: nil, installCommand: nil,
            updateCommand: "", workingDirectory: nil, needsReview: nil
        )]
    }

    /// D3, D11: a `partial`/`failed` enumeration result adds one Check Failed row per affected
    /// root; `loginEnvironmentUnknown` issues are covered by the single row above instead.
    private static func issueErrorRows(_ results: [EnumerationResult]) -> [DetectorConfig] {
        var rows: [DetectorConfig] = []
        for result in results {
            let issues: [EnumerationIssue]
            switch result.status {
            case .partial(let list): issues = list
            case .failed(let issue): issues = [issue]
            case .complete, .unavailable: issues = []
            }
            for issue in issues where issue.kind != .loginEnvironmentUnknown && issue.kind != .previousRunStillBlocked {
                rows.append(makeErrorRow(ecosystem: result.ecosystem, issue: issue))
            }
        }
        return rows
    }

    private static func makeErrorRow(ecosystem: Ecosystem, issue: EnumerationIssue) -> DetectorConfig {
        let root = issue.rootPath ?? ecosystem.rawValue
        let id = ItemBuilder.stableID(prefix: "inv-error-\(ecosystem.rawValue)", path: root)
        let identity = InventoryIdentity.errorMarker(ecosystem: ecosystem, rootPath: root)
        return DetectorConfig(
            id: id, name: "\(ecosystem.rawValue) (\(root))", category: .cli,
            description: PackageNameRules.sanitize(issue.message), schemaVersion: nil, source: .inventory,
            command: nil, packages: nil, selfUpdater: nil, appcastURL: nil, autoUpdates: nil,
            inventory: identity, handle: nil, detect: nil, versionCommand: nil, versionPattern: nil,
            checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil, needsReview: nil
        )
    }

    // MARK: - Ranking and joins

    /// R2: the record whose root's `binDirectories` sits earliest on the login PATH is active;
    /// the rest are shadowed and get no row of their own here (their info is rebuilt as
    /// `OwnerResolution.competing` at check time). A record whose root isn't on PATH at all (an
    /// ecosystem with no PATH dependency, or an unknown login PATH) keeps candidate order.
    private static func rankByPathOrder(_ records: [InstalledPackage], loginPath: LoginPath) -> [InstalledPackage] {
        let entries = loginPath.entries
        func rank(_ record: InstalledPackage) -> Int {
            for directory in record.root.binDirectories {
                if let index = entries.firstIndex(of: directory) { return index }
            }
            return Int.max
        }
        return records.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank(lhs.element), rhsRank = rank(rhs.element)
                return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func isSane(_ packageID: String) -> Bool {
        !packageID.isEmpty && !packageID.contains("\0") && !packageID.hasPrefix("-")
    }

    /// §1 D6: by command, then by package. Never by display name. S4: the command join is skipped
    /// when `allowCommandJoin` is false (an unknown or empty login PATH), since it trusts
    /// `whence`'s candidate paths — exactly what discovery can't do without a known PATH.
    private static func joinCatalogEntry(
        for record: InstalledPackage,
        catalog: [DetectorConfig],
        lookup: CommandPathLookup,
        fileSystem: ReadOnlyFileSystem,
        allowCommandJoin: Bool
    ) -> DetectorConfig? {
        if allowCommandJoin {
            for entry in catalog {
                guard let command = entry.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
                      let candidatePath = lookup.candidates(for: command).first,
                      let canonical = fileSystem.realpath(candidatePath),
                      let stat = fileSystem.stat(canonical) else { continue }
                if stat.fileID == record.fileID { return entry }
            }
        }
        for entry in catalog {
            if entry.packages?.identifier(for: record.ecosystem) == record.packageID { return entry }
        }
        return nil
    }

    // MARK: - Row construction

    private static func identity(for record: InstalledPackage) -> InventoryIdentity {
        InventoryIdentity(
            ecosystem: record.ecosystem, packageID: record.packageID, rootPath: record.root.path,
            packageDirectory: record.packageDirectory, toolPath: record.root.toolPath
        )
    }

    private static func makeJoinedRow(catalogEntry: DetectorConfig, record: InstalledPackage) -> DetectorConfig {
        var row = catalogEntry
        row.source = .inventory
        row.inventory = identity(for: record)
        row.handle = "\(record.ecosystem.rawValue):\(record.packageID)"
        return row
    }

    private static func makeInventoryRow(record: InstalledPackage) -> DetectorConfig {
        let recordIdentity = identity(for: record)
        let id = ItemBuilder.stableID(prefix: "inv-\(record.ecosystem.rawValue)", path: "\(record.root.path)\u{0}\(record.packageID)")
        let name = PackageNameRules.sanitize(record.displayName ?? record.packageID)
        return DetectorConfig(
            id: id, name: name, category: .cli, description: nil, schemaVersion: nil, source: .inventory,
            command: nil, packages: nil, selfUpdater: nil, appcastURL: nil, autoUpdates: nil,
            inventory: recordIdentity, handle: "\(record.ecosystem.rawValue):\(record.packageID)",
            detect: nil, versionCommand: nil, versionPattern: nil, checkCommand: nil, installCommand: nil,
            updateCommand: "", workingDirectory: nil, needsReview: nil
        )
    }

    /// §1: "with `@<root label>` appended only when two rows share a handle."
    private static func assignHandles(_ rows: [DetectorConfig]) -> [DetectorConfig] {
        var countByHandle: [String: Int] = [:]
        for row in rows {
            guard let handle = row.handle else { continue }
            countByHandle[handle, default: 0] += 1
        }
        return rows.map { row in
            var row = row
            if let handle = row.handle, (countByHandle[handle] ?? 0) > 1, let root = row.inventory?.rootPath {
                row.handle = "\(handle)@\(root)"
            }
            return row
        }
    }

    private static func customItemFileIDs(_ customItems: [DetectorConfig], fileSystem: ReadOnlyFileSystem) -> Set<FileID> {
        var ids = Set<FileID>()
        for item in customItems {
            guard let path = item.detect?.paths?.first, !path.isEmpty else { continue }
            let expanded = (path as NSString).expandingTildeInPath
            guard let canonical = fileSystem.realpath(expanded), let stat = fileSystem.stat(canonical) else { continue }
            ids.insert(stat.fileID)
        }
        return ids
    }
}
