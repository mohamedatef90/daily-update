import Foundation
import XCTest
@testable import DailyUpdate

final class PRB1ProvenanceAndSecurityTests: HermeticTestCase {
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

final class PRB1OwnerMatrixTests: HermeticTestCase {
    func testOwnerRowO2RelativeSymlinkResolvesAndBuildsPinnedSpec() throws {
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

    func testOwnerRowRejectsMalformedScopedPackagePath() throws {
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

    func testOwnerRowRejectsLeadingDashPackageNames() throws {
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

    func testOwnerRowRejectsPackageJSONNameMismatch() throws {
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

    func testOwnerRowRejectsPrefixesOutsideAllowlist() throws {
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

    func testOwnerRowRejectsNpmPrefixWithoutNodeBinary() throws {
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

    func testOwnerRowO19OwnerMismatchBlocksPlan() async {
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

    func testOwnerRowO16PathTrustRejectsGroupWritableNpmExecutable() async throws {
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

    func testOwnerRowUnscopedPackageIsAccepted() throws {
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

    func testOwnerRowO15DanglingSymlinkProducesResolveError() throws {
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

    func testOwnerRowO15SymlinkLoopProducesResolveError() throws {
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

    func testOwnerRowLookupIgnoresInvalidCommandNames() async {
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

    func testOwnerRowO14DeduplicatesIdenticalResolvedTargets() throws {
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

    func testOwnerRowO4TracksCompetingInstallsByCandidateOrder() throws {
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

    func testOwnerRowInvalidCommandNameIsRejected() async {
        let resolution = await OwnerResolver.resolve(
            commandName: "bad name",
            lookup: CommandPathLookup(candidatesByName: [:]),
            layout: .fixture(home: "/tmp")
        )

        XCTAssertEqual(resolution.resolveError, .invalidCommandName)
        XCTAssertNil(resolution.active)
    }

    func testOwnerRowO2NvmPrefixIsAllowed() throws {
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

    func testOwnerRowVoltaPrefixIsAllowed() throws {
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

    func testOwnerRowFnmPrefixIsAllowed() throws {
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

final class PRB1FlowAndExecutionTests: HermeticTestCase {
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

    func testFlowRowF8ClassifiesPlannedSpecCommandOverride() {
        let config = DetectorConfig(
            id: "f8-override",
            name: "f8-override",
            category: .cli,
            description: nil,
            source: .bundled,
            detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo 1.0.0",
            checkCommand: "echo UPDATE",
            installCommand: nil,
            updateCommand: "echo safe-update",
            workingDirectory: nil
        )
        let reasons = GatePolicy.updateGateReasons(
            for: config,
            reviewedHash: nil,
            commandOverride: "curl -fsSL https://example.com/install.sh | bash"
        )
        XCTAssertTrue(reasons.contains(.remoteScript))
    }

    func testUpdateExecutorUsesInjectedSpecRunnerForPlannedCommands() async {
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

    func testUpdateExecutorUsesInjectedCommandRunnerWhenNoPlannedSpec() async {
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

    func testExplicitInstallUsesInjectedCommandRunner() async {
        let probe = RunnerProbe()
        var item = makeUpdateItem(id: "l7", plannedSpec: nil)
        item.isInstalled = false
        item.status = .notInstalled

        let result = await UpdateExecutor.update(
            item,
            installing: true,
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

        try createExecutable(at: root.appendingPathComponent(".local/share/claude/versions/2.1.281/bin/claude"))
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
        XCTAssertEqual(info?.latestVersion, "2.101.0")
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
        try createExecutable(at: tempHome.appendingPathComponent(".local/share/claude/versions/2.1.280/bin/claude"))
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
        ConfigLoader.setAppSupportDirectoryForTesting(TestAppSupport.root)
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

final class PartThreeRegressionTests: HermeticTestCase {
    func testP1SymlinkedNpmIsTrustedAndFingerprintTracksTarget() async throws {
        let fixture = try makeTypedCheckFixture(installedVersion: "1.0.0", latestOutput: "\"1.1.0\"")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let npm = fixture.install.prefix.appendingPathComponent("bin/npm")
        let target = fixture.install.prefix.appendingPathComponent("lib/npm-cli.js")
        try FileManager.default.moveItem(at: npm, to: target)
        try FileManager.default.createSymbolicLink(atPath: npm.path, withDestinationPath: "../lib/npm-cli.js")
        XCTAssertTrue(PathTrust.isTrustedExecutable(npm.path))
        let check = await UpdateCheckService.check(fixture.config, installed: true, pathLookup: fixture.lookup)
        XCTAssertEqual(check.status, .updateAvailable)
        let command = fixture.install.commandPath
        let owner = "\(command.path)|\(command.resolvingSymlinksInPath().path)|npm:\(fixture.install.prefix.path):@openai/codex"
        XCTAssertEqual(check.ownerFingerprint, "\(owner)|executor:\(target.path)")
        let replacement = fixture.install.prefix.appendingPathComponent("lib/npm-next.js")
        try FileManager.default.copyItem(at: target, to: replacement)
        try FileManager.default.removeItem(at: npm)
        try FileManager.default.createSymbolicLink(atPath: npm.path, withDestinationPath: replacement.path)
        let changed = await UpdateCheckService.check(fixture.config, installed: true, pathLookup: fixture.lookup)
        XCTAssertEqual(changed.ownerFingerprint, "\(owner)|executor:\(replacement.path)")
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: replacement.path)
        XCTAssertFalse(PathTrust.isTrustedExecutable(npm.path))
    }

    func testP1RejectsWritableAncestorsOfLinkAndTarget() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target/tool")
        let link = root.appendingPathComponent("link/tool")
        try createExecutable(at: target)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        for directory in [link.deletingLastPathComponent(), target.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
            XCTAssertFalse(PathTrust.isTrustedExecutable(link.path), directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        XCTAssertTrue(PathTrust.isTrustedExecutable(link.path))
    }

    func testP2SymlinkedNativeClaudeUsesResolvedVersionAndIsCurrent() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(".local/share/claude/versions/2.1.281")
        let link = root.appendingPathComponent(".local/bin/claude")
        try createExecutable(at: target)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let distTags: StrategyPlanner.ReleaseFetcher = { _ in #"{"latest":"2.1.281","stable":"2.1.281"}"# }
        var config = typedConfig(id: "native", commandName: "claude", packageName: "@anthropic-ai/claude-code")
        config.selfUpdater = "claudeCode"
        let lookup = CommandPathLookup(candidatesByName: ["claude": [link.path]], layout: .fixture(home: root.path))
        let check = await UpdateCheckService.check(config, installed: true, pathLookup: lookup, fetchRelease: distTags)
        XCTAssertEqual(check.status, .upToDate)
        XCTAssertEqual(check.currentVersion, "2.1.281")
        XCTAssertEqual(check.latestVersion, "2.1.281")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: target.path)
        let untrusted = await UpdateCheckService.check(config, installed: true, pathLookup: lookup, fetchRelease: distTags)
        XCTAssertEqual(untrusted.status, .blocked)
        XCTAssertEqual(untrusted.message, "Untrusted Claude executable path")
    }

    func testClaudeDistTagsFetchRunsPinnedCurlWithExactArgv() async {
        XCTAssertEqual(StrategyPlanner.claudeDistTagsRequest, CommandSpec(executablePath: "/usr/bin/curl", arguments: [
            "-q", "--proto", "=https", "--fail", "--silent", "--show-error", "--max-time", "20",
            "https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags"]))
        var requests: [CommandSpec] = []
        let payload = await StrategyPlanner.fetchBody(StrategyPlanner.claudeDistTagsRequest) { spec in
            requests.append(spec)
            return ShellRunner.Result(exitCode: 0, stdout: "{}", stderr: "")
        }
        XCTAssertEqual(payload, "{}")
        XCTAssertEqual(requests, [StrategyPlanner.claudeDistTagsRequest])
        let failed = await StrategyPlanner.fetchBody(StrategyPlanner.claudeDistTagsRequest) { _ in
            ShellRunner.Result(exitCode: 22, stdout: "{}", stderr: "")
        }
        XCTAssertNil(failed)
    }

    func testP2MissingTypedCurrentFailsWithoutLegacyFallback() async throws {
        let fixture = try makeTypedCheckFixture(installedVersion: "", latestOutput: "\"1.1.0\"")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let check = await UpdateCheckService.check(fixture.config, installed: true, pathLookup: fixture.lookup)
        XCTAssertEqual(check.status, .checkFailed)
        XCTAssertNil(check.currentVersion)
        XCTAssertNil(check.plannedUpdateCommandSpec)
        XCTAssertEqual(check.message, "Could not read installed version")
    }

    func testP4KegNodeGlobalPackageIsNpmOwner() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = try createNpmInstallation(root: root, prefixPath: "opt/homebrew/Cellar/node@22/22.0.0",
            commandName: "codex", packageName: "@openai/codex", installedVersion: "1.0.0", latestOutput: "1.1.0")
        let result = OwnerResolver.resolve(commandName: "codex", candidatePaths: [install.commandPath.path], layout: .fixture(home: root.path))
        XCTAssertEqual(result.active?.owner, .npm(prefix: install.prefix.path, package: "@openai/codex"))
    }

    func testOwnerRowO20ComponentPrefixCellar2IsNotCellar() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("opt/homebrew/Cellar2/gh/1.0.0/bin/gh")
        try createExecutable(at: binary)
        let result = OwnerResolver.resolve(commandName: "gh", candidatePaths: [binary.path], layout: .fixture(home: root.path))
        XCTAssertEqual(result.active?.owner, .unknown)
    }

    func testP5FormulaUsesLinkedKegAndOneInfoCallPerPlan() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("opt/homebrew")
        let binary = prefix.appendingPathComponent("Cellar/gh/2.101.0/bin/gh")
        try createExecutable(at: binary)
        let count = root.appendingPathComponent("calls")
        let data = try fixture(named: "brew-info-gh.json")
        try createExecutable(at: prefix.appendingPathComponent("bin/brew"), contents:
            "#!/bin/sh\necho info >> \(ShellEscaping.quote(count.path))\nprintf '%s' \(ShellEscaping.quote(data))\n")
        var config = typedConfig(id: "formula", commandName: "gh", packageName: "unused", brew: "gh")
        config.packages?.npm = nil
        let lookup = CommandPathLookup(candidatesByName: ["gh": [binary.path]], layout: .fixture(home: root.path))
        let check = await UpdateCheckService.check(config, installed: true, pathLookup: lookup)
        XCTAssertEqual(check.status, .upToDate)
        XCTAssertEqual(check.currentVersion, "2.101.0")
        XCTAssertEqual(check.plannedUpdateCommandSpec?.arguments, ["upgrade", "--formula", "gh"])
        XCTAssertEqual(try String(contentsOf: count), "info\n")
        let unlinked = data.replacingOccurrences(of: "\"linked_keg\": \"2.101.0\"", with: "\"linked_keg\": null")
        try createExecutable(at: prefix.appendingPathComponent("bin/brew"), contents: "#!/bin/sh\nprintf '%s' \(ShellEscaping.quote(unlinked))\n")
        let failure = await UpdateCheckService.check(config, installed: true, pathLookup: lookup)
        XCTAssertEqual(failure.status, .checkFailed)
        XCTAssertEqual(failure.message, "Could not read installed version")
        XCTAssertNil(failure.currentVersion)
    }

    func testP5BrewRevisionLinkedKegIsUpToDate() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("opt/homebrew")
        let binary = prefix.appendingPathComponent("Cellar/gh/2.102.0_1/bin/gh")
        try createExecutable(at: binary)
        let data = try fixture(named: "brew-info-gh.json")
            .replacingOccurrences(of: "\"stable\": \"2.101.0\"", with: "\"stable\": \"2.102.0\"")
            .replacingOccurrences(of: "\"revision\": 0", with: "\"revision\": 1")
            .replacingOccurrences(of: "\"linked_keg\": \"2.101.0\"", with: "\"linked_keg\": \"2.102.0_1\"")
        try createExecutable(at: prefix.appendingPathComponent("bin/brew"), contents: "#!/bin/sh\nprintf '%s' \(ShellEscaping.quote(data))\n")
        var config = typedConfig(id: "formula", commandName: "gh", packageName: "unused", brew: "gh")
        config.packages?.npm = nil
        let lookup = CommandPathLookup(candidatesByName: ["gh": [binary.path]], layout: .fixture(home: root.path))
        let check = await UpdateCheckService.check(config, installed: true, pathLookup: lookup)
        XCTAssertEqual(check.status, .upToDate)
        XCTAssertEqual(check.currentVersion, "2.102.0_1")
        XCTAssertEqual(check.latestVersion, "2.102.0_1")
    }

    func testP2CaskroomBinaryVersionDoesNotRequireAppBundle() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("opt/homebrew")
        let binary = prefix.appendingPathComponent("Caskroom/claude-code/2.1.281/claude")
        try createExecutable(at: binary)
        try createExecutable(at: prefix.appendingPathComponent("bin/brew"), contents: "#!/bin/sh\necho '{\"casks\":[{\"version\":\"2.1.281\"}]}'\n")
        let config = typedConfig(id: "cask", commandName: "claude", packageName: "unused", brewCask: "claude-code")
        let lookup = CommandPathLookup(candidatesByName: ["claude": [binary.path]], layout: .fixture(home: root.path))
        let check = await UpdateCheckService.check(config, installed: true, pathLookup: lookup)
        XCTAssertEqual(check.currentVersion, "2.1.281")
        XCTAssertEqual(check.status, .upToDate)
    }

    func testM5LookupFailureBecomesCheckFailed() async {
        let config = typedConfig(id: "lookup", commandName: "codex", packageName: "@openai/codex")
        let lookup = CommandPathLookup(candidatesByName: [:], failureMessage: "lookup fixture failed")
        let resolution = await OwnerResolver.resolve(commandName: "codex", lookup: lookup)
        XCTAssertEqual(resolution.resolveError, .lookupFailed("lookup fixture failed"))
        let check = await UpdateCheckService.check(config, installed: true, pathLookup: lookup)
        XCTAssertEqual(check.status, .checkFailed)
        XCTAssertEqual(check.message, "lookup fixture failed")
        XCTAssertNil(check.blockReason)
    }

    func testT7HomebrewPrefixEnvironmentDefinesLayout() async throws {
        let previous = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"]
        setenv("HOMEBREW_PREFIX", "/custom/brew", 1)
        defer { if let previous { setenv("HOMEBREW_PREFIX", previous, 1) } else { unsetenv("HOMEBREW_PREFIX") } }
        let layout = await EcosystemLayout.discover()
        // PR-B2a (Code Review suggestion 2): the configured prefix is added to the defaults.
        XCTAssertEqual(layout.brewPrefixes, ["/custom/brew", "/opt/homebrew", "/usr/local"])
        XCTAssertEqual(layout.brewCellars, ["/custom/brew/Cellar", "/opt/homebrew/Cellar", "/usr/local/Cellar"])
    }

    func testCatalogV2MigrationAndInvalidEntryIsolation() {
        let items = ConfigLoader.loadConfigs(settings: .defaults).filter { $0.source == .bundled }
        // PR-B2b: cursor-agent and opencode have native-installer strategies now.
        let migrated = Set(["codex-cli", "claude-code", "cline-cli", "gemini-cli", "qwen-code", "gh-cli", "cursor-agent", "opencode"])
        XCTAssertEqual(Set(items.filter { $0.schemaVersion == 2 }.map(\.id)), migrated)
        XCTAssertEqual(ConfigLoader.validateBundledConfigs(items).map(\.id), items.map(\.id))
        var invalid = typedConfig(id: "bad", commandName: "bad", packageName: "unused")
        invalid.packages = nil
        XCTAssertEqual(ConfigLoader.validateBundledConfigs([invalid] + items).map(\.id), items.map(\.id))
        invalid.packages = PackageIdentifiers(npm: "unused")
        invalid.command = " "
        XCTAssertEqual(ConfigLoader.validateBundledConfigs([invalid]).map(\.id), [])
    }

    func testUpdateDoesNotInstallMissingItem() async {
        let probe = RunnerProbe()
        var item = makeUpdateItem(id: "missing", plannedSpec: nil)
        item.isInstalled = false
        let result = await UpdateExecutor.update(item, runner: .init(
            runCommand: { command, directory, timeout in
                await probe.recordCommand(command: command, directory: directory, timeout: timeout)
                return .init(exitCode: 0, stdout: "", stderr: "")
            }, runSpec: { spec, timeout in
                await probe.recordSpec(spec: spec, timeout: timeout)
                return .init(exitCode: 0, stdout: "", stderr: "")
            }))
        XCTAssertEqual(result.status, .error)
        let count = await probe.commandCount
        XCTAssertEqual(count, 0)
    }

    func testP6TypedVerificationUsesOwnerVersionAndBatchedLookup() async throws {
        let fixture = try makeTypedCheckFixture(installedVersion: "1.0.0", latestOutput: "\"1.1.0\"")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.config.toUpdateItem()
        item.isInstalled = true
        item.currentVersion = "1.0.0"
        item.latestVersion = "1.1.0"
        let spec = CommandSpec(executablePath: fixture.install.prefix.appendingPathComponent("bin/npm").path,
            arguments: ["install", "-g", "--prefix", fixture.install.prefix.path, "@openai/codex@1.1.0"])
        item.plannedUpdateCommandSpec = spec
        let json = fixture.install.prefix.appendingPathComponent("lib/node_modules/@openai/codex/package.json")
        try createExecutable(at: fixture.install.prefix.appendingPathComponent("bin/npm"), contents: """
        #!/bin/sh
        if [ "$1" = view ]; then echo '"1.1.0"'; exit 0; fi
        if [ "$1" = install ]; then printf '%s' '{"name":"@openai/codex","version":"1.1.0"}' > \(ShellEscaping.quote(json.path)); exit 0; fi
        exit 2
        """)
        let lookups = LookupProbe()
        let runner = UpdateExecutor.Runner(runCommand: UpdateExecutor.Runner.live.runCommand,
            runSpec: UpdateExecutor.Runner.live.runSpec,
            lookupCommand: { name in await lookups.record(name); return fixture.lookup })
        let result = await UpdateExecutor.update(item, runner: runner, config: fixture.config, pathLookup: fixture.lookup,
            reviewedCommandHash: GatePolicy.reviewedCommandHash(for: fixture.config))
        XCTAssertEqual(result.status, .updated)
        XCTAssertEqual(result.currentVersion, "1.1.0")
        let names = await lookups.names
        XCTAssertEqual(names, ["codex"])
    }

    @MainActor
    func testL7ChangedTypedSpecBetweenDryRunAndConfirmDoesNotRun() async throws {
        try await withTemporaryAppSupportDirectory { root in
            let marker = root.appendingPathComponent("must-not-run")
            let initial = CommandSpec(executablePath: "/usr/bin/touch", arguments: [marker.path])
            let replacement = CommandSpec(executablePath: "/bin/echo", arguments: ["changed"])
            let store = UserSettingsStore()
            let state = AppState(settingsStore: store, plannedCommandResolver: { _, _, _ in (replacement, "same-owner") })
            state.notificationsEnabled = false
            let index = try XCTUnwrap(state.items.firstIndex { $0.id == "codex-cli" })
            state.items[index].isInstalled = true
            state.items[index].status = .updateAvailable
            state.items[index].plannedUpdateCommandSpec = initial
            state.items[index].ownerFingerprint = "same-owner"
            state.items[index].latestVersion = "1.1.0"
            let plan = AppState.PlannedExecutionItem(id: "codex-cli", action: "Update", command: initial.displayString,
                workingDirectory: nil, ownerFingerprint: "same-owner")
            await state.updateSelected(skipDryRun: true, explicitTargetIDs: ["codex-cli"], explicitPlan: ["codex-cli": plan])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(state.logLines.contains { $0.contains("Nothing run: all items changed since you confirmed") })
        }
    }
}


extension PartThreeRegressionTests {
    func testMalformedBundledEntryDoesNotDropValidEntries() throws {
        let config = typedConfig(id: "valid", commandName: "codex", packageName: "@openai/codex")
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        let data = try JSONSerialization.data(withJSONObject: ["items": [["id": "malformed", "command": 5], valid]])
        XCTAssertEqual(ConfigLoader.decodeBundledConfigs(data)?.map(\.id), ["valid"])
    }

    @MainActor
    func testChangedOwnerFingerprintAtConfirmationDoesNotRun() async throws {
        try await withTemporaryAppSupportDirectory { root in
            let marker = root.appendingPathComponent("wrong-owner")
            let spec = CommandSpec(executablePath: "/usr/bin/touch", arguments: [marker.path])
            let store = UserSettingsStore()
            let state = AppState(settingsStore: store, plannedCommandResolver: { _, _, _ in (spec, "new-owner") })
            state.notificationsEnabled = false
            let index = try XCTUnwrap(state.items.firstIndex { $0.id == "codex-cli" })
            state.items[index].isInstalled = true
            state.items[index].status = .updateAvailable
            state.items[index].plannedUpdateCommandSpec = spec
            state.items[index].ownerFingerprint = "old-owner"
            state.items[index].latestVersion = "1.1.0"
            let plan = AppState.PlannedExecutionItem(id: "codex-cli", action: "Update", command: spec.displayString,
                workingDirectory: nil, ownerFingerprint: "old-owner")
            await state.updateSelected(skipDryRun: true, explicitTargetIDs: ["codex-cli"], explicitPlan: ["codex-cli": plan])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(state.logLines.contains { $0.contains("Nothing run: all items changed since you confirmed") })
        }
    }

    func testP6VerificationRejectsOwnerChangedByUpdate() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try createNpmInstallation(root: root, prefixPath: ".nvm/versions/node/first", commandName: "codex",
            packageName: "@openai/codex", installedVersion: "1.0.0", latestOutput: "1.1.0")
        let second = try createNpmInstallation(root: root, prefixPath: ".nvm/versions/node/second", commandName: "codex",
            packageName: "@openai/codex", installedVersion: "1.1.0", latestOutput: "1.1.0")
        let config = typedConfig(id: "changed-owner", commandName: "codex", packageName: "@openai/codex")
        let lookup = CommandPathLookup(candidatesByName: ["codex": [first.commandPath.path]], layout: .fixture(home: root.path))
        let stub = root.appendingPathComponent("change-owner")
        try createExecutable(at: stub, contents: "#!/bin/sh\n/bin/ln -sf \(ShellEscaping.quote(second.resolvedPath.path)) \(ShellEscaping.quote(first.commandPath.path))\n")
        var item = config.toUpdateItem()
        item.isInstalled = true
        item.latestVersion = "1.1.0"
        item.plannedUpdateCommandSpec = CommandSpec(executablePath: stub.path, arguments: [])
        // PR-B2a: the post-update lookup is fresh, so the fixture supplies it too.
        let runner = UpdateExecutor.Runner(runCommand: UpdateExecutor.Runner.live.runCommand,
            runSpec: UpdateExecutor.Runner.live.runSpec, lookupCommand: { _ in lookup })
        let result = await UpdateExecutor.update(item, runner: runner, config: config, pathLookup: lookup)
        XCTAssertEqual(result.status, .failedVerification)
        XCTAssertEqual(result.currentVersion, "1.1.0")
    }

    func testP6VerificationPassesReviewHashToLegacyCheck() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("verified")
        let config = DetectorConfig(id: "reviewed-verification", name: "Reviewed", category: .cli, description: nil,
            source: .user, detect: DetectRule(type: .always, paths: nil, command: nil, appName: nil),
            versionCommand: "echo 1.1.0", checkCommand: "touch \(ShellEscaping.quote(marker.path)); echo OK",
            installCommand: nil, updateCommand: "echo updated", workingDirectory: nil, needsReview: true)
        var item = config.toUpdateItem()
        item.isInstalled = true
        item.latestVersion = "1.1.0"
        let result = await UpdateExecutor.update(item, config: config, reviewedCommandHash: GatePolicy.reviewedCommandHash(for: config))
        XCTAssertEqual(result.status, .updated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}

private actor LookupProbe {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

/// PR-B2a item 1: Code Review's suggestions 1 and 2 and round 7's planner-input fetcher.
final class PRB2aFollowUpTests: HermeticTestCase {
    /// Suggestion 1: the post-update owner check uses a fresh lookup, so a new binary that the
    /// update put earlier on `PATH` is seen instead of the check-time snapshot.
    func testVerificationUsesAFreshLookupAfterTheUpdate() async throws {
        let fixture = try makeTypedCheckFixture(installedVersion: "1.0.0", latestOutput: "\"1.1.0\"")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.config.toUpdateItem()
        item.isInstalled = true
        item.currentVersion = "1.0.0"
        item.latestVersion = "1.1.0"
        let npm = fixture.install.prefix.appendingPathComponent("bin/npm")
        item.plannedUpdateCommandSpec = CommandSpec(executablePath: npm.path,
            arguments: ["install", "-g", "--prefix", fixture.install.prefix.path, "@openai/codex@1.1.0"])
        let json = fixture.install.prefix.appendingPathComponent("lib/node_modules/@openai/codex/package.json")
        let shadow = fixture.root.appendingPathComponent("shadow/codex")
        try createExecutable(at: npm, contents: """
        #!/bin/sh
        if [ "$1" = view ]; then echo '"1.1.0"'; exit 0; fi
        if [ "$1" = install ]; then printf '%s' '{"name":"@openai/codex","version":"1.1.0"}' > \(ShellEscaping.quote(json.path)); exit 0; fi
        exit 2
        """)
        try createExecutable(at: shadow)
        let fresh = CommandPathLookup(candidatesByName: ["codex": [shadow.path, fixture.install.commandPath.path]])
        let lookups = LookupProbe()
        let runner = UpdateExecutor.Runner(runCommand: UpdateExecutor.Runner.live.runCommand,
            runSpec: UpdateExecutor.Runner.live.runSpec,
            lookupCommand: { name in await lookups.record(name); return fresh })
        let result = await UpdateExecutor.update(item, runner: runner, config: fixture.config, pathLookup: fixture.lookup,
            reviewedCommandHash: GatePolicy.reviewedCommandHash(for: fixture.config))
        XCTAssertEqual(result.status, .failedVerification)
        XCTAssertEqual(result.message, "Resolved owner does not match catalog package identity")
        let names = await lookups.names
        XCTAssertEqual(names, ["codex"])
    }

    /// Suggestion 2: a discovered or configured prefix is added to the defaults, not swapped in.
    func testLayoutAddsTheDiscoveredPrefixToTheDefaults() {
        let custom = EcosystemLayout.live(home: "/Users/x", brewPrefix: "/custom/brew")
        XCTAssertEqual(custom.brewPrefixes, ["/custom/brew", "/opt/homebrew", "/usr/local"])
        XCTAssertEqual(custom.brewCaskrooms, ["/custom/brew/Caskroom", "/opt/homebrew/Caskroom", "/usr/local/Caskroom"])
        let rosetta = EcosystemLayout.live(home: "/Users/x", brewPrefix: "/usr/local")
        XCTAssertEqual(rosetta.brewPrefixes, ["/usr/local", "/opt/homebrew"])
        let standard = EcosystemLayout.live(home: "/Users/x", brewPrefix: "/opt/homebrew")
        XCTAssertEqual(standard.brewPrefixes, ["/opt/homebrew", "/usr/local"])
    }

    /// Suggestion 2: `brew --prefix` is spawned once per run, not once per lookup.
    func testBrewPrefixIsProbedOncePerRun() async {
        let probes = LookupProbe()
        let discovery = BrewPrefixDiscovery()
        let probe: @Sendable () async -> String? = { await probes.record("brew --prefix"); return "/custom/brew" }
        let first = await discovery.prefix(probe: probe)
        let second = await discovery.prefix(probe: probe)
        XCTAssertEqual(first, "/custom/brew")
        XCTAssertEqual(second, "/custom/brew")
        let count = await probes.names.count
        XCTAssertEqual(count, 1)
        let failed = BrewPrefixDiscovery()
        let none = await failed.prefix(probe: { nil })
        XCTAssertNil(none)
    }

    /// Round 7: the Claude dist-tags lookup goes through the `fetchRelease` planner input, like `pathLookup`.
    func testClaudeDistTagsFetcherIsAPlannerInput() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(".local/share/claude/versions/2.1.281")
        try createExecutable(at: target)
        var config = typedConfig(id: "native", commandName: "claude", packageName: "@anthropic-ai/claude-code")
        config.selfUpdater = "claudeCode"
        let lookup = CommandPathLookup(candidatesByName: ["claude": [target.path]], layout: .fixture(home: root.path))
        var requests: [CommandSpec] = []
        let newer = await UpdateCheckService.check(config, installed: true, pathLookup: lookup,
            fetchRelease: { spec in requests.append(spec); return #"{"latest":"2.1.282","stable":"2.1.281"}"# })
        XCTAssertEqual(newer.status, .updateAvailable)
        XCTAssertEqual(newer.latestVersion, "2.1.282")
        XCTAssertEqual(requests, [StrategyPlanner.claudeDistTagsRequest])
        let failed = await UpdateCheckService.check(config, installed: true, pathLookup: lookup, fetchRelease: { _ in nil })
        XCTAssertEqual(failed.status, .checkFailed)
        XCTAssertEqual(failed.message, "Could not determine latest version")
    }
}
