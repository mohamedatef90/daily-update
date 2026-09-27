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

    func testLoginEnvironmentOverridesValidation() {
        XCTAssertTrue(LoginEnvironmentOverrides.isValid(name: "HOMEBREW_PREFIX", value: "/opt/homebrew"))
        XCTAssertFalse(LoginEnvironmentOverrides.isValid(name: "HOMEBREW_PREFIX", value: "opt/homebrew"))
        XCTAssertFalse(LoginEnvironmentOverrides.isValid(name: "HOMEBREW_PREFIX", value: ""))
        XCTAssertFalse(LoginEnvironmentOverrides.isValid(name: "HOMEBREW_PREFIX", value: String(repeating: "a", count: 2000)))
        XCTAssertTrue(LoginEnvironmentOverrides.isValid(name: "PYENV_VERSION", value: "system"))
        XCTAssertTrue(LoginEnvironmentOverrides.isValid(name: "UV_INDEX_URL", value: "https://example.com/simple"))
    }
}
