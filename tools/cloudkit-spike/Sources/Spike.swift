// CloudKit phase-C0 spike (docs/design/1.4-cloudkit.md §12). THROWAWAY: not part of any shipping target.
// Runs probes against the DEVELOPMENT environment of iCloud.io.github.anthonytw.sempere, in zones named
// `c0-<uuid>` that it deletes. Output: one JSON object per line on stdout ({"k": probe/key, "v": value}).
//   SPIKE_PROBES=account,conditional,limits,assets,feed,perf,push   (default: all but push)
//   SPIKE_ASSET_MAX_MIB=64    largest asset the assets probe tries (SPIKE_ASSET_MIN_MIB: smallest; the sizes are 1 4 16 32 64 128 256 300 512 1024 2048 4096)
//   SPIKE_NO_ZONE=1           run only the account probe and write nothing (used against the Production environment)
//   SPIKE_NO_MULTI=1          skip the multi-asset part of the assets probe
import CloudKit
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

let containerID = "iCloud.io.github.anthonytw.sempere"
nonisolated(unsafe) var currentProbe = "-"

func out(_ k: String, _ v: Any) {
    let o: [String: Any] = ["probe": currentProbe, "k": k, "v": v, "t": (Date().timeIntervalSince1970 * 10).rounded() / 10]
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .fragmentsAllowed]),
       let s = String(data: d, encoding: .utf8) {
        print(s); fflush(stdout)
        // A launched app's stdout is not always wired up: SPIKE_LOG names a file that gets every line too.
        if let f = ProcessInfo.processInfo.environment["SPIKE_LOG"], let h = FileHandle(forWritingAtPath: f) ?? { FileManager.default.createFile(atPath: f, contents: nil); return FileHandle(forWritingAtPath: f) }() {
            h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close()
        }
    }
}

let codeNames: [Int: String] = [1: "internalError", 2: "partialFailure", 3: "networkUnavailable", 4: "networkFailure", 5: "badContainer", 6: "serviceUnavailable", 7: "requestRateLimited", 8: "missingEntitlement", 9: "notAuthenticated", 10: "permissionFailure", 11: "unknownItem", 12: "invalidArguments", 14: "serverRecordChanged", 15: "serverRejectedRequest", 16: "assetFileNotFound", 17: "assetFileModified", 18: "incompatibleVersion", 19: "constraintViolation", 20: "operationCancelled", 21: "changeTokenExpired", 22: "batchRequestFailed", 23: "zoneBusy", 24: "badDatabase", 25: "quotaExceeded", 26: "zoneNotFound", 27: "limitExceeded", 28: "userDeletionDisallowed", 29: "participantMayNeedVerification", 30: "serverResponseLost", 31: "assetNotAvailable", 32: "accountTemporarilyUnavailable", 33: "managedAccountRestricted", 34: "participantAlreadyInvited"]
func why(_ e: Error) -> String {
    if let c = e as? CKError {
        var s = "CKError.\(codeNames[c.code.rawValue] ?? "?") (\(c.code.rawValue))"
        if let r = c.retryAfterSeconds { s += " retryAfter=\(r)" }
        if c.code == .partialFailure, let m = c.partialErrorsByItemID {
            var kinds = [String: Int]()
            for (_, v) in m { kinds[(v as? CKError).map { "\(codeNames[$0.code.rawValue] ?? "\($0.code.rawValue)")" } ?? "\(v)", default: 0] += 1 }
            s += " items=\(kinds)"
        }
        var d = c.localizedDescription
        while let a = d.range(of: "<CKRecordID"), let b = d[a.lowerBound...].firstIndex(of: ">") { d.replaceSubrange(a.lowerBound...b, with: "<id>") }
        return s + " " + String(d.prefix(140))
    }
    return "\(type(of: e)): \(String(describing: e).prefix(200))"
}

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

func randomFile(_ bytes: Int, dir: URL) throws -> (URL, String) {
    let u = dir.appendingPathComponent("asset-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: u.path, contents: nil)
    let h = try FileHandle(forWritingTo: u)
    var sha = SHA256()
    var left = bytes
    let chunk = 4 << 20
    while left > 0 {
        let n = min(chunk, left)
        var d = Data(count: n)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        sha.update(data: d); try h.write(contentsOf: d); left -= n
    }
    try h.close()
    return (u, sha.finalize().map { String(format: "%02x", $0) }.joined())
}

func fileSHA(_ u: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: u); defer { try? h.close() }
    var sha = SHA256()
    while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { sha.update(data: d) }
    return sha.finalize().map { String(format: "%02x", $0) }.joined()
}

func rname(_ i: Int) -> String { "f-" + SHA256.hash(data: Data("notes/\(i)/rev".utf8)).map { String(format: "%02x", $0) }.joined() }

