import Foundation
import XCTest
@testable import Sempere

final class ClockTests: XCTestCase {
    func testHLCFormatAndParse() {
        let h = HLC(millis: 1_759_632_000_000, counter: 3)!
        XCTAssertEqual(h.description, "17596320000000003")
        XCTAssertEqual(HLC("17596320000000003"), h)
        XCTAssertEqual(HLC(millis: 5, counter: 0)?.description, "00000000000050000")
        XCTAssertNil(HLC("1759632000000000"))       // 16 digits
        XCTAssertNil(HLC("175963200000000033"))     // 18 digits
        XCTAssertNil(HLC("1759632000000000x"))
        XCTAssertNil(HLC("-7596320000000003"))
        XCTAssertNil(HLC(millis: 10_000_000_000_000, counter: 0))
        XCTAssertNil(HLC(millis: 0, counter: 10_000))
        XCTAssertLessThan(HLC("17596320000000003")!, HLC("17596320000000004")!)
        XCTAssertLessThan(HLC("17596320000009999")!, HLC("17596320000010000")!)
    }

    func testHLCMonotonicUnderBackwardsWallClock() {
        var clock = HybridClock()
        var last = HLC.zero
        let walls: [Int64] = [1000, 1000, 1001, 500, 400, 1001, 2000, 10, 2000, 3000]
        var out: [HLC] = []
        for w in walls {
            let h = clock.tick(wall: wallAt(baseMillis + w))
            XCTAssertGreaterThan(h, last, "tick at wall \(w)")
            last = h
            out.append(h)
        }
        // Counter increments on equal/behind wall, resets when the wall advances past.
        XCTAssertEqual(out[0], HLC(millis: baseMillis + 1000, counter: 0))
        XCTAssertEqual(out[1], HLC(millis: baseMillis + 1000, counter: 1))
        XCTAssertEqual(out[2], HLC(millis: baseMillis + 1001, counter: 0))
        XCTAssertEqual(out[3], HLC(millis: baseMillis + 1001, counter: 1))
        XCTAssertEqual(out[5], HLC(millis: baseMillis + 1001, counter: 3))
        XCTAssertEqual(out[6], HLC(millis: baseMillis + 2000, counter: 0))
        XCTAssertEqual(out[7], HLC(millis: baseMillis + 2000, counter: 1))
    }

    func testHLCObserve() {
        var clock = HybridClock()
        _ = clock.tick(wall: wallAt(baseMillis))
        let remote = HLC(millis: baseMillis + 5000, counter: 7)!
        XCTAssertEqual(clock.observe(remote, wall: wallAt(baseMillis + 10)), HLC(millis: baseMillis + 5000, counter: 8))
        XCTAssertGreaterThan(clock.tick(wall: wallAt(baseMillis + 20)), remote)
        // Equal millis on both sides: max counter + 1.
        var c2 = HybridClock(last: HLC(millis: baseMillis, counter: 4)!)
        XCTAssertEqual(c2.observe(HLC(millis: baseMillis, counter: 9)!, wall: wallAt(baseMillis - 1)),
                       HLC(millis: baseMillis, counter: 10))
        // Wall ahead of both: resets.
        XCTAssertEqual(c2.observe(HLC(millis: baseMillis, counter: 9)!, wall: wallAt(baseMillis + 1)),
                       HLC(millis: baseMillis + 1, counter: 0))
    }

    func testCounterOverflowBorrowsAMillisecond() {
        var clock = HybridClock(millis: baseMillis, counter: HLC.maxCounter)
        let h = clock.tick(wall: wallAt(baseMillis))
        XCTAssertEqual(h, HLC(millis: baseMillis + 1, counter: 0))
    }

