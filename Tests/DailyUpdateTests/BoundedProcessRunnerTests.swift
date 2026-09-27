import XCTest
@testable import DailyUpdate

/// Amendment 1's E matrix: `BoundedProcessRunnerTests`.
final class BoundedProcessRunnerTests: HermeticTestCase {
    private func makeStub(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bpr-stub-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// E1: the child environment holds exactly the 9 allowlisted keys, whatever the parent's
    /// environment carries.
    func testEnrichersGetOnlyTheAllowlistedEnvironment() async throws {
        setenv("HOMEBREW_RUBY_PATH", "/malicious", 1)
        setenv("HOMEBREW_DEVELOPER", "1", 1)
        setenv("RUBYLIB", "/malicious", 1)
        setenv("GEM_HOME", "/malicious", 1)
        setenv("RUBYOPT", "-e evil", 1)
        setenv("BASH_ENV", "/malicious", 1)
        setenv("DYLD_INSERT_LIBRARIES", "/malicious.dylib", 1)
        setenv("npm_config_call", "curl x|sh", 1)
        defer {
            for key in ["HOMEBREW_RUBY_PATH", "HOMEBREW_DEVELOPER", "RUBYLIB", "GEM_HOME", "RUBYOPT",
                        "BASH_ENV", "DYLD_INSERT_LIBRARIES", "npm_config_call"] {
                unsetenv(key)
            }
        }
        let stub = try makeStub("#!/bin/sh\nenv\n")
        let environment = ReadOnlyQueries.enricherEnvironment()
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly(environment), timeout: 5, maxStdoutBytes: 64 * 1024
        ))
        let output = String(data: outcome.stdout, encoding: .utf8) ?? ""
        let keys = Set(output.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        // `/bin/sh` itself sets a few variables on startup (shell nesting level, cwd, last
        // argument) regardless of what environment it was launched with; those aren't part of
        // what the runner passed down, so they're excluded from this check.
        let shellInjected: Set<String> = ["SHLVL", "_", "PWD"]
        XCTAssertEqual(keys.subtracting(shellInjected), Set(environment.keys))
        XCTAssertEqual(outcome.evidence.termination, .exited(0))
    }

    /// E2: exit 1 with stderr is kept.
    func testExitedNonZeroKeepsStderr() async throws {
        let stub = try makeStub("#!/bin/sh\necho boom 1>&2\nexit 1\n")
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertEqual(outcome.evidence.termination, .exited(1))
        // §7.4's sanitizer turns the trailing newline `echo` appends into `?` (only printable
        // ASCII survives); it does not trim.
        XCTAssertEqual(outcome.evidence.stderr, "boom?")
    }

    /// E3: a stub that ignores SIGTERM and sleeps ends up `timedOut`, then SIGKILL, and the whole
    /// call still returns within timeout + 3s.
    func testIgnoredSIGTERMEscalatesToSIGKILL() async throws {
        let stub = try makeStub("#!/bin/sh\ntrap '' TERM\nsleep 30\n")
        let start = Date()
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 1, maxStdoutBytes: 1024
        ))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4.0)
        if case .timedOut = outcome.evidence.termination {} else {
            XCTFail("expected timedOut, got \(outcome.evidence.termination)")
        }
    }

    /// E4: a stub that raises SIGSEGV on itself reports `signaled(11)`.
    func testSignaledProcessIsReportedAsSignaled() async throws {
        let stub = try makeStub("#!/bin/sh\nkill -SEGV $$\n")
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertEqual(outcome.evidence.termination, .signaled(SIGSEGV))
    }

    /// E5: stderr over 16 KB is truncated; stdout over the cap stops the process and is never
    /// parsed as a full payload; a grandchild that keeps stdout open never blocks the return.
    func testStderrTruncationAndOutputCap() async throws {
        let stub = try makeStub("#!/bin/sh\nyes err | head -c 20000 1>&2\n")
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertTrue(outcome.evidence.stderrTruncated)
        XCTAssertEqual(outcome.evidence.stderr.utf8.count, 16 * 1024)
    }

    func testStdoutOverCapExceeded() async throws {
        let stub = try makeStub("#!/bin/sh\nyes out | head -c 200000\n")
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertEqual(outcome.evidence.termination, .outputCapExceeded)
        XCTAssertLessThanOrEqual(outcome.stdout.count, 1024)
    }

    func testGrandchildHoldingStdoutOpenNeverBlocksReturn() async throws {
        // The direct child exits immediately, but redirects stdout into a backgrounded `sleep`
        // subshell that inherits the write end of the pipe and keeps it open.
        let stub = try makeStub("#!/bin/sh\n(sleep 30 >&1 &)\nexit 0\n")
        let start = Date()
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 1, maxStdoutBytes: 1024
        ))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0)
        XCTAssertEqual(outcome.evidence.termination, .exited(0))
    }

    /// E8: only a token that passes the cask regex ever reaches argv; with no valid token, no
    /// process starts at all.
    func testOracleArgvOnlyKeepsValidCaskTokens() {
        let tokens = ["-rf", "--eval=x", "Foo", "a b", "antigravity-ide"]
        let validated = tokens.filter(PackageNameRules.isValidCaskToken)
        XCTAssertEqual(validated, ["antigravity-ide"])
    }

    func testNoValidTokenStartsNoProcess() async throws {
        var invoked = false
        let outcome = await ReadOnlyQueries.brewInfoCasks(
            brew: "/nonexistent/brew", tokens: ["-rf", "Foo"], run: { spec in
                invoked = true
                return await BoundedProcessRunner.run(spec)
            }
        )
        XCTAssertFalse(invoked)
        XCTAssertEqual(outcome?.evidence.termination, .launchFailed("no valid cask tokens"))
    }
}
