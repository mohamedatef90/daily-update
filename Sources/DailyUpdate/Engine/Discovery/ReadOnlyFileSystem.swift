import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// mode, uid, device, inode, size, mtime — enough for D4's identity key, D5's activity checks, and
/// PathTrust's ownership/writability rules, without ever exposing a raw `stat` struct to callers
/// outside this file.
struct FileStat: Hashable, Sendable {
    let mode: mode_t
    let uid: uid_t
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationDate: Date

    var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    var isSymbolicLink: Bool { mode & S_IFMT == S_IFLNK }
    var isWorldWritable: Bool { mode & mode_t(S_IWOTH) != 0 }
    var isGroupWritable: Bool { mode & mode_t(S_IWGRP) != 0 }
    var isOwnedByRootOrCurrentUser: Bool { uid == 0 || uid == getuid() }

    var fileID: FileID {
        FileID(device: device, inode: inode)
    }
}

/// Free functions, so the libc `stat`/`lstat`/`realpath` calls below are never shadowed by
/// `LiveFileSystem`'s own methods of the same name (Swift treats a type's own method names as
/// shadowing an identically-named module symbol everywhere inside that type, including the
/// struct-literal call `stat()`).
private func makeEmptyStat() -> stat { stat() }
private func posixStat(_ path: String, _ info: inout stat) -> Int32 { stat(path, &info) }
private func posixLstat(_ path: String, _ info: inout stat) -> Int32 { lstat(path, &info) }
private func posixFStat(_ fd: Int32, _ info: inout stat) -> Int32 { fstat(fd, &info) }
private func posixOpenReadOnly(_ path: String) -> Int32 {
    path.withCString { cPath in open(cPath, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
}
private func posixRealpath(_ path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else { return nil }
    return String(cString: buffer)
}

enum ReadOnlyFileSystemError: Error, Equatable, Sendable {
    case unreadable(String)
    case notRegularFile(String)
    case tooLarge(String)
}

/// ADR-002 §7.1: the only I/O an enumerator may do. Every method here is read-only by
/// construction — there is no path to a write, create, remove, move or copy call through this
/// protocol, so an enumerator built on it can never mutate anything it reads.
protocol ReadOnlyFileSystem: Sendable {
    func contentsOfDirectory(_ path: String) throws -> [String]
    /// RC3: opens the canonical path only, refuses anything that isn't a regular file, and never
    /// blocks on a FIFO, a socket or a stalled network mount.
    func readFile(_ path: String, maxBytes: Int) throws -> Data
    func lstat(_ path: String) -> FileStat?
    func stat(_ path: String) -> FileStat?
    func realpath(_ path: String) -> String?
    func destinationOfSymlink(_ path: String) -> String?
}

/// The real filesystem. Every read goes through this file only; the lint in
/// `DiscoveryLintTests` fails if any other file under `Engine/Discovery/` uses a write API.
struct LiveFileSystem: ReadOnlyFileSystem {
    /// §7.3: at most 5,000 entries per root. A caller that needs the full list for a large
    /// directory should page with `contentsOfDirectory`'s natural order; this cap only protects
    /// against a runaway or hostile directory.
    let maxDirectoryEntries: Int

    init(maxDirectoryEntries: Int = 5000) {
        self.maxDirectoryEntries = maxDirectoryEntries
    }

    func contentsOfDirectory(_ path: String) throws -> [String] {
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: path)
            return Array(entries.prefix(maxDirectoryEntries))
        } catch {
            throw ReadOnlyFileSystemError.unreadable(path)
        }
    }

    /// RC3: `realpath` first, then `open(O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)`.
    /// `fstat` must report `S_ISREG`; anything else (a FIFO, a socket, a device) is closed
    /// immediately and reported as `notRegularFile`, never read. `O_NONBLOCK` means a FIFO with no
    /// writer, or a stalled network mount, can never hang this call — it either opens instantly or
    /// fails instantly. The size cap is checked twice: once from `fstat` before any read (so a
    /// file already over the cap is never read at all), and again while reading (so a file that
    /// grows past the cap during the read is still caught).
    func readFile(_ path: String, maxBytes: Int) throws -> Data {
        guard let canonical = realpath(path) else {
            throw ReadOnlyFileSystemError.unreadable(path)
        }

        let fd = posixOpenReadOnly(canonical)
        guard fd >= 0 else {
            throw ReadOnlyFileSystemError.unreadable(path)
        }
        defer { close(fd) }

        var info = makeEmptyStat()
        guard posixFStat(fd, &info) == 0 else {
            throw ReadOnlyFileSystemError.unreadable(path)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ReadOnlyFileSystemError.notRegularFile(path)
        }
        guard info.st_size <= 0 || Int64(info.st_size) <= Int64(maxBytes) else {
            throw ReadOnlyFileSystemError.tooLarge(path)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        readLoop: while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            switch bytesRead {
            case ..<0:
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue readLoop }
                throw ReadOnlyFileSystemError.unreadable(path)
            case 0:
                break readLoop
            default:
                data.append(buffer, count: bytesRead)
                if data.count > maxBytes {
                    throw ReadOnlyFileSystemError.tooLarge(path)
                }
            }
        }
        return data
    }

    func lstat(_ path: String) -> FileStat? {
        var info = makeEmptyStat()
        guard posixLstat(path, &info) == 0 else { return nil }
        return FileStat(info)
    }

    func stat(_ path: String) -> FileStat? {
        var info = makeEmptyStat()
        guard posixStat(path, &info) == 0 else { return nil }
        return FileStat(info)
    }

    func realpath(_ path: String) -> String? {
        posixRealpath(path)
    }

    func destinationOfSymlink(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}

private extension FileStat {
    init(_ info: Darwin.stat) {
        let seconds = TimeInterval(info.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        self.init(
            mode: info.st_mode,
            uid: info.st_uid,
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationDate: Date(timeIntervalSince1970: seconds + nanoseconds)
        )
    }
}
