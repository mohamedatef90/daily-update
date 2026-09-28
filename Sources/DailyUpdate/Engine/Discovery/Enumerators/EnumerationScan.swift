import Foundation

/// P2-2 (Security re-review FU1): the one place an enumerator turns a filesystem signal into an
/// `EnumerationIssue`. Every enumerator reads through this, so none of them can drop a cap:
/// - `contentsOfDirectory`'s `truncated == true` and `ReadOnlyFileSystemError.capReached` become
///   `capReached`;
/// - `.tooLarge`, `.notRegularFile` and `.unreadable` become their own kinds;
/// - JSON that doesn't parse becomes `malformed`;
/// - the §7.5 soft deadline becomes `deadline`.
///
/// Any issue at all makes the result `partial`, never `complete` (D3, RC2's caps rule).
struct EnumerationScan {
    let ecosystem: Ecosystem
    let context: DiscoveryContext
    private let deadline: DiscoveryDeadline
    private let started = ContinuousClock.now
    private(set) var issues: [EnumerationIssue] = []
    private var deadlineReported = false

    /// §7.3's caps for the files enumerators read.
    static let manifestByteCap = 1_000_000
    static let metadataByteCap = 5_000_000

    init(ecosystem: Ecosystem, context: DiscoveryContext) {
        self.ecosystem = ecosystem
        self.context = context
        deadline = DiscoveryDeadline(context.limits.perEnumeratorDeadline)
    }

    var fileSystem: ReadOnlyFileSystem { context.fileSystem }

    // MARK: - Reads

    /// Whether anything exists at `path` (a dangling symlink counts as nothing).
    func exists(_ path: String) -> Bool {
        fileSystem.stat(path) != nil
    }

    func isDirectory(_ path: String) -> Bool {
        fileSystem.stat(path)?.isDirectory == true
    }

    /// The sorted entries of a directory, or `nil` when there's no directory there. A directory
    /// that exists but can't be listed is an `unreadable` issue; a listing cut at the cap is
    /// returned (so what was read still counts) together with a `capReached` issue.
    mutating func list(_ path: String, root: String? = nil) -> [String]? {
        guard let info = fileSystem.stat(path) else { return nil }
        guard info.isDirectory else { return nil }
        do {
            let (entries, truncated) = try fileSystem.contentsOfDirectory(path)
            if truncated {
                report(.capReached, root: root ?? path,
                    message: "\(path) has more than \(entries.count) entries; only the first \(entries.count) were read")
            }
            return entries
        } catch let error as ReadOnlyFileSystemError {
            record(error, root: root ?? path)
            return nil
        } catch {
            report(.unreadable, root: root ?? path, message: "couldn't list \(path)")
            return nil
        }
    }

    /// The bytes of a regular file within `maxBytes`, or `nil` with the matching issue. A file
    /// that doesn't exist at all is `nil` with no issue unless `required` is set.
    mutating func read(_ path: String, maxBytes: Int, root: String? = nil, required: Bool = false) -> Data? {
        if !required, fileSystem.lstat(path) == nil { return nil }
        do {
            return try fileSystem.readFile(path, maxBytes: maxBytes)
        } catch let error as ReadOnlyFileSystemError {
            record(error, root: root ?? path)
            return nil
        } catch {
            report(.unreadable, root: root ?? path, message: "couldn't read \(path)")
            return nil
        }
    }

