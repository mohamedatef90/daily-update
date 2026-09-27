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
}
