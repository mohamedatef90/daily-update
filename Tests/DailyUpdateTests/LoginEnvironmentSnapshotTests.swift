import XCTest
@testable import DailyUpdate

/// Amendment 1 RC2 (fixtures D19, D20) and F4 (fixture D24): the login PATH's three states, and
/// the `*_HOME`/`*_DIR` override snapshot that comes from the same login shell.
final class LoginEnvironmentSnapshotTests: HermeticTestCase {
    /// A private `ZDOTDIR` so these tests source a throwaway shell profile instead of the real
    /// user's `~/.zprofile` — the same hermetic-fixture principle as `HermeticTestCase`'s App
    /// Support override, applied to the login shell RC2/F4 read from.
    private func withZshProfile(_ contents: String, _ body: () async throws -> Void) async rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zdotdir-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `.zprofile`, not `.zshenv`: macOS's `/etc/zprofile` runs `path_helper` for every login
        // shell and rebuilds `$PATH` right after `.zshenv` runs, which would silently undo a PATH
        // override placed there. `.zprofile` is sourced after that, so it's the file a real
        // profile would use to change PATH, and the one these fixtures need too.
        try! contents.write(to: dir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        let previous = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", dir.path, 1)
        defer {
            if let previous { setenv("ZDOTDIR", previous, 1) } else { unsetenv("ZDOTDIR") }
            try? FileManager.default.removeItem(at: dir)
        }
        try await body()
    }

    func testKnownLoginPathKeepsOnlyAbsoluteEntries() async throws {
        await withZshProfile("export PATH=/usr/bin:/bin:relative\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["ls"])
            // CR#3: exact value, not `contains` — the trailing newline the script's own
            // `printf '%s\n'` adds must never survive onto the last entry (no `/bin\n`).
            XCTAssertEqual(lookup.loginPath, .known(["/usr/bin", "/bin"]))
        }
    }

    /// D20: an empty PATH is its own state, never treated the same as "PATH unknown".
    func testEmptyLoginPath() async throws {
        await withZshProfile("export PATH=\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["ls"])
            XCTAssertEqual(lookup.loginPath, .empty)
        }
    }

    /// D19: the shell exiting non-zero makes the PATH unknown, never empty.
    func testNonZeroExitMakesLoginPathUnknown() async throws {
        await withZshProfile("exit 7\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["ls"])
            guard case .unknown = lookup.loginPath else {
                return XCTFail("expected .unknown, got \(lookup.loginPath)")
            }
            XCTAssertNotNil(lookup.failureMessage)
        }
    }

    /// F4/D24: the override snapshot comes from the login shell, which wins over whatever this
    /// process's own environment already had.
    func testEnvironmentSnapshotPrefersLoginShellOverProcessEnvironment() async throws {
        let previousNvmDir = ProcessInfo.processInfo.environment["NVM_DIR"]
        setenv("NVM_DIR", "/from-process-env", 1)
        defer { if let previousNvmDir { setenv("NVM_DIR", previousNvmDir, 1) } else { unsetenv("NVM_DIR") } }

        await withZshProfile("export NVM_DIR=/custom-from-login-shell\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["ls"])
            XCTAssertEqual(lookup.environmentSnapshot["NVM_DIR"], "/custom-from-login-shell")
        }
    }

    /// F4: a relative value for a root variable is dropped; a non-path value (`PYENV_VERSION`)
    /// only needs to fit the shape rules, not be an absolute path.
    func testEnvironmentSnapshotDropsRelativeRootsButKeepsPlainValues() async throws {
        await withZshProfile("export CARGO_HOME=relative/cargo\nexport PYENV_VERSION=3.12.4\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["ls"])
            XCTAssertNil(lookup.environmentSnapshot["CARGO_HOME"])
            XCTAssertEqual(lookup.environmentSnapshot["PYENV_VERSION"], "3.12.4")
        }
    }

    /// CR#4 (F5): `EcosystemLayout.discover()` used to run `brew --prefix` to find a non-default
    /// prefix; F5 removed that unsandboxed call with nothing to replace it, so a brew outside the
    /// default prefixes silently lost formula/cask ownership. The snapshot's `HOMEBREW_PREFIX`
    /// (from this same login-shell batch) now rebuilds the layout instead.
    func testHomebrewPrefixFromLoginShellDefinesLayout() async throws {
        await withZshProfile("export HOMEBREW_PREFIX=/custom/brew\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["ls"])
            XCTAssertEqual(lookup.layout?.brewPrefixes, ["/custom/brew", "/opt/homebrew", "/usr/local"])
        }
    }