    /// A JSON object read with `read`, or `nil` with a `malformed` issue when it isn't one.
    mutating func readJSONObject(_ path: String, maxBytes: Int = manifestByteCap, root: String? = nil, required: Bool = false) -> [String: Any]? {
        guard let data = read(path, maxBytes: maxBytes, root: root, required: required) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            report(.malformed, root: root ?? path, message: "\(path) isn't a JSON object")
            return nil
        }
        return object
    }

    /// A text file read with `read`, decoded leniently (bytes that aren't UTF-8 become U+FFFD).
    mutating func readText(_ path: String, maxBytes: Int = manifestByteCap, root: String? = nil) -> String? {
        read(path, maxBytes: maxBytes, root: root).map { String(decoding: $0, as: UTF8.self) }
    }

    func canonical(_ path: String) -> String? {
        fileSystem.realpath(path)
    }

    func fileID(of path: String) -> FileID? {
        fileSystem.stat(path)?.fileID
    }

    /// §7.5: checked between entries. The first time it fires, it's reported once for the
    /// enumerator; callers stop reading as soon as it returns true.
    mutating func deadlinePassed() -> Bool {
        guard deadline.hasExpired() else { return false }
        if !deadlineReported {
            deadlineReported = true
            report(.deadline, root: nil, message: "Stopped reading after the per-ecosystem deadline")
        }
        return true
    }

    // MARK: - Issues

    mutating func report(_ kind: IssueKind, root: String?, message: String, process: ProcessEvidence? = nil) {
        issues.append(EnumerationIssue(kind: kind, rootPath: root, message: PackageNameRules.sanitize(message, maxLength: 400), process: process))
    }

    private mutating func record(_ error: ReadOnlyFileSystemError, root: String) {
        switch error {
        case .unreadable(let path): report(.unreadable, root: root, message: "couldn't read \(path)")
        case .notRegularFile(let path): report(.notRegularFile, root: root, message: "\(path) isn't a regular file")
        case .tooLarge(let path): report(.tooLarge, root: root, message: "\(path) is larger than the size cap")
        case .capReached(let path): report(.capReached, root: root, message: "\(path) is behind too many symlinks")
        }
    }

    // MARK: - Result

    /// `complete` when nothing went wrong, else `partial` with every issue. `unavailable` only
    /// ever comes from the caller, and only when no root and no tool were found (D3).
    func result(roots: [InstallRoot], records: [InstalledPackage], brewInfo: BrewInfoProvider? = nil) -> EnumerationResult {
        EnumerationResult(
            ecosystem: ecosystem,
            roots: roots,
            records: records,
            status: issues.isEmpty ? .complete : .partial(issues),
            elapsed: ContinuousClock.now - started,
            brewInfo: brewInfo
        )
    }

    /// Nothing to read. RC2 item 2: "not on PATH" only means `unavailable` when the login PATH is
    /// actually known; otherwise it's `partial(loginEnvironmentUnknown)`.
    func nothingFound(_ reason: String) -> EnumerationResult {
        if context.loginPathIsKnown {
            return EnumerationResult(ecosystem: ecosystem, status: .unavailable(reason), elapsed: ContinuousClock.now - started)
        }
        return EnumerationResult(
            ecosystem: ecosystem,
            status: .partial([EnumerationIssue(kind: .loginEnvironmentUnknown, message: "\(reason), and the login PATH is unknown")]),
            elapsed: ContinuousClock.now - started
        )
    }
}

/// Small path helpers shared by the enumerators. Pure string work; no I/O.
enum DiscoveryPaths {
    static func join(_ base: String, _ components: String...) -> String {
        components.reduce(base) { partial, component in
            partial.hasSuffix("/") ? partial + component : partial + "/" + component
        }
    }

    /// Lexical only: collapses `//` and `.`, and applies `..`. Unlike `standardizedFileURL`, it
    /// never rewrites `/private/var/…` to `/var/…`, so a canonical path stays canonical.
    static func standardized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// `path` equals `root` or sits below it, compared component-wise after standardizing.
    static func isPath(_ path: String, within root: String) -> Bool {
        let path = standardized(path), root = standardized(root)
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// `v24.13.0` → `24.13.0`; anything else is returned unchanged.
    static func withoutLeadingV(_ value: String) -> String {
        value.hasPrefix("v") ? String(value.dropFirst()) : value
    }

    /// Sorts version-named folders oldest → newest (`v9` before `v10`).
    static func numericallySorted(_ names: [String]) -> [String] {
        names.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }
}
