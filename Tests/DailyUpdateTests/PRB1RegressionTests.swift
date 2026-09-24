import Foundation
import XCTest
@testable import DailyUpdate

final class PRB1ProvenanceAndSecurityTests: XCTestCase {
    func testC0CustomBundledSpoofIsForcedToUserAndTypedFieldsDropped() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            var settings = UserSettings.defaults
            settings.customItems = [
                typedConfig(
                    id: "custom-bundled-spoof",
                    commandName: "codex",
                    packageName: "@openai/codex",
                    source: .bundled
                ),
            ]

            let loaded = ConfigLoader.loadConfigs(settings: settings)
            guard let item = loaded.first(where: { $0.id == "custom-bundled-spoof" }) else {
                XCTFail("Custom item missing")
                return
            }

            XCTAssertEqual(item.source, .user)
            XCTAssertNil(item.command)
            XCTAssertNil(item.packages)
            XCTAssertTrue(item.needsReview == true)
        }
    }

    func testC0LegacyBundledSpoofIsForcedToUserAndTypedFieldsDropped() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let legacy = """
            {
              "items": [
                {
                  "id": "legacy-bundled-spoof",
                  "name": "Legacy Bundled Spoof",
                  "category": "cli",
                  "source": "bundled",
                  "schemaVersion": 2,
                  "command": "codex",
                  "packages": { "npm": "@openai/codex" },
                  "detect": { "type": "always" },
                  "versionCommand": "echo 1.0.0",
                  "checkCommand": "echo UPDATE",
                  "updateCommand": "echo update"
                }
              ]
            }
            """
            try legacy.write(to: ConfigLoader.userConfigURL, atomically: true, encoding: .utf8)

            let loaded = ConfigLoader.loadConfigs(settings: .defaults)
            guard let item = loaded.first(where: { $0.id == "legacy-bundled-spoof" }) else {
                XCTFail("Legacy item missing")
                return
            }

            XCTAssertEqual(item.source, .user)
            XCTAssertNil(item.command)
            XCTAssertNil(item.packages)
            XCTAssertTrue(item.needsReview == true)
        }
    }

    func testC5DiscoveredItemsAlwaysUseDiscoveredSourceAndDropTypedFields() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let discovered = typedConfig(
                id: "discovered-typed",
                commandName: "codex",
                packageName: "@openai/codex",
                source: nil
            )

            let loaded = ConfigLoader.loadConfigs(
                settings: .defaults,
                discoveredRepos: [discovered]
            )

            guard let item = loaded.first(where: { $0.id == "discovered-typed" }) else {
                XCTFail("Discovered item missing")
                return
            }

            XCTAssertEqual(item.source, .discovered)
            XCTAssertNil(item.command)
            XCTAssertNil(item.packages)
            XCTAssertFalse(item.needsReview == true)
        }
    }

    func testC5ImportForcesSourceToUser() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            var sourceSettings = UserSettings.defaults
            sourceSettings.customItems = [
                DetectorConfig(
                    id: "imported-source-test",
                    name: "Imported Source Test",
                    category: .cli,
                    description: nil,
                    source: .bundled,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                    versionCommand: "echo 1.0.0",
                    checkCommand: "echo OK",
                    installCommand: nil,
                    updateCommand: "echo update",
                    workingDirectory: nil
                ),
            ]

            let exported = try ConfigImportExport.export(settings: sourceSettings)
            let store = UserSettingsStore()
            try ConfigImportExport.importData(exported, into: store)

            guard let imported = store.settings.customItems.first(where: { $0.id == "imported-source-test" }) else {
                XCTFail("Imported item missing")
                return
            }

            XCTAssertEqual(imported.source, .user)
            XCTAssertTrue(imported.needsReview == true)
        }
    }

    func testSecurityImportedTypedFieldsAreRejected() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            var sourceSettings = UserSettings.defaults
            sourceSettings.customItems = [
                typedConfig(
                    id: "typed-import-rejected",
                    commandName: "codex",
                    packageName: "@openai/codex",
                    source: .bundled
                ),
            ]
            let exported = try ConfigImportExport.export(settings: sourceSettings)
            let store = UserSettingsStore()

            XCTAssertThrowsError(try ConfigImportExport.importData(exported, into: store))
        }
    }
}

