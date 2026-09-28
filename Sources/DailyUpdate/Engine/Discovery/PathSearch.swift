import Foundation

/// ADR-002 §1: `whence -ap` semantics, reimplemented in Swift against the login PATH the
/// coordinator already captured (RC2's `LoginPath`) and a `ReadOnlyFileSystem`, so matching an
/// inventory command against PATH never starts its own process or a long argv.
enum PathSearch {
    /// Every `<dir>/<name>` on `pathEntries` that exists and is executable, in PATH order — the
    /// first entry is what runs (D5's "active"), the rest are "shadowed" (R2's `competing`).
    static func candidates(
        for commandName: String,
        pathEntries: [String],
        fileSystem: ReadOnlyFileSystem
    ) -> [String] {
        var seenDirectories = Set<String>()
        var results: [String] = []
        for directory in pathEntries {
            guard seenDirectories.insert(directory).inserted else { continue }
            let candidate = directory.hasSuffix("/") ? directory + commandName : directory + "/" + commandName
            guard let info = fileSystem.lstat(candidate), isExecutableCandidate(candidate, lstatInfo: info, fileSystem: fileSystem) else {
                continue
            }
            results.append(candidate)
        }
        return results
    }

    private static func isExecutableCandidate(_ path: String, lstatInfo: FileStat, fileSystem: ReadOnlyFileSystem) -> Bool {
        let resolved = lstatInfo.isSymbolicLink ? fileSystem.stat(path) : lstatInfo
        guard let resolved, resolved.isRegularFile else { return false }
        let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
        return resolved.mode & executableBits != 0
    }
}

extension FileID {
    /// RC4 case 2 / D9: a rustup proxy shares `rustup`'s inode but is invoked under a different
    /// name (`cargo`, `rustc`, …). That distinguishes the proxy's row from `rustup`'s own row even
    /// though they're the same file on disk. The broader shim-folder rule (pyenv, mise, asdf,
    /// volta) is P2-4's `DispatcherRule`; this is the one dispatcher case P2-1's own fixture (D9)
    /// needs, and it needs nothing but the candidate and a known `rustup` `FileID`.
    static func rustupProxyAware(candidate: FileID, invokedName: String, rustupFileID: FileID?) -> FileID {
        guard let rustupFileID,
              candidate.device == rustupFileID.device,
              candidate.inode == rustupFileID.inode,
              invokedName != "rustup" else {
            return candidate
        }
        return FileID(device: candidate.device, inode: candidate.inode, dispatchName: invokedName)
    }
}