    /// F4 (Security FU2, CR FU1): a value with an embedded newline used to end its line early,
    /// and whatever followed was parsed as a second variable. Values are NUL-terminated now, so
    /// the newline stays inside the value and `isValid` drops it — and nothing is smuggled in.
    func testNewlineInAnOverrideValueCannotSmuggleASecondVariable() async throws {
        await withZshProfile("unset PNPM_HOME\nexport CARGO_HOME=$'/x\\nPNPM_HOME=/evil'\nexport BUN_INSTALL=/real/bun\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["ls"])
            XCTAssertNil(lookup.environmentSnapshot["CARGO_HOME"])
            XCTAssertNil(lookup.environmentSnapshot["PNPM_HOME"])
            XCTAssertEqual(lookup.environmentSnapshot["BUN_INSTALL"], "/real/bun")
        }
    }

    /// F4: two entries with the same name can only come from output that isn't what the script
    /// printed; neither copy is trusted.
    func testDuplicatedOverrideNameIsDropped() {
        let output = "__DAILY_UPDATE_WHENCE__PATH_BEGIN\n/usr/bin\n__DAILY_UPDATE_WHENCE__PATH_END\n" +
            "__DAILY_UPDATE_WHENCE__ENV_BEGIN\nNVM_DIR=/a\u{0}NVM_DIR=/b\u{0}FNM_DIR=/f\u{0}__DAILY_UPDATE_WHENCE__ENV_END\n"
        let lookup = OwnerResolver.parseLookupOutput(output, layout: .fixture(home: "/h"))
        XCTAssertEqual(lookup.environmentSnapshot, ["FNM_DIR": "/f"])
    }

    /// D19 (CR FU3): the login shell timing out makes the PATH unknown, with the reason.
    func testTimedOutLoginShellMakesLoginPathUnknown() async throws {
        await withZshProfile("sleep 5\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["ls"], timeout: 1)
            XCTAssertEqual(lookup.loginPath, .unknown("timed out"))
            XCTAssertEqual(lookup.failureMessage, "Command lookup failed: timed out")
        }
    }

    /// D19 (CR FU3): output that stops before the PATH block's END marker is unknown, never an
    /// empty or partial PATH.
    func testMissingPathEndMarkerMakesLoginPathUnknown() {
        let output = "__DAILY_UPDATE_WHENCE__PATH_BEGIN\n/usr/bin:/bin\n"
        let lookup = OwnerResolver.parseLookupOutput(output, layout: .fixture(home: "/h"))
        XCTAssertEqual(lookup.loginPath, .unknown("missing PATH marker"))
    }

    /// Security FU3, CR re-review FU2: the batch always runs, and always includes `brew`, even when
    /// no valid catalog name is left.
    func testBatchAlwaysRunsAndAlwaysLooksUpBrew() async throws {
        await withZshProfile("export PATH=/usr/bin:/bin\n") {
            let lookup = await OwnerResolver.lookup(commandNames: ["bad name"])
            XCTAssertEqual(lookup.loginPath, .known(["/usr/bin", "/bin"]))
            XCTAssertEqual(lookup.candidatesByName, ["brew": []])
        }
    }

    func testLoginEnvironmentOverridesValidation() {
        XCTAssertTrue(LoginEnvironmentOverrides.isValid(name: "HOMEBREW_PREFIX", value: "/opt/homebrew"))
        XCTAssertFalse(LoginEnvironmentOverrides.isValid(name: "HOMEBREW_PREFIX", value: "opt/homebrew"))
        XCTAssertFalse(LoginEnvironmentOverrides.isValid(name: "HOMEBREW_PREFIX", value: ""))
        XCTAssertFalse(LoginEnvironmentOverrides.isValid(name: "HOMEBREW_PREFIX", value: String(repeating: "a", count: 2000)))
        XCTAssertTrue(LoginEnvironmentOverrides.isValid(name: "PYENV_VERSION", value: "system"))
        XCTAssertTrue(LoginEnvironmentOverrides.isValid(name: "UV_INDEX_URL", value: "https://example.com/simple"))
    }
}
