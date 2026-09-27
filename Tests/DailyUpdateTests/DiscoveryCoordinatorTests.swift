import XCTest
@testable import DailyUpdate

/// Amendment 1's D21 fixture, plus D11/D12 status pass-through.
final class DiscoveryCoordinatorTests: HermeticTestCase {
    private func shortCeilingLimits(_ ceiling: Duration) -> DiscoveryLimits {
        DiscoveryLimits(perEnumeratorDeadline: .seconds(2), coordinatorCeiling: ceiling, maxEntriesPerRoot: 5000, maxBytesPerFile: 1_000_000)
    }

    func testEveryResultReturnsWhenAllEnumeratorsFinishQuickly() async {
        let fast = FakeEnumerator(ecosystem: .fake, behavior: .immediate(EnumerationResult(ecosystem: .fake, status: .complete)))
        let brew = FakeEnumerator(ecosystem: .brew, behavior: .immediate(EnumerationResult(ecosystem: .brew, status: .unavailable("no brew"))))
        let context = DiscoveryContext(limits: shortCeilingLimits(.seconds(10)))
        let results = await DiscoveryCoordinator.run(
            enumerators: [fast, brew], context: context, registry: DiscoveryInFlightRegistry()
        )
        XCTAssertEqual(Set(results.map(\.ecosystem)), [.fake, .brew])
        XCTAssertEqual(results.first { $0.ecosystem == .brew }?.status, .unavailable("no brew"))
    }

    /// D21 ("an enumerator that never returns"): `run` returns within the ceiling, and that
    /// enumerator is `partial(deadline)`.
    func testEnumeratorThatNeverReturnsInTimeGivesPartialDeadlineWithoutBlocking() async {
        let stuck = FakeEnumerator(ecosystem: .npm, behavior: .neverReturnsInTime(afterSeconds: 3))
        let fine = FakeEnumerator(ecosystem: .fake, behavior: .immediate(EnumerationResult(ecosystem: .fake, status: .complete)))
        let context = DiscoveryContext(limits: shortCeilingLimits(.milliseconds(200)))

        let start = ContinuousClock.now
        let results = await DiscoveryCoordinator.run(
            enumerators: [stuck, fine], context: context, registry: DiscoveryInFlightRegistry()
        )
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(800))

        let npmResult = results.first { $0.ecosystem == .npm }
        guard case .partial(let issues) = npmResult?.status else {
            return XCTFail("expected .partial, got \(String(describing: npmResult?.status))")
        }
        XCTAssertEqual(issues.first?.kind, .deadline)

        let fakeResult = results.first { $0.ecosystem == .fake }
        XCTAssertEqual(fakeResult?.status, .complete)
    }

    /// D21 ("a second run reports previousRunStillBlocked, and only one copy is running"):
    func testSecondRunOfAStillBlockedEcosystemReportsPreviousRunStillBlocked() async {
        let registry = DiscoveryInFlightRegistry()
        let stuck = FakeEnumerator(ecosystem: .npm, behavior: .neverReturnsInTime(afterSeconds: 2))
        let context = DiscoveryContext(limits: shortCeilingLimits(.milliseconds(100)))

        async let firstRun: [EnumerationResult] = DiscoveryCoordinator.run(
            enumerators: [stuck], context: context, registry: registry
        )
        // Give the first run's task a moment to register itself as in-flight before the second
        // run starts, so the race is deterministic.
        try? await Task.sleep(for: .milliseconds(20))

        let secondRun = await DiscoveryCoordinator.run(
            enumerators: [stuck], context: context, registry: registry
        )
        _ = await firstRun

        guard case .partial(let issues) = secondRun.first?.status else {
            return XCTFail("expected .partial, got \(String(describing: secondRun.first?.status))")
        }
        XCTAssertEqual(issues.first?.kind, .previousRunStillBlocked)
    }

    func testFailedAndUnavailableStatusesPassThroughUnchanged() async {
        let failed = FakeEnumerator(ecosystem: .gem, behavior: .immediate(EnumerationResult(
            ecosystem: .gem, status: .failed(EnumerationIssue(kind: .malformed, message: "bad gemspec"))
        )))
        let context = DiscoveryContext(limits: shortCeilingLimits(.seconds(5)))
        let results = await DiscoveryCoordinator.run(enumerators: [failed], context: context, registry: DiscoveryInFlightRegistry())
        guard case .failed(let issue) = results.first?.status else {
            return XCTFail("expected .failed, got \(String(describing: results.first?.status))")
        }
        XCTAssertEqual(issue.kind, .malformed)
    }
}
