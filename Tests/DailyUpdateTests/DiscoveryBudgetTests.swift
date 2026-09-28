import Foundation
import XCTest
@testable import DailyUpdate

private actor EnumerationTimer {
    private var durations: [Ecosystem: Duration] = [:]

    func record(_ duration: Duration, for ecosystem: Ecosystem) {
        durations[ecosystem] = duration
    }

    func snapshot() -> [Ecosystem: Duration] { durations }
}

private struct TimedEnumerator: Enumerator {
    let wrapped: Enumerator
    let timer: EnumerationTimer

    var ecosystem: Ecosystem { wrapped.ecosystem }

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await wrapped.enumerate(context)
        await timer.record(clock.now - start, for: ecosystem)
        return result
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        await wrapped.resolve(identity, context)
    }
}

/// Checks the exact ADR-002 thresholds using synthetic or measured milliseconds.
private func budgetViolations(
    timings: [String: [Double]], sampleCount: Int, results: [EnumerationResult] = []
) -> [String] {
    let blocked = results.flatMap { result -> [String] in
        let issues: [EnumerationIssue]
        switch result.status {
        case .partial(let partial): issues = partial
        case .failed(let failure): issues = [failure]
        case .complete, .unavailable: issues = []
        }
        return issues.filter { $0.kind == .deadline || $0.kind == .previousRunStillBlocked }
            .map { "enumerator:\(result.ecosystem.rawValue) status=\($0.kind.rawValue)" }
    }
    if !blocked.isEmpty { return Array(Set(blocked)).sorted() }

    var violations: [String] = []
    for key in timings.keys.sorted() {
        guard let samples = timings[key], !samples.isEmpty else { continue }
        if key.hasPrefix("enumerator:") && samples.count != sampleCount {
            violations.append("\(key) samples=\(samples.count) expected=\(sampleCount)")
            continue
        }
        if key == "total" {
            let p50 = budgetPercentile(samples, 0.50)
            let p95 = budgetPercentile(samples, 0.95)
            if p50 > 1_500 { violations.append("total p50 \(p50)ms exceeds 1500ms") }
            if p95 > 3_000 { violations.append("total p95 \(p95)ms exceeds 3000ms") }
        } else if key.hasPrefix("enumerator:") && key != "enumerator:brew" && key != "enumerator:cask" {
            let p95 = budgetPercentile(samples, 0.95)
            if p95 > 200 { violations.append("\(key) p95 \(p95)ms exceeds 200ms") }
        }
    }
    for ecosystem in Set(results.map(\.ecosystem)) {
        let key = "enumerator:\(ecosystem.rawValue)"
        if timings[key] == nil { violations.append("\(key) has no measured samples") }
    }
    return violations.sorted()
}

/// Nearest rank: with twenty samples, p95 is the second slowest sample.
private func budgetPercentile(_ samples: [Double], _ fraction: Double) -> Double {
    let sorted = samples.sorted()
    let index = max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)
    return sorted[index]
}

/// Live measurements are opt-in: regular `swift test` remains hermetic and has no timing gate.
final class DiscoveryBudgetTests: HermeticTestCase {
    // Twenty samples make nearest-rank p95 the second-slowest run, so a single
    // machine wake-up or scheduler pause cannot decide the opt-in budget gate.
    private let sampleCount = 20

