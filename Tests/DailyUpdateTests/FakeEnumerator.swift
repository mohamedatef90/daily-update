@testable import DailyUpdate

/// A test-only `Enumerator` (§9 P2-1: "`FakeEnumerator`, `DiscoveryDumpTests`") used both by the
/// coordinator's own tests and by the discovery-dump golden-tree harness. It never touches a real
/// filesystem or process.
final class FakeEnumerator: Enumerator, @unchecked Sendable {
    enum Behavior: @unchecked Sendable {
        case immediate(EnumerationResult)
        /// Sleeps well past any test's own (short) coordinator ceiling, so `run` has to leave it
        /// behind — the "leaked straggler" RC3 describes — before it eventually finishes.
        case neverReturnsInTime(afterSeconds: Double)
    }

    let ecosystem: Ecosystem
    private let behavior: Behavior

    init(ecosystem: Ecosystem, behavior: Behavior) {
        self.ecosystem = ecosystem
        self.behavior = behavior
    }

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        switch behavior {
        case .immediate(let result):
            return result
        case .neverReturnsInTime(let seconds):
            try? await Task.sleep(for: .seconds(seconds))
            return EnumerationResult(ecosystem: ecosystem, status: .complete)
        }
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        nil
    }
}
