import XCTest
@testable import DailyUpdate

/// Amendment 1 RC5's N matrix: a discovered npm row may only be updated from the registry when the
/// installed version was published there. Only stubs run; no real npm.
final class NpmProvenanceTests: HermeticTestCase {
    private struct Setup {
        let prefix: String
        let record: InstalledPackage
        let row: DetectorConfig
    }

    private func setup(_ fixture: FixtureFileSystem, name: String = "typescript", version: String = "5.4.0",
                       extra: String = "", catalogPackage: String? = nil) async throws -> Setup {
        let prefix = NodeFixtures.makePrefix(fixture, "usr/local")
        NodeFixtures.addPackage(fixture, prefix: "usr/local", name: name, version: version, extra: extra)
        let result = await NpmEnumerator().enumerate(NodeFixtures.context(fixture, loginPath: .known(["\(prefix)/bin"])))
        let record = try XCTUnwrap(result.records.first { $0.packageID == name })
        let identity = InventoryIdentity(ecosystem: .npm, packageID: name, rootPath: prefix,
            packageDirectory: record.packageDirectory, toolPath: record.root.toolPath)
        let row = DetectorConfig(
            id: "row", name: name, category: .cli, description: nil, schemaVersion: nil, source: .inventory,
            command: nil, packages: catalogPackage.map { PackageIdentifiers(npm: $0) }, selfUpdater: nil, appcastURL: nil,
            autoUpdates: nil, inventory: identity, handle: "npm:\(name)", detect: nil, versionCommand: nil, versionPattern: nil,
            checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil, needsReview: nil
        )
        return Setup(prefix: prefix, record: record, row: row)
    }

    private func services(_ calls: SpecRecorder, stdout: String, termination: Termination = .exited(0), stderr: String = "",
                          phaseOne: CallRecorder? = nil, phaseOneStdout: String = "") -> StrategyPlanner.Services {
        var services = StrategyPlanner.Services.live
        services.runBounded = { spec in
            calls.record(spec)
            return QueryOutcome(evidence: ProcessEvidence(executable: spec.executable, arguments: spec.arguments,
                termination: termination, stderr: stderr, stderrTruncated: false, elapsedMs: 3), stdout: Data(stdout.utf8))
        }
        services.runProcess = { spec in
            phaseOne?.record(([spec.executablePath] + spec.arguments).joined(separator: " "))
            return ShellRunner.Result(exitCode: 0, stdout: phaseOneStdout, stderr: "")
        }
        return services
    }

    private func plan(_ setup: Setup, _ services: StrategyPlanner.Services) async throws -> StrategyPlan {
        try await XCTUnwrapAsync(await StrategyPlanner.checkPlan(
            config: setup.row, currentVersion: nil, resolve: { _ in setup.record }, services: services))
    }