final class PRB1OwnerMatrixTests: XCTestCase {
    func testOwnerRowO1RelativeSymlinkResolvesAndBuildsPinnedSpec() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v22.12.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\"",
            relativeSymlink: true
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )
        guard case .npm(let prefix, let package) = resolution.active?.owner else {
            XCTFail("Expected npm owner")
            return
        }
        XCTAssertEqual(normalizedPath(prefix), normalizedPath(install.prefix.path))
        XCTAssertEqual(package, "@openai/codex")

        let spec = StrategyPlanner.commandForResolvedOwner(
            config: typedConfig(id: "o1", commandName: "codex", packageName: "@openai/codex"),
            resolution: resolution,
            targetVersion: "1.1.0",
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(normalizedPath(spec?.executablePath ?? ""), normalizedPath("\(install.prefix.path)/bin/npm"))
        XCTAssertEqual(
            spec?.arguments,
            ["install", "-g", "--prefix", normalizedPath(install.prefix.path), "@openai/codex@1.1.0"]
        )
        XCTAssertTrue(spec?.environment["PATH"]?.hasPrefix("\(normalizedPath(install.prefix.path))/bin:") == true)
    }

    func testOwnerRowO2ScopedPackageArgvUsesResolvedPrefix() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v24.13.0",
            commandName: "claude",
            packageName: "@anthropic-ai/claude-code",
            installedVersion: "2.1.280",
            latestOutput: "\"2.1.281\""
        )

        let resolution = OwnerResolver.resolve(
            commandName: "claude",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )
        let spec = StrategyPlanner.commandForResolvedOwner(
            config: typedConfig(id: "o2", commandName: "claude", packageName: "@anthropic-ai/claude-code"),
            resolution: resolution,
            targetVersion: "2.1.281",
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(
            spec?.arguments,
            ["install", "-g", "--prefix", normalizedPath(install.prefix.path), "@anthropic-ai/claude-code@2.1.281"]
        )
    }

    func testOwnerRowO3RejectsMalformedScopedPackagePath() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent(".nvm/versions/node/v20.0.0", isDirectory: true)
        try createExecutable(at: prefix.appendingPathComponent("bin/node"))
        let malformed = prefix.appendingPathComponent("lib/node_modules/@scope")
        try createExecutable(at: malformed)

        let resolution = OwnerResolver.resolve(
            commandName: "tool",
            candidatePaths: [malformed.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(resolution.active?.owner, .unknown)
    }

    func testOwnerRowO4RejectsLeadingDashPackageNames() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent(".nvm/versions/node/v20.0.0", isDirectory: true)
        try createExecutable(at: prefix.appendingPathComponent("bin/node"))
        let path = prefix.appendingPathComponent("lib/node_modules/-evil/bin/evil")
        try createExecutable(at: path)
        try writePackageJSON(
            at: prefix.appendingPathComponent("lib/node_modules/-evil/package.json"),
            name: "-evil",
            version: "1.0.0"
        )

        let resolution = OwnerResolver.resolve(
            commandName: "evil",
            candidatePaths: [path.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(resolution.active?.owner, .unknown)
    }

    func testOwnerRowO5RejectsPackageJSONNameMismatch() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v22.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )
        try writePackageJSON(
            at: install.prefix.appendingPathComponent("lib/node_modules/@openai/codex/package.json"),
            name: "@openai/not-codex",
            version: "1.0.0"
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(resolution.active?.owner, .unknown)
    }

    func testOwnerRowO6RejectsPrefixesOutsideAllowlist() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let install = try createNpmInstallation(
            root: root,
            prefixPath: "custom/node/v22.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(resolution.active?.owner, .unknown)
    }

    func testOwnerRowO7RejectsNpmPrefixWithoutNodeBinary() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v22.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\"",
            createNode: false
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(resolution.active?.owner, .unknown)
    }

    func testOwnerRowO8OwnerMismatchBlocksPlan() async {
        let owner = OwnerCandidate(
            commandPath: "/tmp/node/bin/codex",
            resolvedPath: "/tmp/node/lib/node_modules/@openai/codex/bin/codex.js",
            owner: .npm(prefix: "/tmp/node", package: "@openai/codex")
        )
        let resolution = OwnerResolution(commandName: "codex", active: owner, competing: [])
        let config = typedConfig(
            id: "o8",
            commandName: "codex",
            packageName: "@anthropic-ai/claude-code"
        )

        let plan = await StrategyPlanner.checkPlan(
            config: config,
            currentVersion: "1.0.0",
            resolution: resolution
        )

        XCTAssertEqual(plan.blockReason, .ownerMismatch)
    }

    func testOwnerRowO9PathTrustRejectsGroupWritableNpmExecutable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v22.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775],
            ofItemAtPath: install.prefix.appendingPathComponent("bin/npm").path
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )
        let plan = await StrategyPlanner.checkPlan(
            config: typedConfig(id: "o9", commandName: "codex", packageName: "@openai/codex"),
            currentVersion: "1.0.0",
            resolution: resolution,
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(plan.blockReason, .unknownOwner)
        XCTAssertEqual(plan.failureMessage, "Untrusted npm executable path")
    }

    func testOwnerRowO10UnscopedPackageIsAccepted() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v22.0.0",
            commandName: "openclaw",
            packageName: "openclaw-cli",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )

        let resolution = OwnerResolver.resolve(
            commandName: "openclaw",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )

        guard case .npm(_, let package) = resolution.active?.owner else {
            XCTFail("Expected npm owner")
            return
        }
        XCTAssertEqual(package, "openclaw-cli")
    }

    func testOwnerRowO11PipxSymlinkResolvesPackageIdentity() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent(".local/pipx/venvs/httpie/bin/http")
        try createExecutable(at: target)
        let wrapper = root.appendingPathComponent("bin/http")
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wrapper.path, withDestinationPath: target.path)

        let resolution = OwnerResolver.resolve(
            commandName: "http",
            candidatePaths: [wrapper.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertEqual(resolution.active?.owner, .pipx(package: "httpie"))
    }

    func testOwnerRowO12DanglingSymlinkProducesResolveError() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dangling = root.appendingPathComponent("bin/dangling")
        try FileManager.default.createDirectory(at: dangling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/no/such/path")

        let resolution = OwnerResolver.resolve(
            commandName: "dangling",
            candidatePaths: [dangling.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertNil(resolution.active)
        if case .unresolvedPath = resolution.resolveError {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected unresolvedPath error")
        }
    }

    func testOwnerRowO13SymlinkLoopProducesResolveError() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("bin/loop-a")
        let second = root.appendingPathComponent("bin/loop-b")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: first.path)

        let resolution = OwnerResolver.resolve(
            commandName: "loop-a",
            candidatePaths: [first.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertNil(resolution.active)
        if case .unresolvedPath = resolution.resolveError {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected unresolvedPath error")
        }
    }

    func testOwnerRowO14LookupIgnoresInvalidCommandNames() async {
        let lookup = await OwnerResolver.lookup(commandNames: ["sh", "bad name", "$(oops)", "sh"])
        XCTAssertFalse(lookup.candidates(for: "sh").isEmpty)
        XCTAssertTrue(lookup.candidates(for: "bad name").isEmpty)
        XCTAssertTrue(lookup.candidates(for: "$(oops)").isEmpty)
    }

    func testOwnerRowO15ResolveErrorBecomesTypedEngineCheckFailure() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dangling = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: dangling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/missing/codex")

        let lookup = CommandPathLookup(candidatesByName: ["codex": [dangling.path]])
        let result = await UpdateCheckService.check(
            typedConfig(id: "o15", commandName: "codex", packageName: "@openai/codex"),
            installed: true,
            pathLookup: lookup
        )

        XCTAssertEqual(result.status, .checkFailed)
        XCTAssertTrue(result.message?.contains("Could not resolve command path") == true)
    }

    func testOwnerRowO16DeduplicatesIdenticalResolvedTargets() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent(".local/share/uv/tools/browser-use/bin/browser-use")
        try createExecutable(at: target)
        let first = root.appendingPathComponent("bin-a/browser-use")
        let second = root.appendingPathComponent("bin-b/browser-use")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: target.path)
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: target.path)

        let resolution = OwnerResolver.resolve(
            commandName: "browser-use",
            candidatePaths: [first.path, second.path],
            layout: .fixture(home: root.path)
        )

        XCTAssertNotNil(resolution.active)
        XCTAssertTrue(resolution.competing.isEmpty)
    }

    func testOwnerRowO17TracksCompetingInstallsByCandidateOrder() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v24.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "2.0.0",
            latestOutput: "\"2.0.1\""
        )
        let second = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v22.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.0.1\""
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [first.commandPath.path, second.commandPath.path],
            layout: .fixture(home: root.path)
        )

        guard case .npm(let firstPrefix, _) = resolution.active?.owner else {
            XCTFail("Missing active npm owner")
            return
        }
        guard case .npm(let secondPrefix, _) = resolution.competing.first?.owner else {
            XCTFail("Missing competing npm owner")
            return
        }
        XCTAssertEqual(normalizedPath(firstPrefix), normalizedPath(first.prefix.path))
        XCTAssertEqual(normalizedPath(secondPrefix), normalizedPath(second.prefix.path))
    }

    func testOwnerRowO18InvalidCommandNameIsRejected() async {
        let resolution = await OwnerResolver.resolve(
            commandName: "bad name",
            lookup: CommandPathLookup(candidatesByName: [:]),
            layout: .fixture(home: "/tmp")
        )

        XCTAssertEqual(resolution.resolveError, .invalidCommandName)
        XCTAssertNil(resolution.active)
    }

    func testOwnerRowO19NvmPrefixIsAllowed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v20.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )
        guard case .npm(let prefix, let package) = resolution.active?.owner else {
            XCTFail("Expected npm owner")
            return
        }
        XCTAssertEqual(normalizedPath(prefix), normalizedPath(install.prefix.path))
        XCTAssertEqual(package, "@openai/codex")
    }

    func testOwnerRowO20VoltaPrefixIsAllowed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".volta/tools/image/node/v20.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )
        guard case .npm(let prefix, let package) = resolution.active?.owner else {
            XCTFail("Expected npm owner")
            return
        }
        XCTAssertEqual(normalizedPath(prefix), normalizedPath(install.prefix.path))
        XCTAssertEqual(package, "@openai/codex")
    }

    func testOwnerRowO21FnmPrefixIsAllowed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = try createNpmInstallation(
            root: root,
            prefixPath: ".fnm/node-versions/v20.0.0/installation",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )

        let resolution = OwnerResolver.resolve(
            commandName: "codex",
            candidatePaths: [install.commandPath.path],
            layout: .fixture(home: root.path)
        )
        guard case .npm(let prefix, let package) = resolution.active?.owner else {
            XCTFail("Expected npm owner")
            return
        }
        XCTAssertEqual(normalizedPath(prefix), normalizedPath(install.prefix.path))
        XCTAssertEqual(package, "@openai/codex")
    }
}

