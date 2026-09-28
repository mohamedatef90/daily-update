import Foundation

/// The enumerators `--discover` and (from P2-5) the live check flow run, one per ecosystem. P2-2
/// registers Homebrew, the Node package managers and the Node version managers; P2-3 (Python,
/// Rust, Ruby) and P2-4 (agent skills/plugins, system stubs) add theirs here.
enum DiscoveryEnumeratorRegistry {
    static let all: [Enumerator] = [
        BrewEnumerator(),
        NpmEnumerator(),
        PnpmEnumerator(),
        YarnClassicEnumerator(),
        BunEnumerator(),
        NodeRuntimeEnumerator.nvm,
        NodeRuntimeEnumerator.fnm,
    ]

    /// `InventoryResolver`'s lookup: the enumerator that owns an ecosystem.
    static func enumerator(for ecosystem: Ecosystem) -> Enumerator? {
        all.first { $0.ecosystem == ecosystem }
    }
}
