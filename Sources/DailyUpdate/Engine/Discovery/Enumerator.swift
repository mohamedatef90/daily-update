import Foundation

/// §7.5's per-enumerator deadline and per-root/per-file caps, plus the coordinator's own ceiling
/// (RC3).
struct DiscoveryLimits: Sendable {
    /// §7.5: each filesystem enumerator gets a 2s soft deadline, checked between entries.
    let perEnumeratorDeadline: Duration
    /// RC3: the coordinator returns at this ceiling regardless of what's still running.
    let coordinatorCeiling: Duration
    /// §7.3: at most 5,000 entries per root.
    let maxEntriesPerRoot: Int
    /// §7.3's default; individual manifests have their own tighter caps (package.json 1 MB,
    /// lock/metadata JSON 5 MB, brew JSON 64 MB) applied by the caller.
    let maxBytesPerFile: Int

    static let `default` = DiscoveryLimits(
        perEnumeratorDeadline: .seconds(2),
        coordinatorCeiling: .seconds(10),
        maxEntriesPerRoot: 5000,
        maxBytesPerFile: 1_000_000
    )
}

/// A tiny helper every enumerator can poll between entries to honor its own 2s soft deadline
/// (§7.5) without each one reimplementing a clock check.
struct DiscoveryDeadline: Sendable {
    private let expiry: ContinuousClock.Instant

    init(_ duration: Duration, clock: ContinuousClock = ContinuousClock()) {
        expiry = clock.now.advanced(by: duration)
    }

    func hasExpired(clock: ContinuousClock = ContinuousClock()) -> Bool {
        clock.now >= expiry
    }
}

/// ADR-002 §1: what an enumerator receives. `fileSystem` is the only I/O it may do; `loginPath`
/// and `environmentSnapshot` come from the one `whence` batch the coordinator already ran (RC2,
/// F4) so no enumerator ever starts its own process to learn PATH or an override variable.
struct DiscoveryContext: Sendable {
    let fileSystem: ReadOnlyFileSystem
    let environmentSnapshot: [String: String]
    let loginPath: LoginPath
    let layout: EcosystemLayout
    let limits: DiscoveryLimits

    init(
        fileSystem: ReadOnlyFileSystem = LiveFileSystem(),
        environmentSnapshot: [String: String] = [:],
        loginPath: LoginPath = .unknown("Not queried"),
        layout: EcosystemLayout = .live(),
        limits: DiscoveryLimits = .default
    ) {
        self.fileSystem = fileSystem
        self.environmentSnapshot = environmentSnapshot
        self.loginPath = loginPath
        self.layout = layout
        self.limits = limits
    }
}

protocol Enumerator: Sendable {
    var ecosystem: Ecosystem { get }
    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult
    /// Re-reads one package (manifest, trust, PATH position) for check-time resolution and L3.
    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage?
}
