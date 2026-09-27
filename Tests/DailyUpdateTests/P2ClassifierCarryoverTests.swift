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
}
