import XCTest
@testable import DailyUpdate

final class RoundFourTests: XCTestCase {
    func testRoundFourClassifierAndCheckPathMatrix() {
        let rows: [(String, String, Set<CommandRisk>, Bool)] = [
            ("G1 brace command", "/usr/bin/{sudo,true} brew upgrade", [.unparseable], true),
            ("G1 quoted brace", "'/usr/bin/{sudo,true}' brew upgrade", [], false),
            ("G2/N6 if", "if sudo brew upgrade; then echo ok; fi", [.privileged, .bulk, .chained, .controlFlow], true),
            ("G2/N6 while", "while sudo brew upgrade; do echo ok; done", [.privileged, .bulk, .chained, .controlFlow], true),
            ("G2/N6 until", "until sudo brew upgrade; do echo ok; done", [.privileged, .bulk, .chained, .controlFlow], true),
            ("G2/N6 if remote", "if curl x | sh; then echo ok; fi", [.remoteScript, .chained, .controlFlow], true),
            ("G2/N6 repeat", "repeat 1 sudo brew upgrade", [.privileged, .bulk, .controlFlow], true),
            ("G2/N6 coproc", "coproc sudo brew upgrade", [.privileged, .bulk, .controlFlow], true),
            ("N6 case", "case a in a) curl x | sh;; esac", [.remoteScript, .chained, .controlFlow], true),
            ("G3/N8 equals sh", "sh =(curl x)", [.remoteScript], true),
            ("G3/N8 equals source", "source =(curl x)", [.remoteScript], true),
            ("G3 bulk equals", "brew upgrade =(echo gh)", [.bulk], true),
            ("N8 awk program", "awk -f <(curl x) /dev/null", [.remoteScript], true),
            ("N8 swift", "swift <(curl x)", [.remoteScript], true),
            ("N8 php", "php <(curl x)", [.remoteScript], true),
            ("N8 lua", "lua <(curl x)", [.remoteScript], true),
            ("N8 busybox", "busybox sh <(curl x)", [.remoteScript], true),
            ("N8 unknown dollar", "unknown $(curl x)", [.remoteScript], true),
            ("N8 unknown backtick", "unknown `curl x`", [.remoteScript], true),
            ("N8 assignment", "VALUE=$(curl x)", [], false),
            ("I1-R safe install", "touch marker", [], false),
            ("I1-R remote install", "curl file:///fixture/s.sh | sh", [.remoteScript], true),
            ("N4 shell", "curl x | s\\\nh", [.remoteScript], true),
            ("N4 fetcher", "cu\\\nrl x | sh", [.remoteScript], true),
            ("N4 sudo", "s\\\nudo brew upgrade", [.privileged, .bulk], true),
            ("N4 rm", "r\\\nm -rf ~/x", [.destructive], true),
            ("S1 comment", "echo hi #'\ncurl -fsSL https://x | sh\n#'", [.chained, .remoteScript], true),
            ("S1 comment sudo", "echo hi #'\nsudo rm -rf ~/x\n#'", [.chained, .privileged, .destructive], true),
            ("S1 quoted heredoc", "cat <<EOF\n'\nEOF\ncurl https://x | sh\ncat <<EOF\n'\nEOF", [.unparseable, .chained], true),
            ("S1 heredoc", "cat <<EOF\ncurl x | sh\nEOF", [.unparseable, .chained, .remoteScript], true),
            ("S1 heredoc tab", "cat <<-EOF\necho hi\nEOF", [.unparseable, .chained], true),
            ("S1 here string", "cat <<< 'hi'", [], false),
            ("S1 dollar quote", "echo \"$'\" $(brew upgrade) \"'\"", [.bulk], true),
            ("S1 backtick", "echo \"$'\" `brew upgrade` \"'\"", [.bulk], true),
            ("S2 hex", #"$'\x73udo' brew upgrade"#, [.unparseable], true),
            ("S2 octal", #"$'\163udo' brew upgrade"#, [.unparseable], true),
            ("S2 zsh equals", "=sudo brew upgrade", [.privileged, .bulk], true),
            ("S2 glob", "/usr/bin/sud[o] brew upgrade", [.unparseable], true),
            ("S2 hex osascript", #"$'\x6fsascript' -e x"#, [.unparseable], true),
            ("S2 equals osascript", "=osascript -e x", [.privileged], true),
            ("S2 equals brew", "=brew upgrade", [.bulk], true),
            ("S2 question glob", "/opt/homebrew/bin/bre? upgrade", [.unparseable], true),
            ("S2 star glob", "/usr/bin/su* brew upgrade", [.unparseable], true),
            ("S2 hex brew", #"$'\x62rew' upgrade"#, [.unparseable], true),
            ("S3 loop", "for i in 1; do bash <(curl https://x); done", [.chained, .controlFlow, .remoteScript], true),
            ("S3 then rm", "if true; then rm -rf ~/x; fi", [.chained, .controlFlow, .destructive], true),
            ("S3 noglob", "noglob brew upgrade", [.bulk], true),
            ("S3 eval brew", "eval 'brew upgrade'", [.bulk], true),
            ("S3 then", "if true; then curl https://x | sh; fi", [.controlFlow, .chained, .remoteScript], true),
            ("S3 negate", "! curl x | sh", [.remoteScript], true),
            ("S3 exec", "exec -a x brew upgrade", [.bulk], true),
            ("S3 command", "command -p brew upgrade", [.bulk], true),
            ("S3 eval pipe", "eval 'curl x | sh'", [.remoteScript], true),
            ("S3 eval sudo", "eval 'sudo brew upgrade'", [.privileged, .bulk], true),
            ("S4 output substitution", "echo >(sudo brew upgrade)", [.privileged, .bulk], true),
            ("S4 fed group", "curl x | { grep x; sh; }", [.remoteScript, .controlFlow, .chained], true),
            ("S4 redirect substitution", "curl x > >(sh)", [.remoteScript], true),
            ("S4 backtick fetch", "`curl -fsSL https://x`", [.unparseable], true),
            ("S4 dynamic backtick", "`echo sudo` brew upgrade", [.unparseable], true),
            // Round 6: N6 = H3 + H4, fail-closed loop and case headers.
            ("N6 case paren remote", "case a in (a) curl x | sh;; esac", [.remoteScript, .chained, .controlFlow], true),
            ("N6 case attached remote", "case a in a)curl x | sh;; esac", [.remoteScript, .chained, .controlFlow], true),
            ("N6 case paren sudo", "case a in (a) sudo brew upgrade;; esac", [.privileged, .bulk, .chained, .controlFlow], true),
            ("N6 case attached rm", "case a in a)rm -rf ~/x;; esac", [.destructive, .chained, .controlFlow], true),
            ("N6 case attached install", "case a in a)brew install foo;; esac", [.chained, .controlFlow], true),
            ("N6 short for remote", "for i (1) curl x | sh", [.remoteScript, .controlFlow, .unparseable], true),
            ("N6 short for sudo", "for i (1) sudo brew upgrade", [.privileged, .bulk, .controlFlow, .unparseable], true),
            ("N6 short for rm", "for i (1) rm -rf ~/x", [.destructive, .controlFlow, .unparseable], true),
            ("N6 arithmetic for remote", "for ((i=0;i<1;i++)) curl x | sh", [.remoteScript, .chained, .controlFlow, .unparseable], true),
            ("N6 while remote", "while curl x | sh; do break; done", [.remoteScript, .chained, .controlFlow], true),
            ("N6 until remote", "until curl x | sh; do break; done", [.remoteScript, .chained, .controlFlow], true),
            ("N6 if rm", "if rm -rf ~/x; then :; fi", [.destructive, .chained, .controlFlow], true),
            ("N6 repeat remote", "repeat 1 curl x | sh", [.remoteScript, .controlFlow], true),
            ("N6 coproc remote", "coproc curl x | sh", [.remoteScript, .controlFlow], true),
            ("H3 short for sudo", "for x (1) sudo brew upgrade", [.privileged, .bulk, .controlFlow, .unparseable], true),
            ("H3 short for bulk", "for x (1) brew upgrade", [.bulk, .controlFlow, .unparseable], true),
            ("H3 short for remote", "for x (1) curl x | sh", [.remoteScript, .controlFlow, .unparseable], true),
            ("H3 arithmetic for sudo", "for ((i=0;i<1;i++)) sudo /bin/true", [.privileged, .chained, .controlFlow, .unparseable], true),
            ("H3 foreach", "foreach x (1) sudo /bin/true\nend", [.privileged, .chained, .controlFlow, .unparseable], true),
            ("H3 short select", "select x (1) sudo /bin/true", [.privileged, .controlFlow, .unparseable], true),
            ("H4 case paren sudo", "case x in (x) sudo /bin/true;; esac", [.privileged, .chained, .controlFlow], true),
            ("H4 case paren remote", "case x in (x) curl x | sh;; esac", [.remoteScript, .chained, .controlFlow], true),
            ("H4 case paren bulk", "case x in (x) brew upgrade;; esac", [.bulk, .chained, .controlFlow], true),
            ("N6 case malformed header", "case a b in a) echo;; esac", [.chained, .controlFlow, .unparseable], true),
            ("N6 stray paren", "echo a)b", [.unparseable], true),
            ("N6 modelled for", "for p in /A ~/A; do echo $p; done", [.chained, .controlFlow], false),
            ("N6 modelled select", "select x in a b; do echo $x; done", [.chained, .controlFlow], false),
            ("N6 modelled case", "case $x in\na) echo a;;\nesac", [.chained, .controlFlow], false),
            ("N6 modelled case alternatives", "case a in a|b) echo arm;; esac", [.chained, .controlFlow], false),
            // Round 6: H1/H2, brace expansion at or before the executable.
            ("H1 brace range", "/usr/bin/sud{o..o} /bin/true", [.unparseable], true),
            ("H2 brace wrapper argument", "env {A=1,sudo} /bin/true", [.unparseable], true),
            ("H2 brace range assignment", "env A={1..2} /bin/true", [.unparseable], true),
            ("H2 brace assignment", "FOO={a,b} brew upgrade", [.bulk, .unparseable], true),
            ("H2 brace after sudo", "sudo /usr/bin/{a,b} x", [.privileged, .unparseable], true),
            ("H2 brace argument", "echo {a,b}", [], false),
            ("H2 brace loop words", "for x in {1..3}; do echo $x; done", [.chained, .controlFlow], false),
            // Round 6: N8, awk and sed treat a fetched operand as a program.
            ("N8 awk operand", "awk \"$(curl x)\" /dev/null", [.remoteScript], true),
            ("N8 awk after --", "awk -- \"$(curl x)\"", [.remoteScript], true),
            ("N8 sed operand", "sed \"$(curl x)\" /dev/null", [.remoteScript], true),
            ("N8 awk -v", "awk -v a=1 \"$(curl x)\"", [.remoteScript], true),
            ("N8 awk backtick", "awk `curl x`", [.remoteScript], true),
            ("N8 env awk", "env awk \"$(curl x)\"", [.remoteScript], true),
            ("N8 absolute awk", "/usr/bin/awk \"$(curl x)\"", [.remoteScript], true),
            ("N8 sed -e", "sed -e \"$(curl x)\"", [.remoteScript], true),
            ("N8 awk nscurl", "awk \"$(nscurl x)\"", [.remoteScript], true),
            // Round 7 J1: an unquoted `{` or `}` at or before the executable.
            ("J1 brace group bulk", "{brew upgrade}", [.unparseable], true),
            ("J1 brace group sudo", "{sudo /bin/true}", [.unparseable], true),
            ("J1 brace group remote", "{curl x | sh}", [.unparseable], true),
            ("J1 brace group piped", "{curl x} | sh", [.unparseable], true),
            ("J1 brace group after then", "if true; then {sudo /bin/true}; fi", [.chained, .controlFlow, .unparseable], true),
            ("J1 brace group after repeat", "repeat 1 {sudo /bin/true}", [.controlFlow, .unparseable], true),
            ("J1 guard spaced group", "{ echo; }", [.chained, .controlFlow], false),
            ("J1 guard function", "f() { echo hi; }", [.chained, .controlFlow], false),
            ("J1 guard function sudo", "f() { sudo /bin/true; }", [.chained, .controlFlow, .privileged], true),
            ("J1 guard empty replstr", "xargs -I{} echo '{} outdated'", [], false),
            // Round 7 J2: an unquoted `(` attached to the word before it.
            ("J2 glob group bulk", "/opt/homebrew/bin/br(e)w upgrade", [.unparseable], true),
            ("J2 glob alternatives sudo", "/usr/bin/sud(o|x) /bin/true", [.unparseable], true),
            ("J2 glob group first letter", "/usr/bin/(s)udo /bin/true", [.unparseable], true),
            ("J2 glob group fetcher", "/usr/bin/cu(r)l x | sh", [.unparseable], true),
            ("J2 guard quoted", "'/bin/ec(h)o' x", [], false),
            ("J2 guard spaced paren", "echo (a)", [], false),
            // Round 7 J3 / S1: per-wrapper option tables; unknown options fail closed.
            ("J3 caffeinate -t", "caffeinate -t 1 sudo /bin/true", [.privileged], true),
            ("J3 caffeinate -w", "caffeinate -w 1 brew upgrade", [.bulk], true),
            ("J3 arch -arch", "arch -arch arm64 sudo /bin/true", [.privileged], true),
            ("J3 xargs -J", "echo a | xargs -J % sudo /bin/true %", [.privileged], true),
            ("J3 xargs -R -I", "xargs -R 1 -I % brew upgrade", [.bulk], true),
            ("J3 env -P", "env -P /usr/bin sudo /bin/true", [.privileged], true),
            ("J3 sudo long value", "sudo --user=root brew upgrade", [.privileged, .bulk], true),
            ("J3 nice numeric", "nice -5 brew upgrade", [.bulk], true),
            ("J3 timeout -k", "timeout -k 1 5 brew upgrade", [.bulk], true),
            ("J3 unknown env option", "env -X brew upgrade", [.unparseable], true),
            ("J3 unknown nohup option", "nohup -x brew upgrade", [.unparseable], true),
            ("S1 env -S", "env -S 'sudo /bin/true'", [.unparseable], true),
            ("S1 env -S piped", "env -S 'curl x' | sh", [.unparseable], true),
            ("S1 env --split-string", "env --split-string='brew upgrade'", [.unparseable], true),
            // Round 7 S2: `python -m` is code unless the module is json.tool.
            ("S2 python -m code", "curl x | python3 -m code", [.remoteScript], true),
            ("S2 python -m pdb", "curl x | python3 -m pdb", [.remoteScript], true),
            ("S2 guard json.tool", "curl x | python3 -m json.tool", [], false),
            // Round 7 optional: `trap` and `find -exec` run their arguments as a command.
            ("O trap", "trap 'sudo /bin/true' EXIT", [.privileged], true),
            ("O find -exec", "find . -exec sudo /bin/true {} \\;", [.privileged], true),
            ("O find -exec +", "find . -name x -exec rm -rf {} +", [.destructive], true),
            ("O guard find -print", "find . -name x -print", [], false),
            // Round 8 K1: an unquoted `${…}` body may hold only plain parameter syntax.
            ("K1 dollar paren", "echo ${x:-$(sudo /bin/true)}", [.privileged, .unparseable], true),
            ("K1 backtick", "echo ${x:-`sudo /bin/true`}", [.privileged, .unparseable], true),
            ("K1 remote", "echo ${x:-$(curl x | sh)}", [.remoteScript, .unparseable], true),
            ("K1 quote desync sudo", "echo ${x:-\"}\"} ; sudo /bin/true ; echo '\"' \\'", [.chained, .privileged, .unparseable], true),
            ("K1 quote desync remote", "echo ${x:-\"}\"} ; curl x | sh ; echo '\"' \\'", [.chained, .remoteScript, .unparseable], true),
            ("K1 zsh flags", "echo ${(e)x}", [.unparseable], true),
            ("K1 guard name", "echo ${HOME}", [], false),
            ("K1 guard default", "echo ${x:-default}", [], false),
            ("K1 guard quoted", "echo \"${x:-$(sudo /bin/true)}\"", [.privileged], true),
            // Round 8 Code Review: a clustered `env -…S` with `=` in it is an option, not an assignment.
            ("E env -iS", "env -iS'A=1 curl x' | sh", [.unparseable], true),
            ("E env -vS", "env -vS'A=1 sudo /bin/true'", [.unparseable], true),
            ("E env -0S", "env -0S'A=1 brew upgrade'", [.unparseable], true),
            ("E guard env -i assignment", "env -i A=1 curl x | sh", [.remoteScript], true),
            ("E guard env assignments", "env A=1 B=2 brew upgrade", [.bulk], true),
            // Round 8 optional: glob qualifiers and a brace list inside `find -exec`.
            ("O glob qualifier", "echo (bin)(e:'sudo /bin/true':)", [.unparseable], true),
            ("O find -exec brace", "find . -exec {sudo,/bin/true} \\;", [.unparseable], true),
            // Round 9 L1: a `"` inside a double-quoted `${…}` is a nested quote in zsh;
            // the lexer fails closed there and reads nothing after it.
            ("L1 nested quote sudo", "echo \"${x:-\"'\"}\" ; sudo /bin/true ; echo \"${y:-\"'\"}\"", [.unparseable], true),
            ("L1 nested quote remote", "echo \"${x:-\"'\"}\" ; curl x | sh ; echo \"${y:-\"'\"}\"", [.unparseable], true),
            ("L1 nested quote substitution", "echo \"${x:-\"'\"}\"$(sudo /bin/true)\"${y:-\"'\"}\"", [.unparseable], true),
            ("L1 nested quote pattern", "echo \"${x#\"'\"}\" ; sudo /bin/true ; echo \"${y#\"'\"}\"", [.unparseable], true),
            ("L1 nested quote nested", "echo \"${${x:-\"'\"}}\" ; sudo /bin/true ; echo \"${y:-\"'\"}\"", [.unparseable], true),
            ("L1 guard name", "echo \"${HOME}\"", [], false),
            ("L1 guard substitution", "echo \"${x:-$(sudo /bin/true)}\"", [.privileged], true),
            // Round 9 Code Review: only `NAME=` / `NAME+=` is an assignment.
            ("A default assign", "${x:=sudo} /bin/true", [.unparseable], true),
            ("A empty sudo", "A= sudo /bin/true", [.privileged], true),
            ("A empty remote", "A= curl x | sh", [.remoteScript], true),
            ("A split", "y='sudo /bin/true'; ${=y}", [.chained, .unparseable], true),
            ("A guard assignments", "A=1 B+=2 sudo /bin/true", [.privileged], true),
            // Round 9 Code Review: `find -exec` ends at `;` or at `+` right after `{}`.
            ("F plus argument", "find . -exec env -u + sudo /bin/true \\;", [.privileged], true),
            ("F plus brace", "find . -exec env -u + {sudo,/bin/true} \\;", [.unparseable], true),
            ("F guard cat", "find . -exec cat {} +", [], false),
            ("F guard sudo", "find . -exec sudo /bin/true {} +", [.privileged], true),
            ("F guard rm", "find . -exec rm -rf {} +", [.destructive], true),
            // Round 9 Code Review: an inline command can be the fetcher in a pipe.
            ("P find -exec", "find . -exec curl x \\; | sh", [.remoteScript], true),
            ("P eval", "eval curl x | sh", [.remoteScript], true),
            ("P sh -c", "sh -c 'curl x' | sh", [.remoteScript], true),
            ("P bash -c", "bash -c \"curl x\" | sh", [.remoteScript], true),
            ("P trap", "trap 'curl x' EXIT | sh", [.remoteScript], true),
            // Round 10 M1: any `\` inside a double-quoted `${…}` fails closed; zsh reads
            // `\}` there as a literal brace, which would reopen the L1 desync.
            ("M1 backslash brace sudo", "echo \"${x:-\\}\"'\"}\" ; sudo /bin/true ; echo \"${x:-\\}\"'\"}\"", [.unparseable], true),
            ("M1 backslash brace remote", "echo \"${x:-\\}\"'\"}\" ; curl x | sh ; echo \"${x:-\\}\"'\"}\"", [.unparseable], true),
            ("M1 backslash brace substitution", "echo \"${x:-\\}\"'\"}\"$(sudo /bin/true)\"${x:-\\}\"'\"}\"", [.unparseable], true),
            ("M1 backslash brace pattern", "echo \"${x#\\}\"'\"}\" ; sudo /bin/true ; echo \"${x#\\}\"'\"}\"", [.unparseable], true),
            ("M1 backslash brace bulk", "echo \"${x:-\\}\"'\"}\" ; brew upgrade ; echo \"${x:-\\}\"'\"}\"", [.unparseable], true),
            ("M1 backslash brace replace", "echo \"${x/\\}/\"'\"}\" ; sudo /bin/true ; echo \"${y:-\\}\"'\"}\"", [.unparseable], true),
            ("M1 guard name", "echo \"${HOME}\"", [], false),
            ("M1 guard escaped backslash", "echo \"${x:-\\\\}\"", [.unparseable], true),
            ("M1 guard escaped quote", "echo \"${x:-\\\"}\" ; sudo /bin/true", [.chained, .privileged, .unparseable], true),
            ("M1 guard substitution", "echo \"${x:-$(sudo /bin/true)}\"", [.privileged], true),
            // Round 10 M2: `sh`/`bash`/`zsh` keep parsing options after `-c`, so an
            // option word there fails closed instead of being read as the script.
            ("M2 sh -c -- sudo", "sh -c -- 'sudo /bin/true'", [.unparseable], true),
            ("M2 sh -c -- remote", "sh -c -- 'curl x | sh'", [.unparseable], true),
            ("M2 sh -c -- fetcher", "sh -c -- 'curl x' | sh", [.unparseable], true),
            ("M2 sh -c -e", "sh -c -e 'sudo /bin/true'", [.unparseable], true),
            ("M2 bash -c -x", "bash -c -x 'curl x | sh'", [.unparseable], true),
            ("M2 zsh -c -o", "zsh -c -o errexit 'brew upgrade'", [.unparseable], true),
            ("M2 sh -c +x", "sh -c +x 'sudo /bin/true'", [.unparseable], true),
            ("M2 guard sh -c", "sh -c 'sudo /bin/true'", [.privileged], true),
            ("M2 guard sh -ec", "sh -ec 'sudo /bin/true'", [.privileged], true),
            ("M2 guard zsh -fc", "zsh -fc 'sudo /bin/true'", [.privileged], true),
            // Round 11 N1: between the shell and its script flag only `-` clusters of
            // `c e f i l n u v x` are modelled; `-o name`, `-O`, `+c` and `--command` fail closed.
            ("N1 sh -co remote", "sh -co errexit 'curl x | sh'", [.unparseable], true),
            ("N1 sh -co sudo", "sh -co errexit 'sudo /bin/true'", [.unparseable], true),
            ("N1 sh -co fetcher", "sh -co errexit 'curl x' | sh", [.unparseable], true),
            ("N1 sh -ceo", "sh -ceo errexit 'sudo /bin/true'", [.unparseable], true),
            ("N1 sh -xco", "sh -xco errexit 'sudo /bin/true'", [.unparseable], true),
            ("N1 bash -oc", "bash -oc errexit 'sudo /bin/true'", [.unparseable], true),
            ("N1 bash -Oc", "bash -Oc extglob 'curl x | sh'", [.unparseable], true),
            ("N1 bash -cO", "bash -cO extglob 'sudo /bin/true'", [.unparseable], true),
            ("N1 zsh -co bulk", "zsh -co errexit 'brew upgrade'", [.unparseable], true),
            ("N1 zsh -co sudo", "zsh -co errexit 'sudo /bin/true'", [.unparseable], true),
            ("N1 sh +c remote", "sh +c 'curl x | sh'", [.unparseable], true),
            ("N1 sh +c sudo", "sh +c 'sudo /bin/true'", [.unparseable], true),
            ("N1 sh +c fetcher", "sh +c 'curl x' | sh", [.unparseable], true),
            ("N1 env sh +c", "env sh +c 'sudo /bin/true'", [.unparseable], true),
            ("N1 bash +c", "bash +c 'curl x | sh'", [.unparseable], true),
            ("N1 bash +oc", "bash +oc errexit 'sudo /bin/true'", [.unparseable], true),
            ("N1 zsh +c", "zsh +c 'brew upgrade'", [.unparseable], true),
            ("N1 fish --command=", "fish --command='sudo /bin/true'", [.unparseable], true),
            ("N1 fish --command", "fish --command 'curl x | sh'", [.unparseable], true),
            ("N1 fish --init-command=", "fish --init-command='sudo /bin/true'", [.unparseable], true),
            ("N1 fish -C", "fish -C 'sudo /bin/true'", [.unparseable], true),
            ("N1 sh -o -c over-flag", "sh -o errexit -c 'sudo /bin/true'", [.unparseable], true),
            ("N1 guard sh -c", "sh -c 'sudo /bin/true'", [.privileged], true),
            ("N1 guard sh -ec", "sh -ec 'sudo /bin/true'", [.privileged], true),
            ("N1 guard sh -xc", "sh -xc 'sudo /bin/true'", [.privileged], true),
            ("N1 guard zsh -fc", "zsh -fc 'sudo /bin/true'", [.privileged], true),
            ("N1 guard bash -lc", "bash -lc 'sudo /bin/true'", [.privileged], true),
            ("N1 guard fish -c", "fish -c 'sudo /bin/true'", [.privileged], true),
            // Round 10 Code Review: zsh takes a non-ASCII name like `é=1` as an assignment.
            ("A non-ASCII sudo", "é=1 sudo /bin/true", [.privileged], true),
            ("A non-ASCII remote", "é=1 curl x | sh", [.remoteScript], true),
            ("A non-ASCII bulk", "café_2=1 brew upgrade", [.bulk], true),
            ("A guard digit name", "1A=x sudo /bin/true", [], false),
        ]
        for (id, command, expected, unsafe) in rows {
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, expected, "\(id): \(command)")
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), unsafe, id)
        }
        let remoteStages = ["bash -o pipefail", "bash --rcfile /dev/null", "bash +x", "bash -c sh", "lua -", "sh -o errexit", "bash +o posix", "bash -O extglob", "bash +O extglob", "bash --rcfile /tmp/rc", "bash --init-file /tmp/rc", "sh +x", "sh -c 'source /dev/stdin'", "sh -c sh", "php", "lua", "swift -", "busybox sh", "unknown-interpreter", "perl -I/usr/lib/perl5", "perl -Mfeature=say", "ruby -rset", "python3 -Wmodule", "python3 -Xfrozen_modules=off", "python3 -c", "python3 - -c", "python3 script.py -c code",
            // Round 6 N7: only allow-listed clusters that end in the program flag are inline.
            "perl -i.bake -", "perl -0x1e -", "ruby -Ke -", "ruby -i.bake -", "ruby -Fe -", "perl -l0e -", "ruby -xe -",
            "python3 -ic pass", "node -i -e 1"]
        for stage in remoteStages {
            let command = "curl x | \(stage)"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.remoteScript], command)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), true, command)
        }
        for fetcher in ["lwp-request", "lwp-download", "GET", "nscurl", "aria2c", "https", "xh"] {
            let command = "\(fetcher) x | sh"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.remoteScript], "F1: \(command)")
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), true, command)
        }
        let sources: [(String, Set<CommandRisk>)] = [
            ("echo $(curl x)", [.remoteScript]),
            ("echo \"$(curl x)\"", [.remoteScript]),
            ("cat <(curl x)", [.remoteScript]),
            ("cat >(curl x)", [.remoteScript]),
            ("{ curl x; }", [.remoteScript, .controlFlow, .chained]),
            ("{ echo hi; curl x; }", [.remoteScript, .controlFlow, .chained]),
            ("( echo hi; curl x )", [.remoteScript, .chained]),
        ]
        for (source, expected) in sources {
            let command = "\(source) | sh"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, expected, command)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), true, command)
        }
        for filter in ["grep x", "sed 's/a/b/'", "awk '{print $1}'", "head", "tail", "jq .", "cut -c1", "tr a b", "sort", "uniq", "wc", "shasum", "python3 -c 'print(1)'", "python -m json.tool", "node -e 'console.log(1)'", "perl -e 'print 1'", "ruby -e 'puts 1'", "perl -le 'print 1'", "python3 -W ignore -c 'print(1)'"] {
            let command = "curl x | \(filter)"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [], command)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), false, command)
        }
    }
}