final class PRB1FlowAndExecutionTests: XCTestCase {
    func testFlowRowF1TypedEngineCheckReturnsUpdateAvailableWithPinnedSpec() async throws {
        let fixture = try makeTypedCheckFixture(installedVersion: "1.0.0", latestOutput: "\"1.1.0\"")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await UpdateCheckService.check(
            fixture.config,
            installed: true,
            pathLookup: fixture.lookup
        )

        XCTAssertEqual(
            result.status,
            .updateAvailable,
            "status=\(result.status) block=\(String(describing: result.blockReason)) message=\(String(describing: result.message))"
        )
        XCTAssertEqual(result.latestVersion, "1.1.0")
        XCTAssertEqual(
            result.plannedUpdateCommandSpec?.arguments,
            ["install", "-g", "--prefix", fixture.install.prefix.path, "@openai/codex@1.1.0"]
        )
    }

    func testFlowRowF2TypedEngineCheckReturnsUpToDateWhenVersionsMatch() async throws {
        let fixture = try makeTypedCheckFixture(installedVersion: "1.1.0", latestOutput: "\"1.1.0\"")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await UpdateCheckService.check(
            fixture.config,
            installed: true,
            pathLookup: fixture.lookup
        )

        XCTAssertEqual(
            result.status,
            .upToDate,
            "status=\(result.status) block=\(String(describing: result.blockReason)) message=\(String(describing: result.message))"
        )
        XCTAssertEqual(result.currentVersion, "1.1.0")
        XCTAssertEqual(result.latestVersion, "1.1.0")
    }

