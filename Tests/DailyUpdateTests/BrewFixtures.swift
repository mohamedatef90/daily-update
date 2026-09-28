import XCTest
@testable import DailyUpdate

/// The P2-2 Homebrew fixtures: `Fixtures/brew-info-installed.json` and the Cellar/Caskroom tree
/// it describes. The JSON keeps the shape of `brew info --json=v2 --installed` on this Mac (keys,
/// nesting, `installed[]`, `linked_keg`, `artifacts[]`) trimmed to the cases §9 lists: a linked
/// on-request formula, a dependency, a linked keg-only formula, an unlinked keg-only formula, a
/// third-party tap, a pin, two kegs of one formula, a name that fails §7.4, and the openclaw cask.
/// Values are synthetic: on 2026-09-27 this Mac's Homebrew cache was gone, so the live call
/// couldn't be captured (see the PR's live verification).
enum BrewFixtures {
    static let installedJSON: String = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/brew-info-installed.json")
        return try! String(contentsOf: url, encoding: .utf8)
    }()

    /// `installedJSON` plus one formula whose name fails §7.4.
    static let installedJSONWithRejectedName = installedJSON.replacingOccurrences(of: #""formulae": ["#, with: #"""
    "formulae": [
        {"name": "-rf", "full_name": "-rf", "tap": "homebrew/core", "versions": {"stable": "1.0"},
         "revision": 0, "keg_only": false, "pinned": false, "linked_keg": "1.0",
         "installed": [{"version": "1.0", "installed_as_dependency": false, "installed_on_request": true}]},
    """#)

    /// The Homebrew prefix under `home` that `EcosystemLayout.fixture(home:)` lists first.
    static func prefix(_ fixture: FixtureFileSystem) -> String { fixture.path("opt/homebrew") }

    /// Builds the Cellar/Caskroom tree `installedJSON` describes, with receipts for the fallback.
    /// Returns the canonical prefix.
    @discardableResult
    static func makeTree(_ fixture: FixtureFileSystem) -> String {
        let brew = fixture.makeFile(at: "opt/homebrew/bin/brew", contents: "#!/bin/sh\nexit 99\n")
        fixture.chmod(brew, 0o755)
        func keg(_ name: String, _ version: String, commands: [String], linked: Bool, onRequest: Bool, tap: String = "homebrew/core") {
            fixture.makeDirectory("opt/homebrew/Cellar/\(name)/\(version)")
            fixture.makeFile(at: "opt/homebrew/Cellar/\(name)/\(version)/INSTALL_RECEIPT.json", contents: """
            {"installed_on_request": \(onRequest), "installed_as_dependency": \(!onRequest), "source": {"tap": "\(tap)", "spec": "stable"}}
            """)
            for command in commands {
                let path = fixture.makeFile(at: "opt/homebrew/Cellar/\(name)/\(version)/bin/\(command)", contents: "#!/bin/sh\n")
                fixture.chmod(path, 0o755)
                if linked {
                    fixture.makeSymlink(at: "opt/homebrew/bin/\(command)", relativeTarget: "../Cellar/\(name)/\(version)/bin/\(command)")
                }
            }
            if linked {
                fixture.makeSymlink(at: "opt/homebrew/var/homebrew/linked/\(name)", relativeTarget: "../../../Cellar/\(name)/\(version)")
            }
        }
        keg("gh", "2.101.0", commands: ["gh"], linked: true, onRequest: true)
        keg("abseil", "20260107.1", commands: [], linked: true, onRequest: false)
        keg("node@22", "22.22.2", commands: ["node", "npm"], linked: true, onRequest: true)
        keg("python@3.12", "3.12.10", commands: ["python3.12"], linked: false, onRequest: true)
        keg("bird", "0.8.0", commands: ["bird"], linked: true, onRequest: true, tap: "steipete/tap")
        keg("jq", "1.7.1", commands: ["jq"], linked: true, onRequest: true)
        keg("openssl@3", "3.3.0", commands: [], linked: false, onRequest: false)
        keg("openssl@3", "3.4.0", commands: [], linked: false, onRequest: false)
        fixture.makeFile(at: "opt/homebrew/var/homebrew/pinned/jq", contents: "")
        // An unrelated file in the prefix's bin that points outside every keg.
        let stray = fixture.makeFile(at: "opt/homebrew/bin/stray", contents: "#!/bin/sh\n")
        fixture.chmod(stray, 0o755)

        fixture.makeDirectory("opt/homebrew/Caskroom/openclaw/2026.1.23")
        fixture.makeSymlink(at: "opt/homebrew/Caskroom/openclaw/2026.1.23/Clawdbot.app", absoluteTarget: "/Applications/Clawdbot.app")
        return fixture.fileSystem.realpath(prefix(fixture))!
    }

    static func context(_ fixture: FixtureFileSystem, loginPath: LoginPath? = nil, snapshot: [String: String] = [:],
                        processEnvironment: [String: String] = [:]) -> DiscoveryContext {
        let canonicalBin = (fixture.fileSystem.realpath(prefix(fixture)) ?? prefix(fixture)) + "/bin"
        return DiscoveryContext(
            environmentSnapshot: snapshot,
            loginPath: loginPath ?? .known([canonicalBin, "/usr/bin", "/bin"]),
            layout: .fixture(home: fixture.root.path),
            processEnvironment: processEnvironment
        )
    }

    static func ranOutcome(_ json: String = installedJSON, termination: Termination = .exited(0), stderr: String = "") -> ReadOnlyQueries.EnricherOutcome {
        .ran(QueryOutcome(
            evidence: ProcessEvidence(executable: "/usr/bin/sandbox-exec", arguments: [], termination: termination,
                stderr: stderr, stderrTruncated: false, elapsedMs: 5),
            stdout: Data(json.utf8)
        ))
    }
}

/// Records what a stub enricher or runner was asked to do.
final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func record(_ call: String) {
        lock.lock(); _calls.append(call); lock.unlock()
    }
}

final class SpecRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _specs: [BoundedProcessSpec] = []

    var specs: [BoundedProcessSpec] {
        lock.lock(); defer { lock.unlock() }
        return _specs
    }

    func record(_ spec: BoundedProcessSpec) {
        lock.lock(); _specs.append(spec); lock.unlock()
    }
}
