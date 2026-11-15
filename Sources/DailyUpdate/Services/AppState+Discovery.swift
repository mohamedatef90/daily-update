import Foundation

/// M2 (P2-5): the discovery rows in the live item list.
///
/// Discovery is read-only and runs after the first paint. Its rows are merged with the catalog using the
/// join and dedupe `RowBuilder` already did (a catalog entry that discovery joined is REPLACED by the
/// joined row, never listed twice). A failure or a timeout never blocks the legacy list: the catalog
/// items stay, and a non-blocking banner says discovery did not finish. Rows act only through the
/// existing planner → classifier → dry-run → executor → verify path; this file never runs a command.
extension AppState {
    /// Mutable only so a test can shorten it.
    static var discoveryTimeout: TimeInterval = 20
    /// A check reuses a discovery run younger than this.
    static let discoveryFreshness: TimeInterval = 60

    var discoveryEnabled: Bool {
        get { settingsStore.settings.discoverInstalledTools }
        set {
            settingsStore.settings.discoverInstalledTools = newValue
            settingsStore.save()
            if newValue { startDiscovery() } else { reloadConfigs() }
        }
    }

    /// Ecosystems with at least one listed row, in the sidebar order, with counts.
    var ecosystemGroups: [EcosystemGroup] {
        let counts = Dictionary(grouping: activeItems.compactMap { $0.inventory?.ecosystem }, by: { $0 }).mapValues(\.count)
        return EcosystemPresentation.sidebarOrder.compactMap { ecosystem in
            counts[ecosystem].map { EcosystemGroup(ecosystem: ecosystem, count: $0) }
        }
    }

    func ownerBadge(for item: UpdateItem) -> String? {
        discoveryDetails[item.id]?.ownerBadge
    }

    /// A single-item `--update` or `--install` checks only that item (after discovery, so a discovered row exists).
    func checkItems(ids: [String]) async {
        await ensureFreshDiscovery()
        await recheckItems(ids: ids, useDiscoverySnapshot: true)
    }

    /// The Homebrew data of the last discovery pass, only while that pass is recent. Nil means "ask brew".
    func freshBrewSnapshot() -> BrewInfoProvider? {
        guard settingsStore.settings.discoverInstalledTools, let date = lastDiscoveryDate,
              Date().timeIntervalSince(date) < Self.discoveryFreshness else { return nil }
        return lastDiscovery?.brewInfo
    }

    /// Called after an update ran: what discovery saw is no longer true.
    func invalidateDiscoverySnapshot() {
        lastDiscoveryDate = nil
    }

    // MARK: - Running

    /// Starts (or restarts) a discovery pass in the background. Never blocks the caller.
    func startDiscovery() {
        guard settingsStore.settings.discoverInstalledTools else {
            discoveryStatus = .off
            return
        }
        discoveryTask?.cancel()
        // Set before the task starts, so a check that begins right away waits for this pass.
        discoveryStatus = .running
        discoveryTask = Task { [weak self] in
            await self?.runDiscovery()
        }
    }

    /// "Rescan": a new pass, awaited by callers that want its result.
    func rescan() async {
        guard settingsStore.settings.discoverInstalledTools else { return }
        discoveryTask?.cancel()
        await runDiscovery()
    }

    /// A check uses the discovered rows: it waits for a pass in flight, or runs one when the last is old.
    func ensureFreshDiscovery() async {
        guard settingsStore.settings.discoverInstalledTools else { return }
        // `discoversOnLaunch` is false only where the app must not scan the machine by itself (tests).
        guard discoversOnLaunch else { return }
        if let discoveryTask, discoveryStatus.isRunning {
            await discoveryTask.value
            return
        }
        if let lastDiscoveryDate, Date().timeIntervalSince(lastDiscoveryDate) < Self.discoveryFreshness { return }
        await runDiscovery()
    }

    func runDiscovery() async {
        let settings = settingsStore.settings
        guard settings.discoverInstalledTools else {
            discoveryStatus = .off
            return
        }
        discoveryStatus = .running
        let catalog = catalogConfigs
        let discoverer = self.discoverer
        do {
            let result = try await Self.withTimeout(Self.discoveryTimeout) { try await discoverer(catalog, settings) }
            guard !Task.isCancelled else { return }
            applyDiscovery(result)
        } catch {
            // Fail open: keep whatever list there is, say so, and move on.
            guard !Task.isCancelled else { return }
            discoveryStatus = .failed(Self.discoveryFailureMessage(error))
            appendLog("Discovery did not finish: \(Self.discoveryFailureMessage(error))")
        }
    }

    private struct DiscoveryTimedOut: Error {}