    func testFlowRowF3TypedEngineCheckRejectsHostilePins() async throws {
        for hostile in ["\"npm:x\"", "\"https://example.com/x.tgz\"", "\"git+ssh://example.com/x\""] {
            let fixture = try makeTypedCheckFixture(installedVersion: "1.0.0", latestOutput: hostile)
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let result = await UpdateCheckService.check(
                fixture.config,
                installed: true,
                pathLookup: fixture.lookup
            )

            XCTAssertEqual(
                result.status,
                .checkFailed,
                "\(hostile) status=\(result.status) block=\(String(describing: result.blockReason)) message=\(String(describing: result.message))"
            )
            XCTAssertTrue(result.message?.contains("strict semver") == true, hostile)
        }
    }

    func testFlowRowF4TypedEngineCheckBlocksPerEcosystemOwnerMismatch() async throws {
        let fixture = try makeTypedCheckFixture(installedVersion: "1.0.0", latestOutput: "\"1.1.0\"")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var mismatch = fixture.config
        mismatch.packages = PackageIdentifiers(
            brew: "gh",
            brewCask: nil,
            npm: nil,
            pipx: nil,
            uv: nil,
            cargo: nil,
            gem: nil,
            masAdamID: nil
        )

        let result = await UpdateCheckService.check(
            mismatch,
            installed: true,
            pathLookup: fixture.lookup
        )

        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(result.blockReason, .ownerMismatch)
    }

    func testFlowRowF5TypedEngineCheckBlocksDeferredPipxStrategy() async {
        let owner = OwnerCandidate(
            commandPath: "/tmp/.local/bin/http",
            resolvedPath: "/tmp/.local/pipx/venvs/httpie/bin/http",
            owner: .pipx(package: "httpie")
        )
        let resolution = OwnerResolution(commandName: "http", active: owner, competing: [])
        let config = DetectorConfig(
            id: "f5",
            name: "f5",
            category: .cli,
            description: nil,
            schemaVersion: 2,
            source: .bundled,
            command: "http",
            packages: PackageIdentifiers(
                brew: nil,
                brewCask: nil,
                npm: nil,
                pipx: "httpie",
                uv: nil,
                cargo: nil,
                gem: nil,
                masAdamID: nil
            ),
            selfUpdater: nil,
            appcastURL: nil,
            autoUpdates: nil,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo 1.0.0",
            versionPattern: nil,
            checkCommand: "echo UPDATE",
            installCommand: nil,
            updateCommand: "echo update",
            workingDirectory: nil,
            needsReview: false
        )

        let plan = await StrategyPlanner.checkPlan(
            config: config,
            currentVersion: "1.0.0",
            resolution: resolution
        )

        XCTAssertEqual(plan.blockReason, .noStrategy)
    }

    func testFlowRowF6TypedEngineCheckTurnsResolveErrorsIntoCheckFailures() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dangling = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: dangling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/missing/codex")
        let lookup = CommandPathLookup(candidatesByName: ["codex": [dangling.path]])

        let result = await UpdateCheckService.check(
            typedConfig(id: "f6", commandName: "codex", packageName: "@openai/codex"),
            installed: true,
            pathLookup: lookup
        )

