import Foundation

enum PathTrust {
    static func resolvedExecutable(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    static func isTrustedExecutable(_ path: String) -> Bool {
        let link = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let target = resolvedExecutable(link) else { return false }
        var info = stat()
        guard lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              trusted(info), trustedAncestors(link), trustedAncestors(target) else { return false }
        return true
    }

    private static func trusted(_ info: stat) -> Bool {
        (info.st_uid == getuid() || info.st_uid == 0) &&
            info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func trustedAncestors(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()
        while true {
            var info = stat()
            // Follow directory symlinks as well as checking the resolved target chain.
            guard stat(current.path, &info) == 0,
                  info.st_uid == getuid() || info.st_uid == 0,
                  info.st_mode & S_IWOTH == 0 else { return false }
            if current.path == "/" { return true }
            current.deleteLastPathComponent()
        }
    }
}
