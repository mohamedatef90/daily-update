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

        let prefix = root.appendingPathComponent(".nvm/versions/node/v22.12.0", isDirectory: true)
        try createExecutable(at: prefix.appendingPathComponent("bin/node"))
        let realCommand = prefix.appendingPathComponent("lib/node_modules/@openai/codex/bin/codex.js")
        try createExecutable(at: realCommand)
        try writePackageJSON(
            at: prefix.appendingPathComponent("lib/node_modules/@openai/codex/package.json"),
            name: "@openai/codex",
            version: "1.2.3"
        )

        let symlinkDir = prefix.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
        let symlink = symlinkDir.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: realCommand.path)

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [symlink.path],
            layout: .fixture(home: root.path)
        )

        guard case .npm(let resolvedPrefix, let resolvedPackage) = resolution.active?.owner else {
            XCTFail("Expected npm owner")
            return
        }
        XCTAssertEqual(
            URL(fileURLWithPath: resolvedPrefix).standardizedFileURL.path,
            URL(fileURLWithPath: prefix.path).standardizedFileURL.path
        )
        XCTAssertEqual(resolvedPackage, "@openai/codex")
    }

    func testOwnerResolverTracksNodePrefixByActiveCandidateAndKeepsCompetingPaths() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let node24Prefix = root.appendingPathComponent(".nvm/versions/node/v24.13.0", isDirectory: true)
        let node22Prefix = root.appendingPathComponent(".nvm/versions/node/v22.12.0", isDirectory: true)
        try createExecutable(at: node24Prefix.appendingPathComponent("bin/node"))
        try createExecutable(at: node22Prefix.appendingPathComponent("bin/node"))
        let node24Command = node24Prefix.appendingPathComponent("lib/node_modules/@openai/codex/bin/codex.js")
        let node22Command = node22Prefix.appendingPathComponent("lib/node_modules/@openai/codex/bin/codex.js")
        try createExecutable(at: node24Command)
        try createExecutable(at: node22Command)
        try writePackageJSON(
            at: node24Prefix.appendingPathComponent("lib/node_modules/@openai/codex/package.json"),
            name: "@openai/codex",
            version: "2.0.0"
        )
        try writePackageJSON(
            at: node22Prefix.appendingPathComponent("lib/node_modules/@openai/codex/package.json"),
            name: "@openai/codex",
            version: "1.0.0"
        )

        let node24Bin = node24Prefix.appendingPathComponent("bin", isDirectory: true)
        let node22Bin = node22Prefix.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: node24Bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: node22Bin, withIntermediateDirectories: true)
        let activeCandidate = node24Bin.appendingPathComponent("codex")
        let competingCandidate = node22Bin.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: activeCandidate.path, withDestinationPath: node24Command.path)
        try FileManager.default.createSymbolicLink(atPath: competingCandidate.path, withDestinationPath: node22Command.path)

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [activeCandidate.path, competingCandidate.path],
            layout: .fixture(home: root.path)
        )

        guard case .npm(let activePrefix, let activePackage) = resolution.active?.owner else {
            XCTFail("Expected npm owner for active candidate")
            return
        }
        XCTAssertEqual(
            URL(fileURLWithPath: activePrefix).standardizedFileURL.path,
            URL(fileURLWithPath: node24Prefix.path).standardizedFileURL.path
        )
        XCTAssertEqual(activePackage, "@openai/codex")

        guard case .npm(let competingPrefix, let competingPackage) = resolution.competing.first?.owner else {
            XCTFail("Expected npm owner for competing candidate")
            return
        }
        XCTAssertEqual(
            URL(fileURLWithPath: competingPrefix).standardizedFileURL.path,
            URL(fileURLWithPath: node22Prefix.path).standardizedFileURL.path
        )
        XCTAssertEqual(competingPackage, "@openai/codex")
    }

    func testOwnerResolverDeduplicatesByResolvedPath() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent(".local/share/uv/tools/browser-use/bin/browser-use")
        try createExecutable(at: target)

        let firstBin = root.appendingPathComponent("bin-a", isDirectory: true)
        let secondBin = root.appendingPathComponent("bin-b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondBin, withIntermediateDirectories: true)
        let firstCandidate = firstBin.appendingPathComponent("browser-use")
        let secondCandidate = secondBin.appendingPathComponent("browser-use")
        try FileManager.default.createSymbolicLink(atPath: firstCandidate.path, withDestinationPath: target.path)
        try FileManager.default.createSymbolicLink(atPath: secondCandidate.path, withDestinationPath: target.path)

        let resolution = OwnerResolver.resolve(
            commandName: "browser-use",
            candidatePaths: [firstCandidate.path, secondCandidate.path, target.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(
            URL(fileURLWithPath: resolution.active?.resolvedPath ?? "").standardizedFileURL.path,
            URL(fileURLWithPath: target.path).standardizedFileURL.path
        )
        XCTAssertTrue(resolution.competing.isEmpty)
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

    func testOwnerResolverUsesFirstCandidateWhenUvAndPipxBothExist() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = EcosystemLayout.fixture(home: root.path)
        let uvCandidate = root.appendingPathComponent(".local/share/uv/tools/httpie/bin/http")
        let pipxCandidate = root.appendingPathComponent(".local/pipx/venvs/httpie/bin/http")
        try createExecutable(at: uvCandidate)
        try createExecutable(at: pipxCandidate)

        let uvFirst = OwnerResolver.resolve(
            commandName: "http",
            candidatePaths: [uvCandidate.path, pipxCandidate.path],
            layout: layout
        )
        XCTAssertEqual(uvFirst.active?.owner, .uvTool(name: "httpie"))
        XCTAssertEqual(uvFirst.competing.first?.owner, .pipx(package: "httpie"))

        let pipxFirst = OwnerResolver.resolve(
            commandName: "http",
            candidatePaths: [pipxCandidate.path, uvCandidate.path],
            layout: layout
        )
        XCTAssertEqual(pipxFirst.active?.owner, .pipx(package: "httpie"))
        XCTAssertEqual(pipxFirst.competing.first?.owner, .uvTool(name: "httpie"))
    }

    func testStrategyPlannerPinsNpmCommandToTargetVersion() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent(".nvm/versions/node/v24.13.0", isDirectory: true)
        try createExecutable(at: prefix.appendingPathComponent("bin/npm"))

        let owner = OwnerCandidate(
            commandPath: "\(prefix.path)/bin/claude",
            resolvedPath: "\(prefix.path)/lib/node_modules/@anthropic-ai/claude-code/bin/claude.js",
            owner: .npm(prefix: prefix.path, package: "@anthropic-ai/claude-code")
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

        XCTAssertEqual(spec?.executablePath, "\(prefix.path)/bin/npm")
        XCTAssertEqual(
            spec?.arguments,
            ["install", "-g", "--prefix", prefix.path, "@anthropic-ai/claude-code@2.1.281"]
        )
        XCTAssertEqual(spec?.environment["PATH"], "\(prefix.path)/bin:\(ShellRunner.defaultPath)")
    }

    func testStrategyPlannerReturnsBlockedForOwnerMismatch() async {
        let owner = OwnerCandidate(
            commandPath: "/tmp/node-24/bin/codex",
            resolvedPath: "/tmp/node-24/lib/node_modules/@openai/codex/bin/codex.js",
            owner: .npm(prefix: "/tmp/node-24", package: "@openai/codex")
        )
        let resolution = OwnerResolution(commandName: "codex", active: owner, competing: [])
        let config = makeConfig(
            id: "codex",
            command: "codex",
            packages: PackageIdentifiers(
                brew: nil,
                brewCask: nil,
                npm: "@anthropic-ai/claude-code",
                pipx: nil,
                uv: nil,
                cargo: nil,
                gem: nil,
                masAdamID: nil
            ),
            selfUpdater: nil,
            autoUpdates: nil
        )

        let plan = await StrategyPlanner.checkPlan(
            config: config,
            currentVersion: "1.0.0",
            resolution: resolution
        )

        XCTAssertEqual(plan.blockReason, .ownerMismatch)
        XCTAssertNil(plan.updateCommandSpec)
    }

    func testStrategyPlannerReturnsBlockedForUnknownOwnerAndNoStrategy() async {
        let missingResolution = OwnerResolution(commandName: "missing-tool", active: nil, competing: [])
        let missingPlan = await StrategyPlanner.checkPlan(
            config: makeConfig(id: "missing-tool", command: "missing-tool", packages: nil, selfUpdater: nil, autoUpdates: nil),
            currentVersion: "1.0.0",
            resolution: missingResolution
        )
        XCTAssertEqual(missingPlan.blockReason, .unknownOwner)

        let unknownOwner = OwnerCandidate(
            commandPath: "/tmp/custom/bin/custom-tool",
            resolvedPath: "/tmp/custom/bin/custom-tool",
            owner: .unknown
        )
        let unknownResolution = OwnerResolution(commandName: "custom-tool", active: unknownOwner, competing: [])
        let noStrategyPlan = await StrategyPlanner.checkPlan(
            config: makeConfig(id: "custom-tool", command: "custom-tool", packages: nil, selfUpdater: nil, autoUpdates: nil),
            currentVersion: "1.0.0",
            resolution: unknownResolution
        )
        XCTAssertEqual(noStrategyPlan.blockReason, .noStrategy)
    }

    func testStrategyPlannerUsesNamedCaskUpgradeWithoutGreedyFlag() {
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

        XCTAssertEqual(spec?.arguments, ["upgrade", "--cask", "cursor"])
    }

    func testStrategyPlannerSkipsGreedyFlagForCasksWithoutAutoUpdates() {
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
            autoUpdates: false
        )

        let spec = StrategyPlanner.commandForResolvedOwner(
            config: config,
            resolution: resolution,
            targetVersion: "1.3.0"
        )

        XCTAssertEqual(spec?.arguments, ["upgrade", "--cask", "cursor"])
    }

    func testOwnershipFingerprintIncludesWorkingDirectory() {
        let owner = OwnerCandidate(
            commandPath: "/tmp/node-24/bin/codex",
            resolvedPath: "/tmp/node-24/lib/node_modules/@openai/codex/bin/codex.js",
            owner: .npm(prefix: "/tmp/node-24", package: "@openai/codex")
        )
        let resolution = OwnerResolution(commandName: "codex", active: owner, competing: [])

        let config = makeConfig(
            id: "codex",
            command: "codex",
            packages: nil,
            selfUpdater: nil,
            autoUpdates: nil,
            workingDirectory: "/tmp/workspace/repo"
        )

        let fingerprint = StrategyPlanner.ownershipFingerprint(for: config, resolution: resolution)
        XCTAssertEqual(
            fingerprint,
            "\(resolution.fingerprint!)|cwd:/tmp/workspace/repo"
        )
    }

    private func makeConfig(
        id: String,
        command: String,
        packages: PackageIdentifiers?,
        selfUpdater: String?,
        autoUpdates: Bool?,
        workingDirectory: String? = nil
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
            workingDirectory: workingDirectory,
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

    private func writePackageJSON(at url: URL, name: String, version: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = """
        {"name":"\(name)","version":"\(version)"}
        """
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }
}