    static func discoveryFailureMessage(_ error: Error) -> String {
        error is DiscoveryTimedOut ? "it took longer than \(Int(discoveryTimeout)) seconds" : PackageNameRules.sanitize("\(error)", maxLength: 200)
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DiscoveryTimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DiscoveryTimedOut() }
            return first
        }
    }

    // MARK: - Merging

    /// The catalog with discovery's rows. A row whose id is a catalog id is the catalog entry joined to its
    /// install, so it takes that entry's place. Every other row is appended. No row is ever listed twice.
    static func mergeDiscovery(catalog: [DetectorConfig], rows: [DetectorConfig]) -> [DetectorConfig] {
        var rowsByID: [String: DetectorConfig] = [:]
        for row in rows where rowsByID[row.id] == nil { rowsByID[row.id] = row }
        let catalogIDs = Set(catalog.map(\.id))
        var seen = Set<String>()
        var merged: [DetectorConfig] = []
        for entry in catalog where seen.insert(entry.id).inserted {
            merged.append(rowsByID[entry.id] ?? entry)
        }
        for row in rows where !catalogIDs.contains(row.id) && seen.insert(row.id).inserted {
            merged.append(row)
        }
        return merged
    }

    /// Applies a result that waited for a check or an update to finish.
    func applyPendingDiscovery() {
        guard let result = pendingDiscovery, !isUpdating else { return }
        pendingDiscovery = nil
        applyDiscovery(result, deferIfBusy: false)
    }

    func applyDiscovery(_ result: DiscoveryRunResult, deferIfBusy: Bool = true) {
        // `checkAll`, `recheckItems` and `updateSelected` walk `items` and `configs` by position. Replacing both
        // under them misaligns the two lists, so a result that arrives mid-run waits until the run ends.
        if deferIfBusy, isChecking || isUpdating {
            pendingDiscovery = result
            discoveryStatus = .running
            return
        }
        lastDiscovery = result
        lastDiscoveryDate = Date()
        let merged = Self.mergeDiscovery(catalog: catalogConfigs, rows: result.rows)
        let existing = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        configs = merged
        // Keep the state of rows already listed (status, selection); add the new ones; drop the gone ones.
        items = merged.map { config in
            guard var kept = existing[config.id] else { return applyPreferences(to: config.toUpdateItem()) }
            kept.inventory = config.inventory
            kept.source = config.source
            return kept
        }
        discoveryDetails = Self.details(from: result)
        discoveryUnlistedInactive = result.assembly.inactiveInstalls.filter { $0.rowID == nil }.map { Self.install($0.record) }
        let issues = result.results.filter { if case .complete = $0.status { return false }; if case .unavailable = $0.status { return false }; return true }.count
        discoveryStatus = .ready(rows: result.rows.count, issues: issues, elapsedMs: result.elapsedMs)
        refreshDuplicates()
        appendLog("Discovery listed \(result.rows.count) row(s) in \(result.elapsedMs) ms (\(issues) ecosystem issue(s))")
    }

    // MARK: - Display data

    static func install(_ record: InstalledPackage) -> DiscoveredInstall {
        DiscoveredInstall(
            path: record.executables.first ?? record.packageDirectory,
            version: record.versionRaw,
            ecosystem: EcosystemPresentation.title(record.ecosystem),
            owner: EcosystemPresentation.ownerBadge(owner: record.owner, rootLabel: record.root.label))
    }

    /// The first command the install provides, if it is a plain command name (never a path or odd characters).
    static func primaryCommand(of record: InstalledPackage) -> String? {
        let name = record.commands.first ?? record.executables.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard let name, EvidenceCollector.isValidCommandName(name) else { return nil }
        return name
    }

    static func details(from result: DiscoveryRunResult) -> [String: ItemDiscoveryDetails] {
        var details: [String: ItemDiscoveryDetails] = [:]
        for row in result.rows {
            guard let identity = row.inventory, !identity.isErrorMarker else { continue }
            let record = result.results.lazy.flatMap(\.records).first {
                $0.ecosystem == identity.ecosystem && $0.packageID == identity.packageID && $0.root.path == identity.rootPath
            }
            var entry = ItemDiscoveryDetails(
                // The file that runs. (`identity.toolPath` is the package manager's own tool, not this package.)
                activePath: record?.executables.first ?? identity.packageDirectory,
                primaryCommand: record.flatMap { Self.primaryCommand(of: $0) },
                ownerBadge: record.map { EcosystemPresentation.ownerBadge(owner: $0.owner, rootLabel: $0.root.label) }
                    ?? EcosystemPresentation.title(identity.ecosystem))
            entry.competing = (result.assembly.competing[row.id] ?? []).map { Self.install($0.record) }
            entry.inactive = result.assembly.inactiveInstalls.filter { $0.rowID == row.id }.map { Self.install($0.record) }
            entry.shadowedByUnownedFiles = result.assembly.shadowedByUnownedFiles
                .filter { shadowed in row.command == shadowed.command || identity.packageID == shadowed.record.packageID }
                .map { Self.install($0.record) }
            details[row.id] = entry
        }
        return details
    }
}

/// Check results that arrived but are not applied to the visible list yet. A check finishes one item at a time;
/// applying each one separately publishes `items` 100+ times in a few seconds, and each publish makes SwiftUI
/// lay out the whole Table again. The buffer lets the UI refresh a few times a second instead, while the check
/// itself runs at full speed.
struct CheckResultBuffer {
    /// The shortest time between two applications to the visible list.
    static let interval: TimeInterval = 0.4

    private var pending: [(Int, UpdateItem)] = []
    private(set) var takenCount = 0
    private var lastFlush: Date
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        self.lastFlush = now()
    }

    var isEmpty: Bool { pending.isEmpty }

    mutating func add(index: Int, item: UpdateItem) {
        pending.append((index, item))
    }

    func shouldFlush() -> Bool {
        !pending.isEmpty && now().timeIntervalSince(lastFlush) >= Self.interval
    }

    mutating func take() -> [(Int, UpdateItem)] {
        let result = pending
        takenCount = result.count
        pending = []
        lastFlush = now()
        return result
    }
}