        XCTAssertEqual(result.status, .checkFailed)
        XCTAssertTrue(result.message?.contains("Could not resolve command path") == true)
    }

    func testFlowRowF7TypedEngineCheckIncludesCompetingInstallsMessage() async throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let seed = UUID().uuidString

        let primary = try createNpmInstallation(
            root: home,
            prefixPath: ".nvm/versions/node/dailyupdate-test-\(seed)-primary",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )
        let secondary = try createNpmInstallation(
            root: home,
            prefixPath: ".nvm/versions/node/dailyupdate-test-\(seed)-secondary",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )
        defer {
            try? FileManager.default.removeItem(at: primary.prefix)
            try? FileManager.default.removeItem(at: secondary.prefix)
        }

        let lookup = CommandPathLookup(candidatesByName: [
            "codex": [primary.commandPath.path, secondary.commandPath.path],
        ])
        let result = await UpdateCheckService.check(
            typedConfig(id: "f7", commandName: "codex", packageName: "@openai/codex"),
            installed: true,
            pathLookup: lookup
        )

        XCTAssertEqual(
            result.status,
            .updateAvailable,
            "status=\(result.status) block=\(String(describing: result.blockReason)) message=\(String(describing: result.message))"
        )
        XCTAssertTrue(result.message?.contains("Multiple installs detected") == true)
    }

    func testFlowRowF8TypedEngineCheckReturnsFingerprintAndSingleSpec() async throws {
        let fixture = try makeTypedCheckFixture(installedVersion: "1.0.0", latestOutput: "\"1.1.0\"")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await UpdateCheckService.check(
            fixture.config,
            installed: true,
            pathLookup: fixture.lookup
        )

        XCTAssertNotNil(result.ownerFingerprint, "status=\(result.status) block=\(String(describing: result.blockReason))")
        XCTAssertTrue(
            result.plannedUpdateCommandSpec?.isSingle == true,
            "status=\(result.status) block=\(String(describing: result.blockReason)) message=\(String(describing: result.message))"
        )
    }

    func testL1UpdateExecutorUsesInjectedSpecRunnerForPlannedCommands() async {
        let probe = RunnerProbe()
        let item = makeUpdateItem(
            id: "l1",
            plannedSpec: CommandSpec(executablePath: "/bin/echo", arguments: ["planned"])
        )

        let result = await UpdateExecutor.update(
            item,
            runner: UpdateExecutor.Runner(
                runCommand: { command, directory, timeout in
                    await probe.recordCommand(command: command, directory: directory, timeout: timeout)
                    return .init(exitCode: 1, stdout: "", stderr: "command path should not run")
                },
                runSpec: { spec, timeout in
                    await probe.recordSpec(spec: spec, timeout: timeout)
                    return .init(exitCode: 1, stdout: "", stderr: "spec failed")
                }
            )
        )

        let commandCount = await probe.commandCount
        let specCount = await probe.specCount
        XCTAssertEqual(result.status, .error)
        XCTAssertEqual(commandCount, 0)
        XCTAssertEqual(specCount, 1)
    }

    func testL2UpdateExecutorUsesInjectedCommandRunnerWhenNoPlannedSpec() async {
        let probe = RunnerProbe()
        let item = makeUpdateItem(id: "l2", plannedSpec: nil, workingDirectory: "~/workspace")

        let result = await UpdateExecutor.update(
            item,
            runner: UpdateExecutor.Runner(
                runCommand: { command, directory, timeout in
                    await probe.recordCommand(command: command, directory: directory, timeout: timeout)
                    return .init(exitCode: 1, stdout: "", stderr: "command failed")
                },
                runSpec: { spec, timeout in
                    await probe.recordSpec(spec: spec, timeout: timeout)
                    return .init(exitCode: 1, stdout: "", stderr: "spec should not run")
                }
            )
        )

        let commandCount = await probe.commandCount
        let specCount = await probe.specCount
        XCTAssertEqual(result.status, .error)
        XCTAssertEqual(commandCount, 1)
        XCTAssertEqual(specCount, 0)
    }

    func testL7UpdateExecutorInstallPathUsesInjectedCommandRunner() async {
        let probe = RunnerProbe()
        var item = makeUpdateItem(id: "l7", plannedSpec: nil)
        item.isInstalled = false
        item.status = .notInstalled

        let result = await UpdateExecutor.update(
            item,
            runner: UpdateExecutor.Runner(
                runCommand: { command, directory, timeout in
                    await probe.recordCommand(command: command, directory: directory, timeout: timeout)
                    return .init(exitCode: 1, stdout: "", stderr: "install failed")
                },
                runSpec: { spec, timeout in
                    await probe.recordSpec(spec: spec, timeout: timeout)
                    return .init(exitCode: 1, stdout: "", stderr: "spec should not run")
                }
            )
        )

        let commandCount = await probe.commandCount
        let specCount = await probe.specCount
        XCTAssertEqual(result.status, .error)
        XCTAssertEqual(commandCount, 1)
        XCTAssertEqual(specCount, 0)
    }

    func testC12EveryTypedSpecIsSingle() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = EcosystemLayout.fixture(home: root.path)

        let brewPrefix = root.appendingPathComponent("opt/homebrew")
        try createExecutable(at: brewPrefix.appendingPathComponent("bin/brew"))

        let formulaBinary = brewPrefix.appendingPathComponent("Cellar/gh/2.101.0/bin/gh")
        try createExecutable(at: formulaBinary)
        let formulaResolution = OwnerResolution(
            commandName: "gh",
            active: OwnerCandidate(
                commandPath: formulaBinary.path,
                resolvedPath: formulaBinary.path,
                owner: .brewFormula("gh")
            ),
            competing: []
        )

        let caskBinary = brewPrefix.appendingPathComponent("Caskroom/openclaw/1.0.0/OpenClaw.app/Contents/MacOS/OpenClaw")
        try createExecutable(at: caskBinary)
        let caskResolution = OwnerResolution(
            commandName: "openclaw",
            active: OwnerCandidate(
                commandPath: caskBinary.path,
                resolvedPath: caskBinary.path,
                owner: .brewCask("openclaw")
            ),
            competing: []
        )

        let npmInstall = try createNpmInstallation(
            root: root,
            prefixPath: ".nvm/versions/node/v24.0.0",
            commandName: "codex",
            packageName: "@openai/codex",
            installedVersion: "1.0.0",
            latestOutput: "\"1.1.0\""
        )
        let npmResolution = OwnerResolution(
            commandName: "codex",
            active: OwnerCandidate(
                commandPath: npmInstall.commandPath.path,
                resolvedPath: npmInstall.resolvedPath.path,
                owner: .npm(prefix: npmInstall.prefix.path, package: "@openai/codex")
            ),
            competing: []
        )

        let nativeResolution = OwnerResolution(
            commandName: "claude",
            active: OwnerCandidate(
                commandPath: "\(root.path)/.local/share/claude/versions/2.1.281/bin/claude",
                resolvedPath: "\(root.path)/.local/share/claude/versions/2.1.281/bin/claude",
                owner: .nativeInstaller(.claudeCode)
            ),
            competing: []
        )

        let specs = [
            StrategyPlanner.commandForResolvedOwner(
                config: typedConfig(id: "typed-brew", commandName: "gh", packageName: "@openai/codex", brew: "gh"),
                resolution: formulaResolution,
                targetVersion: nil,
                layout: layout
            ),
            StrategyPlanner.commandForResolvedOwner(
                config: typedConfig(id: "typed-cask", commandName: "openclaw", packageName: "@openai/codex", brewCask: "openclaw"),
                resolution: caskResolution,
                targetVersion: nil,
                layout: layout
            ),
            StrategyPlanner.commandForResolvedOwner(
                config: typedConfig(id: "typed-npm", commandName: "codex", packageName: "@openai/codex"),
                resolution: npmResolution,
                targetVersion: "1.1.0",
                layout: layout
            ),
            StrategyPlanner.commandForResolvedOwner(
                config: DetectorConfig(
                    id: "typed-native",
                    name: "typed-native",
                    category: .cli,
                    description: nil,
                    source: .bundled,
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
                    appcastURL: nil,
                    autoUpdates: nil,
                    detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
                    versionCommand: "echo 2.1.280",
                    checkCommand: "echo UPDATE",
                    installCommand: nil,
                    updateCommand: "echo update",
                    workingDirectory: nil
                ),
                resolution: nativeResolution,
                targetVersion: "2.1.281",
                layout: layout
            ),
        ]
        .compactMap { $0 }

        XCTAssertEqual(specs.count, 4)
        XCTAssertTrue(specs.allSatisfy(\.isSingle))
    }

    func testSection7Point1ParsesBrewFormulaFixture() throws {
        let payload = try fixture(named: "brew-info-gh.json")
        let info = StrategyPlanner.parseBrewFormulaInfo(from: payload)
        XCTAssertEqual(info?.latestVersion, "2.102.0_1")
        XCTAssertEqual(info?.linkedVersion, "2.101.0")
        XCTAssertEqual(info?.linkedCellarPath, "/opt/homebrew/Cellar/gh/2.101.0")
    }

    func testSection7Point1ParsesBrewCaskFixture() throws {
        let payload = try fixture(named: "brew-info-cask-openclaw.json")
        XCTAssertEqual(StrategyPlanner.parseBrewCaskVersion(from: payload), "1.8.0")
    }

    func testSection7Point1ParsesClaudeDistTagsFixture() throws {
        let payload = try fixture(named: "npm-view-claude-code-dist-tags.json")
        let tags = StrategyPlanner.parseClaudeDistTags(from: payload)
        XCTAssertEqual(tags?["latest"], "2.1.281")
        XCTAssertEqual(tags?["stable"], "2.1.280")
    }

    func testClaudeChannelRejectsUnsupportedValue() async throws {
        let tempHome = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
        }

        let claudeSettingsDirectory = tempHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeSettingsDirectory, withIntermediateDirectories: true)
        try #"{"autoUpdatesChannel":"nightly"}"#.write(
            to: claudeSettingsDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let config = DetectorConfig(
            id: "claude-channel",
            name: "Claude Channel",
            category: .cli,
            description: nil,
            source: .bundled,
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
            appcastURL: nil,
            autoUpdates: nil,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo 2.1.280",
            checkCommand: "echo UPDATE",
            installCommand: nil,
            updateCommand: "echo update",
            workingDirectory: nil
        )
        let resolution = OwnerResolution(
            commandName: "claude",
            active: OwnerCandidate(
                commandPath: "\(tempHome.path)/.local/share/claude/versions/2.1.280/bin/claude",
                resolvedPath: "\(tempHome.path)/.local/share/claude/versions/2.1.280/bin/claude",
                owner: .nativeInstaller(.claudeCode)
            ),
            competing: []
        )

        let plan = await StrategyPlanner.checkPlan(
            config: config,
            currentVersion: "2.1.280",
            resolution: resolution
        )

        XCTAssertNil(plan.latestVersion)
        XCTAssertNil(plan.blockReason)
        XCTAssertEqual(plan.failureMessage, "Claude channel must be latest or stable")
    }

    func testDisplayStringRoundTripsThroughZsh() async {
        let spec = CommandSpec(
            executablePath: "/bin/zsh",
            arguments: ["-lc", "printf '%s\\n' \"$TEST_VALUE\" \"$1\" \"$2\"", "--", "arg with spaces", "Ada's tool"],
            environment: ["TEST_VALUE": "value with spaces"]
        )

        let result = await ShellRunner.run(spec.displayString)
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertEqual(
            result.stdout.components(separatedBy: .newlines),
            ["value with spaces", "arg with spaces", "Ada's tool"]
        )
    }

    @MainActor
    func testSecurityNilReplanSkipsExecution() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let store = UserSettingsStore()
            store.settings.confirmBeforeUpdate = false

            let plannedSpec = CommandSpec(executablePath: "/bin/echo", arguments: ["run"])
            let fingerprint = "fingerprint-nil-replan"
            let state = AppState(
                settingsStore: store,
                plannedCommandResolver: { _, _, _ in nil }
            )
            state.notificationsEnabled = false

            guard let index = state.items.firstIndex(where: { $0.id == "codex-cli" }) else {
                XCTFail("Missing codex-cli fixture")
                return
            }
            state.items[index].isInstalled = true
            state.items[index].status = .updateAvailable
            state.items[index].latestVersion = "1.1.0"
            state.items[index].plannedUpdateCommandSpec = plannedSpec
            state.items[index].ownerFingerprint = fingerprint

            let plan = AppState.PlannedExecutionItem(
                id: "codex-cli",
                action: "Update",
                command: plannedSpec.displayString,
                workingDirectory: nil,
                ownerFingerprint: fingerprint
            )
            await state.updateSelected(
                skipDryRun: true,
                explicitTargetIDs: ["codex-cli"],
                explicitPlan: ["codex-cli": plan]
            )

            XCTAssertTrue(state.logLines.contains { $0.contains("changed since you confirmed, not run") })
            XCTAssertTrue(state.logLines.contains { $0.contains("Nothing run: all items changed since you confirmed") })
        }
    }

    @MainActor
    func testSecurityItemChangedDuringAwaitSkipsExecution() async throws {
        try await withTemporaryAppSupportDirectory { _ in
            let store = UserSettingsStore()
            store.settings.confirmBeforeUpdate = false

            let plannedSpec = CommandSpec(executablePath: "/bin/echo", arguments: ["run"])
            let fingerprint = "fingerprint-await-change"
            let state = AppState(
                settingsStore: store,
                plannedCommandResolver: { _, _, _ in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    return (plannedSpec, fingerprint)
                }
            )
            state.notificationsEnabled = false

            guard let index = state.items.firstIndex(where: { $0.id == "codex-cli" }) else {
                XCTFail("Missing codex-cli fixture")
                return
            }
            state.items[index].isInstalled = true
            state.items[index].status = .updateAvailable
            state.items[index].latestVersion = "1.1.0"
            state.items[index].plannedUpdateCommandSpec = plannedSpec
            state.items[index].ownerFingerprint = fingerprint

            let plan = AppState.PlannedExecutionItem(
                id: "codex-cli",
                action: "Update",
                command: plannedSpec.displayString,
                workingDirectory: nil,
                ownerFingerprint: fingerprint
            )

            Task.detached {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await MainActor.run {
                    if let mutableIndex = state.items.firstIndex(where: { $0.id == "codex-cli" }) {
                        state.items[mutableIndex].plannedUpdateCommandSpec = CommandSpec(
                            executablePath: "/bin/echo",
                            arguments: ["changed"]
                        )
                    }
                }
            }

            await state.updateSelected(
                skipDryRun: true,
                explicitTargetIDs: ["codex-cli"],
                explicitPlan: ["codex-cli": plan]
            )

            XCTAssertTrue(state.logLines.contains { $0.contains("changed since you confirmed, not run") })
            XCTAssertTrue(state.logLines.contains { $0.contains("Nothing run: all items changed since you confirmed") })
        }
    }
}

