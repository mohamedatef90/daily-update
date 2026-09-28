import Foundation
import XCTest
@testable import DailyUpdate

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
        let enumerators = DiscoveryEnumeratorRegistry.all
        let layout = EcosystemLayout.live()
        let clock = ContinuousClock()
        var timings: [String: [Double]] = [:]

        for _ in 0..<sampleCount {
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

            for result in results {
                timings["enumerator:\(result.ecosystem.rawValue)", default: []]
                    .append(milliseconds(result.elapsed))
            }
        }

        print("DISCOVERY_BUDGET samples=\(sampleCount) registeredEnumerators=\(enumerators.count)")
        if enumerators.isEmpty {
            print("DISCOVERY_BUDGET note=no enumerators registered on this branch")
        }
        for key in timings.keys.sorted() {
            let samples = try XCTUnwrap(timings[key])
            let p50 = percentile(samples, 0.50)
            let p95 = percentile(samples, 0.95)
            print(String(format: "DISCOVERY_BUDGET %@ p50=%.2fms p95=%.2fms", key, p50, p95))
            if key == "total" {
                XCTAssertLessThanOrEqual(p50, 1_500, "ADR-002 §8 discovery p50")
                XCTAssertLessThanOrEqual(p95, 3_000, "ADR-002 §8 discovery p95")
            } else if key.hasPrefix("enumerator:") && key != "enumerator:brew" && key != "enumerator:cask" {
                XCTAssertEqual(samples.count, sampleCount, "Every enumerator must report each run")
                XCTAssertLessThanOrEqual(p95, 200, "ADR-002 §8 filesystem enumerator p95: \(key)")
            }
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// Nearest-rank percentile: for twenty samples p95 is the second-slowest sample.
    private func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        let sorted = samples.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)
        return sorted[index]
    }
}
