import XCTest
@testable import DailyUpdate

/// PR-B2c: the follow-ups from the PR-B2 reviews (TIF-11 items 1–3).
/// Each row is `(label, command, exact risks, isUnsafeCheckPathCommand)`.
final class PRB2cClassifierTests: HermeticTestCase {
    private func assertRows(_ rows: [(String, String, Set<CommandRisk>, Bool)], file: StaticString = #filePath, line: UInt = #line) {
        for (label, command, risks, unsafe) in rows {
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, risks, "\(label): \(command)", file: file, line: line)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), unsafe,
                "\(label) check path: \(command)", file: file, line: line)
        }
    }

    /// Item 1 (Security #7 item 11, Code Review probes): what feeds a shell's stdin is modelled
    /// only as a literal `echo`/`printf`; any other producer fails closed.
    func testShellStdinFailsClosedUnlessFedByALiteralEchoOrPrintf() {
        assertRows([
            ("here-string", "sh <<< 'touch m'", [.unparseable], true),
            ("here-string after -s", "bash -s <<< 'touch m'", [.unparseable], true),
            ("cat stage", "echo 'x' | cat | sh", [.unparseable], true),
            ("tee stage", "echo 'x' | tee /dev/null | sh", [.unparseable], true),
            ("hex escape", "echo 'touch\\x20m' | sh", [.unparseable], true),
            ("octal escape", "echo -e 'touch\\0040m' | zsh", [.unparseable], true),
            ("printf escape", "printf 'brew upgrade\\n' | sh", [.unparseable], true),
            ("printf directive", "printf '%s' 'sudo id' | sh", [.unparseable], true),
            ("printf %b", "printf '%b' 'sudo\\x20id' | sh", [.unparseable], true),
            ("expansion", "echo \"$X\" | sh", [.unparseable], true),
            ("glob", "echo * | sh", [.unparseable], true),
            ("substitution argument", "echo <(cat f) | sh", [.unparseable], true),
            ("file producer", "cat install.sh | bash", [.unparseable], true),
            ("process substitution", "cat install.sh > >(sh)", [.unparseable], true),
            ("group producer", "{ echo ok; } | sh", [.chained, .controlFlow, .unparseable], true),
            ("script from substitution", "sh <(printf 'touch m')", [.unparseable], true),
            ("script from redirected substitution", "bash < <(cat f)", [.unparseable], true),
            ("nested", "echo $(cat f | sh)", [.unparseable], true),
            ("fetched then filtered", "curl x | cat | sh", [.remoteScript, .unparseable], true),
            ("guard echo ok", "echo ok | sh", [], false),
            ("guard literal payload is code", "echo 'sudo id' | sh", [.privileged], true),
            ("guard echo -n", "echo -n 'brew upgrade' | sh", [.bulk], true),
            ("guard literal printf", "printf 'touch m' | sh", [], false),
            ("guard literal into substitution", "echo 'sudo id' > >(sh)", [.privileged], true),
            ("guard not a shell", "cat f | grep x", [], false),
            ("guard sh -c ignores stdin", "cat f | sh -c 'echo ok'", [], false),
            ("guard fetched", "curl x | sh", [.remoteScript], true),
            ("guard fetched substitution", "sh <(curl x)", [.remoteScript], true),
        ])
    }

    /// Item 2 (Security #7 item 5): startup and trace-time variables, and any assignment a
    /// shell can see, fail closed.
    func testStartupVariablesAndAssignmentsBeforeAShellFailClosed() {
        assertRows([
            ("ZDOTDIR", "ZDOTDIR=/tmp/x zsh -c 'echo ok'", [.unparseable], true),
            ("SHELLOPTS with PS4", "SHELLOPTS=xtrace PS4='$(sudo id)' bash -c 'echo ok'", [.unparseable], true),
            ("PROMPT_COMMAND", "PROMPT_COMMAND='sudo id' bash -i", [.unparseable], true),
            ("ZDOTDIR before another program", "ZDOTDIR=/tmp/x brew upgrade x", [.unparseable], true),
            ("PS4 export", "export PS4='$(id)'; brew outdated", [.chained, .unparseable], true),
            ("any name before a shell", "FOO=1 sh -c 'echo ok'", [.unparseable], true),
            ("through env", "env FOO=1 bash -c 'echo ok'", [.unparseable], true),
            ("bare assignment earlier", "FOO=1; bash -c 'echo ok'", [.chained, .unparseable], true),
            ("export earlier", "export FOO=1; zsh -c 'echo ok'", [.chained, .unparseable], true),
            ("PATH before a shell", "PATH=/tmp/x:$PATH sh -c 'brew outdated'", [.unparseable], true),
            ("guard allowlisted", "LANG=C HOMEBREW_NO_AUTO_UPDATE=1 sh -c 'echo ok'", [], false),
            ("guard another program's prefix", "FOO=1 curl x | sh", [.remoteScript], true),
            ("guard no shell", "current=$(brew --version); echo \"$current\"", [.chained], false),
            ("guard prefix without a shell", "FOO=1 brew outdated", [], false),
        ])
    }

    /// Item 3 (Security #7 item 8, Code Review probes): an unknown executable may be a wrapper,
    /// so a command word among its arguments fails closed.
    func testUnknownWrappersFailClosed() {
        assertRows([
            ("unknown wrapper shell", "mywrap sh -c 'sudo id'", [.unparseable], true),
            ("xcrun", "xcrun sh -c 'sudo id'", [.unparseable], true),
            ("sandbox-exec", "sandbox-exec -f p.sb sh -c 'sudo id'", [.unparseable], true),
            ("unknown wrapper bulk", "mywrap brew upgrade", [.unparseable], true),
            ("unknown wrapper path", "mywrap /bin/rm -rf /tmp/x", [.unparseable], true),
            ("package-manager exec", "npm exec curl x | sh", [.remoteScript, .unparseable], true),
            ("mise exec", "mise exec -- sudo id", [.unparseable], true),
            ("osascript word", "echo osascript", [], true),
            ("guard known tool", "brew info sudo", [], true),
            ("guard npx verb", "npx skills find", [], false),
            ("guard self-updater", "claude update", [], false),
            ("guard opencode method", "opencode upgrade 1.2.3 --method curl", [], false),
            ("guard option only", "mywrap --shell", [], false),
            ("guard busybox", "busybox sh -c 'echo ok'", [], false),
            ("guard npm run", "npm run build", [], false),
        ])
    }

    /// The update-path row: `mywrap curl x | sh` is a remote script, and is refused.
    func testFetcherBehindAnUnknownWrapperIsARemoteScript() {
        let command = "mywrap curl x | sh"
        XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.remoteScript, .unparseable])
        XCTAssertTrue(ActionCommandPolicy.isRemoteScriptInstaller(command))
        XCTAssertTrue(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"))
        XCTAssertTrue(CommandShapeClassifier.containsPrivilegeCommandWord("osascript -e 'beep'"))
        XCTAssertFalse(CommandShapeClassifier.containsPrivilegeCommandWord("echo ok"))
    }
}