    func testObserveIgnoresReadingsFarAhead() {
        let wall = wallAt(baseMillis)
        var clock = HybridClock(last: HLC(millis: baseMillis, counter: 5)!)
        let farAhead = HLC(millis: baseMillis + HybridClock.maxAdoptedDrift + 1, counter: 0)!
        XCTAssertEqual(clock.observe(farAhead, wall: wall), HLC(millis: baseMillis, counter: 5), "not adopted")
        XCTAssertEqual(clock.tick(wall: wall), HLC(millis: baseMillis, counter: 6))
        let nearAhead = HLC(millis: baseMillis + HybridClock.maxAdoptedDrift, counter: 3)!
        XCTAssertEqual(clock.observe(nearAhead, wall: wall), HLC(millis: nearAhead.millis, counter: 4), "adopted")
        // Such a revision still merges by its stamp as written.
        var log = LogBuilder()
        let future = Revision(noteId: testNote, device: devB, seq: 1, hlc: farAhead, wall: wall, app: "x",
                              body: .delta(ops: [.setMeta(.title("future"))]))
        let now = log.delta(devA, 0, [.setMeta(.title("now"))])
        XCTAssertEqual(try NoteReducer.reconstruct([now, future]).meta.title, "future")
    }

    func testClockSaturatesInsteadOfGoingBackwards() {
        let top = HLC(millis: HLC.maxMillis, counter: HLC.maxCounter)!
        var clock = HybridClock(last: top)
        XCTAssertEqual(clock.tick(wall: Date(timeIntervalSince1970: 1e12)), top)
        XCTAssertEqual(clock.observe(top, wall: Date(timeIntervalSince1970: 1e12)), top)
        var almost = HybridClock(millis: HLC.maxMillis - 1, counter: HLC.maxCounter)
        XCTAssertEqual(almost.tick(wall: Date(timeIntervalSince1970: 0)), HLC(millis: HLC.maxMillis, counter: 0))
    }

    func testDeviceIDAndStamp() {
        XCTAssertNotNil(DeviceID("a1b2c3d4"))
        XCTAssertNil(DeviceID("A1B2C3D4"))
        XCTAssertNil(DeviceID("a1b2c3d"))
        XCTAssertNil(DeviceID("a1b2c3dg"))
        var g = SplitMix64(seed: 1)
        for _ in 0..<200 {
            let d = DeviceID.random(using: &g)
            XCTAssertEqual(DeviceID(d.rawValue), d)
        }
        XCTAssertNotNil(DeviceID(DeviceID.random().rawValue))

        let s = Stamp(hlc: HLC("17596320000000003")!, device: DeviceID("a1b2c3d4")!)
        XCTAssertEqual(s.description, "17596320000000003-a1b2c3d4")
        XCTAssertEqual(Stamp(s.description), s)
        XCTAssertNil(Stamp("17596320000000003a1b2c3d4"))
        XCTAssertLessThan(s, Stamp(hlc: s.hlc, device: DeviceID("a1b2c3d5")!))
        XCTAssertLessThan(Stamp(hlc: s.hlc, device: DeviceID("ffffffff")!),
                          Stamp(hlc: HLC("17596320000000004")!, device: DeviceID("00000000")!))
        XCTAssertLessThan(Stamp.zero, s)
    }

    func testRevisionName() {
        let n = RevisionName("17596320000000003-a1b2c3d4-12.delta.age")
        XCTAssertEqual(n?.seq, 12)
        XCTAssertEqual(n?.kind, .delta)
        XCTAssertEqual(n?.filename, "17596320000000003-a1b2c3d4-12.delta.age")
        XCTAssertEqual(RevisionName("17596320000000003-a1b2c3d4-1.snapshot.age")?.kind, .snapshot)
        for bad in ["17596320000000003-a1b2c3d4-012.delta.age", "17596320000000003-a1b2c3d4-0.delta.age",
                    "17596320000000003-a1b2c3d4-12.delta", "17596320000000003-a1b2c3d4-12.diff.age",
                    "1759632000000003-a1b2c3d4-12.delta.age", "17596320000000003-A1B2C3D4-12.delta.age",
                    "17596320000000003-a1b2c3d4--12.delta.age", "17596320000000003-a1b2c3d4-12.delta.age.tmp"] {
            XCTAssertNil(RevisionName(bad), bad)
        }
        let names = ["17596320000000003-bbbbbbbb-1.delta.age", "17596320000000003-aaaaaaaa-10.delta.age",
                     "17596320000000003-aaaaaaaa-9.delta.age", "17596320000000002-ffffffff-50.snapshot.age"]
            .compactMap(RevisionName.init)
        XCTAssertEqual(names.sorted().map(\.filename), [
            "17596320000000002-ffffffff-50.snapshot.age", "17596320000000003-aaaaaaaa-9.delta.age",
            "17596320000000003-aaaaaaaa-10.delta.age", "17596320000000003-bbbbbbbb-1.delta.age",
        ])
    }

