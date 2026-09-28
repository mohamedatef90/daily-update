import Foundation

/// ADR-002 §1's row assembly: `RowBuilder.build` is deterministic — the same input always gives
/// the same output (D18) — and pure: it touches the filesystem only through the injected
/// `ReadOnlyFileSystem`, to resolve PATH candidates and catalog commands to `FileID`s (R2 and the
/// "join by command" step).
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

    /// R2: a record the login PATH shadows. `path` is this record's own (later) PATH candidate
    /// for `command`.
    struct CompetingInstall: Hashable, Sendable {
        let record: InstalledPackage
        let command: String
        let path: String
    }

    /// R2 where what runs isn't any record: the first PATH candidate for `command` is a file no
    /// enumerator owns (a native installer, a catalog-only tool). P2-5 attaches these to the
    /// catalog row for that command (D5: `claude` native, npm `claude-code` competing).
    struct ShadowedByUnownedFile: Hashable, Sendable {
        let record: InstalledPackage
        let command: String
        let path: String
        let activePath: String
    }

    /// R3: a record in a root that isn't on the login PATH (another nvm/fnm version). `rowID` is
    /// the active version-manager row it's listed under, when there is one (D4: `clawdbot` under
    /// `node`); otherwise it's snapshot-level.
    struct InactiveInstall: Hashable, Sendable {
        let record: InstalledPackage
        let rowID: String?
    }

    struct Output: Sendable {
        let rows: [DetectorConfig]
        /// Row ID → the records it shadows (R2).
        let competing: [String: [CompetingInstall]]
        let shadowedByUnownedFiles: [ShadowedByUnownedFile]
        let inactiveInstalls: [InactiveInstall]
    }

    static func build(
        input: Input,
        catalog: [DetectorConfig] = [],
        settings: UserSettings = .defaults,
        fileSystem: ReadOnlyFileSystem = LiveFileSystem()
    ) -> [DetectorConfig] {
        assemble(input: input, catalog: catalog, settings: settings, fileSystem: fileSystem).rows
    }

    static func assemble(
        input: Input,
        catalog: [DetectorConfig] = [],
        settings: UserSettings = .defaults,
        fileSystem: ReadOnlyFileSystem = LiveFileSystem()
    ) -> Output {
        var rows = loginPathErrorRows(input.lookup.loginPath) + issueErrorRows(input.results)

        let customFileIDs = customItemFileIDs(settings.customItems, fileSystem: fileSystem)
        let loginPathKnown: Bool
        if case .known = input.lookup.loginPath { loginPathKnown = true } else { loginPathKnown = false }

        let candidates = input.results.flatMap(\.records)
            .filter { !$0.flags.contains(.dependency) && isSane($0.packageID) && !settings.inventory.hiddenEcosystems.contains($0.ecosystem) }
            .sorted { recordSortKey($0) < recordSortKey($1) }

        // R3: a record in an inactive root gets no row of its own (D3, D4) — but only once the
        // login PATH is actually known. S4/RC2 item 1: an unknown or empty PATH means no root may
        // ever be demoted (an `.inactive` root is treated as `.unknown` instead), so a record
        // under it still surfaces rather than silently disappearing (the G2 failure).
        let inactive = loginPathKnown ? candidates.filter { $0.root.activity == .inactive } : []
        let pool = loginPathKnown ? candidates.filter { $0.root.activity != .inactive } : candidates

        // R1: records naming the same file (device + inode, plus the dispatcher name) are one row.
        var seenFileIDs = Set<FileID>()
        let merged = pool.filter { seenFileIDs.insert($0.fileID).inserted }

        let winners: [InstalledPackage]
        var competingByWinner: [Int: [CompetingInstall]] = [:]
        var shadowedByUnowned: [ShadowedByUnownedFile] = []
        if loginPathKnown {
            let ranking = rankByLoginPath(merged, loginPath: input.lookup.loginPath, fileSystem: fileSystem)
            winners = ranking.winners.map { merged[$0] }
            for (winnerIndex, installs) in ranking.competing {
                guard let position = ranking.winners.firstIndex(of: winnerIndex) else { continue }
                competingByWinner[position] = installs
            }
            shadowedByUnowned = ranking.shadowedByUnowned
        } else {
            // S4/RC2 items 2-3: with no PATH signal there is no ranking, so there is no winner to
            // collapse a group to — every surviving record gets its own row (R1 still merged
            // exact duplicates above).
            winners = merged
        }

        // CR FU7: each catalog command is resolved to a `FileID` once per build, not once per record.
        // S4/RC2 item 3: the command join trusts `whence`'s candidate paths, which is exactly what
        // an unknown or empty login PATH means discovery can't do; the package join still runs.
        let commandJoins = loginPathKnown ? catalogCommandFileIDs(catalog, lookup: input.lookup, fileSystem: fileSystem) : []

        var claimedCatalogIDs = Set<String>()
        var rowIDByWinner: [Int: String] = [:]
        var labelByRowID: [String: String] = [:]
        for (position, winner) in winners.enumerated() {
            // D13: a custom item's file always wins; the inventory row is hidden entirely.
            guard !customFileIDs.contains(winner.fileID) else { continue }

            // CR#5: with no ranking signal, this row may not be the install the user meant — say
            // so, so an update never silently targets an install nobody chose.
            let unknownPathDescription = loginPathKnown ? nil : "PATH unknown"
            let row: DetectorConfig
            if let joined = joinCatalogEntry(for: winner, catalog: catalog, commandJoins: commandJoins, fileSystem: fileSystem),
               claimedCatalogIDs.insert(joined.id).inserted {
                row = makeJoinedRow(catalogEntry: joined, record: winner, descriptionOverride: unknownPathDescription)
            } else {
                row = makeInventoryRow(record: winner, description: unknownPathDescription)
            }
            rows.append(row)
            rowIDByWinner[position] = row.id
            labelByRowID[row.id] = winner.root.label
        }

        var competing: [String: [CompetingInstall]] = [:]
        for (position, installs) in competingByWinner {
            guard let rowID = rowIDByWinner[position] else { continue }
            competing[rowID] = installs.sorted { ($0.command, $0.path) < ($1.command, $1.path) }
        }

        let inactiveInstalls = inactive.map { record -> InactiveInstall in
            InactiveInstall(record: record, rowID: versionManagerRowID(for: record, winners: winners, rowIDByWinner: rowIDByWinner))
        }

        return Output(
            rows: assignHandles(rows, labelByRowID: labelByRowID),
            competing: competing,
            shadowedByUnownedFiles: shadowedByUnowned,
            inactiveInstalls: inactiveInstalls
        )
    }

    // MARK: - R2: what the login PATH runs

    private struct Ranking {
        /// Indexes into the merged records that get a row, in record order.
        var winners: [Int]
        /// Winner index → the records it shadows.
        var competing: [Int: [CompetingInstall]]
        var shadowedByUnowned: [ShadowedByUnownedFile]
    }

    /// ADR-002 D5/R2, replacing P2-1's `(ecosystem, packageID)` key: for every command a record
    /// provides, `PathSearch` lists the login PATH's candidates (`whence -ap` order) and each is
    /// resolved to its `FileID`. The first candidate is what runs; a record owning it is active for
    /// that command, and a record owning a later candidate is shadowed. So brew `node` behind nvm
    /// `node` is one row with brew competing (QA defect 4), whichever ecosystems they come from.
    ///
    /// A record is a row when it's active for at least one of its commands. It's shadowed — no row,
    /// listed under the winner — when every one of its commands found on the PATH runs another
    /// file. A record none of whose commands are on the PATH at all, or with no commands, is a row
    /// when its root is active (D5: "for a package with no commands, a record in a root whose bin is
    /// on PATH"); command-less packages in two active roots are two rows, never merged by name.
    private static func rankByLoginPath(_ records: [InstalledPackage], loginPath: LoginPath, fileSystem: ReadOnlyFileSystem) -> Ranking {
        var owners: [FileID: [Int]] = [:]
        for (index, record) in records.enumerated() {
            for fileID in executableFileIDs(record, fileSystem: fileSystem) {
                owners[fileID, default: []].append(index)
            }
        }

        var activeFor: [Int: Set<String>] = [:]
        var shadowedHits: [Int: [(command: String, path: String)]] = [:]
        var winnerOf: [String: (records: [Int], path: String)] = [:]
        let commands = Set(records.flatMap(\.commands)).sorted()
        for command in commands {
            var winner: (records: [Int], path: String)?
            for path in PathSearch.candidates(for: command, pathEntries: loginPath.entries, fileSystem: fileSystem) {
                let matched = fileSystem.stat(path).flatMap { owners[$0.fileID] } ?? []
                if let current = winner {
                    for index in matched where !current.records.contains(index) {
                        shadowedHits[index, default: []].append((command, path))
                    }
                } else {
                    winner = (matched, fileSystem.realpath(path) ?? path)
                    for index in matched { activeFor[index, default: []].insert(command) }
                }
            }
            if let winner { winnerOf[command] = winner }
        }

        var ranking = Ranking(winners: [], competing: [:], shadowedByUnowned: [])
        for (index, record) in records.enumerated() {
            if activeFor[index] != nil {
                ranking.winners.append(index)
                continue
            }
            guard let hit = shadowedHits[index]?.sorted(by: { ($0.command, $0.path) < ($1.command, $1.path) }).first,
                  let winner = winnerOf[hit.command] else {
                if record.root.activity != .inactive { ranking.winners.append(index) }
                continue
            }
            if let winnerIndex = winner.records.first {
                ranking.competing[winnerIndex, default: []].append(CompetingInstall(record: record, command: hit.command, path: hit.path))
            } else {
                ranking.shadowedByUnowned.append(ShadowedByUnownedFile(record: record, command: hit.command, path: hit.path, activePath: winner.path))
            }
        }
        return ranking
    }

    private static func executableFileIDs(_ record: InstalledPackage, fileSystem: ReadOnlyFileSystem) -> Set<FileID> {
        var ids: Set<FileID> = [record.fileID]
        for executable in record.executables {
            if let fileID = fileSystem.stat(executable)?.fileID { ids.insert(fileID) }
        }
        return ids
    }

    /// R3: an inactive record under a version manager's folder is listed on that manager's active
    /// `node` row (D4); anything else is snapshot-level.
    private static func versionManagerRowID(
        for record: InstalledPackage,
        winners: [InstalledPackage],
        rowIDByWinner: [Int: String]
    ) -> String? {
        for (position, winner) in winners.enumerated() {
            guard case .versionManager(_, let managerRoot) = winner.owner,
                  pathIsWithin(record.root.path, managerRoot) else { continue }
            return rowIDByWinner[position]
        }
        return nil
    }

    private static func pathIsWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The stable order records are considered in (D18). R1 keeps the first of a same-file group.
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

    private struct ErrorRowKey: Hashable {
        let ecosystem: Ecosystem
        let root: String
    }

    /// D3, D11: a `partial`/`failed` enumeration result adds one Check Failed row per affected
    /// root, never one per issue — `loginEnvironmentUnknown` issues are covered by the single row
    /// above instead. CR#6: two issues naming the same root must still collapse to one row (same
    /// key, same id) with both messages, not two rows with a colliding id (`stableID` only keys on
    /// ecosystem+root, so two rows for one root previously got the identical id). `.previousRunStillBlocked`
    /// stays a row too — filtering it out made a still-blocked ecosystem look like "nothing
    /// installed" on the next run instead of "unknown", which D3 forbids.
    private static func issueErrorRows(_ results: [EnumerationResult]) -> [DetectorConfig] {
        var order: [ErrorRowKey] = []
        var issuesByKey: [ErrorRowKey: [EnumerationIssue]] = [:]
        for result in results {
            let issues: [EnumerationIssue]
            switch result.status {
            case .partial(let list): issues = list
            case .failed(let issue): issues = [issue]
            case .complete, .unavailable: issues = []
            }
            for issue in issues where issue.kind != .loginEnvironmentUnknown {
                let key = ErrorRowKey(ecosystem: result.ecosystem, root: issue.rootPath ?? result.ecosystem.rawValue)
                if issuesByKey[key] == nil { order.append(key) }
                issuesByKey[key, default: []].append(issue)
            }
        }
        return order.map { key in makeErrorRow(ecosystem: key.ecosystem, root: key.root, issues: issuesByKey[key] ?? []) }
    }

    private static func makeErrorRow(ecosystem: Ecosystem, root: String, issues: [EnumerationIssue]) -> DetectorConfig {
        let id = ItemBuilder.stableID(prefix: "inv-error-\(ecosystem.rawValue)", path: root)
        let identity = InventoryIdentity.errorMarker(ecosystem: ecosystem, rootPath: root)
        let message = issues.map(\.message).joined(separator: "; ")
        return DetectorConfig(
            id: id, name: "\(ecosystem.rawValue) (\(root))", category: .cli,
            description: PackageNameRules.sanitize(message), schemaVersion: nil, source: .inventory,
            command: nil, packages: nil, selfUpdater: nil, appcastURL: nil, autoUpdates: nil,
            inventory: identity, handle: nil, detect: nil, versionCommand: nil, versionPattern: nil,
            checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil, needsReview: nil
        )
    }

    // MARK: - Ranking and joins

    private static func isSane(_ packageID: String) -> Bool {
        !packageID.isEmpty && !packageID.contains("\0") && !packageID.hasPrefix("-")
    }

    /// §1 D6 "by command": each catalog `command` → its first `whence` candidate → that file's
    /// `FileID`. Built once per build (CR FU7).
    private static func catalogCommandFileIDs(
        _ catalog: [DetectorConfig],
        lookup: CommandPathLookup,
        fileSystem: ReadOnlyFileSystem
    ) -> [(entry: DetectorConfig, fileID: FileID)] {
        catalog.compactMap { entry in
            guard let command = entry.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
                  let candidatePath = lookup.candidates(for: command).first,
                  let canonical = fileSystem.realpath(candidatePath),
                  let stat = fileSystem.stat(canonical) else { return nil }
            return (entry, stat.fileID)
        }
    }

    /// §1 D6: by command (the catalog command runs one of this record's files), then by package.
    /// Never by display name. `commandJoins` is empty when the login PATH isn't known (S4).
    private static func joinCatalogEntry(
        for record: InstalledPackage,
        catalog: [DetectorConfig],
        commandJoins: [(entry: DetectorConfig, fileID: FileID)],
        fileSystem: ReadOnlyFileSystem
    ) -> DetectorConfig? {
        if !commandJoins.isEmpty {
            let recordFileIDs = executableFileIDs(record, fileSystem: fileSystem)
            if let join = commandJoins.first(where: { recordFileIDs.contains($0.fileID) }) { return join.entry }
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

    /// CR#5: `descriptionOverride` (unknown-PATH mode's "PATH unknown") replaces the catalog
    /// entry's own description. `description` is a `let`, so this rebuilds the value rather than
    /// mutating `row` in place.
    private static func makeJoinedRow(
        catalogEntry: DetectorConfig,
        record: InstalledPackage,
        descriptionOverride: String? = nil
    ) -> DetectorConfig {
        var row = catalogEntry
        row.source = .inventory
        row.inventory = identity(for: record)
        row.handle = "\(record.ecosystem.rawValue):\(record.packageID)"
        guard let descriptionOverride else { return row }
        return DetectorConfig(
            id: row.id, name: row.name, category: row.category, description: descriptionOverride,
            schemaVersion: row.schemaVersion, source: row.source, command: row.command, packages: row.packages,
            selfUpdater: row.selfUpdater, appcastURL: row.appcastURL, autoUpdates: row.autoUpdates,
            inventory: row.inventory, handle: row.handle, detect: row.detect, versionCommand: row.versionCommand,
            versionPattern: row.versionPattern, checkCommand: row.checkCommand, installCommand: row.installCommand,
            updateCommand: row.updateCommand, workingDirectory: row.workingDirectory, needsReview: row.needsReview
        )
    }

    private static func makeInventoryRow(record: InstalledPackage, description: String? = nil) -> DetectorConfig {
        let recordIdentity = identity(for: record)
        let id = ItemBuilder.stableID(prefix: "inv-\(record.ecosystem.rawValue)", path: "\(record.root.path)\u{0}\(record.packageID)")
        let name = PackageNameRules.sanitize(record.displayName ?? record.packageID)
        return DetectorConfig(
            id: id, name: name, category: .cli, description: description, schemaVersion: nil, source: .inventory,
            command: nil, packages: nil, selfUpdater: nil, appcastURL: nil, autoUpdates: nil,
            inventory: recordIdentity, handle: "\(record.ecosystem.rawValue):\(record.packageID)",
            detect: nil, versionCommand: nil, versionPattern: nil, checkCommand: nil, installCommand: nil,
            updateCommand: "", workingDirectory: nil, needsReview: nil
        )
    }

    /// §1: "with `@<root label>` appended only when two rows share a handle." CR FU10: the suffix
    /// is the root's label (`nvm v24.13.0`), not its path.
    private static func assignHandles(_ rows: [DetectorConfig], labelByRowID: [String: String]) -> [DetectorConfig] {
        var countByHandle: [String: Int] = [:]
        for row in rows {
            guard let handle = row.handle else { continue }
            countByHandle[handle, default: 0] += 1
        }
        return rows.map { row in
            var row = row
            if let handle = row.handle, (countByHandle[handle] ?? 0) > 1 {
                if let label = labelByRowID[row.id] ?? row.inventory?.rootPath {
                    row.handle = "\(handle)@\(label)"
                }
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
