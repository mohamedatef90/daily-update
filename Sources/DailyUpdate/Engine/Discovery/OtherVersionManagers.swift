import Foundation

/// ADR-002 §2 "mise / asdf" and "pyenv" (P2-3): every install these managers track is filesystem
/// only — the shim/shell-hook side of RC4 (Case 1) is P2-4's `DispatcherRule`, not this file. This
/// file is `documented ⚠️`: none of mise, asdf, pyenv or rustup is installed on this Mac.
private enum ToolInstallRoots {
    /// `installs/<tool>/<version>/`. A symlinked version folder is an alias (`latest`, `lts`) and
    /// is skipped — only a real directory is a distinct install.
    static func toolVersionInstalls(under root: String, context: DiscoveryContext) -> [(tool: String, version: String)] {
        guard let toolListing = try? context.fileSystem.contentsOfDirectory("\(root)/installs") else { return [] }
        var found: [(String, String)] = []
        for tool in toolListing.entries.sorted() {
            guard let versionListing = try? context.fileSystem.contentsOfDirectory("\(root)/installs/\(tool)") else { continue }
            for version in versionListing.entries.sorted() {
                let path = "\(root)/installs/\(tool)/\(version)"
                guard let stat = context.fileSystem.lstat(path), !stat.isSymbolicLink else { continue }
                found.append((tool, version))
            }
        }
        return found
    }
}

/// `MISE_DATA_DIR` → `~/.local/share/mise`.
struct MiseEnumerator: Enumerator {
    let ecosystem: Ecosystem = .mise

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        await OtherVersionManagerSupport.enumerate(kind: .mise, ecosystem: .mise, root: Self.root(context: context), context: context)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        await OtherVersionManagerSupport.resolve(identity, ecosystem: .mise, kind: .mise, root: Self.root(context: context), context: context)
    }

    private static func root(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["MISE_DATA_DIR"], !override.isEmpty { return override }
        return "\(context.layout.homeDirectory)/.local/share/mise"
    }
}

/// `ASDF_DATA_DIR` → `~/.asdf`.
struct AsdfEnumerator: Enumerator {
    let ecosystem: Ecosystem = .asdf

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        await OtherVersionManagerSupport.enumerate(kind: .asdf, ecosystem: .asdf, root: Self.root(context: context), context: context)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        await OtherVersionManagerSupport.resolve(identity, ecosystem: .asdf, kind: .asdf, root: Self.root(context: context), context: context)
    }

    private static func root(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["ASDF_DATA_DIR"], !override.isEmpty { return override }
        return "\(context.layout.homeDirectory)/.asdf"
    }
}

private enum OtherVersionManagerSupport {
    static func enumerate(kind: VersionManagerKind, ecosystem: Ecosystem, root: String, context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        guard context.fileSystem.stat(root) != nil else {
            return EnumerationResult(ecosystem: ecosystem, status: .complete, elapsed: clock.now - start)
        }
        let installRoot = InstallRoot(ecosystem: ecosystem, path: root, label: kind.rawValue, binDirectories: [], activity: .unknown)
        guard PathTrust.isTrustedDirectory(root) else {
            let issue = EnumerationIssue(kind: .untrustedRoot, rootPath: root, message: "\(kind.rawValue) root is not trusted")
            return EnumerationResult(ecosystem: ecosystem, roots: [installRoot], status: .partial([issue]), elapsed: clock.now - start)
        }

        var records: [InstalledPackage] = []
        for install in ToolInstallRoots.toolVersionInstalls(under: root, context: context) {
            let path = "\(root)/installs/\(install.tool)/\(install.version)"
            guard let fileID = context.fileSystem.stat(path)?.fileID else { continue }
            records.append(InstalledPackage(
                ecosystem: ecosystem, packageID: "\(install.tool)@\(install.version)", versionRaw: install.version,
                root: installRoot, packageDirectory: path, owner: .versionManager(kind: kind, root: root),
                evidence: [Evidence(kind: "install-directory", path: path)], confidence: .proven, fileID: fileID
            ))
        }
        return EnumerationResult(ecosystem: ecosystem, roots: [installRoot], records: records, status: .complete, elapsed: clock.now - start)
    }

    static func resolve(_ identity: InventoryIdentity, ecosystem: Ecosystem, kind: VersionManagerKind, root: String, context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == ecosystem else { return nil }
        let result = await enumerate(kind: kind, ecosystem: ecosystem, root: root, context: context)
        return result.records.first { $0.packageID == identity.packageID }
    }
}

