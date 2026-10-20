import Foundation
import Sempere

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The folder transport (docs/io.md "Folder targets", docs/design/device-first-sync.md §3.2, §3.3)
//
// `FolderRemote` is a `SyncRemote` over a directory: a vault folder in iCloud
// Drive or another provider, on a USB drive, a network share or anywhere
// else. Foundation and POSIX calls only, so it runs on Linux; what a provider
// adds (coordination, evicted files, conflict versions, change hints) comes
// from its `FolderProvider`.
//
// Its promises, as the protocol asks (and `SyncRemoteConformanceTests` check):
//
// - **Version tokens** (`stamp`): `"<device>-<inode>-<size>-<mtime ns>-<ctime ns>"`
//   from `lstat(2)`, plus the first 16 hex digits of the SHA-256 of a file at
//   the base (`vault.json`, `settings.age`: the files rewritten in place) of at
//   most 64 KiB. Not the modification time alone: a replace through a new
//   file changes the inode and the change time even within one tick of a
//   coarse clock (FAT keeps 2 s), and the digest catches a same-size rewrite
//   in place within one tick on a file system whose inode and times do not
//   move (FAT, some network shares), for the files where that happens. Strong.
// - **Atomic writes**: every write goes to a hidden temporary file in the
//   same folder (`.sempere-tmp-<uuid>`, which every listing of a vault
//   ignores), is flushed, and is put in place with `link(2)` (create: fails if
//   the name exists) or `rename(2)` (replace); a reader sees the old file or
//   the whole new one, never part of one. Where the file system has no hard
//   links (FAT, some shares) a create checks and renames under the lock.
// - **Conditional writes and deletes** compare the token and act under a
//   lock: in a plain folder an advisory `flock(2)` on `.sempere-lock` at the
//   base (hidden from listings; it serializes Sempere's writers on one
//   machine, the CLI and the app included), in a provider's folder a
//   coordinated write (`NSFileCoordinator` serializes coordinated writers).
// - **Bounded reads**: a file over `maxBytes` is refused before it is read
//   (its size first, then never more than the bound), listings stop past
//   `Limits.maxEntries`, deep listings past their byte bound.
// - **A hostile folder** (format.md §9): a symbolic link anywhere below the
//   base is never followed (reads open each folder with `O_NOFOLLOW`; other
//   operations check every component first) and never listed; FIFOs, sockets
//   and devices are not listed; names that are not UTF-8, `.`, `..`, empty or
//   hold a `/` or NUL are neither listed nor accepted.
// - **Availability** (a provider's folder): a stand-in `.<name>.icloud` is
//   listed as `<name>`, not downloaded; a dataless file under its real name is
//   too; a folder that lists no visible file yet is "listed before its files"
//   (`.downloading`), except the base itself. Reading such a file throws
//   `unavailable` (transient, `isUnavailable`), never blocks until a download
//   finishes: the engine asks for it and waits a bounded time (`Arrivals.swift`).
// - **Errors**: a missing file or folder, a bound, a link, a bad name are not
//   transient; an I/O failure a later run may not see (a share that went
//   away: `EIO`, `ENOTCONN`, `ESTALE`, `ETIMEDOUT`, ...) is.

/// The failures of `FolderRemote`.
public enum FolderRemoteError: Error, Hashable, Sendable {
    /// Nothing at that path.
    case notFound(String)
    /// The parent folder of a write, move or new folder does not exist.
    case missingParent(String)
    /// A file operation on a folder, or a folder operation on a file.
    case notAFile(String)
    /// A path component the folder cannot hold (empty, `.`, `..`, a `/`, a NUL, too long).
    case invalidPath(String)
    /// A symbolic link where a file or folder was expected; never followed.
    case symbolicLink(String)
    /// A read past its `maxBytes`, or a deep listing past its bound.
    case tooLarge(path: String, limit: Int)
    /// A folder with more entries than `Limits.maxEntries`.
    case tooManyEntries(path: String, limit: Int)
    /// A listed file whose bytes the provider has not downloaded yet.
    case unavailable(String)
    /// The folder's lock stayed held by another writer.
    case busy(String)
    /// Any other failure; `transient` when a later run may not see it.
    case io(String, transient: Bool)
}

