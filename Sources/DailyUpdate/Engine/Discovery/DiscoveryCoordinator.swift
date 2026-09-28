import Foundation

/// RC3: never starts a second copy of an enumerator that's still blocked from an earlier run.
/// Persists for the app's lifetime via `.shared`; tests that exercise this behavior inject a
/// fresh instance instead, so one test's leaked straggler can't wedge another.
actor DiscoveryInFlightRegistry {
    static let shared = DiscoveryInFlightRegistry()

    private var inFlight: Set<Ecosystem> = []

    func tryStart(_ ecosystem: Ecosystem) -> Bool {
        guard !inFlight.contains(ecosystem) else { return false }
        inFlight.insert(ecosystem)
        return true
    }

    func finish(_ ecosystem: Ecosystem) {
        inFlight.remove(ecosystem)
    }
}

/// RC3: a sealed collector. Every enumerator runs in its own `Task.detached` and reports back
/// here; once sealed, a late result (one that arrives after the coordinator's ceiling fired) is
/// silently dropped instead of racing with whatever `run` already returned.
private actor DiscoveryRun {
    private var results: [Ecosystem: EnumerationResult] = [:]
    private var sealed = false

    func record(_ result: EnumerationResult) {
        guard !sealed else { return }
        results[result.ecosystem] = result
    }

    func count() -> Int {
        results.count
    }

    func seal() -> [Ecosystem: EnumerationResult] {
        sealed = true
        return results
    }
}

enum DiscoveryCoordinator {
    /// How often `run` polls for completion while waiting on the ceiling. Small enough that the
    /// extra latency it can add is negligible next to the 10s ceiling itself.
    static let pollInterval: Duration = .milliseconds(20)

    /// RC3: every enumerator runs in its own detached task; `run` returns on whichever comes
    /// first — every result is in, or the coordinator's ceiling fires. An enumerator that's still
    /// running at the ceiling is reported `partial(deadline)`; its task keeps running in the
    /// background (a leaked straggler that writes nothing, per `ReadOnlyFileSystem`'s contract)
    /// until it eventually finishes or the process exits.
    static func run(
        enumerators: [Enumerator],
        context: DiscoveryContext,
        registry: DiscoveryInFlightRegistry = .shared,
        clock: ContinuousClock = ContinuousClock()
    ) async -> [EnumerationResult] {
        let collector = DiscoveryRun()

        for enumerator in enumerators {
            Task.detached {
                guard await registry.tryStart(enumerator.ecosystem) else {
                    await collector.record(EnumerationResult(
                        ecosystem: enumerator.ecosystem,
                        status: .partial([EnumerationIssue(
                            kind: .previousRunStillBlocked,
                            message: "A previous discovery run is still reading this ecosystem"
                        )])
                    ))
                    return
                }
                let result = await enumerator.enumerate(context)
                await collector.record(result)
                await registry.finish(enumerator.ecosystem)
            }
        }

        let deadline = clock.now.advanced(by: context.limits.coordinatorCeiling)
        while clock.now < deadline {
            if await collector.count() >= enumerators.count { break }
            try? await Task.sleep(for: pollInterval)
        }

        let sealed = await collector.seal()
        return enumerators.map { enumerator in
            sealed[enumerator.ecosystem] ?? EnumerationResult(
                ecosystem: enumerator.ecosystem,
                status: .partial([EnumerationIssue(kind: .deadline, message: "Did not finish within the discovery ceiling")])
            )
        }
    }
}
