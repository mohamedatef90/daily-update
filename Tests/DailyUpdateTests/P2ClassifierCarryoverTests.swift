import XCTest
@testable import DailyUpdate

/// P2-0 (TIF-26): the classifier carry-overs from ADR-002 §6 and Amendment 1 (RC7), fixture
/// matrix X. Each row is `(label, command, exact risks, isUnsafeCheckPathCommand)`; the
/// remote-script installer flag is `remoteScript || unparseable`, and is asserted too.
final class P2ClassifierCarryoverTests: HermeticTestCase {
    private func assertRows(_ rows: [(String, String, Set<CommandRisk>, Bool)], file: StaticString = #filePath, line: UInt = #line) {
        for (label, command, risks, unsafe) in rows {
            XCTAssertEqual(CommandShapeClassifier.classify(command).risks, risks, "\(label): \(command)", file: file, line: line)
            XCTAssertEqual(GatePolicy.isUnsafeCheckPathCommand(checkCommand: command, updateCommand: "never-run"), unsafe,
                "\(label) check path: \(command)", file: file, line: line)
            XCTAssertEqual(ActionCommandPolicy.isRemoteScriptInstaller(command),
                risks.contains(.remoteScript) || risks.contains(.unparseable), "\(label) remote: \(command)", file: file, line: line)
        }
    }

    /// X1–X4: a package runner downloads a package and runs it, pinned or not, through
    /// wrappers and absolute paths.
    func testDownloadThenRunIsARemoteScript() {
        assertRows([
            ("X1 npx", "npx cowsay", [.remoteScript], true),
            ("X1 pinned scoped", "npx -y @scope/pkg@1.2.3", [.remoteScript], true),
            ("X1 env", "env npx x", [.remoteScript], true),
            ("X1 absolute path", "/usr/local/bin/npx x", [.remoteScript], true),
            ("X1 command", "command npx x", [.remoteScript], true),
            ("X1 caffeinate", "caffeinate -i npx x", [.remoteScript], true),
            ("X1 nice", "nice -n 5 npx x", [.remoteScript], true),
            ("X1 sudo", "sudo npx x", [.privileged, .remoteScript], true),
            ("X1 nested", "echo $(npx x)", [.remoteScript], true),
            ("X2 npx -p", "npx -p pkg cmd", [.remoteScript], true),
            ("X2 npm exec --", "npm exec -- pkg", [.remoteScript], true),
            ("X2 npm x", "npm x pkg", [.remoteScript], true),
            ("X2 npm option before exec", "npm --prefix /tmp/p exec pkg", [.remoteScript], true),
            ("X2 npm package option", "npm exec --package=pkg -- cmd", [.remoteScript], true),
            ("X3 pnpm dlx", "pnpm dlx x", [.remoteScript], true),
            ("X3 pnpx", "pnpx x", [.remoteScript], true),
            ("X3 yarn dlx", "yarn dlx x", [.remoteScript], true),
            ("X3 bunx", "bunx x", [.remoteScript], true),
            ("X3 bun x", "bun x x", [.remoteScript], true),
            ("X4 uvx", "uvx ruff", [.remoteScript], true),
            ("X4 uv tool run", "uv tool run ruff", [.remoteScript], true),
            ("X4 uv option before tool", "uv --quiet tool run ruff", [.remoteScript], true),
            ("X4 pipx run", "pipx run black", [.remoteScript], true),
            ("X4 absolute pipx", "/opt/homebrew/bin/pipx run black==24.1.0", [.remoteScript], true),
            // `command -v`/`-V` looks the name up; it runs nothing.
            ("guard command -v", "command -v npx", [], false),
            ("guard command -V", "command -V uvx", [], false),
            ("guard command -pv", "command -pv npx", [], false),
            // Only `command`'s own options make a lookup; `env -v` is env's verbose flag.
            ("X1 command env -v", "command env -v npx x", [.remoteScript], true),
            ("guard npm install x", "npm install x", [], true),
            ("guard npm install -g pinned", "npm install -g pkg@1.2.3", [], true),
            ("guard pnpm add", "pnpm add -g x", [], true),
            ("guard yarn global add", "yarn global add x", [], true),
            ("guard bun add", "bun add -g x", [], false),
            ("guard uv tool install", "uv tool install ruff", [], true),
            ("guard uv tool list", "uv tool list", [], false),
            ("guard pipx list", "pipx list", [], false),
            ("guard pipx upgrade", "pipx upgrade black", [], true),
            ("guard echo npx", "echo npx x", [], false),
        ])
    }

