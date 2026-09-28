import XCTest
@testable import DailyUpdate

/// Amendment 1's E matrix (E6, E7): the sandbox preflight, and the fallback when `sandbox-exec`
/// itself can't be trusted or found.
final class ReadOnlyQueriesTests: HermeticTestCase {
    private func makeStubSandboxExec(exitCode: Int32) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-exec-stub-\(UUID().uuidString)")
        try "#!/bin/sh\nexit \(exitCode)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// E6: the stub `sandbox-exec` preflight exits 65 (a bad profile on this Mac) → `sandboxRefused`.
    func testPreflightExitNonZeroIsSandboxRefused() async throws {
        let stub = try makeStubSandboxExec(exitCode: 65)
        let availability = await ReadOnlyQueries.checkSandboxAvailability(sandboxExecPath: stub)
        guard case .refused(let evidence) = availability else {
            return XCTFail("expected .refused, got \(availability)")
        }
        XCTAssertEqual(evidence.termination, .exited(65))
    }

    func testPreflightExitZeroIsAvailable() async throws {
        let stub = try makeStubSandboxExec(exitCode: 0)
        let availability = await ReadOnlyQueries.checkSandboxAvailability(sandboxExecPath: stub)
        XCTAssertEqual(availability, .available)
    }

    /// E7: no `sandbox-exec` at all → `sandboxUnavailable`, same fallback as a refusal.
    func testMissingSandboxExecIsUnavailable() async throws {
        let availability = await ReadOnlyQueries.checkSandboxAvailability(sandboxExecPath: "/nonexistent/sandbox-exec")
        XCTAssertEqual(availability, .unavailable)
    }

    func testBrewInfoCasksDropsInvalidTokensButKeepsValidOnes() async {
        var capturedArguments: [String] = []
        _ = await ReadOnlyQueries.brewInfoCasks(brew: "/opt/homebrew/bin/brew", tokens: ["-rf", "antigravity-ide"], run: { spec in
            capturedArguments = spec.arguments
            return QueryOutcome(
                evidence: ProcessEvidence(executable: spec.executable, arguments: spec.arguments,
                    termination: .exited(0), stderr: "", stderrTruncated: false, elapsedMs: 1),
                stdout: Data("{}".utf8)
            )
        })
        // CR FU3: the whole argv, from `-p` through `--` and the one surviving token.
        XCTAssertEqual(capturedArguments, [
            "-p", ReadOnlyQueries.sandboxProfile, "/opt/homebrew/bin/brew", "info", "--json=v2", "--cask", "--", "antigravity-ide",
        ])
    }
}
