import Foundation
import XCTest
@testable import Sempere

/// The compatibility rules of docs/settings-sync.md §6.2: additive registry,
/// dual-written legacy keys, `$minReaderVersion`, and every older reader
/// against every newer file.
final class SettingsCompatibilityTests: VaultTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/settings")
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A reader of an earlier version: its version number and the keys its registry knew.
    struct Reader {
        var version: Int
        var keys: Set<String>
        var specs: [SharedSettingSpec] { SharedSettingsCatalog.specs.filter { keys.contains($0.name) } }
    }

    func readers() throws -> [Reader] {
        try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasPrefix("registry-v") && $0.hasSuffix(".json") }.sorted()
            .map { name in
                let o = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent(name))) as! [String: Any]
                return Reader(version: o["schemaVersion"] as! Int, keys: Set(o["keys"] as! [String]))
            }
    }

    /// Every fixture: one per shipped version (`v<N>.json`) and synthetic later files (`future-*.json`).
    func fixtures() throws -> [(String, Data)] {
        try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { ($0.hasPrefix("v") || $0.hasPrefix("future-")) && $0.hasSuffix(".json") }.sorted()
            .map { ($0, try Data(contentsOf: Self.fixtures.appendingPathComponent($0))) }
    }

    // MARK: - Rule 1: additive

    func testEveryOlderRegistryKeyIsStillRead() throws {
        let rs = try readers()
        XCTAssertFalse(rs.isEmpty)
        for r in rs {
            XCTAssertTrue(r.keys.isSubset(of: SharedSettingsCatalog.allKeyNames),
                          "registry v\(r.version) keys gone: \(r.keys.subtracting(SharedSettingsCatalog.allKeyNames).sorted())")
        }
    }

    func testTheCurrentRegistryHasASnapshot() throws {
        let current = try XCTUnwrap(try readers().first { $0.version == SharedSettingsMigrations.current },
                                    "add Fixtures/settings/registry-v\(SharedSettingsMigrations.current).json")
        XCTAssertEqual(current.keys, Set(SharedSettingsCatalog.specs.map(\.name)),
                       "registry-v\(SharedSettingsMigrations.current).json must list this version's keys")
    }

    func testAFixtureForEveryVersionValidAtItsVersion() throws {
        for n in 1...SharedSettingsMigrations.current {
            let url = Self.fixtures.appendingPathComponent("v\(n).json")
            let decoded = try SharedSettings.decode(Data(contentsOf: url))
            XCTAssertEqual(decoded.settings.schemaVersion, n, "v\(n).json")
            if n == SharedSettingsMigrations.current {
                XCTAssertEqual(SharedSettingsCatalog.issues(in: decoded).filter { $0.severity == .error }, [], "v\(n).json")
            }
        }
    }

    // MARK: - The matrix

    func testEveryOlderReaderLoadsEveryNewerFixtureAndKeepsWhatItDoesNotKnow() throws {
        for reader in try readers() {
            for (name, data) in try fixtures() {
                let decoded = try SharedSettings.decode(data)
                let file = decoded.settings
                guard file.isReadable(byReader: reader.version) else {
                    XCTAssertGreaterThan(file.minReaderVersion, reader.version, name)
                    continue   // the pause path: testAReaderOlderThanMinReaderNeverTouchesTheFile
                }
                let settings = SharedSettingsMigrations.migrated(file, using: [], to: reader.version)
                // Every key the reader knows resolves, on every device type.
                for spec in reader.specs {
                    for type in SettingsDeviceType.allCases {
                        let r = settings.resolve(spec, for: type)
                        XCTAssertNotNil(spec.validated(r.value), "\(name) v\(reader.version) \(spec.name)")
                    }
                }
                // It saves one change; everything else survives verbatim.
                var saved = settings
                let spec = try XCTUnwrap(reader.specs.first { $0.name == "eraser.objectRadius" })
                try saved.write(spec, .number(32), block: nil, type: .ipad, now: Date())
                let reread = try SharedSettings.decode(try saved.encoded()).settings
                XCTAssertEqual(reread.schemaVersion, file.schemaVersion, name)
                XCTAssertEqual(reread.minReaderVersion, file.minReaderVersion, name)
                XCTAssertEqual(reread.extra, file.extra, name)
                for (key, slot) in file.slots where key != SettingSlotKey("eraser.objectRadius") {
                    XCTAssertEqual(reread.slots[key], slot, "\(name): \(key) changed")
                }
                XCTAssertEqual(reread.value(SettingSlotKey("eraser.objectRadius")), .number(32))
            }
        }
    }

    // MARK: - Rules 3 and 4: $minReaderVersion

    func testAReaderOlderThanMinReaderNeverTouchesTheFile() throws {
        let vault = try makeVault(pqIdentity())
        let breaking = try Data(contentsOf: Self.fixtures.appendingPathComponent("future-v3-breaking.json"))
        let body = try BodyFraming.frame(json: breaking, noteId: SharedSettings.tagScope, filename: SharedSettings.fileName,
                                         secret: vault.requireSecret())
        try Vault.encrypt(body, to: vault.ageRecipients()).write(to: vault.sharedSettingsURL)
        let before = try Data(contentsOf: vault.sharedSettingsURL)

        XCTAssertThrowsError(try vault.readSharedSettings()) {
            XCTAssertEqual($0 as? SharedSettingsError, .needsNewerReader(minReaderVersion: 3))
        }
        XCTAssertThrowsError(try vault.updateSharedSettings(replacingUnreadable: true) { _ in }) {
            XCTAssertEqual($0 as? SharedSettingsError, .needsNewerReader(minReaderVersion: 3))
        }
        XCTAssertEqual(try Data(contentsOf: vault.sharedSettingsURL), before, "never rewritten")
    }

    func testMinReaderMergesToTheLargerAndIsKeptByWrites() throws {
        let a = SharedSettings(schemaVersion: 1, minReaderVersion: 1)
        let b = SharedSettings(schemaVersion: 4, minReaderVersion: 2)
        XCTAssertEqual(a.merging(b).minReaderVersion, 2)
        XCTAssertEqual(b.merging(a).schemaVersion, 4)
        XCTAssertFalse(b.isReadable(byReader: 1))
        XCTAssertTrue(b.isReadable(byReader: 2))
    }

    /// Raising `$minReaderVersion` (or `$schemaVersion`) needs its row in
    /// docs/settings-sync.md §6.3, written in the same change.
    func testVersionNumbersHaveTheirRowsInTheDoc() throws {
        let doc = try String(contentsOf: Self.repo.appendingPathComponent("docs/settings-sync.md"), encoding: .utf8)
        func lastRow(after header: String) -> Int? {
            guard let start = doc.range(of: header) else { return nil }
            var last: Int?
            for line in doc[start.upperBound...].split(separator: "\n").dropFirst() {
                guard line.hasPrefix("|") else { break }
                let cell = line.split(separator: "|").first?.trimmingCharacters(in: .whitespaces) ?? ""
                if let n = Int(cell) { last = n }
            }
            return last
        }
        XCTAssertEqual(lastRow(after: "| `$schemaVersion` | Date |"), SharedSettingsMigrations.current,
                       "docs/settings-sync.md §6.3 needs a row for $schemaVersion \(SharedSettingsMigrations.current)")
        XCTAssertEqual(lastRow(after: "| `$minReaderVersion` | Date |"), SharedSettingsMigrations.minReaderVersion,
                       "docs/settings-sync.md §6.3 needs a row for $minReaderVersion \(SharedSettingsMigrations.minReaderVersion)")
        XCTAssertLessThanOrEqual(SharedSettingsMigrations.minReaderVersion, SharedSettingsMigrations.current)
    }

    // MARK: - Rule 2: dual-write window

    /// `ink.width` replaced `pen.width` (whose values were half as large).
    let renamed = SharedSettingSpec("ink.width", .integer([2, 4, 8]), default: .number(4), "test", legacy: [
        .init("pen.width", toLegacy: { if case .number(let n) = $0 { return .number(n / 2) } else { return nil } },
              fromLegacy: { if case .number(let n) = $0 { return .number(n * 2) } else { return nil } }),
    ])

    func testANewerAppWritesBothKeysKeptEqual() throws {
        var s = SharedSettings()
        try s.write(renamed, .number(8), block: nil, type: .mac, now: Date())
        XCTAssertEqual(s.value(SettingSlotKey("ink.width")), .number(8))
        XCTAssertEqual(s.value(SettingSlotKey("pen.width")), .number(4))
        XCTAssertEqual(s.resolve(renamed, for: .mac).value, .number(8))
        try s.write(renamed, nil, block: "ipad", type: .ipad, now: Date())
        XCTAssertNotNil(s.slots[SettingSlotKey("pen.width", type: .ipad)]?.meta, "resets are dual-written too")
    }

    func testAnOlderAppsEditOfTheOldKeyStillCounts() throws {
        var s = SharedSettings()
        try s.write(renamed, .number(8), block: nil, type: .mac, now: wallAt(1_000))
        // An older app knows only pen.width and edits it later.
        try s.set(SettingSlotKey("pen.width"), to: .number(1), type: .ipad, now: wallAt(2_000))
        XCTAssertEqual(s.resolve(renamed, for: .mac).value, .number(2))
        // The newer app's next write puts both keys back in step.
        try s.write(renamed, .number(4), block: nil, type: .mac, now: wallAt(3_000))
        XCTAssertEqual(s.value(SettingSlotKey("pen.width")), .number(2))
        XCTAssertEqual(s.resolve(renamed, for: .ipad).value, .number(4))
        XCTAssertTrue(s.hasSlot(renamed, block: nil))
    }
}
