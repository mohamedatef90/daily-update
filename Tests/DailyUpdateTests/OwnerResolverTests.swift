import XCTest
@testable import DailyUpdate

final class OwnerResolverTests: XCTestCase {
    func testOwnerResolverClassifiesNativeClaudeThroughSymlink() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = EcosystemLayout.fixture(home: root.path)
        let nativeBinary = root
            .appendingPathComponent(".local/share/claude/versions/2.1.281/bin/claude")
        try createExecutable(at: nativeBinary)

        let localBin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let symlink = localBin.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: nativeBinary.path
        )

        let resolution = OwnerResolver.resolve(
            commandName: "claude",
            candidatePaths: [symlink.path],
            layout: layout
        )

        XCTAssertEqual(resolution.active?.owner, .nativeInstaller(.claudeCode))
    }

    func testOwnerResolverUsesResolvedPathForNpmOwnerAndPrefix() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appendingPathComponent("toolchain/node-22", isDirectory: true)
        let realCommand = prefix.appendingPathComponent("lib/node_modules/@openai/codex/bin/codex.js")
        try createExecutable(at: realCommand)

        let symlinkDir = prefix.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
        let symlink = symlinkDir.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: realCommand.path)

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [symlink.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(
            resolution.active?.owner,
            .npm(prefix: prefix.path, package: "@openai/codex")
        )
    }

    func testOwnerResolverClassifiesUvAndPipxTools() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = EcosystemLayout.fixture(home: root.path)
        let uvBinary = root.appendingPathComponent(".local/share/uv/tools/browser-use/bin/browser-use")
        let pipxBinary = root.appendingPathComponent(".local/pipx/venvs/httpie/bin/http")
        try createExecutable(at: uvBinary)
        try createExecutable(at: pipxBinary)

        let uvResolution = OwnerResolver.resolve(
            commandName: "browser-use",
            candidatePaths: [uvBinary.path],
            layout: layout
        )
        let pipxResolution = OwnerResolver.resolve(
            commandName: "http",
            candidatePaths: [pipxBinary.path],
            layout: layout
        )

        XCTAssertEqual(uvResolution.active?.owner, .uvTool(name: "browser-use"))
        XCTAssertEqual(pipxResolution.active?.owner, .pipx(package: "httpie"))
    }

    func testStrategyPlannerPinsNpmCommandToTargetVersion() {
        let owner = OwnerCandidate(
            commandPath: "/tmp/node-22/bin/claude",
            resolvedPath: "/tmp/node-22/lib/node_modules/@anthropic-ai/claude-code/bin/claude.js",
            owner: .npm(prefix: "/tmp/node-22", package: "@anthropic-ai/claude-code")
        )
        let resolution = OwnerResolution(commandName: "claude", active: owner, competing: [])
        let config = makeConfig(
            id: "claude-code",
            command: "claude",
            packages: PackageIdentifiers(
                brew: nil,
                brewCask: "claude-code",
                npm: "@anthropic-ai/claude-code",
                pipx: nil,
                uv: nil,
                cargo: nil,
                gem: nil,
                masAdamID: nil
            ),
            selfUpdater: "claudeCode",
            autoUpdates: nil
        )

        let spec = StrategyPlanner.commandForResolvedOwner(
            config: config,
            resolution: resolution,
            targetVersion: "2.1.281"
        )

        XCTAssertEqual(spec?.executablePath, "/tmp/node-22/bin/npm")
        XCTAssertEqual(spec?.arguments, ["install", "-g", "@anthropic-ai/claude-code@2.1.281"])
    }

    func testStrategyPlannerAddsGreedyFlagForAutoUpdatingCasks() {
        let owner = OwnerCandidate(
            commandPath: "/opt/homebrew/bin/cursor",
            resolvedPath: "/opt/homebrew/Caskroom/cursor/1.2.3/Cursor.app/Contents/MacOS/Cursor",
            owner: .brewCask("cursor")
        )
        let resolution = OwnerResolution(commandName: "cursor", active: owner, competing: [])
        let config = makeConfig(
            id: "cursor",
            command: "cursor",
            packages: PackageIdentifiers(
                brew: nil,
                brewCask: "cursor",
                npm: nil,
                pipx: nil,
                uv: nil,
                cargo: nil,
                gem: nil,
                masAdamID: nil
            ),
            selfUpdater: nil,
            autoUpdates: true
        )

        let spec = StrategyPlanner.commandForResolvedOwner(
            config: config,
            resolution: resolution,
            targetVersion: "1.3.0"
        )

        XCTAssertEqual(spec?.arguments, ["upgrade", "--cask", "--greedy", "cursor"])
    }

    private func makeConfig(
        id: String,
        command: String,
        packages: PackageIdentifiers?,
        selfUpdater: String?,
        autoUpdates: Bool?
    ) -> DetectorConfig {
        DetectorConfig(
            id: id,
            name: id,
            category: .cli,
            description: nil,
            source: .bundled,
            command: command,
            packages: packages,
            selfUpdater: selfUpdater,
            appcastURL: nil,
            autoUpdates: autoUpdates,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo 1.0.0",
            versionPattern: nil,
            checkCommand: "echo UPDATE",
            installCommand: "true",
            updateCommand: "true",
            workingDirectory: nil,
            needsReview: false
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