extension FolderRemoteError: TransientRemoteError {
    public var isTransient: Bool {
        switch self {
        case .unavailable, .busy: return true
        case .io(_, let transient): return transient
        default: return false
        }
    }

    public var isUnavailable: Bool { if case .unavailable = self { return true } else { return false } }
}

extension FolderRemoteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "\(p): not found"
        case .missingParent(let p): return "\(p): the folder it goes in does not exist"
        case .notAFile(let p): return "\(p): not a regular file"
        case .invalidPath(let p): return "\(SyncReport.printable(p)): not a usable path"
        case .symbolicLink(let p): return "\(p) is a symbolic link; not followed"
        case .tooLarge(let p, let limit): return "\(p): over \(limit) bytes; not read"
        case .tooManyEntries(let p, let limit): return "\(p): more than \(limit) entries; not listed"
        case .unavailable(let p): return "\(p): not downloaded by the provider yet"
        case .busy(let p): return "\(p): another writer holds the folder's lock"
        case .io(let m, _): return m
        }
    }
}

/// A `SyncRemote` over a directory (see above).
public struct FolderRemote: SyncRemote {
    /// Bounds of what one call reads from the folder.
    public struct Limits: Sendable, Hashable {
        /// The most entries one folder may list.
        public var maxEntries: Int
        /// The longest a conditional write waits for the lock.
        public var lockWait: TimeInterval

        public init(maxEntries: Int = 500_000, lockWait: TimeInterval = 30) {
            self.maxEntries = maxEntries
            self.lockWait = lockWait
        }
    }

    /// The base folder (symbolic links in the path to it resolved once, at creation).
    public let root: URL
    /// What holds the folder (`FolderProviders.detect` by default).
    public let provider: any FolderProvider
    public var limits: Limits
    public var interrupt: (@Sendable () -> (any Error)?)?

    /// The lock file of conditional writes in a plain folder (hidden from listings).
    public static let lockName = ".sempere-lock"
    /// Files at the base up to this size carry a digest of their bytes in their token.
    public static let digestLimit = 64 << 10

    /// A remote over the folder at `root` (it may not exist yet: `createBase` makes it).
    public init(root: URL, provider: (any FolderProvider)? = nil, limits: Limits = Limits()) {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = resolved
        self.provider = provider ?? FolderProviders.detect(resolved)
        self.limits = limits
    }

    public var location: String { root.path }

    public var capabilities: RemoteCapabilities {
        RemoteCapabilities(strongStamps: true, rangeReads: true, deepListing: true, folderStampsTrackChildren: true,
                           atomicCreate: true, maxObjectBytes: nil)
    }

    // MARK: Paths

    private var manages: Bool { provider.managesFiles }

    private func shown(_ path: [String]) -> String { "/" + path.joined(separator: "/") }

    private func validate(_ path: [String]) throws {
        for c in path {
            if c.isEmpty || c == "." || c == ".." || c.contains("/") || c.unicodeScalars.contains("\0") || c.utf8.count > 255 {
                throw FolderRemoteError.invalidPath(path.joined(separator: "/"))
            }
            // Writing a provider's stand-in name would confuse the provider.
            if manages, provider.standInRealName(c) != nil { throw FolderRemoteError.invalidPath(path.joined(separator: "/")) }
        }
    }

    private func url(_ path: [String]) -> URL {
        path.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// Refuses a path with a symbolic link anywhere below the base (missing components are fine).
    private func checkNoLink(_ path: [String]) throws {
        guard !path.isEmpty else { return }
        if let link = BoundedRead.firstLink(under: root, path.joined(separator: "/")) {
            throw FolderRemoteError.symbolicLink(shown(link.split(separator: "/").map(String.init)))
        }
    }

    private func checkInterrupt() throws {
        if let stop = interrupt?() { throw stop }
    }

    // MARK: Items

    static func lstatItem(_ url: URL) -> (stat: FolderItemStat?, isLink: Bool, errno: Int32) {
        var st = CStat()
        let rc = url.withUnsafeFileSystemRepresentation { p -> Int32 in
            guard let p else { return -1 }
            return lstat(p, &st)
        }
        guard rc == 0 else { return (nil, false, errno) }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return (nil, true, 0) }
        return (Self.item(st), false, 0)
    }