    func testLiveDiscoveryBudget() async throws {
        guard ProcessInfo.processInfo.environment["DAILY_UPDATE_LIVE_DISCOVERY"] == "1" else {
            throw XCTSkip("Set DAILY_UPDATE_LIVE_DISCOVERY=1 to measure the live machine")
        }

        let catalog = ConfigLoader.loadConfigs(settings: .defaults)
        let commandNames = catalog.compactMap(\.command)
        let registered = DiscoveryEnumeratorRegistry.all
        let layout = EcosystemLayout.live()
        let clock = ContinuousClock()
        var timings: [String: [Double]] = [:]
        var allResults: [EnumerationResult] = []

        for _ in 0..<sampleCount {
            let timer = EnumerationTimer()
            let enumerators: [Enumerator] = registered.map { TimedEnumerator(wrapped: $0, timer: timer) }
            let totalStart = clock.now
            let whenceStart = clock.now
            let lookup = await OwnerResolver.lookup(commandNames: commandNames, layout: layout)
            timings["whence", default: []].append(milliseconds(clock.now - whenceStart))

            let context = DiscoveryContext(
                environmentSnapshot: lookup.environmentSnapshot,
                loginPath: lookup.loginPath,
                layout: layout
            )
            let coordinatorStart = clock.now
            let results = await DiscoveryCoordinator.run(
                enumerators: enumerators,
                context: context,
                registry: DiscoveryInFlightRegistry()
            )
            XCTAssertEqual(Set(results.map(\.ecosystem)), Set(enumerators.map(\.ecosystem)),
                           "Every registered enumerator must return a result")
            timings["coordinator", default: []].append(milliseconds(clock.now - coordinatorStart))

            _ = RowBuilder.build(
                input: RowBuilder.Input(results: results, lookup: lookup),
                catalog: catalog,
                settings: .defaults,
                fileSystem: context.fileSystem
            )
            timings["total", default: []].append(milliseconds(clock.now - totalStart))

            let measured = await timer.snapshot()
            for result in results {
                if let duration = measured[result.ecosystem] {
                    timings["enumerator:\(result.ecosystem.rawValue)", default: []]
                        .append(milliseconds(duration))
                }
            }
            allResults.append(contentsOf: results)
        }

        print("DISCOVERY_BUDGET samples=\(sampleCount) registeredEnumerators=\(registered.count)")
        if registered.isEmpty {
            print("DISCOVERY_BUDGET note=no enumerators registered on this branch")
        }
        for key in timings.keys.sorted() {
            let samples = try XCTUnwrap(timings[key])
            let p50 = budgetPercentile(samples, 0.50)
            let p95 = budgetPercentile(samples, 0.95)
            print(String(format: "DISCOVERY_BUDGET %@ p50=%.2fms p95=%.2fms", key, p50, p95))
        }
        for violation in budgetViolations(timings: timings, sampleCount: sampleCount, results: allResults) {
            XCTFail(violation)
        }
    }

    func testBudgetViolationsWithFakeEnumeratorsAndExactBoundaries() async {
        let shortLimits = DiscoveryLimits(
            perEnumeratorDeadline: .seconds(2), coordinatorCeiling: .milliseconds(20),
            maxEntriesPerRoot: 5000, maxBytesPerFile: 1_000_000
        )
        let stuck = FakeEnumerator(ecosystem: .npm, behavior: .neverReturnsInTime(afterSeconds: 0.2))
        let stuckResults = await DiscoveryCoordinator.run(
            enumerators: [TimedEnumerator(wrapped: stuck, timer: EnumerationTimer())],
            context: DiscoveryContext(limits: shortLimits), registry: DiscoveryInFlightRegistry()
        )
        XCTAssertEqual(budgetViolations(timings: [:], sampleCount: 1, results: stuckResults),
                       ["enumerator:npm status=deadline"])

        let immediate = FakeEnumerator(ecosystem: .fake, behavior: .immediate(
            EnumerationResult(ecosystem: .fake, status: .complete)
        ))
        let timer = EnumerationTimer()
        let immediateResults = await DiscoveryCoordinator.run(
            enumerators: [TimedEnumerator(wrapped: immediate, timer: timer)],
            context: DiscoveryContext(), registry: DiscoveryInFlightRegistry()
        )
        let measured = await timer.snapshot()
        XCTAssertNotNil(measured[.fake])
        XCTAssertEqual(budgetViolations(
            timings: ["total": [1_500], "enumerator:fake": [200]],
            sampleCount: 1, results: immediateResults
        ), [])

        let valid: [String: [Double]] = ["total": [1_500], "enumerator:npm": [200],
                     "enumerator:brew": [800], "enumerator:cask": [800]]
        XCTAssertEqual(budgetViolations(timings: valid, sampleCount: 1), [])
        XCTAssertEqual(budgetViolations(timings: ["total": [1_500.001]], sampleCount: 1),
                       ["total p50 1500.001ms exceeds 1500ms"])
        XCTAssertEqual(budgetViolations(timings: ["total": [1_500], "enumerator:npm": [200.001]], sampleCount: 1),
                       ["enumerator:npm p95 200.001ms exceeds 200ms"])
        XCTAssertEqual(budgetViolations(timings: ["total": [1_500, 3_000]], sampleCount: 2), [])
        XCTAssertEqual(budgetViolations(timings: ["total": [1_500, 3_000.001]], sampleCount: 2),
                       ["total p95 3000.001ms exceeds 3000ms"])
        let previous = EnumerationResult(ecosystem: .npm, status: .partial([
            EnumerationIssue(kind: .previousRunStillBlocked, message: "blocked")
        ]))
        XCTAssertEqual(budgetViolations(timings: [:], sampleCount: 1, results: [previous]),
                       ["enumerator:npm status=previousRunStillBlocked"])
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

}
