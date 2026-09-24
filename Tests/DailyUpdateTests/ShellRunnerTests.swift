import XCTest
@testable import DailyUpdate

final class ShellRunnerTests: XCTestCase {
    func testEffectivePathPreservesInheritedOrderBeforeFallbacks() {
        let path = ShellRunner.effectivePath(
            inheritedPath: "/custom/first:/opt/homebrew/bin:/custom/last",
            home: "/Users/test",
            userManagedDirectories: ["/Users/test/tools/bin"]
        )

        XCTAssertEqual(
            Array(path.components(separatedBy: ":").prefix(4)),
            ["/custom/first", "/opt/homebrew/bin", "/custom/last", "/opt/homebrew/sbin"]
        )
        XCTAssertEqual(path.components(separatedBy: ":").filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }

    func testDrainsLargeStdoutAndStderrWithoutDeadlock() async {
        let command = "python3 -c 'import sys; sys.stdout.write(\"o\" * 200000); sys.stderr.write(\"e\" * 200000)'"
        let result = await ShellRunner.run(command, timeout: 10)

        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testTimeoutIsClassifiedDistinctly() async {
        let result = await ShellRunner.run("sleep 10", timeout: 0.1)

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.processIdentifier)
        XCTAssertGreaterThanOrEqual(result.duration, 0.1)
    }

    func testTimeoutKillsDescendantsThatKeepPipesOpen() async {
        let result = await ShellRunner.run(
            "/bin/sh -c 'trap \"\" TERM; sleep 30' & wait",
            timeout: 0.1
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(result.duration, 3)
    }

    func testExitedParentCannotLeaveOutputDrainWaitingForever() async {
        let result = await ShellRunner.run(
            "python3 -c 'import os,time; p=os.fork(); os._exit(0) if p else time.sleep(30)'",
            timeout: 0.2
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(result.duration, 3)
    }

    func testConcurrentTimeoutPipeClosureReturnsResultsWithoutFileHandleExceptions() async {
        let results = await withTaskGroup(of: ShellRunner.Result.self, returning: [ShellRunner.Result].self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await ShellRunner.run(
                        "python3 -c 'import os,time; p=os.fork(); os._exit(0) if p else time.sleep(30)'",
                        timeout: 0.05
                    )
                }
            }

            var collected: [ShellRunner.Result] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, 32)
        let terminations = Dictionary(grouping: results, by: \.termination).mapValues(\.count)
        let slowest = results.map(\.duration).max() ?? 0
        XCTAssertTrue(results.allSatisfy { $0.termination == .timedOut }, "terminations: \(terminations)")
        XCTAssertTrue(results.allSatisfy { $0.duration < 3 }, "slowest duration: \(slowest)")
    }
}