    static func item(_ st: CStat) -> FolderItemStat {
        let type = st.st_mode & S_IFMT
        #if canImport(Darwin)
        let mtime = Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec)
        let ctime = Int64(st.st_ctimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_ctimespec.tv_nsec)
        let flags = UInt32(st.st_flags)
        #else
        let mtime = Int64(st.st_mtim.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtim.tv_nsec)
        let ctime = Int64(st.st_ctim.tv_sec) &* 1_000_000_000 &+ Int64(st.st_ctim.tv_nsec)
        let flags: UInt32 = 0
        #endif
        return FolderItemStat(isDirectory: type == S_IFDIR, isRegularFile: type == S_IFREG, size: Int64(st.st_size),
                              blocks: Int64(st.st_blocks), flags: flags, device: UInt64(truncatingIfNeeded: st.st_dev),
                              inode: UInt64(truncatingIfNeeded: st.st_ino), modifiedNanoseconds: mtime, changedNanoseconds: ctime)
    }

    /// The version token of an item; `digest` for a small file at the base.
    static func stamp(_ s: FolderItemStat, digest: String? = nil) -> String {
        var t = "\(s.device)-\(s.inode)-\(s.isDirectory ? 0 : s.size)-\(s.modifiedNanoseconds)-\(s.changedNanoseconds)"
        if let digest { t += "-" + digest }
        return "\"" + t + "\""
    }

    /// The digest that goes in the token of the file at `path`, when it has one.
    private func digest(_ path: [String], _ s: FolderItemStat, available: Bool) -> String? {
        guard path.count == 1, s.isRegularFile, s.size <= Int64(Self.digestLimit), available,
              let data = try? BoundedRead.contents(under: root, path[0], maxBytes: Self.digestLimit) else { return nil }
        return String(FileDigest.sha256(data).prefix(16))
    }

    /// The entry of the item at `path` as `s` describes it.
    private func entry(_ path: [String], _ s: FolderItemStat, name: String) -> RemoteEntry {
        let u = url(path)
        var availability = RemoteAvailability.available
        if manages {
            availability = provider.availability(of: u, stat: s)
            // A folder that lists no file yet is listed before its files (iCloud lists a
            // folder's contents after the folder), except the base.
            if s.isDirectory, availability == .available, !path.isEmpty, !Self.listsAnything(u, provider) {
                availability = .downloading
            }
        }
        let stamp = Self.stamp(s, digest: digest(path, s, available: availability == .available))
        return RemoteEntry(name: name, isCollection: s.isDirectory, etag: stamp,
                           size: s.isDirectory ? nil : Int(clamping: s.size), availability: availability)
    }

    /// The entry of a stand-in (`.<name>.icloud`) for the file `path`: listed, never readable as it is.
    private func standInEntry(_ path: [String], _ standIn: FolderItemStat) -> RemoteEntry {
        var availability = provider.availability(of: url(path), stat: standIn)
        if availability == .available { availability = .remoteOnly }
        return RemoteEntry(name: path.last ?? "", isCollection: false, etag: "\"standin-" + String(Self.stamp(standIn).dropFirst()),
                           size: nil, availability: availability)
    }

    /// Whether a folder lists any visible name or a provider's stand-in (hidden temporary files say nothing).
    private static func listsAnything(_ dir: URL, _ provider: any FolderProvider) -> Bool {
        var found = false
        _ = try? readNames(dir, max: Int.max) { name in
            if !name.hasPrefix(".") || provider.standInRealName(name) != nil { found = true; return false }
            return true
        }
        return found
    }

    /// Calls `each` with every entry name of `dir` that is valid UTF-8 (not `.` or `..`), until it returns false.
    /// Throws past `max` names; nil when `dir` is missing.
    @discardableResult
    private static func readNames(_ dir: URL, max: Int, _ each: (String) throws -> Bool) throws -> Bool? {
        guard let d = dir.withUnsafeFileSystemRepresentation({ $0.flatMap { opendir($0) } }) else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw Self.ioError("list \(dir.path)", code)
        }
        defer { closedir(d) }
        var count = 0
        while true {
            errno = 0
            guard let e = readdir(d) else {
                if errno != 0 { throw Self.ioError("list \(dir.path)", errno) }
                return true
            }
            let bytes: [UInt8] = withUnsafePointer(to: &e.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: e.pointee.d_name)) { p in
                    var out: [UInt8] = []
                    var i = 0
                    while i < MemoryLayout.size(ofValue: e.pointee.d_name), p[i] != 0 { out.append(p[i]); i += 1 }
                    return out
                }
            }
            let name = String(decoding: bytes, as: UTF8.self)
            // A name that is not UTF-8 cannot be named back: never listed.
            guard Array(name.utf8) == bytes, name != ".", name != ".." else { continue }
            count += 1
            if count > max { throw FolderRemoteError.tooManyEntries(path: dir.path, limit: max) }
            if try !each(name) { return true }
        }
    }

    static func ioError(_ what: String, _ code: Int32) -> FolderRemoteError {
        let transient: Set<Int32> = [EIO, ENOTCONN, ETIMEDOUT, ESTALE, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH,
                                     EAGAIN, EINTR, EBUSY, ENOSPC, EDQUOT]
        return .io("\(what): \(String(cString: strerror(code))) (errno \(code))", transient: transient.contains(code))
    }

    // MARK: Listing

    /// The entries of the folder at `path`; nil when it is not there or not a folder.
    private func entries(_ path: [String]) throws -> [RemoteEntry]? {
        let dir = url(path)
        var real: [String: RemoteEntry] = [:]
        var standIns: [String: RemoteEntry] = [:]
        let read = try Self.readNames(dir, max: limits.maxEntries) { name in
            try checkInterrupt()
            if path.isEmpty, name == Self.lockName { return true }
            let (s, isLink, _) = Self.lstatItem(dir.appendingPathComponent(name))
            // Symbolic links are never followed nor listed; FIFOs, sockets and devices are not files.
            guard !isLink, let s, s.isDirectory || s.isRegularFile else { return true }
            if manages, s.isRegularFile, let realName = provider.standInRealName(name) {
                standIns[realName] = standInEntry(path + [realName], s)
                return true
            }
            real[name] = entry(path + [name], s, name: name)
            return true
        }
        guard read != nil else { return nil }
        // The real file wins over a leftover stand-in of the same name.
        for (name, e) in standIns where real[name] == nil { real[name] = e }
        return real.values.sorted { $0.name < $1.name }
    }

    public func list(_ path: [String]) throws -> [RemoteEntry]? {
        try validate(path)
        try checkInterrupt()
        try checkNoLink(path)
        let (s, _, _) = Self.lstatItem(url(path))
        guard let s, s.isDirectory else { return nil }
        if path.isEmpty, manages {
            // The base itself not downloaded: nothing below it can be judged; a later run lists it.
            let a = provider.availability(of: root, stat: s)
            if a != .available {
                try? provider.requestDownload(root)
                throw FolderRemoteError.unavailable(root.path)
            }
        }
        return try provider.coordinatedRead(url(path)) { try entries(path) }
    }

    public func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? {
        try validate(path)
        try checkNoLink(path)
        let (s, _, _) = Self.lstatItem(url(path))
        guard let s, s.isDirectory else { return nil }
        var out: [[String]: [RemoteEntry]] = [:]
        var bytes = 0
        var queue: [[String]] = [[]]
        while let rel = queue.popLast() {
            try checkInterrupt()
            guard let listed = try entries(path + rel) else { continue }
            out[rel] = listed
            for e in listed {
                // About what a PROPFIND answer spends on one entry (as `MemoryRemote` counts).
                bytes += e.name.utf8.count + 200
                // A folder listed before its files gets no key: its children are not known.
                if e.isCollection, e.availability == .available { queue.append(rel + [e.name]) }
            }
            if bytes > maxBytes { throw FolderRemoteError.tooLarge(path: shown(path), limit: maxBytes) }
        }
        return .listed(out)
    }

    public func stat(_ path: [String]) throws -> RemoteEntry? {
        try validate(path)
        try checkInterrupt()
        try checkNoLink(path)
        let u = url(path)
        let (s, isLink, _) = Self.lstatItem(u)
        if isLink { return nil }
        if let s {
            guard s.isDirectory || s.isRegularFile else { return nil }
            return entry(path, s, name: path.last ?? "")
        }
        // Only the provider's stand-in is here.
        if manages, let name = path.last {
            let standIn = u.deletingLastPathComponent().appendingPathComponent(UbiquitousPlaceholder.standInName(for: name))
            if let st = Self.lstatItem(standIn).stat, st.isRegularFile, provider.standInRealName(standIn.lastPathComponent) == name {
                return standInEntry(path, st)
            }
        }
        return nil
    }

    // MARK: Reading

    /// Opens the regular file at `path`, following no link below the base, and checks it is readable now.
    private func openFile(_ path: [String]) throws -> (fd: Int32, stat: FolderItemStat) {
        guard !path.isEmpty else { throw FolderRemoteError.notAFile(shown(path)) }
        if manages, let e = try stat(path), e.availability != .available {
            throw FolderRemoteError.unavailable(shown(path))
        }
        var dir = root.withUnsafeFileSystemRepresentation { p -> Int32 in
            guard let p else { return -1 }
            return open(p, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard dir >= 0 else {
            let code = errno
            if code == ENOENT { throw FolderRemoteError.notFound(shown(path)) }
            throw Self.ioError("open \(root.path)", code)
        }
        defer { if dir >= 0 { _ = close(dir) } }
        func failure(_ name: String, _ code: Int32, _ at: Int32, _ upTo: Int) -> FolderRemoteError {
            var st = CStat()
            if fstatat(at, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                return .symbolicLink(shown(Array(path.prefix(upTo))))
            }
            if code == ENOENT || code == ENOTDIR { return .notFound(shown(path)) }
            return Self.ioError("open \(shown(path))", code)
        }
        for (i, name) in path.dropLast().enumerated() {
            let next = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure(name, errno, dir, i + 1) }
            _ = close(dir)
            dir = next
        }
        let leaf = path[path.count - 1]
        let fd = openat(dir, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(leaf, errno, dir, path.count) }
        var st = CStat()
        guard fstat(fd, &st) == 0 else {
            let code = errno
            _ = close(fd)
            throw Self.ioError("stat \(shown(path))", code)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            _ = close(fd)
            throw FolderRemoteError.notAFile(shown(path))
        }
        return (fd, Self.item(st))
    }

    public func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        try validate(path)
        try checkInterrupt()
        return try provider.coordinatedRead(url(path)) {
            let (fd, s) = try openFile(path)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            if s.size > Int64(maxBytes) { throw FolderRemoteError.tooLarge(path: shown(path), limit: maxBytes) }
            let data: Data
            do { data = try handle.read(upToCount: max(maxBytes, 0) + 1) ?? Data() } catch {
                throw FolderRemoteError.io("read \(shown(path)): \(error.localizedDescription)", transient: true)
            }
            if data.count > maxBytes { throw FolderRemoteError.tooLarge(path: shown(path), limit: maxBytes) }
            let digest = path.count == 1 && data.count <= Self.digestLimit && Int64(data.count) == s.size
                ? String(FileDigest.sha256(data).prefix(16)) : nil
            return (data, Self.stamp(s, digest: digest))
        }
    }

    @discardableResult
    public func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                         segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try validate(path)
        try checkInterrupt()
        return try provider.coordinatedRead(url(path)) {
            let (fd, s) = try openFile(path)
            let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? source.close() }
            if s.size > Int64(maxBytes) { throw FolderRemoteError.tooLarge(path: shown(path), limit: maxBytes) }
            let stamp = Self.stamp(s, digest: path.count == 1 ? digest(path, s, available: true) : nil)
            let fm = FileManager.default
            if !fm.fileExists(atPath: file.path) {
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw SyncError.io("cannot create \(file.path)")
                }
            }
            let out = try FileHandle(forWritingTo: file)
            defer { try? out.close() }
            let have = Int(try out.seekToEnd())
            var offset = 0
            if resumeFrom > 0, let ifETag, SyncEngine.isStrong(ifETag), ifETag == stamp, have >= resumeFrom,
               Int64(resumeFrom) <= s.size {
                offset = resumeFrom
            }
            try out.truncate(atOffset: UInt64(offset))
            try out.seek(toOffset: UInt64(offset))
            try source.seek(toOffset: UInt64(offset))
            let segment = min(max(segmentBytes, 1), 8 << 20)
            var total = offset
            while true {
                try checkInterrupt()
                let piece: Data
                do { piece = try autoreleasing { try source.read(upToCount: segment) } ?? Data() } catch {
                    throw FolderRemoteError.io("read \(shown(path)): \(error.localizedDescription)", transient: true)
                }
                if piece.isEmpty { break }
                total += piece.count
                // The file grew while it was read: still bounded.
                if total > maxBytes { throw FolderRemoteError.tooLarge(path: shown(path), limit: maxBytes) }
                try autoreleasing { try out.write(contentsOf: piece) }
                try progress?(piece.count)
            }
            if total == offset, offset == 0 { try progress?(0) }
            return DownloadResult(resumed: offset > 0, etag: stamp)
        }
    }

    // MARK: Writing

    /// The folder `path` goes in: it must exist and be a folder (no link below the base).
    private func parentFolder(_ path: [String]) throws -> URL {
        let parent = Array(path.dropLast())
        try checkNoLink(parent)
        let (s, _, code) = Self.lstatItem(url(parent))
        guard let s else {
            if code == ENOENT || code == ENOTDIR { throw FolderRemoteError.missingParent(shown(path)) }
            throw Self.ioError("stat \(shown(parent))", code)
        }
        guard s.isDirectory else { throw FolderRemoteError.missingParent(shown(path)) }
        return url(parent)
    }

    /// Writes `body` to a new hidden temporary file in `dir`, flushed; returns it.
    private func writeTemporary(_ body: RemoteBody, in dir: URL) throws -> URL {
        let tmp = FileIO.tempURL(in: dir)
        do {
            try FileIO.writeNewFile(tmp) { write in
                switch body {
                case .data(let data):
                    try write(data)
                case .file(let source):
                    let h: FileHandle
                    do { h = try BoundedRead.openRegularFile(source) } catch {
                        throw SyncError.io("read \(source.path): \(error)")
                    }
                    defer { try? h.close() }
                    while true {
                        try checkInterrupt()
                        let piece = try autoreleasing { try h.read(upToCount: 1 << 20) } ?? Data()
                        if piece.isEmpty { break }
                        try write(piece)
                    }
                }
            }
        } catch let e as VaultError {
            throw FolderRemoteError.io("\(e)", transient: false)
        }
        return tmp
    }

    /// Runs `body` holding the folder's write lock: a coordinated write of `url` in a provider's
    /// folder, an advisory lock on `.sempere-lock` at the base otherwise.
    private func locked<T>(_ target: URL, _ body: () throws -> T) throws -> T {
        if manages { return try provider.coordinatedWrite(target, body) }
        let lockURL = root.appendingPathComponent(Self.lockName)
        let fd = lockURL.withUnsafeFileSystemRepresentation { p -> Int32 in
            guard let p else { return -1 }
            return open(p, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw Self.ioError("open \(lockURL.path)", errno) }
        defer { _ = close(fd) }
        let end = Date().addingTimeInterval(limits.lockWait)
        var pause = 0.005
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else { throw Self.ioError("lock \(lockURL.path)", code) }
            try checkInterrupt()
            if Date() > end { throw FolderRemoteError.busy(root.path) }
            Thread.sleep(forTimeInterval: pause)
            pause = min(pause * 2, 0.1)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// The current token of the file at `path`; nil when there is no regular file.
    private func currentStamp(_ path: [String]) -> String? {
        guard let s = Self.lstatItem(url(path)).stat, s.isRegularFile else { return nil }
        let available = !manages || provider.availability(of: url(path), stat: s) == .available
        return Self.stamp(s, digest: digest(path, s, available: available))
    }

    private static func link(_ from: URL, _ to: URL) -> Int32 {
        from.withUnsafeFileSystemRepresentation { src in
            to.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { errno = EINVAL; return -1 }
                return cLink(src, dst) == 0 ? 0 : errno
            }
        }
    }

    private static func rename(_ from: URL, _ to: URL) -> Int32 {
        from.withUnsafeFileSystemRepresentation { src in
            to.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return EINVAL }
                return cRename(src, dst) == 0 ? 0 : errno
            }
        }
    }

    /// Flushes a folder's entries (`fsync(2)` on it); a file system that cannot is accepted as is.
    static func syncDirectory(_ dir: URL) throws {
        let fd = dir.withUnsafeFileSystemRepresentation { p -> Int32 in
            guard let p else { return -1 }
            return open(p, O_RDONLY | O_CLOEXEC)
        }
        guard fd >= 0 else { throw ioError("open \(dir.path) for fsync", errno) }
        defer { _ = close(fd) }
        if fsync(fd) != 0, errno != EINVAL, errno != ENOTSUP { throw ioError("fsync \(dir.path)", errno) }
    }

    /// Errors of `link(2)` that mean the file system has no hard links (then: check, rename, under the lock).
    private static let noHardLinks: Set<Int32> = [EPERM, ENOTSUP, EOPNOTSUPP, EXDEV, ENOSYS, EMLINK]

    /// Moves the flushed `tmp` to `dest` only if nothing is there; false when something is.
    private func placeNew(_ tmp: URL, at dest: URL) throws -> Bool {
        let rc = Self.link(tmp, dest)
        if rc == 0 {
            try? Self.syncDirectory(dest.deletingLastPathComponent())
            return true
        }
        if rc == EEXIST { return false }
        guard Self.noHardLinks.contains(rc) else { throw Self.ioError("link \(dest.path)", rc) }
        return try locked(dest) {
            if Self.lstatItem(dest).stat != nil || Self.lstatItem(dest).isLink { return false }
            let r = Self.rename(tmp, dest)
            guard r == 0 else { throw Self.ioError("rename to \(dest.path)", r) }
            try? Self.syncDirectory(dest.deletingLastPathComponent())
            return true
        }
    }

    @discardableResult
    public func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try validate(path)
        try checkInterrupt()
        guard !path.isEmpty else { throw FolderRemoteError.notAFile(shown(path)) }
        let dir = try parentFolder(path)
        let dest = url(path)
        let existing = Self.lstatItem(dest)
        if existing.isLink { throw FolderRemoteError.symbolicLink(shown(path)) }
        if existing.stat?.isDirectory == true { throw FolderRemoteError.notAFile(shown(path)) }
        return try provider.coordinatedWrite(dest) {
            let tmp = try writeTemporary(body, in: dir)
            defer { try? FileManager.default.removeItem(at: tmp) }
            switch condition {
            case .create:
                return try placeNew(tmp, at: dest)
            case .replace(let etag):
                return try locked(dest) {
                    guard currentStamp(path) == etag else { return false }
                    let r = Self.rename(tmp, dest)
                    guard r == 0 else { throw Self.ioError("rename to \(dest.path)", r) }
                    try? Self.syncDirectory(dir)
                    return true
                }
            case .unconditional:
                let r = Self.rename(tmp, dest)
                guard r == 0 else { throw Self.ioError("rename to \(dest.path)", r) }
                try? Self.syncDirectory(dir)
                return true
            }
        }
    }

    @discardableResult
    public func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try validate(path)
        try validate(destination)
        try checkInterrupt()
        try checkNoLink(path)
        let source = url(path)
        let (s, isLink, code) = Self.lstatItem(source)
        if isLink { throw FolderRemoteError.symbolicLink(shown(path)) }
        guard let s else {
            if code == ENOENT || code == ENOTDIR { throw FolderRemoteError.notFound(shown(path)) }
            throw Self.ioError("stat \(shown(path))", code)
        }
        guard s.isRegularFile else { throw FolderRemoteError.notAFile(shown(path)) }
        _ = try parentFolder(destination)
        let dest = url(destination)
        return try provider.coordinatedWrite(dest) {
            let rc = Self.link(source, dest)
            if rc == 0 {
                try? FileManager.default.removeItem(at: source)
                try? Self.syncDirectory(dest.deletingLastPathComponent())
                return true
            }
            if rc == EEXIST { return false }
            guard Self.noHardLinks.contains(rc) else { throw Self.ioError("link \(dest.path)", rc) }
            return try locked(dest) {
                if Self.lstatItem(dest).stat != nil || Self.lstatItem(dest).isLink { return false }
                let r = Self.rename(source, dest)
                guard r == 0 else { throw Self.ioError("rename to \(dest.path)", r) }
                try? Self.syncDirectory(dest.deletingLastPathComponent())
                return true
            }
        }
    }

    public func makeCollection(_ path: [String]) throws -> CollectionResult {
        try validate(path)
        try checkInterrupt()
        let dest = url(path)
        if path.isEmpty {
            if let s = Self.lstatItem(root).stat { return s.isDirectory ? .exists : .missingParent }
            return .missingParent
        }
        try checkNoLink(Array(path.dropLast()))
        return try provider.coordinatedWrite(dest) {
            let rc = dest.withUnsafeFileSystemRepresentation { p -> Int32 in
                guard let p else { return EINVAL }
                return mkdir(p, 0o755) == 0 ? 0 : errno
            }
            switch rc {
            case 0:
                try? Self.syncDirectory(dest.deletingLastPathComponent())
                return .created
            case EEXIST:
                let (s, isLink, _) = Self.lstatItem(dest)
                if isLink { throw FolderRemoteError.symbolicLink(shown(path)) }
                guard s?.isDirectory == true else { throw FolderRemoteError.notAFile(shown(path)) }
                return .exists
            case ENOENT, ENOTDIR:
                return .missingParent
            default:
                throw Self.ioError("mkdir \(dest.path)", rc)
            }
        }
    }

    public func createBase() throws {
        try checkInterrupt()
        if let s = Self.lstatItem(root).stat {
            guard s.isDirectory else { throw FolderRemoteError.notAFile(root.path) }
            return
        }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } catch {
            throw FolderRemoteError.io("mkdir \(root.path): \(error.localizedDescription)", transient: false)
        }
    }

    @discardableResult
    public func delete(_ path: [String], ifETag: String?) throws -> Bool {
        try validate(path)
        try checkInterrupt()
        guard !path.isEmpty else { throw FolderRemoteError.notAFile(shown(path)) }
        try checkNoLink(Array(path.dropLast()))
        let target = url(path)
        let (s, isLink, code) = Self.lstatItem(target)
        if isLink { throw FolderRemoteError.symbolicLink(shown(path)) }
        guard let s else {
            if code == ENOENT || code == ENOTDIR { return true }
            throw Self.ioError("stat \(shown(path))", code)
        }
        guard s.isRegularFile else { throw FolderRemoteError.notAFile(shown(path)) }
        func unlinkIt() throws -> Bool {
            let rc = target.withUnsafeFileSystemRepresentation { p -> Int32 in
                guard let p else { return EINVAL }
                return unlink(p) == 0 ? 0 : errno
            }
            guard rc == 0 || rc == ENOENT else { throw Self.ioError("remove \(target.path)", rc) }
            try? Self.syncDirectory(target.deletingLastPathComponent())
            return true
        }
        return try provider.coordinatedWrite(target) {
            guard let ifETag, SyncEngine.isStrong(ifETag) else { return try unlinkIt() }
            return try locked(target) {
                guard let now = currentStamp(path) else { return true }
                guard now == ifETag else { return false }
                return try unlinkIt()
            }
        }
    }

    public func missingCollectionError(_ path: [String]) -> any Error {
        FolderRemoteError.notFound(shown(path))
    }

    // MARK: A provider's files

    public func requestDownload(_ paths: [[String]]) throws {
        for p in paths {
            try validate(p)
            try checkNoLink(p)
            try provider.requestDownload(url(p))
        }
    }

    public func conflictVersions(_ path: [String]) -> [RemoteVersion] {
        guard (try? validate(path)) != nil, (try? checkNoLink(path)) != nil else { return [] }
        return provider.conflictVersions(of: url(path))
    }

    public func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try validate(path)
        try checkNoLink(path)
        guard let file = provider.versionFile(of: url(path), id: version.id) else {
            throw FolderRemoteError.notFound("\(shown(path)) (version \(SyncReport.printable(version.id)))")
        }
        do { return try BoundedRead.contents(of: file, maxBytes: maxBytes) } catch VaultError.fileTooLarge {
            throw FolderRemoteError.tooLarge(path: shown(path), limit: maxBytes)
        }
    }

    public func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws {
        guard !versions.isEmpty else { return }
        try validate(path)
        try checkNoLink(path)
        try provider.resolveConflicts(of: url(path), ids: Set(versions.map(\.id)))
    }

    public func changes() -> AsyncStream<RemoteChange>? { provider.changes(below: root) }
}

// The C calls under names that do not collide with this type's own methods.
#if canImport(Darwin)
typealias CStat = Darwin.stat
private func cLink(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Darwin.link(a, b) }
private func cRename(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Darwin.rename(a, b) }
#elseif canImport(Glibc)
typealias CStat = Glibc.stat
private func cLink(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Glibc.link(a, b) }
private func cRename(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Glibc.rename(a, b) }
#elseif canImport(Musl)
typealias CStat = Musl.stat
private func cLink(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Musl.link(a, b) }
private func cRename(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 { Musl.rename(a, b) }
#endif