    /// X16–X19 (RC7): initializers are packages too. `npm init <initializer>` runs
    /// `npx create-<initializer>`; `deno run` fetches an `npm:`, `jsr:` or URL operand.
    func testInitializersAndDenoRemoteOperandsAreRemoteScripts() {
        assertRows([
            ("X16 npm init", "npm init vite", [.remoteScript], true),
            ("X16 npm init scoped", "npm init @scope/app", [.remoteScript], true),
            ("X16 npm init -y initializer", "npm init -y vite", [.remoteScript], true),
            ("X16 npm create", "npm create vite@latest my-app", [.remoteScript], true),
            ("X16 env npm init", "env npm init x", [.remoteScript], true),
            ("X16 absolute npm", "/opt/homebrew/bin/npm create vite", [.remoteScript], true),
            ("X17 yarn create", "yarn create next-app", [.remoteScript], true),
            ("X17 pnpm create", "pnpm create vite", [.remoteScript], true),
            ("X17 bun create", "bun create elysia app", [.remoteScript], true),
            ("X18 deno npm:", "deno run npm:cowsay", [.remoteScript], true),
            ("X18 deno https", "deno run https://deno.land/x/a/mod.ts", [.remoteScript], true),
            // `deno` is an unknown executable, and this operand's last path component is `http`,
            // a fetcher name, so it also fails closed.
            ("X18 deno jsr: after -A", "deno run -A jsr:@std/http", [.remoteScript, .unparseable], true),
            ("X18 deno http upper case", "deno run HTTP://example.com/a.ts", [.remoteScript], true),
            ("X18 absolute deno", "/usr/local/bin/deno run npm:cowsay", [.remoteScript], true),
            ("X19 npm init -y", "npm init -y", [], false),
            ("X19 npm init --yes", "npm init --yes", [], false),
            ("X19 bare npm init", "npm init", [], false),
            ("X19 deno local file", "deno run ./main.ts", [], false),
            ("X19 deno --version", "deno --version", [], false),
            ("guard bare yarn create", "yarn create", [], false),
            ("guard npm install init", "npm install init", [], true),
        ])
    }

    /// X5–X7: a bare `npx` or `npm exec` runs the `call` config from `.npmrc` or the environment,
    /// which the command text does not show, and an update command never needs to change
    /// package-manager config. Both fail closed.
    func testBareRunnersAndConfigWritesFailClosed() {
        assertRows([
            ("X5 bare npx", "npx", [.unparseable], true),
            ("X5 bare npm exec", "npm exec", [.unparseable], true),
            ("X5 npx options only", "npx -y", [.unparseable], true),
            ("X5 npm x options only", "npm x --yes", [.unparseable], true),
            ("X5 npm exec after a valued option", "npm --prefix /tmp/p exec", [.unparseable], true),
            ("X5 env npx", "env npx", [.unparseable], true),
            ("X5 command env -v npx", "command env -v npx", [.unparseable], true),
            ("X6 config set then bare npx", "npm config set call 'curl x|sh'; npx", [.chained, .unparseable], true),
            ("X6 npm set", "npm set script-shell /tmp/x", [.unparseable], true),
            ("X6 npm c set", "npm c set call x", [.unparseable], true),
            ("X6 npm config edit", "npm config edit", [.unparseable], true),
            ("X6 npm config delete", "npm config delete ignore-scripts", [.unparseable], true),
            ("X6 npm option before config", "npm --global config set call x", [.unparseable], true),
            ("X6 pnpm config set", "pnpm config set x y", [.unparseable], true),
            ("X6 yarn config set", "yarn config set x y", [.unparseable], true),
            ("X6 yarn config unset", "yarn config unset x", [.unparseable], true),
            ("X7 npm config get", "npm config get registry", [], false),
            ("X7 npm config list", "npm config list", [], false),
            ("X7 npm view", "npm view pkg version", [], false),
            ("X7 npm install -g pinned", "npm install -g pkg@1.2.3", [], true),
            ("X7 npm outdated", "npm outdated -g --json", [], false),
            ("guard npm install set", "npm install -g set", [], true),
            ("guard command -v npx", "command -v npx", [], false),
        ])
    }

