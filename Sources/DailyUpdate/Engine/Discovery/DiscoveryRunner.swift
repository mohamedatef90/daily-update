import Foundation

/// Ties the pieces together for a single discovery pass: the login-shell snapshot (RC2/F4),
/// every registered enumerator under the coordinator's ceiling (RC3), and row assembly. `CLIRunner`
/// is the only caller in P2-1 (`--discover`); P2-5 wires the same pieces into the live check flow.
struct DiscoveryRunResult: Sendable {
    let results: [EnumerationResult]
    let lookup: CommandPathLookup
    let assembly: RowBuilder.Output
    let elapsedMs: Int

    var rows: [DetectorConfig] { assembly.rows }

    /// The Homebrew snapshot `StrategyPlanner` reads (§1), when the brew enumerator ran.
    var brewInfo: BrewInfoProvider? { results.lazy.compactMap(\.brewInfo).first }
}

enum DiscoveryRunner {
    static func run(
        enumerators: [Enumerator] = DiscoveryEnumeratorRegistry.all,
        catalog: [DetectorConfig] = [],
        settings: UserSettings = .defaults,
        fileSystem: ReadOnlyFileSystem = LiveFileSystem(),
        layout: EcosystemLayout = .live(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> DiscoveryRunResult {
        let start = Date()
        let commandNames = catalog.compactMap(\.command)
        let lookup = await OwnerResolver.lookup(commandNames: commandNames, layout: layout)
        // F5: the layout `lookup` rebuilt from the login snapshot (`HOMEBREW_PREFIX`, else a trusted
        // brew's prefix) is the one enumerators read; the caller's is only the starting point.
        let context = DiscoveryContext(
            fileSystem: fileSystem,
            environmentSnapshot: lookup.environmentSnapshot,
            loginPath: lookup.loginPath,
            layout: lookup.layout ?? layout,
            processEnvironment: processEnvironment
        )
        let results = await DiscoveryCoordinator.run(enumerators: enumerators, context: context)
        let assembly = RowBuilder.assemble(
            input: RowBuilder.Input(results: results, lookup: lookup),
            catalog: catalog,
            settings: settings,
            fileSystem: fileSystem
        )
        return DiscoveryRunResult(
            results: results, lookup: lookup, assembly: assembly,
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }
}