/// `PYENV_ROOT` → `~/.pyenv`. `versions/<v>/envs/*` (virtualenvs) are never listed directly — this
/// only reads the top level of `versions/`, so a nested `envs/` folder is never reached at all —
/// and a name that doesn't look like a version (doesn't start with a digit) is skipped.
struct PyenvEnumerator: Enumerator {
    let ecosystem: Ecosystem = .pyenv

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        let root = Self.root(context: context)
        guard context.fileSystem.stat(root) != nil else {
            return EnumerationResult(ecosystem: .pyenv, status: .complete, elapsed: clock.now - start)
        }
        let installRoot = InstallRoot(ecosystem: .pyenv, path: root, label: "pyenv", binDirectories: [], activity: .unknown)
        guard PathTrust.isTrustedDirectory(root) else {
            let issue = EnumerationIssue(kind: .untrustedRoot, rootPath: root, message: "pyenv root is not trusted")
            return EnumerationResult(ecosystem: .pyenv, roots: [installRoot], status: .partial([issue]), elapsed: clock.now - start)
        }
        guard let listing = try? context.fileSystem.contentsOfDirectory("\(root)/versions") else {
            return EnumerationResult(ecosystem: .pyenv, roots: [installRoot], status: .complete, elapsed: clock.now - start)
        }

        var records: [InstalledPackage] = []
        for version in listing.entries.sorted() {
            guard version.range(of: #"^\d"#, options: .regularExpression) != nil else { continue }
            let versionDirectory = "\(root)/versions/\(version)"
            guard let binListing = try? context.fileSystem.contentsOfDirectory("\(versionDirectory)/bin"),
                  binListing.entries.contains(where: { $0.hasPrefix("python") }) else { continue }
            guard let fileID = context.fileSystem.stat(versionDirectory)?.fileID else { continue }
            records.append(InstalledPackage(
                ecosystem: .pyenv, packageID: version, versionRaw: version, root: installRoot,
                packageDirectory: versionDirectory, owner: .versionManager(kind: .pyenv, root: root),
                evidence: [Evidence(kind: "install-directory", path: versionDirectory)], confidence: .proven, fileID: fileID
            ))
        }
        return EnumerationResult(ecosystem: .pyenv, roots: [installRoot], records: records, status: .complete, elapsed: clock.now - start)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .pyenv else { return nil }
        let result = await enumerate(context)
        return result.records.first { $0.packageID == identity.packageID }
    }

    private static func root(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["PYENV_ROOT"], !override.isEmpty { return override }
        return "\(context.layout.homeDirectory)/.pyenv"
    }
}

/// `RUSTUP_HOME` → `~/.rustup`; `CARGO_HOME/bin` for the proxies. Each installed toolchain in
/// `toolchains/<name>/` becomes its own row; the proxy files that share `rustup`'s own inode
/// (`FileID.rustupProxyAware`, P2-1) become their own rows too, so an inventory-sourced `cargo` or
/// `rustc` already carries `versionManager(rustup)` ownership without waiting for P2-4's
/// classify-time `DispatcherRule` — neither the toolchain scan nor the proxy scan ever runs
/// `rustc`/`cargo`/`rustup` itself.
struct RustupEnumerator: Enumerator {
    let ecosystem: Ecosystem = .rustup

    /// The standard proxy set rustup installs into `CARGO_HOME/bin` alongside itself.
    static let proxyNames = ["cargo", "rustc", "rustdoc", "rust-gdb", "rust-gdbgui", "rust-lldb", "cargo-clippy", "cargo-fmt", "clippy-driver", "rustfmt"]

    func enumerate(_ context: DiscoveryContext) async -> EnumerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        let root = Self.root(context: context)
        let cargoBin = Self.cargoBin(context: context)
        var installRoots: [InstallRoot] = []
        var records: [InstalledPackage] = []
        var issues: [EnumerationIssue] = []

        if context.fileSystem.stat(root) != nil {
            let toolchainsRoot = InstallRoot(ecosystem: .rustup, path: root, label: "rustup", binDirectories: [], activity: .unknown)
            installRoots.append(toolchainsRoot)
            if PathTrust.isTrustedDirectory(root) {
                if let listing = try? context.fileSystem.contentsOfDirectory("\(root)/toolchains") {
                    for name in listing.entries.sorted() {
                        guard let record = Self.toolchainRecord(name: name, root: root, installRoot: toolchainsRoot, context: context) else { continue }
                        records.append(record)
                    }
                }
            } else {
                issues.append(EnumerationIssue(kind: .untrustedRoot, rootPath: root, message: "rustup root is not trusted"))
            }
        }

