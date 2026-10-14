#if DEBUG
import Foundation
import Sempere

/// Debug builds only: logs how iCloud Drive presents a vault's files
/// (listing, placeholder names, download status, dataless flags) without
/// printing any note content. `SEMPERE_DEBUG_PROBE=1`.
enum DebugProbe {
    static func log(_ message: String) { NSLog("SempereProbe %@", message) }

    /// Summarises the vault folder at `root`. Security scope must be active.
    static func probe(_ root: URL, label: String) {
        let fm = FileManager.default
        log("[\(label)] ubiquitous=\(fm.isUbiquitousItem(at: root)) cloud=\(CloudVault.isUbiquitous(root))")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: notes.path) } catch {
            log("[\(label)] list notes failed: \(error)"); return
        }
        let dirs = names.filter { !$0.hasPrefix(".") }
        log("[\(label)] notes entries=\(names.count) dirs=\(dirs.count) dotted=\(names.count - dirs.count)")
        var histogram: [String: Int] = [:]
        var emptyDirs = 0
        var files = 0
        for dir in dirs.sorted() {
            let d = notes.appendingPathComponent(dir, isDirectory: true)
            let inside = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
            if inside.isEmpty { emptyDirs += 1 }
            for name in inside {
                files += 1
                let key = describe(d.appendingPathComponent(name), name: name)
                histogram[key, default: 0] += 1
            }
        }
        log("[\(label)] noteDirs=\(dirs.count) emptyDirs=\(emptyDirs) files=\(files)")
        for (key, count) in histogram.sorted(by: { $0.key < $1.key }) { log("[\(label)]   \(count)x \(key)") }
    }

    /// One file's presentation: placeholder name or not, status, size, flags.
    static func describe(_ url: URL, name: String) -> String {
        var u = url
        u.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                         .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingErrorKey,
                                         .fileSizeKey, .fileAllocatedSizeKey]
        let v = try? u.resourceValues(forKeys: keys)
        var st = stat()
        let statOK = lstat(url.path, &st) == 0
        let dataless = statOK && (st.st_flags & 0x40000000) != 0   // SF_DATALESS
        let kind = CloudPlaceholder.realName(of: name) != nil ? "icloudPlaceholder" : (name.hasPrefix(".") ? "dot" : "real")
        let status = v?.ubiquitousItemDownloadingStatus?.rawValue ?? "nil"
        let alloc = (v?.fileAllocatedSize ?? -1) == 0 ? "alloc0" : "alloc>0"
        let item = CloudScan.Item(url: url, placeholder: kind == "icloudPlaceholder")
        return "\(kind) ubi=\(v?.isUbiquitousItem.map { "\($0)" } ?? "nil") status=\(status) "
            + "downloading=\(v?.ubiquitousItemIsDownloading.map { "\($0)" } ?? "nil") "
            + "err=\(v?.ubiquitousItemDownloadingError != nil) \(alloc) dataless=\(dataless) "
            + "state=\(CloudVault.state(of: item))"
    }

    /// Evicts every note folder's files from this device (they stay in iCloud).
    static func evictNotes(_ root: URL, mode: String = "1") {
        let fm = FileManager.default
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        if mode == "notes" {
            do { try fm.evictUbiquitousItem(at: notes); log("evicted notes/") } catch { log("evict notes/ failed: \(error)") }
            return
        }
        if mode == "dirs" {
            var ok = 0, failed = 0
            for dir in (try? fm.contentsOfDirectory(atPath: notes.path)) ?? [] where !dir.hasPrefix(".") {
                do { try fm.evictUbiquitousItem(at: notes.appendingPathComponent(dir, isDirectory: true)); ok += 1 } catch {
                    failed += 1
                    if failed < 3 { log("evict dir failed: \(error)") }
                }
            }
            log("evicted dirs=\(ok) failed=\(failed)")
            return
        }
        var ok = 0, failed = 0
        for dir in (try? fm.contentsOfDirectory(atPath: notes.path)) ?? [] where !dir.hasPrefix(".") {
            let d = notes.appendingPathComponent(dir, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where name.hasSuffix(".age") {
                do {
                    try fm.evictUbiquitousItem(at: d.appendingPathComponent(name)); ok += 1
                    if ok % 25 == 0 { log("evicted \(ok)") }
                } catch {
                    failed += 1
                    if failed < 3 { log("evict failed: \(error)") }
                }
            }
        }
        log("evicted=\(ok) failed=\(failed)")
    }
}
#endif