private actor RunnerProbe {
    private(set) var commandCount = 0
    private(set) var specCount = 0

    func recordCommand(command: String, directory: String?, timeout: TimeInterval) {
        _ = command
        _ = directory
        _ = timeout
        commandCount += 1
    }

    func recordSpec(spec: CommandSpec, timeout: TimeInterval) {
        _ = spec
        _ = timeout
        specCount += 1
    }
}

private struct NpmInstallation {
    let prefix: URL
    let commandPath: URL
    let resolvedPath: URL
}

private struct TypedCheckFixture {
    let root: URL
    let install: NpmInstallation
    let config: DetectorConfig
    let lookup: CommandPathLookup
}

private func makeTypedCheckFixture(
    installedVersion: String,
    latestOutput: String
) throws -> TypedCheckFixture {
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let pathSuffix = ".nvm/versions/node/dailyupdate-test-\(UUID().uuidString)"
    let install = try createNpmInstallation(
        root: home,
        prefixPath: pathSuffix,
        commandName: "codex",
        packageName: "@openai/codex",
        installedVersion: installedVersion,
        latestOutput: latestOutput
    )
    let config = typedConfig(
        id: "typed-check-\(UUID().uuidString)",
        commandName: "codex",
        packageName: "@openai/codex"
    )
    let lookup = CommandPathLookup(candidatesByName: ["codex": [install.commandPath.path]])
    return TypedCheckFixture(root: install.prefix, install: install, config: config, lookup: lookup)
}