        if let rustupFileID = Self.rustupFileID(cargoBin: cargoBin, context: context) {
            let proxyRoot = InstallRoot(ecosystem: .rustup, path: cargoBin, label: "rustup proxies", binDirectories: [cargoBin], activity: Self.activity(cargoBin: cargoBin, loginPath: context.loginPath))
            installRoots.append(proxyRoot)
            for name in Self.proxyNames {
                let candidatePath = "\(cargoBin)/\(name)"
                guard let stat = context.fileSystem.stat(candidatePath), stat.fileID == rustupFileID else { continue }
                let dispatchFileID = FileID.rustupProxyAware(candidate: stat.fileID, invokedName: name, rustupFileID: rustupFileID)
                records.append(InstalledPackage(
                    ecosystem: .rustup, packageID: name, versionRaw: nil, root: proxyRoot,
                    packageDirectory: cargoBin, executables: [candidatePath], owner: .versionManager(kind: .rustup, root: root),
                    evidence: [Evidence(kind: "rustup-proxy", path: candidatePath)], confidence: .proven, fileID: dispatchFileID
                ))
            }
        }

        let status: EnumerationStatus = issues.isEmpty ? .complete : .partial(issues)
        return EnumerationResult(ecosystem: .rustup, roots: installRoots, records: records, status: status, elapsed: clock.now - start)
    }

    func resolve(_ identity: InventoryIdentity, _ context: DiscoveryContext) async -> InstalledPackage? {
        guard identity.ecosystem == .rustup else { return nil }
        let result = await enumerate(context)
        return result.records.first { $0.packageID == identity.packageID }
    }

    private static func root(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["RUSTUP_HOME"], !override.isEmpty { return override }
        return "\(context.layout.homeDirectory)/.rustup"
    }

    private static func cargoBin(context: DiscoveryContext) -> String {
        if let override = context.environmentSnapshot["CARGO_HOME"], !override.isEmpty { return "\(override)/bin" }
        return "\(context.layout.homeDirectory)/.cargo/bin"
    }

    private static func rustupFileID(cargoBin: String, context: DiscoveryContext) -> FileID? {
        context.fileSystem.stat("\(cargoBin)/rustup")?.fileID
    }

    private static func activity(cargoBin: String, loginPath: LoginPath) -> RootActivity {
        switch loginPath {
        case .known(let entries): return entries.contains(cargoBin) ? .active : .inactive
        case .empty, .unknown: return .unknown
        }
    }

    private static func toolchainRecord(name: String, root: String, installRoot: InstallRoot, context: DiscoveryContext) -> InstalledPackage? {
        let toolchainDirectory = "\(root)/toolchains/\(name)"
        guard let fileID = context.fileSystem.stat(toolchainDirectory)?.fileID else { return nil }
        let version = Self.version(forToolchain: name, toolchainDirectory: toolchainDirectory, context: context)
        return InstalledPackage(
            ecosystem: .rustup, packageID: name, versionRaw: version, root: installRoot,
            packageDirectory: toolchainDirectory, owner: .versionManager(kind: .rustup, root: root),
            evidence: [Evidence(kind: "toolchain-directory", path: toolchainDirectory)], confidence: .proven, fileID: fileID
        )
    }

    /// RC4: if the toolchain name itself starts with a version (`1.82.0-aarch64-apple-darwin`),
    /// that's the version. Otherwise (`stable-aarch64-apple-darwin`) the first `version = "..."`
    /// line after `[pkg.rustc]` in the toolchain's own channel manifest, capped at 4 MB.
    private static func version(forToolchain name: String, toolchainDirectory: String, context: DiscoveryContext) -> String? {
        if let leadingVersion = name.split(separator: "-").first, Version(String(leadingVersion)) != nil {
            return String(leadingVersion)
        }
        let manifestPath = "\(toolchainDirectory)/lib/rustlib/multirust-channel-manifest.toml"
        guard let data = try? context.fileSystem.readFile(manifestPath, maxBytes: 4_000_000),
              let text = String(data: data, encoding: .utf8),
              let pkgRange = text.range(of: "[pkg.rustc]", options: .literal) else {
            return nil
        }
        let afterPkg = text[pkgRange.upperBound...]
        guard let versionLine = afterPkg.range(of: #"version\s*=\s*"([^"]*)""#, options: .regularExpression) else { return nil }
        let line = String(afterPkg[versionLine])
        guard let quoted = line.range(of: #""([^"]*)""#, options: .regularExpression) else { return nil }
        return String(line[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