    func testOrigin() {
        let o = Origin("17596320000000003-a1b2c3d4-12-0")
        XCTAssertEqual(o?.seq, 12)
        XCTAssertEqual(o?.op, 0)
        XCTAssertEqual(o?.description, "17596320000000003-a1b2c3d4-12-0")
        for bad in ["17596320000000003-a1b2c3d4-12", "17596320000000003-a1b2c3d4-12-01",
                    "17596320000000003-a1b2c3d4-x-0", "17596320000000003-a1b2c3d4-12-0-1"] {
            XCTAssertNil(Origin(bad), bad)
        }
        XCTAssertLessThan(Origin("17596320000000003-a1b2c3d4-12-1")!, Origin("17596320000000003-a1b2c3d4-12-2")!)
        XCTAssertNil(Origin("17596320000000003-a1b2c3d4-0-0"), "seq starts at 1")
        XCTAssertNotNil(Origin("17596320000000003-a1b2c3d4-1-0"))
    }

    func testIncluded() throws {
        var inc = Included()
        XCTAssertFalse(inc.covers(device: devA, seq: 1))
        for s in [1, 2, 5, 6, 3] { inc.insert(device: devA, seq: s) }
        XCTAssertEqual(inc.entries[devA], Included.Entry(upTo: 3, extra: [5, 6]))
        XCTAssertTrue(inc.covers(device: devA, seq: 5))
        XCTAssertFalse(inc.covers(device: devA, seq: 4))
        inc.insert(device: devA, seq: 4)
        XCTAssertEqual(inc.entries[devA], Included.Entry(upTo: 6, extra: []))
        XCTAssertFalse(inc.covers(device: devA, seq: 0))
        XCTAssertFalse(inc.covers(device: devA, seq: -3))
        inc.insert(device: devA, seq: 0)    // ignored
        XCTAssertEqual(inc.entries[devA]?.upTo, 6)

        let other = Included([devA: .init(upTo: 2, extra: [8]), devB: .init(upTo: 1, extra: [3])])
        let u = inc.union(other)
        XCTAssertEqual(u.entries[devA], Included.Entry(upTo: 6, extra: [8]))
        XCTAssertEqual(u.entries[devB], Included.Entry(upTo: 1, extra: [3]))
        XCTAssertEqual(u, other.union(inc))

        // Normalises on construction and decode.
        XCTAssertEqual(Included.Entry(upTo: 2, extra: [4, 3, 1, 7]), Included.Entry(upTo: 4, extra: [7]))
        let json = #"{"a1b2c3d4":{"upTo":12,"extra":[15,16]},"99ee00ff":{"upTo":3,"extra":[]}}"#
        let decoded = try InkJSON.decoder().decode(Included.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.covers(device: DeviceID("a1b2c3d4")!, seq: 16))
        XCTAssertFalse(decoded.covers(device: DeviceID("a1b2c3d4")!, seq: 13))
        XCTAssertEqual(String(decoding: try InkJSON.encoder().encode(decoded), as: UTF8.self),
                       #"{"99ee00ff":{"extra":[],"upTo":3},"a1b2c3d4":{"extra":[15,16],"upTo":12}}"#)
        XCTAssertThrowsError(try InkJSON.decoder().decode(Included.self, from: Data(#"{"XYZ":{"upTo":1,"extra":[]}}"#.utf8)))
    }
}