private func typedConfig(
    id: String,
    commandName: String,
    packageName: String,
    source: ItemSource? = .bundled,
    brew: String? = nil,
    brewCask: String? = nil
) -> DetectorConfig {
    DetectorConfig(
        id: id,
        name: id,
        category: .cli,
        description: nil,
        schemaVersion: 2,
        source: source,
        command: commandName,
        packages: PackageIdentifiers(
            brew: brew,
            brewCask: brewCask,
            npm: packageName,
            pipx: nil,
            uv: nil,
            cargo: nil,
            gem: nil,
            masAdamID: nil
        ),
        selfUpdater: nil,
        appcastURL: nil,
        autoUpdates: nil,
        detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
        versionCommand: "echo 1.0.0",
        versionPattern: nil,
        checkCommand: "echo UPDATE",
        installCommand: nil,
        updateCommand: "echo update",
        workingDirectory: nil,
        needsReview: false
    )
}

private func makeUpdateItem(
    id: String,
    plannedSpec: CommandSpec?,
    workingDirectory: String? = nil
) -> UpdateItem {
    UpdateItem(
        id: id,
        name: id,
        category: .cli,
        description: nil,
        currentVersion: "1.0.0",
        latestVersion: "1.1.0",
        status: .updateAvailable,
        statusMessage: nil,
        isInstalled: true,
        isSelected: true,
        isUserDefined: false,
        source: .bundled,
        iconPath: nil,
        detectCommand: nil,
        command: "codex",
        packages: PackageIdentifiers(
            brew: nil,
            brewCask: nil,
            npm: "@openai/codex",
            pipx: nil,
            uv: nil,
            cargo: nil,
            gem: nil,
            masAdamID: nil
        ),
        selfUpdater: nil,
        appcastURL: nil,
        autoUpdates: nil,
        versionCommand: "echo 1.0.0",
        versionPattern: nil,
        checkCommand: "echo UPDATE",
        installCommand: "echo install",
        updateCommand: "echo update",
        workingDirectory: workingDirectory,
        plannedUpdateCommandSpec: plannedSpec,
        ownerFingerprint: plannedSpec == nil ? nil : "fingerprint"
    )
}

