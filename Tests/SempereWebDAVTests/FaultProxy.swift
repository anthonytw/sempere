import Foundation
import XCTest
@testable import SempereWebDAV

/// The control side of `scripts/dav-fault-proxy.py` (docs/ci.md "Sync
/// stress"): a test configures latency, bandwidth, resets, 5xx answers,
/// stalls and drips for the requests it is about to make, and reads the
/// proxy's request log. `scripts/test-webdav.sh` and `scripts/sync-stress.sh`
/// start the proxy in front of wsgidav and set `SEMPERE_WEBDAV_PROXY_URL`;
/// without it the tests that need it skip.
struct FaultProxy: @unchecked Sendable {
    let base: URL
    let credentials: WebDAVCredentials?
    private let transport = URLSessionTransport(timeout: 30)

    /// One rule (see the script's documentation).
    struct Rule {
        var method = "*"
        var path: String
        var action: String
        var direction = "response"
        var afterBytes = 0
        var status = 503
        var delayMs = 0
        var bytesPerSecond = 64
        var stallSeconds = 600
        var skip = 0
        var times = 1
        var probability = 1.0

        var json: [String: Any] {
            ["method": method, "path": path, "action": action, "direction": direction, "afterBytes": afterBytes,
             "status": status, "delayMs": delayMs, "bytesPerSecond": bytesPerSecond, "stallSeconds": stallSeconds,
             "skip": skip, "times": times, "probability": probability]
        }
    }

    /// One proxied request, as the proxy logged it.
    struct Request {
        var method: String
        var path: String
        /// The answer's status; -1 reset before an answer, -2 stalled.
        var status: Int
        /// The action of the fault that hit it, if any.
        var fault: String?
        /// Its `Range` header.
        var range: String?
    }

    static func fromEnvironment() throws -> FaultProxy {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SEMPERE_WEBDAV_PROXY_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("SEMPERE_WEBDAV_PROXY_URL not set (scripts/test-webdav.sh, scripts/sync-stress.sh)")
        }
        let creds = env["SEMPERE_WEBDAV_TEST_USER"].map {
            WebDAVCredentials(user: $0, password: env["SEMPERE_WEBDAV_TEST_PASSWORD"] ?? "")
        }
        return FaultProxy(base: url, credentials: creds)
    }

    /// A client for `path` on the server, through the proxy, with its own transport.
    func client(_ path: String, transport: any WebDAVTransport = URLSessionTransport()) throws -> WebDAVClient {
        try WebDAVClient(baseURL: base.appendingPathComponent(path, isDirectory: true), credentials: credentials,
                         transport: transport)
    }

    private func post(_ name: String, _ body: [String: Any]) throws {
        let r = try transport.send(WebDAVRequest(method: "POST", url: base.appendingPathComponent("__proxy__/\(name)"),
                                                 headers: ["Content-Type": "application/json"],
                                                 body: try JSONSerialization.data(withJSONObject: body)))
        guard r.status == 204 else { throw WebDAVError.http(method: "POST", path: name, status: r.status) }
    }

    /// Replaces the configuration (the counters stay).
    func configure(latencyMs: Int = 0, bytesPerSecond: Int = 0, errorRate: Double = 0, errorStatus: Int = 503,
                   seed: Int = 1, rules: [Rule] = []) throws {
        try post("config", ["latencyMs": latencyMs, "bytesPerSecond": bytesPerSecond, "errorRate": errorRate,
                            "errorStatus": errorStatus, "seed": seed, "rules": rules.map(\.json)])
    }

    /// Clears the configuration and the counters.
    func reset(seed: Int = 1) throws { try post("reset", ["seed": seed]) }

    /// Every request since the last reset, in order.
    func requests() throws -> [Request] {
        let r = try transport.send(WebDAVRequest(method: "GET", url: base.appendingPathComponent("__proxy__/stats")))
        guard r.status == 200, let json = try JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let rows = json["requests"] as? [[Any]] else { throw WebDAVError.malformedResponse("proxy stats") }
        return rows.map { row in
            Request(method: row[0] as? String ?? "", path: row[1] as? String ?? "", status: (row[2] as? NSNumber)?.intValue ?? 0,
                    fault: row[3] as? String, range: row.count > 4 ? row[4] as? String : nil)
        }
    }
}