struct Env {
    let container = CKContainer(identifier: containerID)
    var db: CKDatabase { container.privateCloudDatabase }
    let zone: CKRecordZone.ID
    let tmp: URL
    func record(_ name: String, bytes: Int = 16, path: String = "notes/x/rev") -> CKRecord {
        let r = CKRecord(recordType: "VaultFile", recordID: CKRecord.ID(recordName: name, zoneID: zone))
        r.encryptedValues["path"] = path
        r.encryptedValues["sha256"] = Data(count: 32)
        r.encryptedValues["bytes"] = Data(count: bytes)
        r["size"] = bytes as NSNumber
        r["v"] = 1 as NSNumber
        return r
    }
    func save(_ rs: [CKRecord], _ policy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged,
              atomically: Bool = false) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        try await db.modifyRecords(saving: rs, deleting: [], savePolicy: policy, atomically: atomically).saveResults
    }
    func tag(_ r: CKRecord) -> String { r.recordChangeTag ?? "nil" }
}

func result(_ r: Result<CKRecord, Error>?) -> String {
    switch r { case .success(let x)?: return "ok tag=\(x.recordChangeTag ?? "nil")"; case .failure(let e)?: return why(e); case nil: return "missing" }
}

// MARK: probes

func pAccount(_ e: Env) async {
    do {
        let st = try await e.container.accountStatus()
        out("accountStatus", "\(st) (\(st.rawValue))")
        let u = try await e.container.userRecordID()
        out("userRecordID.sha8", SHA256.hash(data: Data(u.recordName.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined())
        out("containerID", e.container.containerIdentifier ?? "nil")
    } catch { out("error", why(error)) }
    out("note", "CKAccountChanged observed for 0.1s only; sign-out/switch is not scriptable here")
}

func pConditional(_ e: Env) async throws {
    let id = rname(1)
    let a = e.record(id)
    let t0 = ContinuousClock.now
    let r1 = try await e.save([a])[a.recordID]
    out("A create new, ifServerRecordUnchanged", result(r1) + " ms=\(Int(ms(ContinuousClock.now - t0)))")
    guard case .success(let saved)? = r1 else { return }
    out("A.record.keys", saved.allKeys().sorted() + ["(encrypted: \(saved.encryptedValues.allKeys().sorted()))"])
    // B: a second create of the same name, fresh record without a tag.
    let b = e.record(id, bytes: 20)
    let r2 = try await e.save([b])[b.recordID]
    out("B create over existing (fresh CKRecord, no tag), ifServerRecordUnchanged", result(r2))
    if case .failure(let err)? = r2, let ck = err as? CKError {
        out("B.serverRecord.tag", ck.serverRecord?.recordChangeTag ?? "nil")
        out("B.ancestorRecord", ck.ancestorRecord != nil)
        out("B.serverRecord.hasDecryptedBytes", ck.serverRecord?.encryptedValues["bytes"] != nil)
    }
    // C: fetch, then replace under the tag; keep the old copy for D.
    let got = try await e.db.record(for: saved.recordID)
    out("C fetch tag == save tag", e.tag(got) == e.tag(saved))
    let stale = try await e.db.record(for: saved.recordID)
    got.encryptedValues["bytes"] = Data(count: 33)
    let r3 = try await e.save([got])[got.recordID]
    out("C replace under tag", result(r3))
    // D: replace using the stale copy.
    stale.encryptedValues["bytes"] = Data(count: 44)
    let r4 = try await e.save([stale])[stale.recordID]
    out("D replace with stale tag", result(r4))
    // E: unconditional policies with a fresh record of an existing name.
    for (n, p) in [("changedKeys", CKModifyRecordsOperation.RecordSavePolicy.changedKeys), ("allKeys", .allKeys)] {
        let f = e.record(id, bytes: 55)
        out("E fresh CKRecord over existing, \(n)", result(try await e.save([f], p)[f.recordID]))
    }
    // F: delete API: IDs only. Delete then read back.
    let delRes = try await e.db.modifyRecords(saving: [], deleting: [saved.recordID], savePolicy: .ifServerRecordUnchanged, atomically: false).deleteResults
    out("F delete by id (API has no tag/precondition parameter)", "\(delRes[saved.recordID].map { "\($0)" } ?? "missing")")
    do { _ = try await e.db.record(for: saved.recordID); out("F fetch after delete", "STILL THERE") }
    catch { out("F fetch after delete", why(error)) }
    // G: recreate after a hard delete: allowed under ifServerRecordUnchanged? tag?
    let g = e.record(id, bytes: 60)
    out("G create after hard delete", result(try await e.save([g])[g.recordID]))
    // H: race: 8 concurrent creates of one name; exactly one must win.
    let rid = rname(2)
    let wins = await withTaskGroup(of: String.self) { g in
        for i in 0..<8 { g.addTask { let r = e.record(rid, bytes: 10 + i); return result((try? await e.save([r]))?[r.recordID]) } }
        var all = [String](); for await s in g { all.append(s) }; return all
    }
    out("H 8 concurrent creates: winners", wins.filter { $0.hasPrefix("ok") }.count)
    out("H losers", Dictionary(wins.filter { !$0.hasPrefix("ok") }.map { ($0.prefix(60).description, 1) }, uniquingKeysWith: +))
    // I: 8 concurrent replaces from the same tag.
    let base = try await e.db.record(for: CKRecord.ID(recordName: rid, zoneID: e.zone))
    let rep = await withTaskGroup(of: String.self) { g in
        for i in 0..<8 { g.addTask {
            let c = base.copy() as! CKRecord; c.encryptedValues["bytes"] = Data(count: 100 + i)
            return result((try? await e.save([c]))?[c.recordID]) } }
        var all = [String](); for await s in g { all.append(s) }; return all
    }
    out("I 8 concurrent replaces from one tag: winners", rep.filter { $0.hasPrefix("ok") }.count)
    // J: atomic batch with one stale member.
    let j1 = e.record(rname(3)); let j2 = e.record(rid, bytes: 5) // j2 has no tag but exists: conflict
    let jr = try? await e.save([j1, j2], .ifServerRecordUnchanged, atomically: true)
    out("J atomic batch [new, conflicting]: new saved?", result(jr?[j1.recordID]))
    out("J conflicting", result(jr?[j2.recordID]))
    // K: tombstone flow timing: save tomb=1 with cleared fields, then delete.
    let k = e.record(rname(4)); _ = try await e.save([k])
    let kk = try await e.db.record(for: k.recordID)
    kk.encryptedValues["bytes"] = nil; kk["tomb"] = 1 as NSNumber
    let t1 = ContinuousClock.now
    out("K tombstone save", result(try await e.save([kk])[kk.recordID]) + " ms=\(Int(ms(ContinuousClock.now - t1)))")
    let t2 = ContinuousClock.now
    _ = try await e.db.modifyRecords(saving: [], deleting: [kk.recordID], savePolicy: .ifServerRecordUnchanged, atomically: false)
    out("K then hard delete ms", Int(ms(ContinuousClock.now - t2)))
    // L: record name charset/length: 66 ASCII chars used throughout; also 255 and 256 chars.
    for n in [255] { // 256 raises an Objective-C exception in CKRecord.ID (documented maximum is 255)
        let name = "f-" + String(repeating: "a", count: n - 2)
        let r = e.record(name)
        out("L record name length \(n)", result(try? await e.save([r])[r.recordID]))
    }
}

func pLimits(_ e: Env) async throws {
    // Records per modify request.
    for n in [100, 200, 300, 400, 401, 500, 1000] {
        let rs = (0..<n).map { e.record("lim-\(n)-\($0)", bytes: 8) }
        let t = ContinuousClock.now
        do {
            let r = try await e.save(rs)
            let ok = r.values.filter { if case .success = $0 { return true }; return false }.count
            var errs = [String: Int]()
            for v in r.values { if case .failure(let x) = v { errs[why(x).prefix(70).description, default: 0] += 1 } }
            out("batch \(n) records", "ok=\(ok) errors=\(errs) ms=\(Int(ms(ContinuousClock.now - t)))")
        } catch { out("batch \(n) records", "request failed: " + why(error)) }
    }
    // Record size: inline encrypted bytes.
    for kib in [64, 128, 256, 512, 768, 900, 1000, 1024, 1536, 2048] {
        let r = e.record("sz-\(kib)", bytes: kib * 1024)
        out("inline encrypted bytes \(kib) KiB", result(try? await e.save([r])[r.recordID]))
        if let res = try? await e.save([e.record("sz-\(kib)", bytes: kib * 1024)]) , case .failure(let x)? = res.values.first, (x as? CKError)?.code != .serverRecordChanged { out("  detail", why(x)) }
    }
    // Same through an ordinary (unencrypted) field.
    for kib in [512, 1000, 1024, 1536] {
        let r = CKRecord(recordType: "VaultFile", recordID: CKRecord.ID(recordName: "pl-\(kib)", zoneID: e.zone))
        r["bytes"] = Data(count: kib * 1024)
        do { out("plain Bytes field \(kib) KiB", result(try await e.save([r])[r.recordID])) } catch { out("plain Bytes field \(kib) KiB", why(error)) }
    }
    // Bytes per request: n records of 100 KiB.
    for n in [10, 40, 100, 200, 400] {
        let rs = (0..<n).map { e.record("rq-\(n)-\($0)", bytes: 100 * 1024) }
        let t = ContinuousClock.now
        do {
            let r = try await e.save(rs)
            let ok = r.values.filter { if case .success = $0 { return true }; return false }.count
            var errs = [String: Int]()
            for v in r.values { if case .failure(let x) = v { errs[why(x).prefix(70).description, default: 0] += 1 } }
            out("\(n) x 100 KiB in one request (\(n * 100 / 1024) MiB)", "ok=\(ok) errors=\(errs) ms=\(Int(ms(ContinuousClock.now - t)))")
        } catch { out("\(n) x 100 KiB in one request", "request failed: " + why(error)) }
    }
}

/// Where the per-request byte limit lies: n records of 100 KiB inline.
func pReqBytes(_ e: Env) async throws {
    for n in [45, 50, 55, 60, 70, 80, 90] {
        let rs = (0..<n).map { e.record("rb-\(n)-\($0)", bytes: 100 * 1024) }
        do {
            let r = try await e.save(rs)
            let ok = r.values.filter { if case .success = $0 { return true }; return false }.count
            var errs = [String: Int]()
            for v in r.values { if case .failure(let x) = v { errs[why(x).prefix(110).description, default: 0] += 1 } }
            out("\(n) x 100 KiB (\(String(format: "%.2f", Double(n) * 100 / 1024)) MiB) in one request", "ok=\(ok) errors=\(errs)")
        } catch { out("\(n) x 100 KiB in one request", "request failed: " + why(error)) }
    }
}

/// Can the zone feed return the encrypted metadata fields (path, sha256) the mirror needs, without `bytes`?
func pEnc(_ e: Env) async throws {
    _ = try await e.save((0..<5).map { e.record("en-\($0)", bytes: 100 * 1024, path: "notes/\($0)/rev.delta.age") })
    let r = try await e.db.recordZoneChanges(inZoneWith: e.zone, since: nil, desiredKeys: ["path", "sha256", "size", "tomb", "v"])
    var ok = 0, hasBytes = 0, hasPath = 0
    for (_, res) in r.modificationResultsByID { if case .success(let m) = res { ok += 1; if m.record.encryptedValues["path"] as? String != nil { hasPath += 1 }; if m.record.encryptedValues["bytes"] != nil { hasBytes += 1 } } }
    out("feed with encrypted desiredKeys", "records=\(ok) withPath=\(hasPath) withBytes=\(hasBytes)")
    let one = try await e.db.records(for: [CKRecord.ID(recordName: "en-0", zoneID: e.zone)], desiredKeys: ["path", "sha256"])
    if case .success(let m)? = one.values.first { out("fetch by id, desiredKeys path+sha256", "path=\(m.encryptedValues["path"] as? String ?? "nil") bytes=\(m.encryptedValues["bytes"] != nil) tag=\(m.recordChangeTag ?? "nil") modDate=\(m.modificationDate != nil)") }
}

func pAssets(_ e: Env) async throws {
    let maxMiB = Int(ProcessInfo.processInfo.environment["SPIKE_ASSET_MAX_MIB"] ?? "64") ?? 64
    let minMiB = Int(ProcessInfo.processInfo.environment["SPIKE_ASSET_MIN_MIB"] ?? "1") ?? 1
    for mib in [1, 4, 16, 32, 64, 128, 256, 300, 512, 1024, 2048, 4096] where mib >= minMiB && mib <= maxMiB {
        let (u, sha) = try randomFile(mib << 20, dir: e.tmp)
        defer { try? FileManager.default.removeItem(at: u) }
        let r = e.record("as-\(mib)", bytes: 0)
        r["asset"] = CKAsset(fileURL: u)
        let t = ContinuousClock.now
        do {
            let res = try await e.save([r])[r.recordID]
            let up = ms(ContinuousClock.now - t)
            out("asset \(mib) MiB upload", result(res) + " ms=\(Int(up)) MB/s=\(String(format: "%.1f", Double(mib) * 1.048576 / (up / 1000)))")
            guard case .success = res else { continue }
            // Metadata-only fetch: no asset comes down.
            let t1 = ContinuousClock.now
            let metaRes = try await e.db.records(for: [r.recordID], desiredKeys: ["size", "v"])
            guard case .success(let meta)? = metaRes[r.recordID] else { out("desiredKeys fetch", "failed"); continue }
            out("asset \(mib) MiB desiredKeys without asset", "asset key present=\(meta["asset"] != nil) ms=\(Int(ms(ContinuousClock.now - t1)))")
            let t2 = ContinuousClock.now
            let full = try await e.db.record(for: r.recordID)
            if let a = full["asset"] as? CKAsset, let f = a.fileURL {
                let dn = ms(ContinuousClock.now - t2)
                let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? -1
                out("asset \(mib) MiB download", "size ok=\(size == mib << 20) sha ok=\((try? fileSHA(f)) == sha) ms=\(Int(dn)) MB/s=\(String(format: "%.1f", Double(mib) * 1.048576 / (dn / 1000)))")
            } else { out("asset \(mib) MiB download", "no asset fileURL") }
            // Free quota as we go.
            _ = try? await e.db.modifyRecords(saving: [], deleting: [r.recordID])
        } catch { out("asset \(mib) MiB upload", why(error)); if mib >= 128 { break } }
    }
    if ProcessInfo.processInfo.environment["SPIKE_NO_MULTI"] != nil { return }
    // Several assets: 4 records x 16 MiB in one request; 2 assets in one record.
    var files = [URL]()
    defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
    var rs = [CKRecord]()
    for i in 0..<4 { let (u, _) = try randomFile(16 << 20, dir: e.tmp); files.append(u)
        let r = e.record("mb-\(i)", bytes: 0); r["asset"] = CKAsset(fileURL: u); rs.append(r) }
    let t = ContinuousClock.now
    do { let res = try await e.save(rs); out("4 x 16 MiB in one request", res.values.map { result($0) }.joined(separator: "; ") + " ms=\(Int(ms(ContinuousClock.now - t)))") }
    catch { out("4 x 16 MiB in one request", why(error)) }
    let (u2, _) = try randomFile(1 << 20, dir: e.tmp); files.append(u2)
    let two = e.record("two-assets", bytes: 0); two["asset"] = CKAsset(fileURL: u2); two["asset2"] = CKAsset(fileURL: u2)
    out("one record, two CKAsset fields", result(try? await e.save([two])[two.recordID]))
    // 4 parallel requests of 1 x 16 MiB (TransferPool width 4).
    let t3 = ContinuousClock.now
    let par = await withTaskGroup(of: String.self) { g in
        for i in 0..<4 { g.addTask {
            guard let (u, _) = try? randomFile(16 << 20, dir: e.tmp) else { return "file" }
            defer { try? FileManager.default.removeItem(at: u) }
            let r = e.record("par-\(i)", bytes: 0); r["asset"] = CKAsset(fileURL: u)
            return result((try? await e.save([r]))?[r.recordID]) } }
        var a = [String](); for await s in g { a.append(s) }; return a }
    out("4 parallel requests x 16 MiB", par.joined(separator: "; ") + " ms=\(Int(ms(ContinuousClock.now - t3)))")
    // Failed conditional save with an asset: does the asset upload happen anyway (cost of a lost race)?
    let (u3, _) = try randomFile(16 << 20, dir: e.tmp); files.append(u3)
    let dup = e.record("mb-0", bytes: 0); dup["asset"] = CKAsset(fileURL: u3)
    let t4 = ContinuousClock.now
    out("create of an existing name with a 16 MiB asset", result(try? await e.save([dup])[dup.recordID]) + " ms=\(Int(ms(ContinuousClock.now - t4)))")
}

func pFeed(_ e: Env) async throws {
    // 1200 records in three requests.
    for b in 0..<3 { _ = try await e.save((0..<400).map { e.record("fd-\(b)-\($0)", bytes: 8) }) }
    var token: CKServerChangeToken?
    var pages = [Int](); var total = 0; var more = true
    let t = ContinuousClock.now
    while more {
        let r = try await e.db.recordZoneChanges(inZoneWith: e.zone, since: token, desiredKeys: ["size", "v", "tomb"])
        pages.append(r.modificationResultsByID.count); total += r.modificationResultsByID.count
        if let first = r.modificationResultsByID.first, case .success(let m) = first.value {
            out("feed record sample keys with desiredKeys", m.record.allKeys().sorted() + ["encryptedValues present: \(m.record.encryptedValues["path"] != nil)"])
        }
        token = r.changeToken; more = r.moreComing
    }
    out("full feed from nil", "records=\(total) pages=\(pages) ms=\(Int(ms(ContinuousClock.now - t)))")
    if let tk = token { out("token archived bytes", (try NSKeyedArchiver.archivedData(withRootObject: tk, requiringSecureCoding: true)).count) }
    let again = try await e.db.recordZoneChanges(inZoneWith: e.zone, since: token, desiredKeys: ["size"])
    out("feed since token, nothing changed", "mods=\(again.modificationResultsByID.count) dels=\(again.deletions.count) moreComing=\(again.moreComing) tokenChanged=\(again.changeToken != token)")
    token = again.changeToken
    // resultsLimit
    let lim = try await e.db.recordZoneChanges(inZoneWith: e.zone, since: nil, desiredKeys: ["size"], resultsLimit: 50)
    out("resultsLimit 50", "got=\(lim.modificationResultsByID.count) moreComing=\(lim.moreComing)")
    // Change, delete, tombstone then delete: what does the feed say?
    let victim = CKRecord.ID(recordName: "fd-0-0", zoneID: e.zone)
    let v = try await e.db.record(for: victim)
    out("victim tag before", e.tag(v))
    v.encryptedValues["bytes"] = nil; v["tomb"] = 1 as NSNumber
    _ = try await e.save([v])
    let ch1 = try await e.db.recordZoneChanges(inZoneWith: e.zone, since: token, desiredKeys: ["size", "tomb"])
    out("feed after tombstone save", "mods=\(ch1.modificationResultsByID.count) dels=\(ch1.deletions.count)")
    if let m = ch1.modificationResultsByID.values.first, case .success(let x) = m { out("  tombstone in feed", "tomb=\(x.record["tomb"].map { "\($0)" } ?? "nil") tag=\(x.record.recordChangeTag ?? "nil")") }
    token = ch1.changeToken
    _ = try await e.db.modifyRecords(saving: [], deleting: [victim])
    let ch2 = try await e.db.recordZoneChanges(inZoneWith: e.zone, since: token, desiredKeys: ["size"])
    out("feed after hard delete", "mods=\(ch2.modificationResultsByID.count) dels=\(ch2.deletions.map { "\($0.recordID.recordName.prefix(8)) type=\($0.recordType)" })")
    token = ch2.changeToken
    // Recreate the deleted name; what does the feed give?
    let re = e.record("fd-0-0", bytes: 9)
    out("recreate after delete", result(try await e.save([re])[re.recordID]))
    let ch3 = try await e.db.recordZoneChanges(inZoneWith: e.zone, since: token, desiredKeys: ["size"])
    out("feed after recreate", "mods=\(ch3.modificationResultsByID.count) dels=\(ch3.deletions.count)")
    // Delete a batch of 400: deletions in one page?
    let ids = (0..<400).map { CKRecord.ID(recordName: "fd-1-\($0)", zoneID: e.zone) }
    let t5 = ContinuousClock.now
    let dres = try await e.db.modifyRecords(saving: [], deleting: ids).deleteResults
    out("delete 400 in one request", "ok=\(dres.values.filter { if case .success = $0 { return true }; return false }.count) ms=\(Int(ms(ContinuousClock.now - t5)))")
    let ch4 = try await e.db.recordZoneChanges(inZoneWith: e.zone, since: ch3.changeToken, desiredKeys: ["size"])
    out("feed after 400 deletes", "dels=\(ch4.deletions.count) moreComing=\(ch4.moreComing)")
    // Database-level changes.
    let dbc = try await e.db.databaseChanges(since: nil)
    out("databaseChanges from nil: c0 zones listed", dbc.modifications.filter { $0.zoneID.zoneName.hasPrefix("c0-") }.count)
    let dbc2 = try await e.db.databaseChanges(since: dbc.changeToken)
    out("databaseChanges since token, quiet", "mods=\(dbc2.modifications.count) dels=\(dbc2.deletions.count)")
    _ = try await e.save([e.record("fd-after", bytes: 1)])
    try await Task.sleep(for: .seconds(2))
    let dbc3 = try await e.db.databaseChanges(since: dbc2.changeToken)
    out("databaseChanges after a write", "mods=\(dbc3.modifications.map { $0.zoneID.zoneName.prefix(8) }) dels=\(dbc3.deletions.count)")
    // A zone deleted by another actor: fetching it afterwards.
    let z2 = CKRecordZone.ID(zoneName: "c0-\(UUID().uuidString.lowercased())", ownerName: CKCurrentUserDefaultName)
    _ = try await e.db.modifyRecordZones(saving: [CKRecordZone(zoneID: z2)], deleting: [])
    _ = try await e.db.modifyRecordZones(saving: [], deleting: [z2])
    do { _ = try await e.db.recordZoneChanges(inZoneWith: z2, since: nil); out("feed of a deleted zone", "no error") }
    catch { out("feed of a deleted zone", why(error)) }
    do { let rr = CKRecord(recordType: "VaultFile", recordID: CKRecord.ID(recordName: "x", zoneID: z2)); out("save into a deleted zone", result(try await e.save([rr])[rr.recordID])) }
    catch { out("save into a deleted zone", why(error)) }
}

func pPerf(_ e: Env) async throws {
    for width in [1, 4, 8, 16] {
        let n = 48
        let t = ContinuousClock.now
        let errs = await withTaskGroup(of: String?.self) { g -> [String] in
            var next = 0; var running = 0; var bad = [String]()
            func add() { let i = next; next += 1; running += 1
                g.addTask { let r = e.record("pf-\(width)-\(i)", bytes: 2048)
                    do { let res = try await e.save([r]); if case .failure(let x)? = res[r.recordID] { return why(x) }; return nil } catch { return why(error) } } }
            while next < n && running < width { add() }
            while let r = await g.next() { running -= 1; if let r { bad.append(r) }; if next < n { add() } }
            return bad }
        let el = ms(ContinuousClock.now - t)
        out("width \(width): \(n) single-record saves", "ms=\(Int(el)) per-op ms=\(Int(el / Double(n))) ops/s=\(String(format: "%.1f", Double(n) / (el / 1000))) errors=\(Dictionary(errs.map { ($0.prefix(60).description, 1) }, uniquingKeysWith: +))")
    }
    // One fetch latency, one batched fetch of 100 by id.
    let t = ContinuousClock.now
    _ = try await e.db.record(for: CKRecord.ID(recordName: "pf-1-0", zoneID: e.zone))
    out("single fetch ms", Int(ms(ContinuousClock.now - t)))
    let ids = (0..<48).map { CKRecord.ID(recordName: "pf-4-\($0)", zoneID: e.zone) }
    let t2 = ContinuousClock.now
    let r = try await e.db.records(for: ids)
    out("batched fetch of 48 ids", "ok=\(r.values.filter { if case .success = $0 { return true }; return false }.count) ms=\(Int(ms(ContinuousClock.now - t2)))")
}

// MARK: push

actor PushBox {
    static let shared = PushBox()
    var notes = [(Date, [AnyHashable: Any])](); var token: String?; var regError: String?
    func add(_ u: [AnyHashable: Any]) { notes.append((Date(), u)) }
    var count: Int { notes.count }
    func setToken(_ t: String) { token = t }
    func setError(_ s: String) { regError = s }
}

func pPush(_ e: Env) async throws {
    // Register with APNs FIRST and wait for the token: CloudKit binds a subscription to the device's push token.
    #if canImport(UIKit)
    await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    try await Task.sleep(for: .seconds(5))
    let tok = await PushBox.shared.token; let regErr = await PushBox.shared.regError
    out("APNs registration", tok.map { "token bytes=\($0.count / 2)" } ?? ("no token; error=" + (regErr ?? "none")))
    #else
    out("APNs registration", "not applicable (no UIKit): the CLI never registers for pushes")
    #endif
    let subID = "c0-db-\(UUID().uuidString.prefix(8))"
    let sub = CKDatabaseSubscription(subscriptionID: subID)
    let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
    if ProcessInfo.processInfo.environment["SPIKE_PUSH_BADGE"] != nil { info.shouldBadge = true } // a non-silent push, to tell throttling from a dead channel
    sub.notificationInfo = info
    do { let s = try await e.db.save(sub); out("save CKDatabaseSubscription", "ok id=\(s.subscriptionID)") }
    catch { out("save CKDatabaseSubscription", why(error)); return }
    let zsub = CKRecordZoneSubscription(zoneID: e.zone, subscriptionID: "c0-zone-\(UUID().uuidString.prefix(8))")
    zsub.notificationInfo = info
    do { _ = try await e.db.save(zsub); out("save CKRecordZoneSubscription", "ok") } catch { out("save CKRecordZoneSubscription", why(error)) }
    _ = try? await e.save([e.record("push-seed", bytes: 1)]) // make sure the zone has a record
    // 1. Write from this process.
    let t0 = Date()
    let w = e.record("push-self", bytes: 1)
    out("self write", result(try? await e.save([w])[w.recordID]))
    for _ in 0..<30 { if await !PushBox.shared.notes.isEmpty { break }; try await Task.sleep(for: .seconds(1)) }
    var got = await PushBox.shared.notes
    out("push after own write within 30 s", got.isEmpty ? "none" : "arrived after \(String(format: "%.1f", got[0].0.timeIntervalSince(t0))) s")
    // 2. Write by an outside actor (the runner script calls cktool when it sees this line).
    out("READY-FOR-EXTERNAL-WRITE", e.zone.zoneName)
    let wait = Int(ProcessInfo.processInfo.environment["SPIKE_PUSH_WAIT"] ?? "90") ?? 90
    for _ in 0..<wait { try await Task.sleep(for: .seconds(1)) }
    got = await PushBox.shared.notes
    for (i, n) in got.enumerated() {
        let c = CKNotification(fromRemoteNotificationDictionary: n.1)
        out("push \(i + 1)", "t=\(n.0.timeIntervalSince1970) class=\(c.map { String(describing: type(of: $0)) } ?? "nil") type=\(c?.notificationType.rawValue ?? -1) subscriptionID=\(c?.subscriptionID ?? "nil") isPruned=\(c?.isPruned ?? false) keys=\(n.1.keys.map { "\($0)" }.sorted())")
    }
    out("total pushes seen", got.count)
    _ = try? await e.db.deleteSubscription(withID: subID)
}

// MARK: runner

func runAll() async {
    let probes = (ProcessInfo.processInfo.environment["SPIKE_PROBES"] ?? "account,conditional,limits,assets,feed,perf").split(separator: ",").map(String.init)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("c0-\(UUID().uuidString.prefix(6))")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    // SPIKE_ZONE names an existing zone to share with another process (the push test); it is not deleted at the end.
    let shared = ProcessInfo.processInfo.environment["SPIKE_ZONE"]
    let zone = CKRecordZone.ID(zoneName: shared ?? "c0-\(UUID().uuidString.lowercased())", ownerName: CKCurrentUserDefaultName)
    let env = Env(zone: zone, tmp: tmp)
    currentProbe = "setup"
    let noZone = ProcessInfo.processInfo.environment["SPIKE_NO_ZONE"] != nil // account probe only, nothing written
    if noZone { if probes.contains("account") { currentProbe = "account"; await pAccount(env) }; out("DONE", true); return }
    do {
        if probes.contains("cleanup") {
            let zs = try await env.db.allRecordZones().filter { $0.zoneID.zoneName.hasPrefix("c0-") }
            _ = try await env.db.modifyRecordZones(saving: [], deleting: zs.map(\.zoneID))
            let subs = try await env.db.allSubscriptions()
            for s in subs where s.subscriptionID.hasPrefix("c0-") { _ = try? await env.db.deleteSubscription(withID: s.subscriptionID) }
            out("cleanup", "deleted zones=\(zs.count)")
            return
        }
        let t = ContinuousClock.now
        let z = try await env.db.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: []).saveResults[zone]
        out("create zone ms", Int(ms(ContinuousClock.now - t)))
        if case .success(let zz)? = z {
            let c = zz.capabilities
            out("zone capabilities", ["fetchChanges": c.contains(.fetchChanges), "atomic": c.contains(.atomic), "sharing": c.contains(.sharing), "zoneWideSharing": c.contains(.zoneWideSharing), "ckAssets": "n/a"] as [String: Any])
        }
        let zs = try await env.db.allRecordZones()
        out("allRecordZones", zs.map { $0.zoneID.zoneName.prefix(10) })
    } catch { out("create zone", why(error)); return }
    for p in probes {
        currentProbe = p
        do {
            switch p {
            case "account": await pAccount(env)
            case "conditional": try await pConditional(env)
            case "limits": try await pLimits(env)
            case "assets": try await pAssets(env)
            case "reqbytes": try await pReqBytes(env)
            case "enc": try await pEnc(env)
            case "feed": try await pFeed(env)
            case "perf": try await pPerf(env)
            case "push": try await pPush(env)
            case "pushwrite": // the other device of the push test: two writes, 5 s apart, after SPIKE_PUSH_DELAY seconds
                try await Task.sleep(for: .seconds(Int(ProcessInfo.processInfo.environment["SPIKE_PUSH_DELAY"] ?? "3") ?? 3))
                for i in 1...2 { let r = env.record("pw-\(i)-\(UUID().uuidString.prefix(6))", bytes: 4); out("write \(i)", result(try? await env.save([r])[r.recordID])); try await Task.sleep(for: .seconds(5)) }
            default: out("unknown probe", p)
            }
        } catch { out("PROBE FAILED", why(error)) }
    }
    currentProbe = "teardown"
    if shared != nil { out("zone kept (SPIKE_ZONE)", shared!); return }
    do {
        _ = try await env.db.modifyRecordZones(saving: [], deleting: [zone])
        let left = try await env.db.allRecordZones().filter { $0.zoneID.zoneName.hasPrefix("c0-") }.count
        out("zone deleted; c0 zones left", left)
    } catch { out("delete zone", why(error)) }
}

#if canImport(UIKit)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ a: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in out("CKAccountChanged", "received") }
        Task { await runAll(); out("DONE", true); exit(0) }
        return true
    }
    func application(_ a: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken t: Data) { Task { await PushBox.shared.setToken(t.map { String(format: "%02x", $0) }.joined()) } }
    func application(_ a: UIApplication, didFailToRegisterForRemoteNotificationsWithError e: Error) { let s = String(describing: e); Task { await PushBox.shared.setError(s) } }
    func application(_ a: UIApplication, didReceiveRemoteNotification u: [AnyHashable: Any], fetchCompletionHandler done: @escaping (UIBackgroundFetchResult) -> Void) {
        out("didReceiveRemoteNotification", "yes"); let box = UncheckedBox(u)
        Task { await PushBox.shared.add(box.value); done(.noData) }
    }
}
struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
@objc(SpikeSceneDelegate) final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: ws); window?.rootViewController = UIViewController(); window?.makeKeyAndVisible()
    }
}
@main enum Main { static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self)) } }
#else
@main enum Main {
    static func main() async { await runAll(); out("DONE", true) }
}
#endif
