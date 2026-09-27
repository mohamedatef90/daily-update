import Foundation

/// ADR-002 §1, and Amendment 1 RC1-RC3: the read-only discovery model. Every type here is a
/// plain record; nothing in this file may perform I/O (ADR-002 §7.1's lint enforces that).
enum Ecosystem: String, Codable, CaseIterable, Sendable {
    case brew, cask, npm, pnpm, yarn, bun, pipx, uv, pip, cargo, gem, app
    case nvm, fnm, mise, asdf, pyenv, rustup, skill, plugin, system
    /// Only used by `DiscoveryDumpTests`' `FakeEnumerator` (ADR-002 §9 P2-1, "fake ecosystem only").
    case fake
}

enum Confidence: String, Codable, Sendable {
    /// Manifest plus root containment.
    case proven
    /// A receipt or a framework marker is present.
    case strong
    /// A key alone.
    case hint
}

enum PackageFlag: String, Codable, Sendable {
    case onRequest, dependency, linked, pinned, kegOnly, bundledWithRuntime
}

struct Evidence: Hashable, Codable, Sendable {
    let kind: String
    let path: String
}

/// `(st_dev, st_ino)` identify the file that actually runs. `dispatchName` breaks the tie for a
/// dispatcher (a rustup proxy, or a file in a version-manager shim folder) so invoking `cargo`
/// through a rustup proxy and invoking `rustc` through the same inode key differently (D9, RC4).
struct FileID: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let dispatchName: String?

    init(device: UInt64, inode: UInt64, dispatchName: String? = nil) {
        self.device = device
        self.inode = inode
        self.dispatchName = dispatchName
    }
}

/// RC2: the login PATH is not simply present or absent. `whence` can also fail, time out, hit its
/// output cap, or come back without the `END` marker discovery expects.
enum LoginPath: Hashable, Sendable {
    /// At least one absolute entry, after empty and relative entries are dropped.
    case known([String])
    /// The shell ran and reported no usable entry.
    case empty
    /// Exit code was non-zero, it timed out, hit the output cap, or the END marker was missing.
    case unknown(String)

    var entries: [String] {
        if case .known(let entries) = self { return entries }
        return []
    }
}

/// Replaces `InstallRoot.isActive: Bool` (RC2): when the login PATH is unknown, no root may be
/// demoted to inactive, so activity itself becomes three-valued.
enum RootActivity: String, Codable, Sendable {
    case active, inactive, unknown
}

enum VersionManagerKind: String, Codable, Sendable {
    case nvm, fnm, mise, asdf, pyenv, rustup, volta, rbenv, nodenv, jenv, goenv
}

struct InstallRoot: Hashable, Sendable {
    let ecosystem: Ecosystem
    /// Canonical.
    let path: String
    /// "nvm v24.13.0", "{BREW}", "uv tools".
    let label: String
    let binDirectories: [String]
    let activity: RootActivity
    /// The trusted executable that manages this root (brew, `<P>/bin/npm`, uv).
    let toolPath: String?

    init(
        ecosystem: Ecosystem,
        path: String,
        label: String,
        binDirectories: [String],
        activity: RootActivity,
        toolPath: String? = nil
    ) {
        self.ecosystem = ecosystem
        self.path = path
        self.label = label
        self.binDirectories = binDirectories
        self.activity = activity
        self.toolPath = toolPath
    }
}

struct InstalledPackage: Hashable, Sendable {
    let ecosystem: Ecosystem
    /// Validated by `PackageNameRules` (§7.4).
    let packageID: String
    /// Sanitized.
    let displayName: String?
    /// Straight from the manifest; never from `--version`.
    let versionRaw: String?
    let root: InstallRoot
    /// Canonical.
    let packageDirectory: String
    /// Canonical; each proven by a manifest bin map or by root containment.
    let executables: [String]
    let owner: ResolvedOwner
    let flags: Set<PackageFlag>
    let evidence: [Evidence]
    let confidence: Confidence
    /// The identity of the file that runs: the executable's `FileID`, or the package folder's
    /// when there's no executable (D4).
    let fileID: FileID

    var version: VersionValue? { versionRaw.map(VersionValue.init(token:)) }

