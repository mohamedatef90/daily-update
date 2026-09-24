import Foundation

enum PathTrust {
    static func isTrustedExecutable(_ path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path

        var statBuffer = stat()
        guard lstat(normalizedPath, &statBuffer) == 0 else { return false }

        let mode = statBuffer.st_mode
        let fileType = mode & S_IFMT
        guard fileType == S_IFREG else { return false }

        let owner = statBuffer.st_uid
        let currentUID = getuid()
        guard owner == currentUID || owner == 0 else { return false }

        // Group or world writable executables are not trusted.
        guard mode & S_IWGRP == 0, mode & S_IWOTH == 0 else { return false }
        return !hasWorldWritableAncestor(normalizedPath)
    }

    private static func hasWorldWritableAncestor(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()

        while true {
            let currentPath = current.path
            var statBuffer = stat()
            guard lstat(currentPath, &statBuffer) == 0 else { return true }
            if statBuffer.st_mode & S_IWOTH != 0 {
                return true
            }
            if currentPath == "/" {
                return false
            }
            current.deleteLastPathComponent()
        }
    }
}
