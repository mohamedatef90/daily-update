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
}