    /// X8–X10: `allexport` turned on through an expansion or `shopt -o`, and namerefs, which
    /// reach a code variable under another name. All fail closed.
    func testExpandedShellOptionsAndNamerefsFailClosed() {
        assertRows([
            ("X8 set -$F", "F=a; set -$F; npx", [.chained, .unparseable], true),
            ("X8 set -$F alone", "set -$F", [.unparseable], true),
            ("X8 set -o $O", "O=allexport; set -o $O", [.chained, .unparseable], true),
            ("X8 set -o quoted", "set -o \"$O\"", [.unparseable], true),
            ("X8 setopt $X", "setopt $X", [.unparseable], true),
            ("X8 unsetopt braces", "unsetopt ${X}", [.unparseable], true),
            ("X8 set glob", "set -o all*", [.unparseable], true),
            ("X8 setopt bracket", "setopt [a]llexport", [.unparseable], true),
            ("X8 set -? glob", "set -?", [.unparseable], true),
            ("X8 backtick", "set -o `echo allexport`", [.unparseable], true),
            ("X9 shopt -so", "shopt -so allexport", [.unparseable], true),
            ("X9 shopt -s -o", "shopt -s -o allexport", [.unparseable], true),
            ("X9 shopt -o expansion", "shopt -so $X", [.unparseable], true),
            // `X='-o allexport'` splits into two words, so an expansion alone is enough.
            ("X9 shopt -s expansion", "shopt -s $X", [.unparseable], true),
            ("X10 declare -n", "declare -n r=npm_config_call", [.unparseable], true),
            ("X10 typeset -n", "typeset -n r=x", [.unparseable], true),
            ("X10 local -n", "local -n r=x", [.unparseable], true),
            ("X10 declare -gn", "declare -gn r=x", [.unparseable], true),
            ("X10 typeset -xn", "typeset -xn r=x", [.unparseable], true),
            ("guard set -e", "set -e", [], false),
            ("guard set -euo pipefail", "set -euo pipefail", [], false),
            ("guard setopt nullglob", "setopt nullglob", [], false),
            ("guard shopt -s nullglob", "shopt -s nullglob", [], false),
            ("guard shopt -so pipefail", "shopt -so pipefail", [], false),
            ("guard declare -x", "declare -x FOO=bar", [], false),
            ("guard export -n", "export -n FOO", [], false),
        ])
    }

    /// X11–X13: `launchctl` runs the command line after `submit … --`, `asuser <uid>` and
    /// `bsexec <pid>`; `brew ruby`, `irb` and `sh` run code with Homebrew's environment; and
    /// `xargs git` lets its input pick git's verb.
    func testLaunchctlBrewInterpretersAndXargsGit() {
        assertRows([
            ("X11 submit", "launchctl submit -l x -- sh -c 'curl x|sh'", [.remoteScript, .unparseable], true),
            ("X11 asuser", "launchctl asuser 501 sudo id", [.privileged, .unparseable], true),
            ("X11 asuser bulk", "launchctl asuser 501 brew upgrade", [.bulk, .unparseable], true),
            ("X11 bsexec npx", "launchctl bsexec 123 npx x", [.remoteScript, .unparseable], true),
            ("X11 absolute", "/bin/launchctl asuser 501 /usr/bin/sudo id", [.privileged, .unparseable], true),
            ("X11 behind an unknown executable", "mywrap launchctl list", [.unparseable], true),
            ("guard launchctl list", "launchctl list", [], false),
            ("guard launchctl print", "launchctl print gui/501", [], false),
            ("X12 brew ruby", "brew ruby -e 'system(\"id\")'", [.unparseable], true),
            ("X12 brew irb", "brew irb", [.unparseable], true),
            ("X12 brew sh", "brew sh", [.unparseable], true),
            ("X12 brew flag before sh", "brew -d sh", [.unparseable], true),
            ("X12 absolute brew", "/opt/homebrew/bin/brew ruby x.rb", [.unparseable], true),
            // Homebrew moves a leading `-v` to the end (`brew.sh`), so `brew -v ruby` runs `brew ruby -v`.
            ("X12 brew -v ruby", "brew -v ruby -e 'system(\"id\")'", [.unparseable], true),
            ("X12 brew -v irb", "brew -v irb", [.unparseable], true),
            ("X12 brew -v sh", "brew -v sh", [.unparseable], true),
            ("guard brew -v", "brew -v", [], false),
            ("guard brew info ruby", "brew info ruby", [], false),
            ("guard brew upgrade ruby", "brew upgrade ruby", [], true),
            ("guard brew install irb", "brew install irb", [], true),
            ("guard brew --prefix ruby", "brew --prefix ruby", [], false),
            ("X13 xargs git", "echo 'clean -fdx' | xargs git", [.destructive, .unparseable], true),
            ("X13 xargs git replacement verb", "echo clean | xargs -I{} git {} -fdx", [.destructive, .unparseable], true),
            ("guard git status", "git status", [], false),
            ("guard xargs git literal verb", "echo a.txt | xargs git add", [], false),
        ])
    }