extension RoundFourTests {
    @MainActor
    func testMDPinnedRealAppStateNeverRunsRemoteUpdateWithYes() async throws {
        try await withStateFixture { root, store in
            var commands: [String: String] = [:]
            for id in ["ok", "available", "blocked", "failed", "pin-matches"] {
                commands[id] = try remoteScript(root: root, marker: root.appendingPathComponent(id))
            }
            let rows: [(String, String, ItemStatus, [GateReason], BlockReason?)] = [
                ("ok", "echo OK", .upToDate, [], nil),
                ("available", "printf 'UPDATE\\nlatest: 1.3.0\\n'", .gated, [.remoteScript, .pinned], nil),
                ("blocked", commands["blocked"]!, .blocked, [], .unsafeCheckCommand),
                ("failed", "exit 3", .checkFailed, [], nil),
                // Pinned `1.2` matches `v1.2.0` as a version, so the pin does not gate.
                ("pin-matches", "printf 'UPDATE\\nlatest: v1.2.0\\n'", .gated, [.remoteScript], nil),
            ]
            let pins = ["pin-matches": "1.2"]
            store.settings.customItems = rows.map { row in
                DetectorConfig(id: row.0, name: row.0, category: .cli, description: nil, source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil), versionCommand: "echo 1.0.0",
                    checkCommand: row.1, installCommand: nil, updateCommand: commands[row.0]!, workingDirectory: nil)
            }
            for row in rows {
                store.settings.itemPreferences[row.0] = ItemPreference(autoUpdate: false,
                    snoozedUntil: nil, pinnedVersion: pins[row.0] ?? "0.9.0", permanentlyIgnored: false, reviewedCommandHash: nil)
            }
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: rows.map { $0.0 })
            await state.recheckItems(ids: rows.map { $0.0 })
            for row in rows {
                var output: [String] = []
                let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--update", row.0, "--yes"], state: wrapper, output: { output.append($0) })
                XCTAssertNotEqual(exit, 0, row.0)
                let item = try XCTUnwrap(state.items.first { $0.id == row.0 })
                XCTAssertEqual(item.status, row.2, row.0)
                XCTAssertEqual(item.gateReasons, row.3, row.0)
                XCTAssertEqual(item.blockReason, row.4, row.0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(row.0).path), row.0)
            }
        }
    }

    @MainActor
    func testI1ScopedRemoteInstallWithYesRequiresAppConfirmation() async throws {
        try await assertRemoteInstallRefused(arguments: ["--install", "install-fixture", "--yes"])
    }

    @MainActor
    func testI1InstallAllWithYesRequiresAppConfirmation() async throws {
        try await assertRemoteInstallRefused(arguments: ["--install-all", "--yes"])
    }

    @MainActor
    func testI1EqualsSubstitutionInstallRequiresAppConfirmation() async throws {
        try await assertRemoteInstallRefused(arguments: ["--install", "install-fixture", "--yes"], equals: true)
    }

    @MainActor
    func testI1ShortLoopInstallRequiresAppConfirmation() async throws {
        try await assertRemoteInstallRefused(arguments: ["--install", "install-fixture", "--yes"], shortLoop: true)
    }

    @MainActor
    func testI1UnparseableBraceGroupInstallIsRefusedLikeRemoteScript() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let command = try remoteScript(root: root, marker: marker).replacingOccurrences(of: " curl ", with: " {curl ") + "}"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.unparseable])
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--install", "install-fixture", "--yes"], state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2)
            XCTAssertEqual(output, ["Dry-run plan:", "  [Install] Install fixture (install-fixture)", "    \(command)",
                "This install runs a remote script and must be confirmed in the app."])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// Security round 8 (K1): a `$(…)` inside an unquoted `${…}` default is
    /// refused like a remote-script installer and never runs.
    @MainActor
    func testK1ParameterDefaultSubstitutionInstallIsRefused() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let remote = try remoteScript(root: root, marker: marker)
            let command = "export \(remote.components(separatedBy: " curl ")[0]); echo ${x:-$(curl x | sh)}"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.chained, .remoteScript, .unparseable])
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--install", "install-fixture", "--yes"], state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2)
            XCTAssertEqual(output, ["Dry-run plan:", "  [Install] Install fixture (install-fixture)", "    \(command)",
                "This install runs a remote script and must be confirmed in the app."])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// Security round 9 (L1): a `"` inside a double-quoted `${…}` cannot
    /// hide a remote-script installer from the refusal.
    @MainActor
    func testL1NestedQuoteInParameterInstallIsRefused() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let remote = try remoteScript(root: root, marker: marker)
            let command = "export \(remote.components(separatedBy: " curl ")[0]); echo \"${x:-\"'\"}\" ; curl x | sh ; echo \"${y:-\"'\"}\""
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.chained, .unparseable])
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--install", "install-fixture", "--yes"], state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2)
            XCTAssertEqual(output, ["Dry-run plan:", "  [Install] Install fixture (install-fixture)", "    \(command)",
                "This install runs a remote script and must be confirmed in the app."])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// Security round 10 (M1): a `\}` inside a double-quoted `${…}` cannot
    /// hide a remote-script installer from the refusal.
    @MainActor
    func testM1BackslashBraceInParameterInstallIsRefused() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let remote = try remoteScript(root: root, marker: marker)
            let command = "export \(remote.components(separatedBy: " curl ")[0]); echo \"${x:-\\}\"'\"}\" ; curl x | sh ; echo \"${x:-\\}\"'\"}\""
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.chained, .unparseable])
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--install", "install-fixture", "--yes"], state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2)
            XCTAssertEqual(output, ["Dry-run plan:", "  [Install] Install fixture (install-fixture)", "    \(command)",
                "This install runs a remote script and must be confirmed in the app."])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// Security round 10 (M2): `sh -c --` cannot hide a remote-script
    /// installer from the refusal.
    @MainActor
    func testM2ShellOptionAfterDashCInstallIsRefused() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let remote = try remoteScript(root: root, marker: marker)
            let command = "export \(remote.components(separatedBy: " curl ")[0]); sh -c -- 'curl x | sh'"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.chained, .unparseable])
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--install", "install-fixture", "--yes"], state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2)
            XCTAssertEqual(output, ["Dry-run plan:", "  [Install] Install fixture (install-fixture)", "    \(command)",
                "This install runs a remote script and must be confirmed in the app."])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// Security round 11 (N1): `sh -co errexit` cannot hide a remote-script
    /// installer from the refusal.
    @MainActor
    func testN1ClusteredOptionBeforeDashCInstallIsRefused() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let remote = try remoteScript(root: root, marker: marker)
            let command = "export \(remote.components(separatedBy: " curl ")[0]); sh -co errexit 'curl x | sh'"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.chained, .unparseable])
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--install", "install-fixture", "--yes"], state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2)
            XCTAssertEqual(output, ["Dry-run plan:", "  [Install] Install fixture (install-fixture)", "    \(command)",
                "This install runs a remote script and must be confirmed in the app."])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// Security round 11 (N1): `sh +c` cannot hide a remote-script
    /// installer from the refusal.
    @MainActor
    func testN1PlusCInstallIsRefused() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let remote = try remoteScript(root: root, marker: marker)
            let command = "export \(remote.components(separatedBy: " curl ")[0]); sh +c 'curl x | sh'"
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, [.chained, .unparseable])
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--install", "install-fixture", "--yes"], state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2)
            XCTAssertEqual(output, ["Dry-run plan:", "  [Install] Install fixture (install-fixture)", "    \(command)",
                "This install runs a remote script and must be confirmed in the app."])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// QA round 6: the short loop, the `(a)` case arm and a brace-expanded
    /// fetcher all refuse on one path, with one message and exit 2, even
    /// after the command was reviewed.
    @MainActor
    func testRemoteAndUnparseableCustomUpdatesRefuseOnOnePath() async throws {
        try await withStateFixture { root, store in
            var commands: [String: String] = [:]
            for id in ["short-loop", "case-arm", "brace-fetcher"] {
                let pipeline = try remoteScript(root: root, marker: root.appendingPathComponent(id))
                commands[id] = id == "short-loop" ? "for x (1) \(pipeline)"
                    : id == "case-arm" ? "case a in (a) \(pipeline);; esac"
                    : pipeline.replacingOccurrences(of: "curl -fsSL", with: "{curl,-fsSL}")
            }
            let ids = ["short-loop", "case-arm", "brace-fetcher"]
            store.settings.customItems = ids.map { id in
                DetectorConfig(id: id, name: id, category: .cli, description: nil, source: .user,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil), versionCommand: "echo 1.0.0",
                    checkCommand: "printf 'UPDATE\\nlatest: 1.3.0\\n'", installCommand: nil, updateCommand: commands[id]!, workingDirectory: nil)
            }
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ids)
            await state.recheckItems(ids: ids)
            for id in ids {
                var output: [String] = []
                let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--update", id, "--yes"], state: wrapper, output: { output.append($0) })
                XCTAssertEqual(exit, 2, id)
                XCTAssertEqual(output, ["Dry-run plan:", "  [Update] \(id) (\(id))", "    \(commands[id]!)",
                    "This update runs a remote script and must be confirmed in the app."], id)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path), id)
            }
        }
    }

    func testPinsUseVersionEquality() {
        XCTAssertTrue(GatePolicy.versionsMatch("v1.2.0", "1.2"))
        XCTAssertFalse(GatePolicy.versionsMatch("1.2.0-rc.1", "1.2.0"))
        XCTAssertTrue(GatePolicy.versionsMatch("abc123", "abc123"))
        XCTAssertFalse(GatePolicy.versionsMatch("abc123", "def456"))
    }

    @MainActor
    func testI1RMixedBatchInstallsSafeItemAndSkipsRemote() async throws {
        try await withStateFixture { root, store in
            let safeMarker = root.appendingPathComponent("safe-installed")
            let remoteMarker = root.appendingPathComponent("remote-installed")
            let remote = try remoteScript(root: root, marker: remoteMarker)
            store.settings.customItems = [("safe", "touch \(ShellEscaping.quote(safeMarker.path))"), ("remote", remote)].map { id, command in
                DetectorConfig(id: id, name: id, category: .cli, description: nil, source: .user,
                    detect: DetectRule(type: .command, paths: nil,
                        command: "test -f \(ShellEscaping.quote((id == "safe" ? safeMarker : remoteMarker).path))", appName: nil),
                    versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command,
                    updateCommand: "echo update", workingDirectory: nil)
            }
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["safe", "remote"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--install-all", "--yes"], state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 0, "\(output)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: safeMarker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: remoteMarker.path))
            XCTAssertEqual(output.filter { $0.hasPrefix("skipped ") }, ["skipped remote: remote-script install must be confirmed in the app"])
        }
    }

    @MainActor
    func testRunSelectedActionsDropsPreselectedRemoteInstaller() async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("remote-installed")
            store.settings.customItems = [DetectorConfig(id: "remote", name: "remote", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: try remoteScript(root: root, marker: marker),
                updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            // Selection bypasses the install policy, so only runSelectedActions can drop it.
            let wrapper = FixtureCLIState(state, ids: ["remote"], forceSelected: ["remote"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate", "--update-all", "--yes"], state: wrapper, output: { output.append($0) })
            // Nothing ran and the only candidate was a remote installer: exit 2.
            XCTAssertEqual(exit, 2, "\(output)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertEqual(output, ["skipped remote: remote-script install must be confirmed in the app", "No matching items found."])
            XCTAssertEqual(state.items.filter(\.isSelected).map(\.id), [])
        }
    }

    @MainActor
    private func assertRemoteInstallRefused(arguments: [String], equals: Bool = false, shortLoop: Bool = false) async throws {
        try await withStateFixture { root, store in
            let marker = root.appendingPathComponent("installed")
            let pipeline = try remoteScript(root: root, marker: marker)
            let command = equals ? "sh =(\(pipeline.replacingOccurrences(of: " | sh", with: "")))"
                : shortLoop ? "for x (1) \(pipeline)" : pipeline
            store.settings.customItems = [DetectorConfig(id: "install-fixture", name: "Install fixture", category: .cli, description: nil,
                source: .user, detect: DetectRule(type: .command, paths: nil, command: "false", appName: nil),
                versionCommand: "echo 1.0.0", checkCommand: "echo OK", installCommand: command, updateCommand: "echo update", workingDirectory: nil)]
            let state = AppState(settingsStore: store)
            state.notificationsEnabled = false
            let wrapper = FixtureCLIState(state, ids: ["install-fixture"])
            var output: [String] = []
            let exit = await CLIRunner.run(arguments: ["DailyUpdate"] + arguments, state: wrapper, output: { output.append($0) })
            XCTAssertEqual(exit, 2, "\(output)")
            XCTAssertTrue(output.joined(separator: "\n").contains("confirmed in the app"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    private func remoteScript(root: URL, marker: URL) throws -> String {
        let script = root.appendingPathComponent("\(marker.lastPathComponent).sh")
        try "touch \(ShellEscaping.quote(marker.path))\n".write(to: script, atomically: true, encoding: .utf8)
        let stubDirectory = root.appendingPathComponent("stub-\(marker.lastPathComponent)")
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        let stub = stubDirectory.appendingPathComponent("curl")
        try "#!/bin/sh\n/bin/cat \(ShellEscaping.quote(script.path))\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return "PATH=\(ShellEscaping.quote(stubDirectory.path)):$PATH curl -fsSL file://\(script.path) | sh"
    }

    @MainActor
    private func withStateFixture(_ operation: (URL, UserSettingsStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigLoader.setAppSupportDirectoryForTesting(root)
        defer {
            ConfigLoader.setAppSupportDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }
        try await operation(root, UserSettingsStore())
    }
}

@MainActor
private final class FixtureCLIState: CLIRunnerState {
    let state: AppState
    let ids: [String]
    let forceSelected: [String]
    init(_ state: AppState, ids: [String], forceSelected: [String] = []) {
        self.state = state
        self.ids = ids
        self.forceSelected = forceSelected
        state.items = state.items.filter { ids.contains($0.id) }
        // Review is independent of the non-liftable remote-script and pin gates.
        for id in ids { state.markCommandReviewed(id: id) }
    }
    var items: [UpdateItem] { state.items }
    var confirmBeforeUpdate: Bool { state.confirmBeforeUpdate }
    var selectedActionableItems: [UpdateItem] { state.selectedActionableItems }
    func checkAll() async { await state.recheckItems(ids: ids) }
    func selectAllInstallable() { state.selectAllInstallable() }
    func selectAllUpdates(limitTo ids: [String]?) {
        state.selectAllUpdates(limitTo: ids)
        for id in forceSelected { state.setSelection(for: id, selected: true) }
    }
    func deselectAll(limitTo ids: [String]?) { state.deselectAll(limitTo: ids) }
    func setSelection(for id: String, selected: Bool) { state.setSelection(for: id, selected: selected) }
    func updateSelected(skipDryRun: Bool, explicitTargetIDs: [String]?) async {
        await state.updateSelected(skipDryRun: skipDryRun, explicitTargetIDs: explicitTargetIDs)
    }
}
