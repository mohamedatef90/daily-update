import XCTest
@testable import DailyUpdate

/// ADR-002 §2 "mise / asdf", "pyenv" and "rustup" / §9 P2-3 task 7: trees built from the
/// documentation (none of these four is installed on this Mac), with rustup's proxies as real hard
/// links so `FileID` equality is the same POSIX fact `RustupEnumerator` reads on a real machine.
final class OtherVersionManagersTests: HermeticTestCase {
    // MARK: - mise / asdf

    func testMiseSkipsSymlinkedAliasFoldersButKeepsRealVersionDirectories() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("mise")
        fixture.makeDirectory("mise/installs/node/22.11.0")
        fixture.makeSymlink(at: "mise/installs/node/lts", relativeTarget: "22.11.0")

        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["MISE_DATA_DIR": root])
        let result = await MiseEnumerator().enumerate(context)

        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.packageID, "node@22.11.0")
        XCTAssertEqual(record.versionRaw, "22.11.0")
        XCTAssertEqual(record.owner, .versionManager(kind: .mise, root: root))
    }

    func testAsdfSameShapeAsMise() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("asdf")
        fixture.makeDirectory("asdf/installs/ruby/3.3.0")

        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["ASDF_DATA_DIR": root])
        let result = await AsdfEnumerator().enumerate(context)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.owner, .versionManager(kind: .asdf, root: root))
    }

    func testMiseMissingRootIsCompleteWithNoRecords() async {
        let fixture = FixtureFileSystem()
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["MISE_DATA_DIR": fixture.path("nope")])
        let result = await MiseEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    // MARK: - pyenv

    func testPyenvOnlyCountsVersionFoldersWithAPythonBinaryAndSkipsNonVersionNames() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("pyenv")
        let script = fixture.makeFile(at: "pyenv/versions/3.12.4/bin/python3.12", contents: "#!/bin/sh\n")
        fixture.chmod(script, 0o755)
        // A virtualenv nested under a version, and a non-version name at the top level: both skipped.
        fixture.makeDirectory("pyenv/versions/3.12.4/envs/myproject")
        fixture.makeDirectory("pyenv/versions/miniconda3-info")

        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["PYENV_ROOT": root])
        let result = await PyenvEnumerator().enumerate(context)

        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.packageID, "3.12.4")
        XCTAssertEqual(result.records.first?.owner, .versionManager(kind: .pyenv, root: root))
    }

    // MARK: - rustup

    func testRustupToolchainVersionFromTheFolderNameItself() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("rustup")
        fixture.makeDirectory("rustup/toolchains/1.82.0-aarch64-apple-darwin")

        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["RUSTUP_HOME": root, "CARGO_HOME": fixture.path("cargo-empty")])
        let result = await RustupEnumerator().enumerate(context)
        let toolchain = try! XCTUnwrap(result.records.first { $0.packageID == "1.82.0-aarch64-apple-darwin" })
        XCTAssertEqual(toolchain.versionRaw, "1.82.0")
    }

    func testRustupToolchainVersionFromTheChannelManifestWhenTheNameIsAChannelAlias() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("rustup")
        fixture.makeFile(at: "rustup/toolchains/stable-aarch64-apple-darwin/lib/rustlib/multirust-channel-manifest.toml", contents: """
        [pkg.rust]
        version = "1.82.0 (a-really-long-commit-hash 2026-09-01)"

        [pkg.rustc]
        version = "1.82.0"
        """)

        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["RUSTUP_HOME": root, "CARGO_HOME": fixture.path("cargo-empty")])
        let result = await RustupEnumerator().enumerate(context)
        let toolchain = try! XCTUnwrap(result.records.first { $0.packageID == "stable-aarch64-apple-darwin" })
        XCTAssertEqual(toolchain.versionRaw, "1.82.0")
    }

    func testRustupProxiesAreFoundByInodeAndNeverRun() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("rustup")
        let cargoHome = fixture.path("cargo")
        fixture.makeDirectory("rustup/toolchains")
        let rustupBinary = fixture.makeFile(at: "cargo/bin/rustup", contents: "not a real binary\n")
        fixture.chmod(rustupBinary, 0o755)
        fixture.makeHardLink(at: "cargo/bin/cargo", to: rustupBinary)
        fixture.makeHardLink(at: "cargo/bin/rustc", to: rustupBinary)
        // A regular, unrelated file with a proxy-like name must never be treated as a proxy.
        let unrelated = fixture.makeFile(at: "cargo/bin/rustfmt", contents: "a real standalone binary\n")
        fixture.chmod(unrelated, 0o755)

        let context = DiscoveryContext(
            fileSystem: fixture.fileSystem,
            environmentSnapshot: ["RUSTUP_HOME": root, "CARGO_HOME": cargoHome],
            loginPath: .known([cargoHome + "/bin"])
        )
        let result = await RustupEnumerator().enumerate(context)

        let cargoProxy = try! XCTUnwrap(result.records.first { $0.packageID == "cargo" })
        XCTAssertEqual(cargoProxy.owner, .versionManager(kind: .rustup, root: root))
        let rustcProxy = try! XCTUnwrap(result.records.first { $0.packageID == "rustc" })
        XCTAssertEqual(rustcProxy.owner, .versionManager(kind: .rustup, root: root))
        // Two different invoked names sharing rustup's inode must not collapse into one row.
        XCTAssertNotEqual(cargoProxy.fileID, rustcProxy.fileID)
        XCTAssertFalse(result.records.contains { $0.packageID == "rustfmt" })
    }

    func testCargoRowStaysBlockedManagedByRustup() async {
        let config = DetectorConfig(
            id: "test-item", name: "Test", category: .cli, description: nil, schemaVersion: 2,
            source: .bundled, command: "cargo", packages: nil, selfUpdater: nil, appcastURL: nil,
            autoUpdates: nil, inventory: nil, detect: nil, versionCommand: nil, versionPattern: nil,
            checkCommand: nil, installCommand: nil, updateCommand: "noop", workingDirectory: nil, needsReview: nil
        )
        let candidate = OwnerCandidate(commandPath: "/x/cargo", resolvedPath: "/x/cargo", owner: .versionManager(kind: .rustup, root: "/x/.rustup"))
        let resolution = OwnerResolution(commandName: "cargo", active: candidate, competing: [])
        let plan = await StrategyPlanner.checkPlan(config: config, currentVersion: nil, resolution: resolution)
        XCTAssertEqual(plan.blockReason, .managedByVersionManager)
        XCTAssertEqual(plan.failureMessage, "Managed by rustup")
    }
}