private func makeTemporaryRoot() throws -> URL {
    let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent(".dailyupdate-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func normalizedPath(_ value: String) -> String {
    URL(fileURLWithPath: value).standardizedFileURL.path
}

private func createExecutable(at url: URL, contents: String = "#!/bin/sh\nexit 0\n") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func writePackageJSON(at url: URL, name: String, version: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload = """
    {"name":"\(name)","version":"\(version)"}
    """
    try payload.write(to: url, atomically: true, encoding: .utf8)
}

private func createNpmInstallation(
    root: URL,
    prefixPath: String,
    commandName: String,
    packageName: String,
    installedVersion: String,
    latestOutput: String,
    relativeSymlink: Bool = false,
    createNode: Bool = true
) throws -> NpmInstallation {
    let prefix = root.appendingPathComponent(prefixPath, isDirectory: true)
    if createNode {
        try createExecutable(at: prefix.appendingPathComponent("bin/node"))
    } else {
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    let latestEscaped = latestOutput.replacingOccurrences(of: "'", with: "'\"'\"'")
    let npmScript = """
    #!/bin/sh
    if [ "$1" = "view" ]; then
      printf '%s\\n' '\(latestEscaped)'
      exit 0
    fi
    echo "unexpected invocation: $*" >&2
    exit 1
    """
    try createExecutable(at: prefix.appendingPathComponent("bin/npm"), contents: npmScript)

    let resolvedPath = prefix
        .appendingPathComponent("lib/node_modules")
        .appendingPathComponent(packageName)
        .appendingPathComponent("bin")
        .appendingPathComponent(commandName)
    try createExecutable(at: resolvedPath)

    try writePackageJSON(
        at: prefix.appendingPathComponent("lib/node_modules").appendingPathComponent(packageName).appendingPathComponent("package.json"),
        name: packageName,
        version: installedVersion
    )

    let commandPath = prefix.appendingPathComponent("bin/\(commandName)")
    let destination: String
    if relativeSymlink {
        destination = resolvedPath.path.replacingOccurrences(of: "\(prefix.path)/", with: "../")
    } else {
        destination = resolvedPath.path
    }
    try? FileManager.default.removeItem(at: commandPath)
    try FileManager.default.createSymbolicLink(atPath: commandPath.path, withDestinationPath: destination)

    return NpmInstallation(prefix: prefix, commandPath: commandPath, resolvedPath: resolvedPath)
}

private func withTemporaryAppSupportDirectory(
    _ operation: (URL) async throws -> Void
) async throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    ConfigLoader.setAppSupportDirectoryForTesting(tempRoot)
    defer {
        ConfigLoader.setAppSupportDirectoryForTesting(nil)
        try? FileManager.default.removeItem(at: tempRoot)
    }
    try await operation(tempRoot)
}

private func fixture(named filename: String) throws -> String {
    let path = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(filename)
    return try String(contentsOf: path, encoding: .utf8)
}
