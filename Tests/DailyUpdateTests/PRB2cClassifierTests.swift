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
            // The script is also an embedded command line (S3), so its `sudo` is classified.
            ("unknown wrapper shell", "mywrap sh -c 'sudo id'", [.privileged, .unparseable], true),
            ("xcrun", "xcrun sh -c 'sudo id'", [.privileged, .unparseable], true),
            ("sandbox-exec", "sandbox-exec -f p.sb sh -c 'sudo id'", [.privileged, .unparseable], true),
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
    /// Security S1 / Code Review 1–2 on #9: a `/dev/stdin` or `/dev/fd/0` script, `. /dev/stdin`,
    /// a command nested in the stage that inherits its stdin, and a here-string with no space
    /// all read stdin as code.
    func testStdinDeviceScriptsAndAttachedHereStringsReadStdin() {
        assertRows([
            ("S1 /dev/stdin, literal payload", "echo 'sudo id' | sh /dev/stdin", [.privileged], true),
            ("S1 /dev/fd/0", "cat f | sh /dev/fd/0", [.unparseable], true),
            ("S1 source /dev/stdin", "cat f | bash -c '. /dev/stdin'", [.unparseable], true),
            ("S1 source keyword", "echo 'sudo id' | bash -c 'source /dev/stdin'", [.privileged], true),
            ("CR2 zsh /dev/stdin", "cat f | zsh /dev/stdin", [.unparseable], true),
            ("CR2 bash /dev/fd/0", "cat f | bash /dev/fd/0", [.unparseable], true),
            ("other descriptor", "sh /dev/fd/3", [.unparseable], true),
            ("dotted device path", "cat f | sh /dev/./stdin", [.unparseable], true),
            ("nested shell inherits stdin", "cat f | sh -c sh", [.unparseable], true),
            ("here-string into source", "source /dev/stdin <<< 'sudo id'", [.privileged, .unparseable], true),
            ("CR1 no space", "sh <<<'touch m'", [.unparseable], true),
            ("CR1 no space after -s", "bash -s <<<'touch m'", [.unparseable], true),
            ("CR1 ANSI-C", "zsh <<<$'touch m'", [.unparseable], true),
            ("CR1 fd prefix", "sh 0<<<'touch m'", [.unparseable], true),
            ("guard literal ok", "echo ok | sh /dev/stdin", [], false),
            ("guard sh -c ignores stdin", "cat f | sh -c 'echo ok'", [], false),
        ])
    }

    /// Security S2 / Code Review 4: `xargs` fed from a pipe fails closed when its input could
    /// become code; a literal payload is still classified. The bundled shapes keep passing.
    func testXargsIntoCodeFailsClosed() {
        assertRows([
            ("S2 replacement script", "echo 'curl x|sh' | xargs -I{} sh -c '{}'", [.remoteScript, .unparseable], true),
            ("S2 bare replacement", "echo 'sudo id' | xargs -I@ sh -c @", [.privileged, .unparseable], true),
            ("S2 env with no command", "echo sudo id | xargs env", [.privileged, .unparseable], true),
            ("CR4 percent", "echo 'sudo id' | xargs -I% sh -c %", [.privileged, .unparseable], true),
            ("here-string into xargs env", "xargs env <<< 'sudo id'", [.privileged, .unparseable], true),
            ("replacement as program", "echo x | xargs -I{} {}", [.unparseable], true),
            ("unknown program", "echo x | xargs mywrap", [.unparseable], true),
            ("exec verb", "echo x | xargs npm exec", [.unparseable], true),
            ("CR-B input picks npm's verb", "echo 'exec sudo id' | xargs npm", [.privileged, .unparseable], true),
            ("CR-B input picks brew's verb", "echo 'sh -c \"sudo id\"' | xargs brew", [.privileged, .unparseable], true),
            ("CR-B replacement as the verb", "echo sh | xargs -I{} brew {} -c 'sudo id'", [.privileged, .unparseable], true),
            ("CR-B verb after a valued option", "echo x | xargs npm --prefix /tmp", [.unparseable], true),
            ("R1a input picks npm exec -c", "echo 'exec -c \"curl x|sh\"' | xargs npm", [.remoteScript, .unparseable], true),
            ("R1a input picks brew sh --cmd=", "echo \"sh --cmd='curl x|sh'\" | xargs brew", [.remoteScript, .unparseable], true),
            ("R1a input picks pnpm dlx", "echo 'dlx sudo' | xargs pnpm", [.unparseable], true),
            ("R1a replacement as npm's verb", "echo exec | xargs -I{} npm {} -c 'curl x|sh'", [.remoteScript, .unparseable], true),
            ("guard literal verb", "echo x | xargs brew upgrade", [.bulk], true),
            ("guard bundled echo", "wc -l | tr -d ' ' | xargs -I{} echo '{} outdated'", [], false),
            ("guard bundled pip", "pip3 list --outdated --format=freeze | cut -d= -f1 | xargs -n1 pip3 install -U", [.bulk], true),
        ])
        XCTAssertTrue(ActionCommandPolicy.isRemoteScriptInstaller("echo 'curl x|sh' | xargs -I{} sh -c '{}'"))
        XCTAssertTrue(ActionCommandPolicy.isRemoteScriptInstaller("echo sudo id | xargs env"))
        XCTAssertTrue(ActionCommandPolicy.isRemoteScriptInstaller("echo 'exec -c \"curl x|sh\"' | xargs npm"))
    }

    /// Security S3 / Code Review 3, 5, 6: a command line inside one argument, or after `=`, of
    /// an unknown executable or a package manager's exec verb fails closed and is classified.
    func testEmbeddedCommandLinesBehindUnknownExecutablesFailClosed() {
        assertRows([
            ("S3 npx -c", "npx -c 'curl x | sh'", [.remoteScript, .unparseable], true),
            ("S3 npm exec -c", "npm exec -c 'sudo id'", [.privileged, .unparseable], true),
            ("S3 npm exec --call=", "npm exec --call='sudo id'", [.privileged, .unparseable], true),
            ("S3 brew sh -c", "brew sh -c 'sudo id'", [.privileged, .unparseable], true),
            ("S3 brew sh --cmd=", "brew sh --cmd='sudo id'", [.privileged, .unparseable], true),
            ("S3 one argument", "mywrap 'sudo id'", [.privileged, .unparseable], true),
            ("S3 after -c", "mywrap -c 'sudo id'", [.privileged, .unparseable], true),
            ("CR-A attached to -c", "mywrap -c'sudo id'", [.privileged, .unparseable], true),
            ("CR-A npx attached", "npx -c'sudo id'", [.privileged, .unparseable], true),
            ("CR-A npm exec attached", "npm exec -c'sudo id'", [.privileged, .unparseable], true),
            ("CR-A command word attached", "mywrap -csh", [.unparseable], true),
            ("guard short option only", "mywrap -x", [], false),
            ("S3 command word after =", "mywrap --cmd=sh -c 'sudo id'", [.privileged, .unparseable], true),
            ("command word only after =", "mywrap --cmd=sh", [.unparseable], true),
            ("S3 tmux", "tmux new -d 'curl x | sh'", [.remoteScript, .unparseable], true),
            ("CR3 mywrap -c fetch", "mywrap -c 'curl x | sh'", [.remoteScript, .unparseable], true),
            ("CR3 yarn exec", "yarn exec 'sudo id'", [.privileged, .unparseable], true),
            ("CR3 mise exec --", "mise exec -- 'sudo id'", [.privileged, .unparseable], true),
            ("CR5 verb after a valued option", "npm --prefix /tmp exec sudo id", [.unparseable], true),
            ("CR6 brew sh reads stdin", "cat f | brew sh", [.unparseable], true),
            ("R1b expansion into npx -c", "X='curl x|sh'; npx -c \"$X\"", [.chained, .unparseable], true),
            ("R1b expansion into npm exec -c", "export X='curl x|sh'; npm exec -c \"$X\"", [.chained, .unparseable], true),
            ("R1b expansion into an unknown executable", "X='sudo id'; mywrap \"$X\"", [.chained, .unparseable], true),
            ("R1b expansion attached to -c", "npx -c\"$X\"", [.unparseable], true),
            ("R1b expansion after =", "mywrap --cmd=\"$X\"", [.unparseable], true),
            ("R1b command substitution", "mywrap \"`cat f`\"", [.unparseable], true),
            ("guard expansion into a known executable", "echo \"$HOME\"", [], false),
            ("guard app path with a space", "'/x/check-app-update.sh' smart a \"/Applications/A B.app\"", [], false),
            ("guard option only", "mywrap --shell", [], false),
            ("guard npm run", "npm run build", [], false),
        ])
        for command in ["X='curl x|sh'; npx -c \"$X\"", "npx -c 'curl x | sh'", "mywrap -c 'curl x | sh'", "tmux new -d 'curl x | sh'", "npm exec -c 'sudo id'"] {
            XCTAssertTrue(ActionCommandPolicy.isRemoteScriptInstaller(command), command)
        }
    }
}