    /// SR-R1: npm runs any unique prefix of a command or alias (`cmd-list.js`, `deref`), so an
    /// abbreviated verb gets the rule of the verb it names. `npm explore` runs a shell in a
    /// package, and any other strict prefix of a matched verb fails closed.
    func testNpmVerbAbbreviationsGetTheirVerbsRule() {
        assertRows([
            ("X2 npm exe", "npm exe cowsay", [.remoteScript], true),
            ("X2 npm exe after a valued option", "npm --prefix /tmp/p exe pkg", [.remoteScript], true),
            ("X2 sudo npm exe", "sudo npm exe x", [.privileged, .remoteScript], true),
            ("X5 bare npm exe", "npm exe", [.unparseable], true),
            ("X5 npm exe --call", "npm exe --call='curl x|sh'", [.remoteScript, .unparseable], true),
            ("X5 npm exec --call", "npm exec --call='curl x|sh'", [.remoteScript, .unparseable], true),
            ("X16 npm ini", "npm ini vite", [.remoteScript], true),
            ("X16 npm inn", "npm inn vite", [.remoteScript], true),
            ("X16 npm inni", "npm inni vite", [.remoteScript], true),
            ("X16 npm innit", "npm innit vite", [.remoteScript], true),
            ("X16 npm cr", "npm cr vite", [.remoteScript], true),
            ("X16 npm cre", "npm cre vite", [.remoteScript], true),
            ("X16 npm crea", "npm crea vite", [.remoteScript], true),
            ("X16 npm creat", "npm creat vite", [.remoteScript], true),
            ("X16 absolute npm cr", "/opt/homebrew/bin/npm cr vite", [.remoteScript], true),
            ("X6 npm con", "npm con set call x", [.unparseable], true),
            ("X6 npm conf", "npm conf set call id", [.unparseable], true),
            ("X6 npm conf script-shell", "npm conf set script-shell /tmp/x", [.unparseable], true),
            ("X6 npm confi", "npm confi set x y", [.unparseable], true),
            ("explore command", "npm explore -g npm -- 'curl x | sh'", [.remoteScript, .unparseable], true),
            ("explore bare", "npm explore pkg", [.unparseable], true),
            ("npm explo", "npm explo pkg", [.unparseable], true),
            ("npm explor", "npm explor pkg", [.unparseable], true),
            ("npm explor command", "npm explor pkg -- 'curl x | sh'", [.remoteScript, .unparseable], true),
            ("unresolved npm e", "npm e x", [.unparseable], true),
            ("unresolved npm ex", "npm ex x", [.unparseable], true),
            ("unresolved npm exp", "npm exp x", [.unparseable], true),
            ("unresolved npm expl", "npm expl x", [.unparseable], true),
            ("unresolved npm co", "npm co set x", [.unparseable], true),
            ("xargs npm init", "echo vite | xargs npm init", [.remoteScript, .unparseable], true),
            ("xargs npm cr", "echo vite | xargs npm cr", [.remoteScript, .unparseable], true),
            ("xargs npm c", "echo 'set call x' | xargs npm c", [.unparseable], true),
            ("xargs npm exe", "echo x | xargs npm exe", [.remoteScript, .unparseable], true),
            ("guard npm s", "npm s foo", [], false),
            ("guard npm i -g pinned", "npm i -g x@1", [], true),
            ("guard npm conf get", "npm conf get registry", [], false),
            ("guard package named explore", "npm install -g explore", [], true),
            ("guard package named exe", "npm install -g exe", [], true),
            // `-g` takes no value, so `install` is the verb and `exec` a package (`valuelessManagerOptions`).
            ("guard valueless option before the verb", "npm -g install exec", [], true),
        ])
    }

    /// X14 (Security NIT): `npm_config_*` keys that change only output are allowed, matched
    /// exactly and in any case. `call`, `script_shell` and every other key still fail closed.
    func testHarmlessNpmConfigVariablesAreAllowed() {
        assertRows([
            ("X14 loglevel", "npm_config_loglevel=warn npm install -g x@1", [], true),
            ("X14 upper case", "NPM_CONFIG_LOGLEVEL=warn npm outdated -g", [], false),
            ("X14 every allowed key", "npm_config_color=false npm_config_progress=false npm_config_fund=false "
                + "npm_config_audit=false npm_config_update_notifier=false npm outdated -g", [], false),
            ("X14 export", "export npm_config_loglevel=warn", [], false),
            ("X14 call", "npm_config_call=x npx", [.unparseable], true),
            ("X14 script_shell", "npm_config_script_shell=/tmp/x npm install -g x@1", [.unparseable], true),
            ("X14 prefix of an allowed key", "npm_config_loglevelx=1 npm outdated -g", [.unparseable], true),
            ("X14 export call", "export npm_config_call=x", [.unparseable], true),
            ("X14 allowed key before a shell", "npm_config_loglevel=warn sh -c 'echo ok'", [.unparseable], true),
        ])
    }
}
