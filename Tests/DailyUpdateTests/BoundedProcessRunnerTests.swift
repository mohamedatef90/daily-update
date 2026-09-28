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

    /// Polls until `pid` no longer exists (reaped), up to `limit`.
    private func waitUntilGone(_ pid: pid_t, limit: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            usleep(20_000)
        }
        return false
    }

    private func readPID(_ path: String) throws -> pid_t {
        let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text))
    }

    /// E3: a stub that ignores SIGTERM and sleeps ends up `timedOut`, then SIGKILL, and the whole
    /// call still returns within timeout + 3s. CR FU3: the SIGKILL is asserted — the stub itself is
    /// gone afterwards, which SIGTERM alone can't do because the stub ignores it.
    ///
    /// P2-2 flake note: in a parallel run on 2026-09-27 this test measured 1039.96 s against its
    /// 4 s bound while the Mac was in Sleep/DarkWake cycles (`pmset -g log`). The wall-clock bounds
    /// in this file can't hold while the machine sleeps; the assertions below don't depend on it.
    func testIgnoredSIGTERMEscalatesToSIGKILL() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("bpr-pid-\(UUID().uuidString)").path
        let stub = try makeStub("#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile)'\nsleep 30\n")
        let start = Date()
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 1, maxStdoutBytes: 1024
        ))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4.0)
        if case .timedOut = outcome.evidence.termination {} else {
            XCTFail("expected timedOut, got \(outcome.evidence.termination)")
        }
        XCTAssertTrue(waitUntilGone(try readPID(pidFile)), "the stub ignores SIGTERM, so only SIGKILL can have ended it")
    }

    /// Security FU5 / CR FU2: past the stdout cap, a child that ignores SIGTERM still gets SIGKILL.
    func testStdoutCapEscalatesToSIGKILL() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("bpr-pid-\(UUID().uuidString)").path
        let stub = try makeStub("#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile)'\nwhile :; do echo out; done\n")
        let start = Date()
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 20, maxStdoutBytes: 1024
        ))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
        XCTAssertEqual(outcome.evidence.termination, .outputCapExceeded)
        XCTAssertEqual(outcome.stdout.count, 1024)
        XCTAssertTrue(waitUntilGone(try readPID(pidFile)), "the stub ignores SIGTERM, so only SIGKILL can have ended it")
    }

    /// CR FU2: output of exactly the cap isn't "over the cap".
    func testStdoutOfExactlyTheCapIsKeptWhole() async throws {
        let stub = try makeStub("#!/bin/sh\nhead -c 1024 /dev/zero | tr '\\0' 'a'\n")
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly(["PATH": "/usr/bin:/bin"]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertEqual(outcome.evidence.termination, .exited(0))
        XCTAssertEqual(outcome.stdout, Data(repeating: UInt8(ascii: "a"), count: 1024))
    }

    /// Security re-review FU3: `stderrTruncated` means bytes were dropped, not "reached 16 KB".
    func testStderrTruncatedOnlyWhenBytesWereDropped() async throws {
        let exact = try makeStub("#!/bin/sh\nhead -c 16384 /dev/zero | tr '\\0' 'e' 1>&2\n")
        let exactOutcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: exact, arguments: [], environment: .exactly(["PATH": "/usr/bin:/bin"]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertEqual(exactOutcome.evidence.stderr.utf8.count, 16384)
        XCTAssertFalse(exactOutcome.evidence.stderrTruncated)

        let over = try makeStub("#!/bin/sh\nhead -c 16385 /dev/zero | tr '\\0' 'e' 1>&2\n")
        let overOutcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: over, arguments: [], environment: .exactly(["PATH": "/usr/bin:/bin"]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertEqual(overOutcome.evidence.stderr.utf8.count, 16384)
        XCTAssertTrue(overOutcome.evidence.stderrTruncated)
    }

    /// E4: a stub that raises SIGSEGV on itself reports `signaled(11)`.
    func testSignaledProcessIsReportedAsSignaled() async throws {
        let stub = try makeStub("#!/bin/sh\nkill -SEGV $$\n")
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertEqual(outcome.evidence.termination, .signaled(SIGSEGV))
    }

    /// E5 (amendment): a child that writes 1 MB of stderr — far more than a pipe buffer holds —
    /// then exits 3 must still be drained past the 16 KB cap and report its real exit status.
    /// Before the fix, `drainOnce` stopped reading once the cap was hit, so the child blocked on
    /// a full stderr pipe until the timeout and its `exit 3` was lost behind `timedOut`.
    func testStderrTruncationAndOutputCap() async throws {
        let stub = try makeStub("#!/bin/sh\nyes err | head -c 1000000 1>&2\nexit 3\n")
        let start = Date()
        let outcome = await BoundedProcessRunner.run(BoundedProcessSpec(
            executable: stub, arguments: [], environment: .exactly([:]), timeout: 5, maxStdoutBytes: 1024
        ))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
        XCTAssertEqual(outcome.evidence.termination, .exited(3))
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
