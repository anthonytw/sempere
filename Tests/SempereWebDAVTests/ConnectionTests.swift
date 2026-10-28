import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// "Test Connection" and the vault list (`WebDAVConnection`, `sempere webdav check`).
final class ConnectionTests: SyncTestCase {
    func client(_ server: MockDAV, path: String, auth: WebDAVCredentials? = nil) throws -> WebDAVClient {
        try WebDAVClient(baseURL: URL(string: "https://dav.example.com\(path)")!, credentials: auth, transport: server)
    }

    /// Pushes vault `name` to the server folder `/dav/<folder>`.
    func publish(_ name: String, to folder: String, _ server: MockDAV) throws {
        var o = SyncOptions(deviceLabel: name)
        o.pushOnly = true
        let c = try client(server, path: "/dav/\(folder)/")
        _ = try SyncEngine(directory: dir(name), vault: try openVault(name), client: c,
                           stateURL: tmp.appendingPathComponent("state-\(name)-\(folder).json"), options: o).run()
    }

    func vaultId(_ name: String) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: try vaultJSON(name)) as? [String: Any]
        return try XCTUnwrap(obj?["vaultId"] as? String).lowercased()
    }

    func testTheURLItselfIsAVault() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try publish("A", to: "vault", server)
        let r = try WebDAVConnection.check(try client(server, path: "/dav/vault/"))
        XCTAssertEqual(r.outcome, .vault)
        XCTAssertEqual(r.vaults.map(\.path), [[]])
        XCTAssertEqual(r.vaults.first?.name, "vault")
        XCTAssertEqual(r.vaults.first?.vaultId, try vaultId("A"))
        XCTAssertEqual(r.vaults.first?.format, "sempere/1")
        XCTAssertEqual(r.vaults.first?.url, "https://dav.example.com/dav/vault/")
    }

    /// W1: a vault's `label` (format.md §2) names it in the list, not the server folder ("dav").
    func testTheVaultsLabelNamesIt() throws {
        let server = MockDAV()
        var a = try makeVault("A")
        try a.setLabel("Notes")
        try publish("A", to: "vault", server)
        _ = try makeVault("B")
        try publish("B", to: "Work.sempere", server)
        let r = try WebDAVConnection.check(try client(server, path: "/dav/vault/"))
        XCTAssertEqual(r.vaults.first?.name, "Notes")
        XCTAssertEqual(r.vaults.first?.folder, "vault")
        let below = try WebDAVConnection.check(try client(server, path: "/dav/"))
        XCTAssertEqual(below.vaults.map(\.name).sorted(), ["Notes", "Work"], "no label: the folder name")

        // A label the server set is shown cleaned, never as raw control characters.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(server.file("vault.json"))) as? [String: Any])
        json["label"] = "\u{1B}]0;pwned\u{07}Notes"
        server.putDirect("vault.json", try JSONSerialization.data(withJSONObject: json))
        let hostile = try WebDAVConnection.check(try client(server, path: "/dav/vault/"))
        XCTAssertEqual(hostile.vaults.first?.name, "]0;pwned Notes")

        // The app's local copy reads it without the key.
        let copy = LocalCopy(directory: tmp.appendingPathComponent("loc"), folderName: "V.sempere")
        XCTAssertNil(copy.label)
        _ = try copy.download(client: try client(server, path: "/dav/Work.sempere/"))
        XCTAssertNil(copy.label)
        try FileManager.default.removeItem(at: copy.directory)
        _ = try copy.download(client: try client(server, path: "/dav/vault/"))
        XCTAssertEqual(copy.label, "]0;pwned Notes")
    }

    func testVaultsOneLevelBelowAreListedAndOthersIgnored() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        _ = try makeVault("B")
        try publish("A", to: "vault", server)
        try publish("B", to: "Work.sempere", server)
        // A folder with something that is not a manifest, and a hidden folder with a real one.
        try publish("A", to: ".hidden", server)
        let junk = try client(server, path: "/dav/junk/")
        try junk.createBase()
        try junk.put(["vault.json"], Data("{}".utf8), condition: .create)
        let r = try WebDAVConnection.check(try client(server, path: "/dav/"))
        XCTAssertEqual(r.outcome, .vaultsBelow)
        XCTAssertEqual(r.vaults.map(\.name), ["Work", "vault"])
        XCTAssertEqual(r.vaults.map(\.path), [["Work.sempere"], ["vault"]])
        XCTAssertEqual(r.vaults.map(\.vaultId), [try vaultId("B"), try vaultId("A")])
        XCTAssertEqual(r.vaults.first?.url, "https://dav.example.com/dav/Work.sempere/")
        XCTAssertEqual(r.unreadable, ["junk"])
        XCTAssertEqual(r.foldersChecked, 3)
        // The listed folder opens as the vault.
        let sub = try client(server, path: "/dav/").descendant(r.vaults[0].path)
        XCTAssertEqual(try WebDAVConnection.check(sub).outcome, .vault)
    }

    func testNoVault() throws {
        let server = MockDAV()
        let r = try WebDAVConnection.check(try client(server, path: "/dav/vault/"))
        XCTAssertEqual(r.outcome, .noVault)
        XCTAssertTrue(r.vaults.isEmpty)
    }

    func testFailuresAreClassified() throws {
        let server = MockDAV()
        server.requiredAuthorization = "Basic nobody"
        XCTAssertThrowsError(try WebDAVConnection.check(try client(server, path: "/dav/",
                                                                     auth: .init(user: "u", password: "wrong")))) {
            XCTAssertEqual(WebDAVSyncProblem.from(error: $0), .unauthorized)
            XCTAssertTrue(($0 as? WebDAVError)?.isUnauthorized == true)
        }
        server.requiredAuthorization = nil
        XCTAssertThrowsError(try WebDAVConnection.check(try client(server, path: "/nowhere/"))) {
            XCTAssertEqual(WebDAVSyncProblem.from(error: $0), .notFound)
        }
        server.interceptor = { _ in WebDAVResponse(status: 301, headers: ["Location": "https://elsewhere/\u{1b}[2J"]) }
        XCTAssertThrowsError(try WebDAVConnection.check(try client(server, path: "/dav/"))) {
            XCTAssertEqual(WebDAVSyncProblem.from(error: $0), .redirect("https://elsewhere/\\u{1B}[2J"))
        }
        server.interceptor = { _ in WebDAVResponse(status: 200, body: Data("<html>hello</html>".utf8)) }
        XCTAssertThrowsError(try WebDAVConnection.check(try client(server, path: "/dav/"))) {
            XCTAssertEqual(WebDAVSyncProblem.from(error: $0).code, "failed")
        }
        let offline = StubTransport(error: WebDAVError.offline("The Internet connection appears to be offline."))
        let c = try WebDAVClient(baseURL: URL(string: "https://dav.example.com/")!, transport: offline)
        XCTAssertThrowsError(try WebDAVConnection.check(c)) {
            XCTAssertEqual(WebDAVSyncProblem.from(error: $0), .offline)
            XCTAssertTrue(WebDAVSyncProblem.from(error: $0).isTransient)
        }
    }

    func testServerNamesAreEscapedAndBounded() {
        XCTAssertEqual(WebDAVConnection.display("Notes.sempere"), "Notes")
        XCTAssertEqual(WebDAVConnection.display("a\u{1b}[31mb"), "a\\u{1B}[31mb")
        XCTAssertEqual(WebDAVConnection.display(".sempere"), "vault")
        let long = WebDAVConnection.display(String(repeating: "x", count: 500))
        XCTAssertEqual(long.count, WebDAVConnection.maxNameLength)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertNil(WebDAVConnection.manifestFields(Data(#"{"vaultId":"../../etc"}"#.utf8)))
        XCTAssertNil(WebDAVConnection.manifestFields(Data("[]".utf8)))
        let f = WebDAVConnection.manifestFields(Data(#"{"vaultId":"7E57C0DE-0000-4000-8000-000000000001","format":"sempere/1"}"#.utf8))
        XCTAssertEqual(f?.vaultId, "7e57c0de-0000-4000-8000-000000000001")
        XCTAssertEqual(f?.format, "sempere/1")
    }

    func testAtMost64FoldersAreLookedInto() throws {
        let server = MockDAV(collections: Set(["", "/dav"] + (0..<70).map { String(format: "/dav/f%02d", $0) }))
        let r = try WebDAVConnection.check(try client(server, path: "/dav/"))
        XCTAssertEqual(r.foldersChecked, WebDAVConnection.maxFoldersChecked)
        XCTAssertEqual(r.foldersSkipped, 70 - WebDAVConnection.maxFoldersChecked)
        XCTAssertEqual(server.requestLog.count, 1 + WebDAVConnection.maxFoldersChecked)
    }

    func testDescendantRefusesUnsafeNames() throws {
        let c = try client(MockDAV(), path: "/dav/")
        for bad in [[".."], ["."], ["a/b"], [""], ["a\0"]] {
            XCTAssertThrowsError(try c.descendant(bad), "\(bad)")
        }
        XCTAssertEqual(try c.descendant(["a b"]).baseURL.absoluteString, "https://dav.example.com/dav/a%20b/")
        XCTAssertEqual(try c.descendant([]).baseURL, c.baseURL)
    }

    // MARK: - Transport errors

    func testURLErrorsAreClassified() {
        func classify(_ code: Int) -> WebDAVError {
            URLSessionTransport.classify(NSError(domain: NSURLErrorDomain, code: code))
        }
        for code in [-1009, -1005, -1003, -1004, -1001] { XCTAssertTrue(classify(code).isOffline, "\(code)") }
        // Only a failure to connect at all sent nothing (offline P3: no evidence about a window's length).
        for code in [-1009, -1003, -1004, -1006] { XCTAssertTrue(classify(code).sentNothing, "\(code)") }
        for code in [-1005, -1001] { XCTAssertFalse(classify(code).sentNothing, "\(code)") }
        XCTAssertTrue(URLSessionTransport.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))).sentNothing)
        XCTAssertFalse(URLSessionTransport.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))).sentNothing)
        for code in [-1202, -1203, -1201, -1204] {
            guard case .untrustedCertificate = classify(code) else { return XCTFail("\(code)") }
        }
        guard case .transport = classify(-1200) else { return XCTFail() }
        guard case .transport = URLSessionTransport.classify(NSError(domain: "other", code: -1009)) else { return XCTFail() }
    }

    func testErrorMessagesNameTheProblem() {
        XCTAssertEqual(WebDAVError.offline("x").localizedDescription, "server not reachable: x")
        XCTAssertEqual(WebDAVError.untrustedCertificate("y").localizedDescription, "the server's certificate is not trusted: y")
        XCTAssertEqual(WebDAVSyncProblem.from(error: WebDAVError.untrustedCertificate("y")), .certificate("y"))
    }
}

/// A transport that never gets a response.
struct StubTransport: WebDAVTransport {
    var error: WebDAVError
    func send(_ request: WebDAVRequest) throws -> WebDAVResponse { throw error }
}