    private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
        let resolved = try await value()
        return try XCTUnwrap(resolved)
    }

    /// N1: installed 5.4.0 is published and latest is 5.6.0 → Update Available, the exact view
    /// argv, and the exact install argv.
    func testN1PublishedVersionGetsAnUpdate() async throws {
        let fixture = FixtureFileSystem()
        let setup = try await setup(fixture)
        let calls = SpecRecorder()
        let plan = try await plan(setup, services(calls, stdout: #"{"versions": ["5.3.0", "5.4.0", "5.6.0"], "dist-tags": {"latest": "5.6.0", "next": "5.7.0-beta"}}"#))
        XCTAssertEqual(calls.specs.map(\.executable), ["\(setup.prefix)/bin/npm"])
        XCTAssertEqual(calls.specs.map(\.arguments), [["view", "--json", "--global", "--prefix", setup.prefix, "typescript", "versions", "dist-tags"]])
        XCTAssertEqual(calls.specs.first?.environment, .inherited(overridingPATH: "\(setup.prefix)/bin:\(ShellRunner.defaultPath)"))
        XCTAssertEqual(calls.specs.first?.maxStdoutBytes, 4 * 1024 * 1024)
        XCTAssertEqual(plan.currentVersion, "5.4.0")
        XCTAssertEqual(plan.latestVersion, "5.6.0")
        XCTAssertNil(plan.blockReason)
        XCTAssertNil(plan.failureMessage)
        XCTAssertEqual(plan.updateCommandSpec?.executablePath, "\(setup.prefix)/bin/npm")
        XCTAssertEqual(plan.updateCommandSpec?.arguments, ["install", "-g", "--prefix", setup.prefix, "typescript@5.6.0"])
    }

    /// N2: the installed version isn't in `versions` → Blocked(manualOnly).
    func testN2UnpublishedVersionIsBlocked() async throws {
        let fixture = FixtureFileSystem()
        let setup = try await setup(fixture)
        let plan = try await plan(setup, services(SpecRecorder(), stdout: #"{"versions": ["5.3.0", "5.6.0"], "dist-tags": {"latest": "5.6.0"}}"#))
        XCTAssertEqual(plan.blockReason, .manualOnly)
        XCTAssertEqual(plan.failureMessage, "Installed version isn't on the registry (git or tarball install?)")
        XCTAssertNil(plan.updateCommandSpec)
    }

    /// N3: `_resolved` is git or a file path → Blocked, before any `npm view`, even though the
    /// version is published.
    func testN3NonRegistryResolvedIsBlocked() async throws {
        for resolved in ["git+ssh://git@github.com/me/typescript.git#abc", "file:../x", "/Users/me/typescript", "github:me/typescript"] {
            let fixture = FixtureFileSystem()
            let setup = try await setup(fixture, extra: "\"_resolved\": \"\(resolved)\", \"_from\": \"x\"")
            let calls = SpecRecorder()
            let plan = try await plan(setup, services(calls, stdout: #"{"versions": ["5.4.0", "5.6.0"], "dist-tags": {"latest": "5.6.0"}}"#))
            XCTAssertEqual(plan.blockReason, .manualOnly, resolved)
            XCTAssertEqual(plan.failureMessage, "Installed version isn't on the registry (git or tarball install?)", resolved)
            XCTAssertEqual(calls.specs.count, 0, resolved)
        }
    }

    /// A registry-shaped `_resolved` passes; so does a scoped one.
    func testRegistryShapedResolvedIsAllowed() async throws {
        let fixture = FixtureFileSystem()
        let setup = try await setup(fixture, extra: #""_resolved": "https://registry.npmjs.org/typescript/-/typescript-5.4.0.tgz""#)
        let plan = try await plan(setup, services(SpecRecorder(), stdout: #"{"versions": ["5.4.0", "5.6.0"], "dist-tags": {"latest": "5.6.0"}}"#))
        XCTAssertEqual(plan.latestVersion, "5.6.0")
        XCTAssertNil(plan.blockReason)
        XCTAssertTrue(NpmPackageStrategyShape.isRegistryTarball(
            "https://registry.npmjs.org/@scope/pkg/-/pkg-1.0.0.tgz", package: "@scope/pkg", version: "1.0.0"))
        XCTAssertFalse(NpmPackageStrategyShape.isRegistryTarball(
            "https://registry.npmjs.org/typescript/-/typescript-5.4.1.tgz", package: "typescript", version: "5.4.0"))
        XCTAssertFalse(NpmPackageStrategyShape.isRegistryTarball(
            "http://registry.npmjs.org/typescript/-/typescript-5.4.0.tgz", package: "typescript", version: "5.4.0"))
        XCTAssertFalse(NpmPackageStrategyShape.isRegistryTarball(
            "https://evil.example/x?/typescript/-/typescript-5.4.0.tgz", package: "typescript", version: "5.4.0"))
    }

    /// N4: E404 or a timeout → Check Failed; never Current, never Update Available.
    func testN4FailedViewIsCheckFailed() async throws {
        let fixture = FixtureFileSystem()
        let setup = try await setup(fixture)
        let notFound = try await plan(setup, services(SpecRecorder(), stdout: "", termination: .exited(1),
            stderr: "npm error code E404?npm error 404 Not Found"))
        XCTAssertEqual(notFound.failureMessage, "npm view failed: exit 1: npm error code E404")
        XCTAssertNil(notFound.blockReason)
        XCTAssertNil(notFound.latestVersion)
        XCTAssertNil(notFound.updateCommandSpec)
        let timedOut = try await plan(setup, services(SpecRecorder(), stdout: "", termination: .timedOut(afterMs: 30000)))
        XCTAssertEqual(timedOut.failureMessage, "npm view failed: timed out")
        XCTAssertNil(timedOut.updateCommandSpec)
    }

    /// N5: a package with one published version returns `versions` as a string.
    func testN5StringVersionsIsOneElementList() async throws {
        let fixture = FixtureFileSystem()
        let setup = try await setup(fixture, version: "1.0.0")
        let plan = try await plan(setup, services(SpecRecorder(), stdout: #"{"versions": "1.0.0", "dist-tags": {"latest": "1.0.0"}}"#))
        XCTAssertNil(plan.blockReason)
        XCTAssertNil(plan.failureMessage)
        XCTAssertEqual(plan.latestVersion, "1.0.0")
    }

    /// N6: a catalog-joined `@openai/codex` keeps the Phase 1 call and argv.
    func testN6CatalogJoinedPackageKeepsPhaseOne() async throws {
        let fixture = FixtureFileSystem()
        let setup = try await setup(fixture, name: "@openai/codex", version: "1.0.0", catalogPackage: "@openai/codex")
        let bounded = SpecRecorder()
        let phaseOne = CallRecorder()
        let plan = try await plan(setup, services(bounded, stdout: "", phaseOne: phaseOne, phaseOneStdout: "\"1.1.0\""))
        XCTAssertEqual(bounded.specs.count, 0)
        XCTAssertEqual(phaseOne.calls, ["\(setup.prefix)/bin/npm view @openai/codex@latest version --json"])
        XCTAssertEqual(plan.latestVersion, "1.1.0")
        XCTAssertEqual(plan.updateCommandSpec?.arguments, ["install", "-g", "--prefix", setup.prefix, "@openai/codex@1.1.0"])
    }

    /// A `latest` dist-tag that isn't strict semver is Check Failed.
    func testNonSemverLatestIsCheckFailed() async throws {
        let fixture = FixtureFileSystem()
        let setup = try await setup(fixture)
        let plan = try await plan(setup, services(SpecRecorder(), stdout: #"{"versions": ["5.4.0"], "dist-tags": {"latest": "latest\n"}}"#))
        XCTAssertEqual(plan.failureMessage, "npm's latest dist-tag is missing or isn't strict semver")
        XCTAssertNil(plan.updateCommandSpec)
    }
}
