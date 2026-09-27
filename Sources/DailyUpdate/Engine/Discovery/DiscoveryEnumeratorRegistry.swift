import Foundation

/// The enumerators `--discover` and (eventually) the live check flow run. Empty in P2-1: no
/// ecosystem enumerator lands until P2-2 (Homebrew, npm family), P2-3 (Python/Rust/Ruby) and P2-4
/// (agent skills/plugins, system stubs) add their own here. `--discover` is fully wired and
/// tested against `FakeEnumerator` in the meantime (`DiscoveryDumpTests`), so this list is the
/// only thing later PRs need to extend.
enum DiscoveryEnumeratorRegistry {
    static let all: [Enumerator] = []
}
