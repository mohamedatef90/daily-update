import Foundation

/// ADR-002 §1: re-reads one package (manifest, trust, PATH position) for check-time resolution and
/// L3, by dispatching to the enumerator that owns its ecosystem. Enumerator lookup is injected so
/// this file never needs to know the concrete list of ecosystems P2-2 through P2-4 add.
enum InventoryResolver {
    typealias EnumeratorLookup = (Ecosystem) -> Enumerator?

    static func resolve(
        identity: InventoryIdentity,
        context: DiscoveryContext,
        enumerators: EnumeratorLookup
    ) async -> InstalledPackage? {
        guard let enumerator = enumerators(identity.ecosystem) else { return nil }
        return await enumerator.resolve(identity, context)
    }
}
