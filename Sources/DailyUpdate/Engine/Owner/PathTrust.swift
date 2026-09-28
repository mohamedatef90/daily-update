import Foundation

enum PathTrust {
    static func resolvedExecutable(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    static func isTrustedExecutable(_ path: String) -> Bool {
        let link = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let target = resolvedExecutable(link), let hops = symlinkHops(from: link) else { return false }
        var info = stat()
        guard lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              trusted(info), hops.allSatisfy(trustedAncestors), trustedAncestors(target) else { return false }
        return true
    }

    /// The link and every path its chain passes through. Whoever can write the directory
    /// of any hop could re-point it between this check and the exec. A relative
    /// destination keeps its `..` so the ancestor walk sees the directories the kernel does.
    private static func symlinkHops(from path: String) -> [String]? {
        var hops = [path]
        var current = path
        // MAXSYMLINKS on macOS.
        for _ in 0..<32 {
            var info = stat()
            guard lstat(current, &info) == 0 else { return nil }
            guard info.st_mode & S_IFMT == S_IFLNK else { return hops }
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { return nil }
            current = destination.hasPrefix("/") ? destination
                : (current as NSString).deletingLastPathComponent + "/" + destination
            hops.append(current)
        }
        return nil
    }

    private static func trusted(_ info: stat) -> Bool {
        (info.st_uid == getuid() || info.st_uid == 0) &&
            info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func trustedAncestors(_ path: String) -> Bool {
        var current = (path as NSString).deletingLastPathComponent
        while true {
            guard isTrustedPathEntry(current) else { return false }
            if current == "/" || current.isEmpty { return true }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// ADR-002 F3: a discovery root and every one of its ancestors must be owned by uid 0 or the
    /// current user, and not world-writable. Group-writable is allowed — that's the rule
    /// `trustedAncestors` already applies to a directory, as opposed to `trusted(_:)`'s stricter
    /// file rule (no group *or* world write), which still applies to executables (D16 covers
    /// world-writable; D23 is a user-owned `drwxrwxr-x` Cellar, which this trusts).
    static func isTrustedDirectory(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        while true {
            guard isTrustedPathEntry(current) else { return false }
            if current == "/" || current.isEmpty { return true }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func isTrustedPathEntry(_ path: String) -> Bool {
        var info = stat()
        // Follow directory symlinks as well as checking the resolved target chain.
        guard stat(path, &info) == 0,
              info.st_uid == getuid() || info.st_uid == 0,
              info.st_mode & S_IWOTH == 0 else { return false }
        return true
    }
}
