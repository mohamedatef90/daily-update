import XCTest
@testable import DailyUpdate

/// Builders for the P2-2 Node trees (npm prefixes, nvm/fnm versions, pnpm/yarn/bun global
/// folders). The npm and nvm shapes are the ones captured on this Mac with values made up; pnpm,
/// yarn classic, bun and fnm follow their documentation (§2 "documented").
enum NodeFixtures {
    /// A prefix with `bin/node`, `bin/npm` and `lib/node_modules`. `relative` is under the fixture
    /// root. Returns the canonical prefix.
    @discardableResult
    static func makePrefix(_ fixture: FixtureFileSystem, _ relative: String) -> String {
        for tool in ["node", "npm"] {
            let path = fixture.makeFile(at: "\(relative)/bin/\(tool)", contents: "#!/bin/sh\n")
            fixture.chmod(path, 0o755)
        }
        fixture.makeDirectory("\(relative)/lib/node_modules")
        return fixture.fileSystem.realpath(fixture.path(relative))!
    }

    /// `lib/node_modules/<name>` with a `package.json`, its bin files, and `<prefix>/bin/<cmd>`
    /// links into it. `extra` is spliced into the manifest (`"_resolved": …`).
    static func addPackage(
        _ fixture: FixtureFileSystem, prefix relative: String, name: String, version: String?,
        bins: [String: String] = [:], extra: String = "", linkBins: Bool = true
    ) {
        let folder = "\(relative)/lib/node_modules/\(name)"
        writeManifest(fixture, folder: folder, name: name, version: version, bins: bins, extra: extra)
        for (command, target) in bins.sorted(by: { $0.key < $1.key }) {
            let file = fixture.makeFile(at: "\(folder)/\(target)", contents: "#!/usr/bin/env node\n")
            fixture.chmod(file, 0o755)
            let depth = name.contains("/") ? "../lib/node_modules/\(name)" : "../lib/node_modules/\(name)"
            if linkBins { fixture.makeSymlink(at: "\(relative)/bin/\(command)", relativeTarget: "\(depth)/\(target)") }
        }
    }

    static func writeManifest(_ fixture: FixtureFileSystem, folder: String, name: String, version: String?,
                              bins: [String: String] = [:], extra: String = "") {
        var fields = ["\"name\": \"\(name)\""]
        if let version { fields.append("\"version\": \"\(version)\"") }
        if !bins.isEmpty {
            let map = bins.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
            fields.append("\"bin\": {\(map)}")
        }
        if !extra.isEmpty { fields.append(extra) }
        fixture.makeFile(at: "\(folder)/package.json", contents: "{\(fields.joined(separator: ", "))}")
    }

    /// An nvm version folder `~/.nvm/versions/node/v<version>` that is also an npm prefix.
    @discardableResult
    static func makeNvmVersion(_ fixture: FixtureFileSystem, _ version: String) -> String {
        makePrefix(fixture, ".nvm/versions/node/v\(version)")
    }

    static func context(_ fixture: FixtureFileSystem, loginPath: LoginPath, snapshot: [String: String] = [:]) -> DiscoveryContext {
        DiscoveryContext(environmentSnapshot: snapshot, loginPath: loginPath, layout: .fixture(home: fixture.root.path))
    }

    static func canonical(_ fixture: FixtureFileSystem, _ relative: String) -> String {
        fixture.fileSystem.realpath(fixture.path(relative))!
    }
}
