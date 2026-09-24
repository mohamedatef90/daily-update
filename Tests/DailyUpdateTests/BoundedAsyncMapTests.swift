import XCTest
@testable import DailyUpdate

final class BoundedAsyncMapTests: XCTestCase {
    actor ConcurrencyProbe {
        private var inFlight = 0
        private(set) var maximum = 0
        private(set) var completedBeforeSlowest = 0
        private var slowestFinished = false

        func enter() {
            inFlight += 1
            maximum = max(maximum, inFlight)
        }

        func leave(value: Int) {
            inFlight -= 1
            if value == 0 { slowestFinished = true }
        }

        func recordCompletion() {
            if !slowestFinished { completedBeforeSlowest += 1 }
        }
    }

    func testMapPreservesAllResultsWithoutExceedingConcurrencyLimit() async {
        let probe = ConcurrencyProbe()
        let inputs = Array(0..<24)

        let results = await BoundedAsyncMap.run(
            inputs,
            maxConcurrent: 4,
            operation: { value in
                await probe.enter()
                let delay: UInt64 = value == 0 ? 200_000_000 : 20_000_000
                try? await Task.sleep(nanoseconds: delay)
                await probe.leave(value: value)
                return value * 2
            },
            onResult: { _, _ in
                await probe.recordCompletion()
            }
        )

        let maximum = await probe.maximum
        let completedBeforeSlowest = await probe.completedBeforeSlowest
        XCTAssertEqual(results, inputs.map { $0 * 2 })
        XCTAssertLessThanOrEqual(maximum, 4)
        XCTAssertGreaterThan(maximum, 1)
        XCTAssertGreaterThan(completedBeforeSlowest, 0)
    }
}
