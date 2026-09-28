import Foundation

/// ADR-002 §7.1, plus Amendment 1 RC1: the only two enricher calls discovery ever starts, and the
/// sandbox preflight that decides whether they run at all. This is the one file under
/// `Engine/Discovery/` allowed to reference `BoundedProcessRunner` (the lint enforces that) — every
/// other file only ever sees an `InstalledPackage` record or a `QueryOutcome` that already happened.
enum ReadOnlyQueries {
    typealias Runner = (BoundedProcessSpec) async -> QueryOutcome

    static let sandboxExecutable = "/usr/bin/sandbox-exec"

    /// §7.1: network denied, and every write denied except the descriptors a well-behaved child
    /// already inherits (stdout/stderr/tty/its own fd table). F1 (P2-2) adds `process-exec`
    /// denials for `/usr/bin/open` and `/usr/bin/osascript`, so nothing brew evaluates can hand
    /// work to LaunchServices or AppleScript.
    ///
    /// §7.8 residual risk (F1): `(allow default)` still allows every other `process-exec`, and
    /// mach/XPC lookups. `brew info` evaluates the Ruby of installed third-party tap formulae. The
    /// trust boundary doesn't change, because every `brew` command already runs that code; the
    /// sandbox only guarantees that none of it reaches the network or writes a file.
    static let sandboxProfile = """
    (version 1)(allow default)(deny network*)(deny file-write* (require-not (require-any (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr") (literal "/dev/tty") (subpath "/dev/fd"))))(deny process-exec (literal "/usr/bin/open") (literal "/usr/bin/osascript"))
    """

    /// RC1: built from scratch every time; nothing is copied from `ProcessInfo` except the handful
    /// of values that must reflect the real account it runs as.
    static func enricherEnvironment() -> [String: String] {
        let processEnvironment = ProcessInfo.processInfo.environment
        return [
            "HOME": processEnvironment["HOME"] ?? NSHomeDirectory(),
            "USER": processEnvironment["USER"] ?? NSUserName(),
            "LOGNAME": processEnvironment["LOGNAME"] ?? NSUserName(),
            "TMPDIR": processEnvironment["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
        ]
    }

    enum SandboxAvailability: Equatable {
        case available
        case unavailable
        case refused(ProcessEvidence)
    }

    /// RC1: "sandbox refusal is its own kind, detected by a preflight instead of guessed from
    /// brew's exit code." Runs once per discovery run.
    static func checkSandboxAvailability(
        sandboxExecPath: String = sandboxExecutable,
        fileSystem: ReadOnlyFileSystem = LiveFileSystem(),
        run: Runner = BoundedProcessRunner.run
    ) async -> SandboxAvailability {
        guard fileSystem.stat(sandboxExecPath) != nil else { return .unavailable }
        let outcome = await run(BoundedProcessSpec(
            executable: sandboxExecPath,
            arguments: ["-p", sandboxProfile, "/usr/bin/true"],
            environment: .exactly(enricherEnvironment()),
            timeout: 10,
            maxStdoutBytes: 4096
        ))
        if case .exited(0) = outcome.evidence.termination {
            return .available
        }
        return .refused(outcome.evidence)
    }

    /// What the Homebrew enricher came back with. Only `.ran` means brew itself was started;
    /// every other case is decided before any brew process exists.
    enum EnricherOutcome: Sendable {
        case ran(QueryOutcome)
        case untrustedExecutable(String)
        case sandboxUnavailable
        case sandboxRefused(ProcessEvidence)
    }

    /// `brew info --json=v2 --installed`, sandboxed. §7.5: a 10 s timeout, capped at 64 MB.
    ///
    /// CR FU5 (P2-1 review): this is the enricher's single entry point, so no caller can skip a
    /// step. In order:
    /// 1. `brew` must pass `PathTrust.isTrustedExecutable` (§7.1), or nothing runs.
    /// 2. The sandbox preflight (RC1): a missing `sandbox-exec` or a refused profile means brew
    ///    never runs, and the caller falls back to the filesystem.
    /// 3. The real call. After a clean preflight its exit status is brew's own, except exit 71
    ///    with stderr starting `sandbox-exec: execvp`, which is `sandbox-exec` failing to start
    ///    brew at all — reported as `launchFailed`, not as a brew failure.
    static func brewInfoInstalled(
        brew: String,
        sandboxExecPath: String = sandboxExecutable,
        fileSystem: ReadOnlyFileSystem = LiveFileSystem(),
        isTrustedExecutable: (String) -> Bool = PathTrust.isTrustedExecutable,
        run: Runner = BoundedProcessRunner.run
    ) async -> EnricherOutcome {
        guard isTrustedExecutable(brew) else { return .untrustedExecutable(brew) }
        switch await checkSandboxAvailability(sandboxExecPath: sandboxExecPath, fileSystem: fileSystem, run: run) {
        case .unavailable: return .sandboxUnavailable
        case .refused(let evidence): return .sandboxRefused(evidence)
        case .available: break
        }
        let outcome = await run(BoundedProcessSpec(
            executable: sandboxExecPath,
            arguments: ["-p", sandboxProfile, brew, "info", "--json=v2", "--installed"],
            environment: .exactly(enricherEnvironment()),
            timeout: 10,
            maxStdoutBytes: 64 * 1024 * 1024
        ))
        return .ran(reclassifyingLaunchFailure(outcome))
    }

    static func reclassifyingLaunchFailure(_ outcome: QueryOutcome) -> QueryOutcome {
        guard outcome.evidence.termination == .exited(71),
              outcome.evidence.stderr.hasPrefix("sandbox-exec: execvp") else { return outcome }
        let evidence = outcome.evidence
        return QueryOutcome(
            evidence: ProcessEvidence(
                executable: evidence.executable, arguments: evidence.arguments,
                termination: .launchFailed(evidence.stderr), stderr: evidence.stderr,
                stderrTruncated: evidence.stderrTruncated, elapsedMs: evidence.elapsedMs
            ),
            stdout: Data()
        )
    }

    /// The batched cask oracle. RC1/E8: every token must pass the cask regex (no leading `-`)
    /// before it reaches argv, and `--` always comes before the tokens. A token that fails is
    /// dropped; with no valid token left, no process starts at all.
    static func brewInfoCasks(
        brew: String,
        tokens: [String],
        run: Runner = BoundedProcessRunner.run
    ) async -> QueryOutcome? {
        let validTokens = tokens.filter(PackageNameRules.isValidCaskToken)
        guard !validTokens.isEmpty else {
            return QueryOutcome(
                evidence: ProcessEvidence(
                    executable: sandboxExecutable,
                    arguments: [],
                    termination: .launchFailed("no valid cask tokens"),
                    stderr: "",
                    stderrTruncated: false,
                    elapsedMs: 0
                ),
                stdout: Data()
            )
        }
        return await run(BoundedProcessSpec(
            executable: sandboxExecutable,
            arguments: ["-p", sandboxProfile, brew, "info", "--json=v2", "--cask", "--"] + validTokens,
            environment: .exactly(enricherEnvironment()),
            timeout: 10,
            maxStdoutBytes: 8 * 1024 * 1024
        ))
    }
}
