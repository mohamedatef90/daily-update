import XCTest
@testable import DailyUpdate

/// PR-B2a: the classifier and lexer items deferred from Phase 1 (TIF-10 items 2, 3 and 5–11).
/// Each row is `(label, command, exact risks, isUnsafeCheckPathCommand)`.
final class PRB2aClassifierTests: HermeticTestCase {
    private func assertRows(_ rows: [(String, String, Set<CommandRisk>, Bool)], file: StaticString = #filePath, line: UInt = #line) {
        for (label, command, risks, unsafe) in rows {
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, risks, "\(label): \(command)", file: file, line: line)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), unsafe,
                "\(label) check path: \(command)", file: file, line: line)
        }
    }

    /// Item 2 (Code Review NIT 1): fish's `-c` takes a value, so in `-ci` fish runs `i`.
    func testFishClusterWhereCIsNotLastFailsClosed() {
        assertRows([
            ("fish -ci", "fish -ci 'echo ok'", [.unparseable], true),
            ("fish -cx", "fish -cx 'sudo /bin/true'", [.unparseable], true),
            ("fish -lci", "fish -lci 'brew upgrade'", [.unparseable], true),
            ("guard fish -ic", "fish -ic 'sudo /bin/true'", [.privileged], true),
            ("guard fish -c", "fish -c 'echo ok'", [], false),
            ("guard bash -ci", "bash -ci 'sudo /bin/true'", [.privileged], true),
        ])
    }

    /// Item 3 (round-14 NIT): inside a `{ … }` group, `}` ends a `>&N` target; zsh prints `x`.
    func testDupTargetBeforeClosingBraceEndsTheGroup() {
        assertRows([
            ("group dup", "{ echo x >&2}", [.controlFlow], false),
            ("group dup sudo", "{ sudo /bin/true >&2}", [.controlFlow, .privileged], true),
            ("group dup then more", "{ echo x >&2}; echo y", [.controlFlow, .chained], false),
            ("guard outside a group", "echo x >&2}", [.unparseable], true),
            ("guard spaced group", "{ echo x >&2; }", [.chained, .controlFlow], false),
            ("guard subshell", "(echo x >&2})", [.unparseable], true),
        ])
    }

    /// Item 5 (Security): bash expands `BASH_ENV`, and `sh -i` expands `ENV`, before it runs anything.
    func testBashEnvAndEnvAssignmentsFailClosed() {
        assertRows([
            ("BASH_ENV prefix", "BASH_ENV='$(sudo /bin/true)' bash -c 'echo ok'", [.unparseable], true),
            ("ENV prefix", "ENV='$(sudo /bin/true)' sh -i", [.unparseable], true),
            ("BASH_ENV through env", "env BASH_ENV='$(sudo /bin/true)' bash -c 'echo ok'", [.unparseable], true),
            ("ENV through env -i", "env -i ENV='$(sudo /bin/true)' sh -i", [.unparseable], true),
            ("BASH_ENV export", "export BASH_ENV='$(sudo /bin/true)'; bash -c 'echo ok'", [.chained, .unparseable], true),
            ("ENV assign then export", "ENV='$(sudo /bin/true)'; export ENV; sh -i", [.chained, .unparseable], true),
            ("BASH_ENV typeset", "typeset -x BASH_ENV='$(sudo /bin/true)'; bash -c 'echo ok'", [.chained, .unparseable], true),
            ("BASH_ENV declare", "declare -x BASH_ENV=/tmp/rc; bash -c 'echo ok'", [.chained, .unparseable], true),
            ("BASH_ENV append", "BASH_ENV+=x bash -c 'echo ok'", [.unparseable], true),
            ("guard other name", "FOO='$(sudo /bin/true)' bash -c 'echo ok'", [], false),
            ("guard longer name", "ENVIRONMENT=1 sh -c 'echo ok'", [], false),
            ("guard word ENV", "echo ENV BASH_ENV", [], false),
            ("guard export other", "export PATH=/usr/bin:$PATH; echo ok", [.chained], false),
        ])
    }

    /// Item 6 (Security, optional): zsh counts a bare `{` inside a quoted `${…}` too.
    func testBareBraceInsideQuotedParameterFailsClosed() {
        assertRows([
            ("bare brace in default", "echo \"${x:-a{b}\"", [.unparseable], true),
            ("bare brace before sudo", "echo \"${x:-{}\" sudo /bin/true", [.unparseable], true),
            ("guard plain parameter", "echo \"${HOME}\"", [], false),
            ("guard nested parameter", "echo \"${a:-${b}}\"", [], false),
            ("guard brace outside parameter", "echo \"{a}\"", [], false),
            ("guard unquoted parameter", "echo ${HOME}", [], false),
        ])
    }

    /// Item 7 (Security): `/bin/csh` and `/bin/tcsh` ship with macOS and take `-c`.
    func testCshAndTcshAreShells() {
        assertRows([
            ("csh -c remote", "csh -c 'curl x | sh'", [.remoteScript], true),
            ("tcsh -c sudo", "tcsh -c 'sudo /bin/true'", [.privileged], true),
            ("csh -fc bulk", "/bin/csh -fc 'brew upgrade'", [.bulk], true),
            ("tcsh unknown option", "tcsh -X -c 'sudo /bin/true'", [.unparseable], true),
            ("csh reads stdin", "curl x | csh", [.remoteScript], true),
            ("guard csh script file", "csh script.csh", [], false),
        ])
    }

    /// Item 8 (Security): `taskpolicy` and `script` are modelled wrappers, and on the check
    /// path any word that normalizes to a privilege command is unsafe, whatever wraps it.
    func testExecWrappersAndCheckPathPrivilegeWords() {
        assertRows([
            ("taskpolicy sudo", "taskpolicy -c utility sudo /bin/true", [.privileged], true),
            ("taskpolicy clustered", "taskpolicy -bx brew upgrade", [.bulk], true),
            ("taskpolicy remote", "taskpolicy -b curl x | sh", [.remoteScript], true),
            ("taskpolicy unknown option", "taskpolicy -z sudo /bin/true", [.unparseable], true),
            ("script sudo", "script -q /dev/null sudo /bin/true", [.privileged], true),
            ("script bulk", "script -q -t 0 /dev/null brew upgrade", [.bulk], true),
            ("script unknown option", "script -Z /dev/null sudo /bin/true", [.unparseable], true),
            ("unknown wrapper sudo", "mywrap sudo /bin/true", [], true),
            ("unknown wrapper doas", "mywrap -x doas id", [], true),
            ("unknown wrapper path sudo", "mywrap /usr/bin/sudo -n true", [], true),
            ("unknown wrapper pkexec", "mywrap --flag pkexec id", [], true),
            ("unknown wrapper su", "mywrap su -c id", [], true),
            ("unknown wrapper nested", "echo $(mywrap sudo id)", [], true),
            ("guard sudoers path", "grep -c x /etc/sudoers", [], false),
            ("guard suffix word", "echo pseudo sudoku", [], false),
        ])
    }

    /// Item 9 (Code Review): zsh glob qualifiers run code when a string becomes a pattern.
    func testGlobSubstFormsFailClosed() {
        assertRows([
            ("${~x}", "x='/(e:sudo /bin/true:)'; echo ${~x}", [.chained, .unparseable], true),
            ("$~x", "echo $~x", [.unparseable], true),
            ("${=~x}", "echo ${=~x}", [.unparseable], true),
            ("${^~x}", "echo ${^~x}", [.unparseable], true),
            ("setopt globsubst", "setopt globsubst; echo $x", [.chained, .unparseable], true),
            ("setopt GLOB_SUBST", "setopt GLOB_SUBST; echo $x", [.chained, .unparseable], true),
            ("setopt glob_subst", "setopt nullglob glob_subst; echo $x", [.chained, .unparseable], true),
            ("unsetopt noglobsubst", "unsetopt noglobsubst; echo $x", [.chained, .unparseable], true),
            ("set -o globsubst", "set -o globsubst; echo $x", [.chained, .unparseable], true),
            ("emulate sh", "emulate sh; echo $x", [.chained, .unparseable], true),
            ("emulate -c", "emulate ksh -c 'echo $x'", [.unparseable], true),
            ("options array", "options[globsubst]=on; echo $x", [.chained, .unparseable], true),
            ("guard tilde default", "echo ${HOME:-~}", [], false),
            ("guard quoted tilde", "echo \"${~x}\"", [], false),
            ("guard other option", "setopt nullglob; echo ok", [.chained], false),
            ("guard emulate zsh", "emulate -L zsh; echo ok", [.chained], false),
        ])
    }

    /// Item 10 (Security): `-s` reads the script from stdin; words after it are positional parameters.
    func testDashSReadsStdinAndTakesPositionalParameters() {
        assertRows([
            ("rustup install", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y", [.remoteScript], true),
            ("bash -s --", "curl x | bash -s -- --yes", [.remoteScript], true),
            ("sh -s", "curl x | sh -s", [.remoteScript], true),
            ("sh -s operand", "curl x | sh -s arg", [.remoteScript], true),
            ("zsh -es --", "curl x | zsh -es -- -y", [.remoteScript], true),
            ("positional -c", "sh -s -- -c 'sudo /bin/true'", [], false),
            ("-sc is -c", "sh -sc 'sudo /bin/true'", [.privileged], true),
            ("-s then -c", "bash -s -c 'sudo /bin/true'", [.privileged], true),
            ("-s then -o", "curl x | sh -s -o errexit", [.remoteScript, .unparseable], true),
            ("fish has no -s", "curl x | fish -s", [.remoteScript, .unparseable], true),
            ("guard -- without -s", "sh -- x.sh", [.unparseable], true),
        ])
    }

    /// Item 11 (Security): text printed into a shell is code, through `|` and `> >(…)` alike.
    func testEchoedCodeIntoAShellIsClassified() {
        assertRows([
            ("echo into proc sub", "echo 'sudo /bin/true' > >(sh)", [.privileged], true),
            ("echo into pipe", "echo 'sudo /bin/true' | sh", [.privileged], true),
            ("echo remote into pipe", "echo 'curl x | sh' | bash", [.remoteScript], true),
            ("echo remote into proc sub", "echo 'curl x | sh' > >(bash -s)", [.remoteScript], true),
            ("printf format", "printf 'brew upgrade\\n' | sh", [.bulk], true),
            ("printf argument", "printf '%s\\n' 'brew upgrade' | zsh", [.bulk], true),
            ("echo -n", "echo -n 'rm -rf ~/x' | sh", [.destructive], true),
            ("echo variable", "echo \"$x\" | sh", [.unparseable], true),
            ("pipe and", "echo 'sudo id' |& sh", [.privileged], true),
            ("guard plain text", "echo ok | sh", [], false),
            ("guard filter", "echo 'brew upgrade' | grep brew", [], false),
            ("guard script operand", "echo 'sudo /bin/true' | sh script.sh", [], false),
            ("guard sh -c", "echo 'sudo /bin/true' | sh -c 'cat'", [], false),
            ("guard proc sub filter", "echo 'brew upgrade' > >(cat)", [], false),
        ])
    }
}
