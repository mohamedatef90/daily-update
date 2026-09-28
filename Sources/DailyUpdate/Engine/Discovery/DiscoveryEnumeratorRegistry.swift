import Foundation

/// The enumerators `--discover` and (eventually) the live check flow run. P2-2 (Homebrew, npm
/// family) and P2-4 (agent skills/plugins, system stubs) add their own here alongside P2-3's
/// Python/Rust/Ruby enumerators below.
enum DiscoveryEnumeratorRegistry {
    static let all: [Enumerator] = [
        UvToolEnumerator(),
        PipxEnumerator(),
    ]
}
