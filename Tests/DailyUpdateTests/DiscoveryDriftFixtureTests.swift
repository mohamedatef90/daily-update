import XCTest
@testable import DailyUpdate

/// ADR-002 §2 item 2 / §9 P2-3 task 8: "Fixtures are built from the documentation, plus the drift
/// set (extra keys, a missing version, a truncated file, an empty root). Only `complete` over an
/// empty root counts as '0 installed'." One drift case per P2-3 ecosystem, plus the "empty root is
/// complete, an unreadable one is not" pair each enumerator already gets from its own tests'
/// "missing root" case — this file adds the complementary "root exists but is empty" case, extra
/// keys tolerated, a missing version handled without crashing, and a truncated/malformed file
/// reported as an issue rather than a silent zero.
final class DiscoveryDriftFixtureTests: HermeticTestCase {
    // MARK: - uv: extra keys in METADATA, and an existing-but-empty tools root

    func testUvToolExtraMetadataKeysAreIgnored() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("tools")
        fixture.makeFile(
            at: "tools/browser-use/lib/python3.12/site-packages/browser_use-1.2.3.dist-info/METADATA",
            contents: "Metadata-Version: 2.1\nName: browser-use\nVersion: 1.2.3\nSummary: does things\nHome-page: https://example.com\nClassifier: Programming Language :: Python\n"
        )
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["UV_TOOL_DIR": root])
        let result = await UvToolEnumerator().enumerate(context)
        XCTAssertEqual(result.records.first?.versionRaw, "1.2.3")
    }

    func testUvToolEmptyRootIsCompleteWithZeroRecords() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("tools")
        fixture.makeDirectory("tools")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["UV_TOOL_DIR": root])
        let result = await UvToolEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    // MARK: - pipx: a missing package_version doesn't crash, and extra top-level keys are ignored

    func testPipxToleratesAMissingVersionAndExtraTopLevelKeys() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("pipx")
        fixture.makeFile(at: "pipx/venvs/black/pipx_metadata.json", contents: """
        {
          "main_package": { "package": "black", "apps": ["black"] },
          "some_future_field": { "nested": true },
          "pipx_metadata_version": "0.6"
        }
        """)
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["PIPX_HOME": home])
        let result = await PipxEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 1)
        XCTAssertNil(result.records.first?.versionRaw)
        XCTAssertEqual(result.records.first?.packageID, "black")
    }

    func testPipxEmptyVenvsRootIsCompleteWithZeroRecords() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("pipx")
        fixture.makeDirectory("pipx/venvs")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["PIPX_HOME": home])
        let result = await PipxEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    // MARK: - pip user: a truncated METADATA (no Name line at all) is malformed, not silently dropped

    func testPipUserTruncatedMetadataIsReportedNotSilentlyZero() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("home")
        fixture.makeFile(at: "home/Library/Python/3.12/lib/python/site-packages/broken-1.0.dist-info/METADATA", contents: "Metadata-Vers")
        fixture.makeFile(at: "home/Library/Python/3.12/lib/python/site-packages/broken-1.0.dist-info/REQUESTED", contents: "")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, layout: .fixture(home: home))
        let result = await PipUserEnumerator().enumerate(context)
        guard case .partial(let issues) = result.status else { return XCTFail("expected partial, got \(result.status)") }
        XCTAssertTrue(issues.contains { $0.kind == .malformed })
        XCTAssertEqual(result.records.count, 0)
    }

    func testPipUserEmptySitePackagesIsCompleteWithZeroRecords() async {
        let fixture = FixtureFileSystem()
        let home = fixture.path("home")
        fixture.makeDirectory("home/Library/Python/3.12/lib/python/site-packages")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, layout: .fixture(home: home))
        let result = await PipUserEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    // MARK: - cargo: extra keys in an install entry are ignored; an empty installs map is complete

    func testCargoExtraInstallKeysAreIgnored() async {
        let fixture = FixtureFileSystem()
        let cargoHome = fixture.path("cargo")
        fixture.makeFile(at: "cargo/.crates2.json", contents: """
        {
          "v": 1,
          "installs": {
            "ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)": {
              "version_req": null, "bins": [], "features": [], "all_features": false,
              "no_default_features": false, "profile": "release", "target": "aarch64-apple-darwin", "rustc": "1.82.0"
            }
          }
        }
        """)
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["CARGO_HOME": cargoHome])
        let result = await CargoEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.first?.packageID, "ripgrep")
    }

    func testCargoEmptyInstallsMapIsCompleteWithZeroRecords() async {
        let fixture = FixtureFileSystem()
        let cargoHome = fixture.path("cargo")
        fixture.makeFile(at: "cargo/.crates2.json", contents: #"{ "v": 1, "installs": {} }"#)
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["CARGO_HOME": cargoHome])
        let result = await CargoEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    // MARK: - gem: an unparseable gemspec file name is skipped, not reported as a crash; an empty
    // specifications/ folder is complete

    func testGemUnparseableFileNameIsSkipped() async {
        let fixture = FixtureFileSystem()
        let gemHome = fixture.path("gems")
        fixture.makeFile(at: "gems/specifications/not-a-version-anywhere.gemspec", contents: "Gem::Specification.new do |s|\nend\n")
        fixture.makeFile(at: "gems/specifications/rake-12.3.3.gemspec", contents: "Gem::Specification.new do |s|\nend\n")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["GEM_HOME": gemHome])
        let result = await GemEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.packageID, "rake")
    }

    func testGemEmptySpecificationsIsCompleteWithZeroRecords() async {
        let fixture = FixtureFileSystem()
        let gemHome = fixture.path("gems")
        fixture.makeDirectory("gems/specifications")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["GEM_HOME": gemHome])
        let result = await GemEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    // MARK: - version managers: an empty installs/ tree, and a pyenv versions/ folder with no
    // python binary at all inside it (a truncated/incomplete install), are both handled

    func testMiseEmptyInstallsIsCompleteWithZeroRecords() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("mise")
        fixture.makeDirectory("mise/installs")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["MISE_DATA_DIR": root])
        let result = await MiseEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testPyenvVersionFolderWithNoPythonBinaryIsSkippedNotCrashed() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("pyenv")
        fixture.makeDirectory("pyenv/versions/3.12.4/bin")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["PYENV_ROOT": root])
        let result = await PyenvEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }

    func testRustupEmptyToolchainsIsCompleteWithZeroRecords() async {
        let fixture = FixtureFileSystem()
        let root = fixture.path("rustup")
        fixture.makeDirectory("rustup/toolchains")
        let context = DiscoveryContext(fileSystem: fixture.fileSystem, environmentSnapshot: ["RUSTUP_HOME": root, "CARGO_HOME": fixture.path("cargo-empty")])
        let result = await RustupEnumerator().enumerate(context)
        guard case .complete = result.status else { return XCTFail("expected complete, got \(result.status)") }
        XCTAssertEqual(result.records.count, 0)
    }
}