    init(
        ecosystem: Ecosystem,
        packageID: String,
        displayName: String? = nil,
        versionRaw: String?,
        root: InstallRoot,
        packageDirectory: String,
        executables: [String] = [],
        owner: ResolvedOwner,
        flags: Set<PackageFlag> = [],
        evidence: [Evidence] = [],
        confidence: Confidence,
        fileID: FileID
    ) {
        self.ecosystem = ecosystem
        self.packageID = packageID
        self.displayName = displayName
        self.versionRaw = versionRaw
        self.root = root
        self.packageDirectory = packageDirectory
        self.executables = executables
        self.owner = owner
        self.flags = flags
        self.evidence = evidence
        self.confidence = confidence
        self.fileID = fileID
    }
}

/// RC1's process-contract types. Owned by Discovery; the app's legacy shell runner is never
/// referenced from this directory (F10). Only one file here may reference the bounded runner
/// that replaces it (RC1), and the lint enforces that.
enum Termination: Hashable, Codable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut(afterMs: Int)
    case outputCapExceeded
    case launchFailed(String)
}

struct ProcessEvidence: Hashable, Codable, Sendable {
    let executable: String
    let arguments: [String]
    let termination: Termination
    /// At most 16 KB, sanitized (§7.4), with `$HOME` shown as `~`.
    let stderr: String
    let stderrTruncated: Bool
    let elapsedMs: Int
}

struct QueryOutcome: Sendable {
    let evidence: ProcessEvidence
    let stdout: Data
}

/// RC1: every issue kind discovery can report, including the ones a sandbox preflight or a
/// bounded read can produce.
enum IssueKind: String, Codable, Sendable {
    case unreadable, malformed, tooLarge, notRegularFile, capReached, deadline, previousRunStillBlocked
    case untrustedRoot, sandboxUnavailable, sandboxRefused, enricherFailed, loginEnvironmentUnknown
}

struct EnumerationIssue: Hashable, Sendable {
    let kind: IssueKind
    let rootPath: String?
    let message: String
    let process: ProcessEvidence?

    init(kind: IssueKind, rootPath: String? = nil, message: String, process: ProcessEvidence? = nil) {
        self.kind = kind
        self.rootPath = rootPath
        self.message = message
        self.process = process
    }
}

enum EnumerationStatus: Hashable, Sendable {
    case complete
    case partial([EnumerationIssue])
    case unavailable(String)
    case failed(EnumerationIssue)
}

struct EnumerationResult: Sendable {
    let ecosystem: Ecosystem
    let roots: [InstallRoot]
    let records: [InstalledPackage]
    let status: EnumerationStatus
    let elapsed: Duration

    init(
        ecosystem: Ecosystem,
        roots: [InstallRoot] = [],
        records: [InstalledPackage] = [],
        status: EnumerationStatus,
        elapsed: Duration = .zero
    ) {
        self.ecosystem = ecosystem
        self.roots = roots
        self.records = records
        self.status = status
        self.elapsed = elapsed
    }
}

/// Built each run; never loaded from settings or an import (D2).
struct InventoryIdentity: Codable, Hashable, Sendable {
    let ecosystem: Ecosystem
    let packageID: String
    let rootPath: String
    let packageDirectory: String
    let toolPath: String?

    init(
        ecosystem: Ecosystem,
        packageID: String,
        rootPath: String,
        packageDirectory: String,
        toolPath: String? = nil
    ) {
        self.ecosystem = ecosystem
        self.packageID = packageID
        self.rootPath = rootPath
        self.packageDirectory = packageDirectory
        self.toolPath = toolPath
    }

    /// D3/RowBuilder: a `partial`/`failed` enumeration adds a visible Check Failed row instead of
    /// a real package. `StrategyPlanner` recognizes this marker and reports Check Failed directly
    /// from the row's `description`, without ever calling an enumerator's `resolve`.
    static let errorMarkerPackageID = "__discovery_error__"

    var isErrorMarker: Bool { packageID == Self.errorMarkerPackageID }

    static func errorMarker(ecosystem: Ecosystem, rootPath: String) -> InventoryIdentity {
        InventoryIdentity(ecosystem: ecosystem, packageID: errorMarkerPackageID, rootPath: rootPath, packageDirectory: rootPath)
    }
}
