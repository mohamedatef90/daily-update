import Foundation

/// Ties the pieces together for a single discovery pass: the login-shell snapshot (RC2/F4),
/// every registered enumerator under the coordinator's ceiling (RC3), and row assembly. `CLIRunner`
/// is the only caller in P2-1 (`--discover`); P2-5 wires the same pieces into the live check flow.
struct DiscoveryRunResult: Sendable {
    let results: [EnumerationResult]
    let lookup: CommandPathLookup
    let rows: [DetectorConfig]
    let elapsedMs: Int
}

enum DiscoveryRunner {
    static func run(
        enumerators: [Enumerator] = DiscoveryEnumeratorRegistry.all,
        catalog: [DetectorConfig] = [],
        settings: UserSettings = .defaults,
        fileSystem: ReadOnlyFileSystem = LiveFileSystem(),
        layout: EcosystemLayout = .live()
    ) async -> DiscoveryRunResult {
        let start = Date()
        let commandNames = catalog.compactMap(\.command)
        let lookup = await OwnerResolver.lookup(commandNames: commandNames, layout: layout)
        let context = DiscoveryContext(
            fileSystem: fileSystem,
            environmentSnapshot: lookup.environmentSnapshot,
            loginPath: lookup.loginPath,
            layout: layout
        )
        let results = await DiscoveryCoordinator.run(enumerators: enumerators, context: context)
        let rows = RowBuilder.build(
            input: RowBuilder.Input(results: results, lookup: lookup),
            catalog: catalog,
            settings: settings,
            fileSystem: fileSystem
        )
        return DiscoveryRunResult(
            results: results, lookup: lookup, rows: rows,
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }
}
