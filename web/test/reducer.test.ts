// Note merge (format.md §5.2–§5.6), ported from Tests/SempereTests/MergeTests.swift,
// the page-paper cases of PaperModelTests.swift and the ordering rules behind
// PageOrderTests.swift.

import { describe, expect, it } from "vitest";
import { originOf, originString, stampString } from "../src/format/ids.ts";
import {
  type NoteState, type Op, type Revision, type Stroke, decodeRevision, defaultPaper, encodeState, revisionName,
} from "../src/format/model.ts";
import { NoteLogError, reconstruct } from "../src/format/reducer.ts";
import { formatRFC3339 } from "../src/format/rfc3339.ts";
import {
  HybridClock, LogBuilder, SplitMix64, a4, hlcString, allStrokeIds, applyDeltas, baseMillis, compact, devA, devB, devC, emptyState,
  instancesOf, letter, makeSnapshot, newUUID, op, p1, p2, page, recognition, snapshotParts, stampOf, stroke, strokeIds,
  testNote, withState, zeroStampValue,
} from "./builders.ts";

function json(s: NoteState): string {
  return JSON.stringify(encodeState(s, formatRFC3339));
}

describe("merge scenarios", () => {
  it("keeps concurrent adds on two devices", () => {
    const log = new LogBuilder();
    const s1 = stroke(), s2 = stroke(), s3 = stroke();
    const base = log.delta(devA, 0, [op.addPage(p1, "V")]);
    const a = log.delta(devA, 100, [op.addStroke(p1, s1), op.addStroke(p1, s3)]);
    const b = log.delta(devB, 100, [op.addStroke(p1, s2)]);
    const state = reconstruct([b, a, base]);
    // Insertion order by add stamp: (100, aaaaaaaa) before (100, bbbbbbbb).
    expect(strokeIds(state)).toEqual([[s1.id, s3.id, s2.id]]);
    expect(reconstruct([a, base, b])).toEqual(state);
  });

  it("lets a remove win over a concurrent re-add", () => {
    const log = new LogBuilder();
    const s = stroke();
    const d1 = log.delta(devA, 0, [op.addPage(p1, "V"), op.addStroke(p1, s)]);
    const rmA = log.delta(devA, 200, [op.removeStroke(p1, s.id)]);
    // B, not having seen the remove, re-adds the same stroke later (e.g. undo).
    const reB = log.delta(devB, 300, [op.addStroke(p1, s)]);
    expect(allStrokeIds(reconstruct([d1, rmA, reB]))).toEqual([]);
    expect(allStrokeIds(reconstruct([reB, rmA, d1]))).toEqual([]);
    // Still removed when a snapshot saw all three.
    const snapAll = log.snapshot(devC, 400, [d1, rmA, reB]);
    expect(allStrokeIds(reconstruct([snapAll, reB, d1]))).toEqual([]);
  });

  it("never re-adds a removed stroke id", () => {
    const log = new LogBuilder();
    const s = stroke();
    const d1 = log.delta(devA, 0, [op.addPage(p1, "V")]);
    const rm = log.delta(devB, 100, [op.removeStroke(p1, s.id)]);
    const snap = log.snapshot(devB, 150, [d1, rm]);
    const { state } = snapshotParts(snap);
    expect(state.tombstones?.strokes).toEqual([s.id]);

    // A re-add of a tombstoned id is ignored.
    const reAdd = log.delta(devA, 200, [op.addStroke(p1, s)]);
    expect(allStrokeIds(applyDeltas([reAdd], state, stampOf(snap)))).toEqual([]);
    // A remove and a later re-add in the same run: the re-add is ignored.
    const s2 = stroke();
    const add2 = log.delta(devA, 300, [op.addStroke(p1, s2)]);
    const rm2 = log.delta(devA, 400, [op.removeStroke(p1, s2.id)]);
    const reAdd2 = log.delta(devB, 500, [op.addStroke(p1, s2)]);
    expect(allStrokeIds(applyDeltas([reAdd2, rm2, add2], state, stampOf(snap)))).toEqual([]);
    // The conforming way to undo an erase: a new id with `parent` set.
    const restored = stroke(newUUID(), s2.id);
    const undo = log.delta(devA, 600, [op.addStroke(p1, restored)]);
    const after = applyDeltas([add2, rm2, undo], state, stampOf(snap));
    expect(allStrokeIds(after)).toEqual([restored.id]);
    expect(after.pages[0]?.strokes[0]?.parent).toBe(s2.id);
  });

  it("honours a removal seen by another snapshot", () => {
    // A removes X and snapshots; B, which never saw the removal, later writes
    // a newer snapshot that still holds X. The remove delta is compacted.
    const log = new LogBuilder();
    const x = stroke(), y = stroke();
    const d1 = log.delta(devA, 0, [op.addPage(p1, "V"), op.addStroke(p1, x), op.addStroke(p1, y)]);
    const rm = log.delta(devA, 200, [op.removeStroke(p1, x.id)]);
    const snapA = log.snapshot(devA, 250, [d1, rm]); // saw add and remove: no x, no tombstone
    const snapB = log.snapshot(devB, 1000, [d1]); // holds x and y
    expect(snapshotParts(snapA).state.tombstones).toBeUndefined();
    expect(snapA.hlc < snapB.hlc).toBe(true);
    for (const order of [[snapA, snapB], [snapB, snapA]]) {
      expect(allStrokeIds(reconstruct(order))).toEqual([y.id]);
    }
    const held = reconstruct([snapB]).pages[0]?.strokes.find((s) => s.id === x.id);
    expect(held?.origin).toBe(originString(originOf(revisionName(d1), 1)));
  });

  it("keeps a compacted delta's content through an offline device's snapshot", () => {
    const log = new LogBuilder();
    const x = stroke();
    const d1 = log.delta(devA, 0, [op.addPage(p1, "V"), op.addStroke(p1, x), op.title("From A")]);
    const snapA = log.snapshot(devA, 10, [d1]);
    expect(compact([d1, snapA])).toEqual([snapA]);

    const dB = log.delta(devB, 5_000_000, [op.addPage(p2, "W"), op.favorite(true)]);
    const snapB = log.snapshot(devB, 5_000_100, [dB]);
    expect(snapB.hlc > snapA.hlc).toBe(true);
    // d1 is gone from disk; the vault now holds snapA, dB and snapB.
    const state = reconstruct([snapB, dB, snapA]);
    expect(state.pages.map((p) => p.id)).toEqual([p1, p2]);
    expect(allStrokeIds(state)).toEqual([x.id]);
    expect(state.meta.title).toBe("From A");
    expect(state.meta.favorite).toBe(true);

    // Neither snapshot subsumes the other ...
    expect(compact([snapA, dB, snapB])).toEqual([snapA, snapB]);
    // ... until a snapshot that merged both exists.
    const merged = log.snapshot(devB, 5_000_200, [snapA, dB, snapB]);
    expect(compact([snapA, snapB, merged])).toEqual([merged]);
    expect(reconstruct([merged]).pages).toEqual(state.pages);
  });

  it("applies an orphan addStroke once its page arrives", () => {
    const log = new LogBuilder();
    const x = stroke();
    const addPage = log.delta(devA, 0, [op.addPage(p1, "V")]); // A seq 1
    const draw = log.delta(devA, 100, [op.addStroke(p1, x), op.title("t")]); // A seq 2
    // C received A's seq 2 but not seq 1.
    const snap = log.snapshot(devC, 200, [draw]);
    const { included, state } = snapshotParts(snap);
    expect(included.covers(devA, 2)).toBe(false);
    expect(state.meta.title).toBe("t");
    expect(allStrokeIds(state)).toEqual([]);
    // The page arrives; the stroke appears.
    expect(strokeIds(reconstruct([snap, draw, addPage]))).toEqual([[x.id]]);
    // And a snapshot taken now includes both.
    const snap2 = log.snapshot(devC, 300, [snap, draw, addPage]);
    const inc2 = snapshotParts(snap2).included;
    expect(inc2.covers(devA, 1) && inc2.covers(devA, 2)).toBe(true);
    expect(strokeIds(reconstruct([snap2]))).toEqual([[x.id]]);
  });

  it("keeps a tombstone while the adding revision is an orphan", () => {
    const log = new LogBuilder();
    const q = "00000000-0000-4000-8000-0000000000a9";
    const s = stroke(), t = stroke();
    const a1 = log.delta(devA, 0, [op.addPage(p1, "V")]);
    const a2 = log.delta(devA, 100, [op.addStroke(p1, s), op.addStroke(q, t)]); // q unseen
    const c1 = log.snapshot(devC, 200, [a1, a2]);
    expect(snapshotParts(c1).included.covers(devA, 2)).toBe(false);
    expect(allStrokeIds(snapshotParts(c1).state)).toEqual([s.id]);
    const b1 = log.delta(devB, 300, [op.removeStroke(p1, s.id)]);
    const c2 = log.snapshot(devC, 400, [c1, a2, b1]);
    expect(snapshotParts(c2).included.covers(devA, 2)).toBe(false);
    expect(snapshotParts(c2).state.tombstones?.strokes).toEqual([s.id]);

    // Compact everything the rule allows; a2 must survive and S must stay removed.
    const kept = compact([a1, a2, c1, b1, c2]);
    expect(kept).toEqual([a2, c2]);
    expect(allStrokeIds(reconstruct(kept))).toEqual([]);

    // Once q arrives, a2 is applied in full: T appears, S stays removed, and
    // the next snapshot may drop the tombstone.
    const addQ = log.delta(devB, 500, [op.addPage(q, "W")]);
    expect(allStrokeIds(reconstruct([...kept, addQ]))).toEqual([t.id]);
    const c3 = log.snapshot(devC, 600, [...kept, addQ]);
    expect(snapshotParts(c3).included.covers(devA, 2)).toBe(true);
    expect(snapshotParts(c3).state.tombstones?.strokes[0]).toBeUndefined();
    expect(allStrokeIds(reconstruct([c3, a2]))).toEqual([t.id]);
  });

  it("treats a late addStroke on a removed page as a covered no-op", () => {
    const log = new LogBuilder();
    const addP = log.delta(devA, 0, [op.addPage(p1, "V")]);
    const rmP = log.delta(devB, 100, [op.removePage(p1)]);
    const s1 = log.snapshot(devB, 200, [addP, rmP]);
    expect(snapshotParts(s1).state.tombstones?.pages).toEqual([p1]);
    const lateLog = log.copy();
    const late = lateLog.delta(devC, 50, [op.addStroke(p1, stroke())]);
    let current = [s1, late];
    for (let i = 0; i < 3; i++) {
      const snap = lateLog.snapshot(devB, 300 + i * 100, current);
      const { included, state } = snapshotParts(snap);
      expect(included.entries.get(devC)).toEqual({ upTo: 1, extra: [] });
      expect(state.pages).toEqual([]);
      expect(state.tombstones?.pages).toEqual([p1]);
      current = [snap];
    }
  });

  it("does not invent origins when applying to a bare state", () => {
    const log = new LogBuilder();
    const held = stroke();
    const state = emptyState(baseMillis, [{ ...page(p1, "V"), strokes: [held] }]);
    const added = stroke();
    const d = log.delta(devA, 100, [op.addStroke(p1, added)]);
    const out = applyDeltas([d], state, { hlc: hlcString(baseMillis), device: devB });
    const strokes = out.pages[0]?.strokes ?? [];
    expect(strokes.map((s) => s.id)).toEqual([held.id, added.id]);
    expect(strokes[0]?.origin).toBeUndefined();
    expect(out.pages[0]?.origin).toBeUndefined();
    expect(strokes[1]?.origin).toBe(originString(originOf(revisionName(d), 0)));
  });

  it("keeps one piece set of a concurrent slice (format.md §5.6.1)", () => {
    const log = new LogBuilder();
    const x = stroke();
    const a1 = stroke(newUUID(), x.id), a2 = stroke(newUUID(), x.id);
    const b1 = stroke(newUUID(), x.id), b2 = stroke(newUUID(), x.id);
    const d0 = log.delta(devA, 0, [op.addPage(p1, "V"), op.addStroke(p1, x)]);
    const sliceA = log.delta(devA, 100, [op.removeStroke(p1, x.id), op.addStroke(p1, a1), op.addStroke(p1, a2)]);
    const sliceB = log.delta(devB, 100, [op.removeStroke(p1, x.id), op.addStroke(p1, b1), op.addStroke(p1, b2)]);
    const state = reconstruct([sliceB, d0, sliceA]);
    // Same hlc: B's greater device id wins; A's pieces are superseded.
    expect(strokeIds(state)).toEqual([[b1.id, b2.id]]);
    expect(state.pages[0]?.strokes.every((s) => s.parent === x.id && s.replaces === true)).toBe(true);
    expect(new Set(state.tombstones?.superseded)).toEqual(new Set([a1.id, a2.id]));
    expect(state.tombstones?.strokes).toEqual([]);
  });

  it("lets the later of two concurrent replacements win, with what the loser did to its pieces", () => {
    const log = new LogBuilder();
    const x = stroke();
    const a1 = stroke(newUUID(), x.id), a2 = stroke(newUUID(), x.id), a11 = stroke(newUUID(), a1.id);
    const b1 = stroke(newUUID(), x.id);
    const d0 = log.delta(devA, 0, [op.addPage(p1, "V"), op.addStroke(p1, x)]);
    const sliceA = log.delta(devA, 100, [op.removeStroke(p1, x.id), op.addStroke(p1, a1), op.addStroke(p1, a2)]);
    const againA = log.delta(devA, 150, [op.removeStroke(p1, a1.id), op.addStroke(p1, a11)]);
    const sliceB = log.delta(devB, 200, [op.removeStroke(p1, x.id), op.addStroke(p1, b1)]);
    expect(allStrokeIds(reconstruct([sliceB, againA, d0, sliceA]))).toEqual([b1.id]);
    // A snapshot of A's side alone keeps a1's link, so B still wins once the deltas are gone.
    const snap = log.snapshot(devA, 160, [d0, sliceA, againA]);
    expect(snapshotParts(snap).state.tombstones?.lineage).toEqual(
      [{ stroke: a1.id, parent: x.id, by: `${hlcString(baseMillis + 100)}-${devA}-2` }]);
    expect(allStrokeIds(reconstruct([sliceB, snap]))).toEqual([b1.id]);
    // A re-creation (undo of an erase: x already removed) is not a replacement.
    const back = stroke(newUUID(), x.id);
    const undo = log.delta(devC, 300, [op.addStroke(p1, back)]);
    expect(new Set(allStrokeIds(reconstruct([d0, sliceA, againA, sliceB, undo])))).toEqual(new Set([b1.id, back.id]));
  });

  it("does not resurrect a stroke whose add arrives after its remove", () => {
    const log = new LogBuilder();
    const s = stroke();
    const pg = log.delta(devA, 0, [op.addPage(p1, "V")]);
    const add = log.delta(devA, 100, [op.addStroke(p1, s)]); // A seq 2
    const remove = log.delta(devB, 200, [op.removeStroke(p1, s.id)]);
    // C has received the page and the remove, but not yet the add.
    const snap = log.snapshot(devC, 300, [pg, remove]);
    const { included, state } = snapshotParts(snap);
    expect(included.covers(devA, 2)).toBe(false);
    expect(state.tombstones).toEqual({ strokes: [s.id], pages: [], items: [], recordings: [], lineage: [], superseded: [] });
    // The add arrives late; the old remove still wins.
    expect(allStrokeIds(reconstruct([snap, add]))).toEqual([]);
    expect(allStrokeIds(reconstruct([add, pg, snap, remove]))).toEqual([]);
    // Without the tombstone, the snapshot would resurrect it (guards the test itself).
    const bare = structuredClone(state);
    delete bare.tombstones;
    const unsafe = withState({ ...snap, app: "x" }, bare);
    expect(allStrokeIds(reconstruct([unsafe, add]))).toEqual([s.id]);
    // Once a later snapshot sees the add, the tombstone is dropped and the stroke stays gone.
    const snap2 = log.snapshot(devA, 400, [snap, add]);
    expect(snapshotParts(snap2).included.covers(devA, 2)).toBe(true);
    expect(snapshotParts(snap2).state.tombstones).toBeUndefined();
    expect(allStrokeIds(reconstruct([snap2, snap, add, pg, remove]))).toEqual([]);
  });

  it("keeps a removed page's tombstone", () => {
    const log = new LogBuilder();
    const addP = log.delta(devA, 0, [op.addPage(p2, "V"), op.addStroke(p2, stroke())]);
    const rmP = log.delta(devB, 100, [op.removePage(p2)]);
    const snap = log.snapshot(devC, 200, [rmP]);
    expect(snapshotParts(snap).state.tombstones?.pages).toEqual([p2]);
    expect(reconstruct([addP, snap]).pages).toEqual([]);
  });

  it("weighs a late delta against the snapshot's recorded clock", () => {
    // The snapshot recorded title set at t=300; a late delta at t=200 loses.
    const log = new LogBuilder();
    const t1 = log.delta(devA, 100, [op.title("One")]);
    const t3 = log.delta(devA, 300, [op.title("Three")]);
    const snap = log.snapshot(devB, 400, [t1, t3]);
    expect(snapshotParts(snap).state.clocks?.title).toBe(stampString(stampOf(t3)));
    const lateOlder = log.delta(devC, 200, [op.title("Two")]);
    expect(reconstruct([lateOlder, snap]).meta.title).toBe("Three");

    // The snapshot recorded title set at t=100; a late delta at t=200 (older
    // than the snapshot itself) wins.
    const log2 = new LogBuilder();
    const u1 = log2.delta(devA, 100, [op.title("One")]);
    const snapB = log2.snapshot(devB, 400, [u1]);
    const late = log2.delta(devC, 200, [op.title("Two")]);
    expect(reconstruct([snapB, late]).meta.title).toBe("Two");
    expect(reconstruct([late, u1, snapB]).meta.title).toBe("Two");

    // A snapshot without clocks stamps registers with its own (hlc, device).
    const bare = structuredClone(snapshotParts(snapB).state);
    delete bare.clocks;
    const unclocked = withState({ ...snapB, app: "x" }, bare);
    expect(reconstruct([unclocked, late]).meta.title).toBe("One");
    const newer = log2.delta(devC, 500, [op.title("Five")]);
    expect(reconstruct([unclocked, late, newer]).meta.title).toBe("Five");
  });

  it("orders pages by LWW order keys", () => {
    const log = new LogBuilder();
    const add = log.delta(devA, 0, [op.addPage(p1, "a"), op.addPage(p2, "b")]);
    const moveA = log.delta(devA, 100, [op.setPageOrder(p1, "c")]); // p1 after p2
    const moveB = log.delta(devB, 150, [op.setPageOrder(p2, "0")]); // p2 first
    const moveC = log.delta(devC, 120, [op.setPageOrder(p1, "Z")]); // 120 > 100: wins on p1
    const state = reconstruct([moveA, moveB, moveC, add]);
    expect(state.pages.map((p) => p.id)).toEqual([p2, p1]);
    expect(state.pages.map((p) => p.order)).toEqual(["0", "Z"]);
    expect(state.pages[1]?.orderClock).toBe(stampString(stampOf(moveC)));

    // Equal order keys tie-break on id.
    const tie = log.delta(devA, 200, [op.setPageOrder(p2, "Z")]);
    expect(reconstruct([add, moveC, tie]).pages.map((p) => p.id)).toEqual([p1, p2]);

    // The recorded orderClock survives a snapshot: a late older move loses, a late newer one wins.
    const snap = log.snapshot(devB, 300, [add, moveA]);
    const lateOld = log.delta(devC, 50, [op.setPageOrder(p1, "0")]);
    expect(reconstruct([snap, lateOld]).pages.find((p) => p.id === p1)?.order).toBe("c");
    const lateNew = log.delta(devC, 250, [op.setPageOrder(p1, "0")]);
    expect(reconstruct([snap, lateNew]).pages.find((p) => p.id === p1)?.order).toBe("0");
  });

  it("orders pages byte-wise by order key, not by locale or UTF-16", () => {
    const log = new LogBuilder();
    const ids = [newUUID(), newUUID(), newUUID(), newUUID(), newUUID()];
    // UTF-8 byte order: "Z" < "a" < "a0" < "\u{E000}" < "\u{1F600}" (UTF-16 would put the emoji first).
    const orders = ["\u{1F600}", "a0", "\u{E000}", "Z", "a"];
    const add = log.delta(devA, 0, ids.map((id, i) => op.addPage(id, orders[i] ?? "")));
    const state = reconstruct([add]);
    expect(state.pages.map((p) => p.order)).toEqual(["Z", "a", "a0", "\u{E000}", "\u{1F600}"]);
  });

  it("merges page recognition by LWW", () => {
    const log = new LogBuilder();
    const add = log.delta(devA, 0, [op.addPage(p1, "a"), op.addPage(p2, "b")]);
    // Never set: no recognition and no clock.
    const plain = reconstruct([add]);
    expect(plain.pages[0]?.recognition).toBeUndefined();
    expect(plain.pages[0]?.recognitionClock).toBeUndefined();

    const setA = log.delta(devA, 100, [op.setPageRecognition(p1, recognition("one"))]);
    const setB = log.delta(devB, 150, [op.setPageRecognition(p1, recognition("two"))]);
    const setC = log.delta(devC, 120, [op.setPageRecognition(p1, recognition("three"))]);
    const state = reconstruct([setC, setB, add, setA]);
    expect(state.pages[0]?.recognition?.text).toBe("two");
    expect(state.pages[0]?.recognitionClock).toBe(stampString(stampOf(setB)));
    expect(state.pages[1]?.recognition).toBeUndefined();
    expect(reconstruct([add, setA, setB, setC])).toEqual(state);

    // Clearing is an ordinary LWW write.
    const clear = log.delta(devA, 200, [op.setPageRecognition(p1, undefined)]);
    const cleared = reconstruct([add, setA, setB, clear]);
    expect(cleared.pages[0]?.recognition).toBeUndefined();
    expect(cleared.pages[0]?.recognitionClock).toBe(stampString(stampOf(clear)));

    // The recorded clock survives a snapshot: a late older write loses, a late newer one wins.
    const snap = log.snapshot(devB, 300, [add, setA, setB]);
    const snapState = snapshotParts(snap).state;
    expect(snapState.pages.find((p) => p.id === p1)?.recognition?.text).toBe("two");
    expect(snapState.pages.find((p) => p.id === p2)?.recognitionClock).toBeUndefined();
    const lateOld = log.delta(devC, 50, [op.setPageRecognition(p1, recognition("old"))]);
    expect(reconstruct([snap, lateOld]).pages[0]?.recognition?.text).toBe("two");
    const lateNew = log.delta(devC, 250, [op.setPageRecognition(p1, recognition("new"))]);
    expect(reconstruct([lateNew, snap]).pages[0]?.recognition?.text).toBe("new");
    // A page the snapshot never saw recognized does not compete: an older uncovered write still lands.
    const lateP2 = log.delta(devC, 60, [op.setPageRecognition(p2, recognition("p2"))]);
    expect(reconstruct([snap, lateP2]).pages[1]?.recognition?.text).toBe("p2");
    // A cleared register in a snapshot does compete.
    const snapCleared = log.snapshot(devB, 400, [add, setA, setB, clear]);
    expect(reconstruct([snapCleared, lateOld]).pages[0]?.recognition).toBeUndefined();

    // Applying to a state honors the same register.
    expect(applyDeltas([lateNew], snapState, stampOf(snap)).pages[0]?.recognition?.text).toBe("new");
    expect(applyDeltas([lateOld], snapState, stampOf(snap)).pages[0]?.recognition?.text).toBe("two");

    // An op naming a page nobody has seen is an orphan, applied again once the page arrives.
    const p3 = newUUID();
    const early = log.delta(devA, 500, [op.setPageRecognition(p3, recognition("early"))]);
    const s2 = log.snapshot(devB, 510, [add, early]);
    expect(snapshotParts(s2).included.covers(devA, early.seq)).toBe(false);
    const page3 = log.delta(devC, 520, [op.addPage(p3, "c")]);
    expect(reconstruct([s2, early, page3]).pages.find((p) => p.id === p3)?.recognition?.text).toBe("early");
  });

  it("merges page paper by LWW, apart from the note's paper", () => {
    const log = new LogBuilder();
    const add = log.delta(devA, 0, [op.addPage(p1, "a"), op.addPage(p2, "b")]);
    expect(reconstruct([add]).pages[0]?.paper).toBeUndefined();
    expect(reconstruct([add]).pages[0]?.paperClock).toBeUndefined();
    const grid = defaultPaper("grid"), dots = defaultPaper("dot"), staff = defaultPaper("staff");
    const a = log.delta(devA, 100, [op.setPagePaper(p1, grid)]);
    const b = log.delta(devB, 150, [op.setPagePaper(p1, dots)]);
    const c = log.delta(devC, 120, [op.setPagePaper(p1, staff)]);
    const state = reconstruct([c, b, add, a]);
    expect(state.pages[0]?.paper).toEqual(dots);
    expect(state.pages[0]?.paperClock).toBe(stampString(stampOf(b)));
    expect(state.pages[1]?.paper).toBeUndefined();
    expect(reconstruct([add, a, b, c])).toEqual(state);

    // Clearing wins by clock and records it.
    const clear = log.delta(devA, 200, [op.setPagePaper(p1, undefined)]);
    const cleared = reconstruct([add, a, b, clear]);
    expect(cleared.pages[0]?.paper).toBeUndefined();
    expect(cleared.pages[0]?.paperClock).toBeDefined();

    // Through a snapshot: a late older write loses, a late newer one wins.
    const snap = log.snapshot(devB, 300, [add, a, b]);
    const lateOld = log.delta(devC, 50, [op.setPagePaper(p1, staff)]);
    expect(reconstruct([snap, lateOld]).pages[0]?.paper).toEqual(dots);
    const lateNew = log.delta(devC, 250, [op.setPagePaper(p1, staff)]);
    expect(reconstruct([lateNew, snap]).pages[0]?.paper).toEqual(staff);
    // A note-level paper change does not touch a page's own paper.
    const meta = log.delta(devA, 400, [op.paper(defaultPaper("isoDot"))]);
    const both = reconstruct([snap, meta]);
    expect(both.meta.paper.kindName).toBe("isoDot");
    expect(both.pages[0]?.paper).toEqual(dots);
  });

  it("deletes and restores the note by LWW", () => {
    const log = new LogBuilder();
    const d0 = log.delta(devA, 0, [op.title("x")]);
    const del = log.delta(devA, 100, [op.deleteNote()]);
    expect(reconstruct([d0, del]).deleted).toBe(true);
    const restore = log.delta(devB, 200, [op.restoreNote()]);
    expect(reconstruct([restore, d0, del]).deleted).toBe(false);
    const delAgain = log.delta(devC, 150, [op.deleteNote()]); // concurrent, older than the restore
    expect(reconstruct([delAgain, restore, d0, del]).deleted).toBe(false);
    const snap = log.snapshot(devA, 300, [d0, del, restore]);
    expect(reconstruct([snap, delAgain]).deleted).toBe(false);
    const delLater = log.delta(devC, 400, [op.deleteNote()]);
    expect(reconstruct([snap, delAgain, delLater]).deleted).toBe(true);
  });

  it("takes created from the earliest revision's wall", () => {
    const log = new LogBuilder();
    const d1 = log.delta(devA, 500, [op.title("x")]);
    const d2 = log.delta(devB, 100, [op.favorite(true)]);
    expect(reconstruct([d1, d2]).meta.created).toBe(d2.wall);
  });

  it("rejects empty, mixed and conflicting logs and accepts exact duplicates", () => {
    const log = new LogBuilder();
    const d = log.delta(devA, 0, []);
    expect(() => reconstruct([])).toThrow(NoteLogError);
    expect(() => reconstruct([d, { ...d, noteId: newUUID() }])).toThrow(NoteLogError);
    const clash: Revision = { ...d, body: { type: "delta", ops: [op.deleteNote()] } };
    expect(() => reconstruct([d, clash])).toThrow(/conflicting revisions for device aaaaaaaa seq 1/);
    expect(() => reconstruct([d, d])).not.toThrow();
    // An equal copy decoded separately is a duplicate too, not a conflict.
    const text = {
      noteId: testNote, device: devA, seq: 1, hlc: d.hlc, wall: "2025-10-05T02:40:00.000Z", app: "test/0",
      type: "delta", ops: [{ op: "addPage", page: { id: p1, order: "V", strokes: [] } }],
    };
    expect(() => reconstruct([decodeRevision(text), decodeRevision(structuredClone(text))])).not.toThrow();
  });

  it("matches reconstruct when deltas are applied incrementally", () => {
    const log = new LogBuilder();
    const d1 = log.delta(devA, 0, [op.addPage(p1, "V"), op.addStroke(p1, stroke())]);
    const d2 = log.delta(devA, 100, [op.addStroke(p1, stroke()), op.title("t")]);
    const d3 = log.delta(devB, 200, [op.setPageOrder(p1, "W")]);
    let state = reconstruct([d1]);
    state = applyDeltas([d2], state, zeroStampValue);
    state = applyDeltas([d3], state, zeroStampValue);
    const want = reconstruct([d3, d1, d2]);
    expect(state).toEqual(want);
    const snap = log.snapshot(devA, 300, [d1]);
    expect(() => applyDeltas([snap], state, zeroStampValue)).toThrow();
  });
});

// MARK: - Property: order independence (format.md §5.3)

/**
 * 3 devices, 200 ops (adds, removes incl. of never-added ids, slices, meta
 * incl. per-tag adds and removes, page moves, page
 * removes, delete/restore), 2 snapshots from partial views. Writers follow
 * §5.2: no removed id is re-added. (MergeTests.randomLog.)
 */
function randomLog(rng: SplitMix64): Revision[] {
  const devices = [devA, devB, devC];
  const clocks = [new HybridClock(), new HybridClock(), new HybridClock()];
  const seqs = [0, 0, 0];
  const log: Revision[] = [];
  const pages: string[] = [];
  const strokes: { page: string; stroke: Stroke }[] = [];
  const tagInstances: { tag: string; origin: { hlc: string; device: string; seq: number; op: number } }[] = [];
  let opCount = 0;
  const snapshotAt = [rng.int(30, 100), rng.int(100, 190)];
  let snapshotsDone = 0;
  let step = 0;

  while (opCount < 200) {
    step += 1;
    const di = rng.int(0, 3);
    const device = devices[di] ?? devA;
    const clock = clocks[di] ?? new HybridClock();
    const wall = baseMillis + step * 1000 + rng.int(-5000, 5001);
    const hlc = clock.tick(wall);
    const ops: Op[] = [];
    const n = rng.int(1, 5);
    for (let k = 0; k < n && opCount < 200; k++) {
      opCount += 1;
      const r = rng.float();
      if (pages.length === 0 || r < 0.10) {
        const id = rng.uuid();
        pages.push(id);
        ops.push(op.addPage(id, rng.pick(["a", "b", "V", "c0"])));
      } else if (r < 0.40 || strokes.length === 0) {
        const pg = rng.pick(pages);
        const s = stroke(rng.uuid());
        strokes.push({ page: pg, stroke: s });
        ops.push(op.addStroke(pg, s));
      } else if (r < 0.50) {
        if (rng.float() < 0.15) {
          // Removal of an id whose add nobody ever writes.
          ops.push(op.removeStroke(pages[0] ?? "", rng.uuid()));
        } else {
          const victim = rng.pick(strokes);
          ops.push(op.removeStroke(victim.page, victim.stroke.id));
        }
      } else if (r < 0.58) {
        // Slice: remove + two pieces.
        const victim = rng.pick(strokes);
        ops.push(op.removeStroke(victim.page, victim.stroke.id));
        for (let j = 0; j < 2; j++) {
          const piece = stroke(rng.uuid(), victim.stroke.id);
          strokes.push({ page: victim.page, stroke: piece });
          ops.push(op.addStroke(victim.page, piece));
        }
      } else if (r < 0.78) {
        switch (rng.int(0, 6)) {
          case 0: ops.push(op.title(`t${rng.int(0, 100)}`)); break;
          case 1: {
            // Per-tag ops (§5.4.1).
            const pick = rng.int(0, 5);
            if (pick <= 1 || tagInstances.length === 0) {
              const tag = rng.pick(["x0", "X0", "x1", "y", "Y", "Fall Term"]);
              tagInstances.push({ tag, origin: { hlc, device, seq: (seqs[di] ?? 0) + 1, op: ops.length } });
              ops.push(op.addTag(tag));
            } else {
              const victim = rng.pick(tagInstances);
              const key = victim.tag.toLowerCase();
              // A partial view of the key's instances, sometimes an unknown one.
              const observed = tagInstances.filter((t) => t.tag.toLowerCase() === key && rng.bool()).map((t) => t.origin);
              if (rng.float() < 0.2) observed.push({ hlc, device: devA, seq: 999, op: 0 });
              ops.push(op.removeTag(victim.tag.toUpperCase(), [...observed, victim.origin]));
            }
            break;
          }
          case 2: ops.push(op.notebook(rng.bool() ? undefined : "nb")); break;
          case 3: ops.push(op.favorite(rng.bool())); break;
          case 4: ops.push(op.paper(defaultPaper(rng.bool() ? "ruled" : "blank"))); break;
          default: ops.push(op.pageSize(rng.bool() ? a4 : letter)); break;
        }
      } else if (r < 0.84) {
        ops.push(op.setPageOrder(rng.pick(pages), rng.pick(["0", "U", "V", "a", "aV", "b", "bV", "c"])));
      } else if (r < 0.88) {
        const text = `r${rng.int(0, 100)}`;
        ops.push(op.setPageRecognition(rng.pick(pages), rng.bool() ? undefined : recognition(text, false)));
      } else if (r < 0.92 && pages.length > 2) {
        ops.push(op.removePage(rng.pick(pages)));
      } else {
        ops.push(rng.bool() ? op.deleteNote() : op.restoreNote());
      }
    }
    seqs[di] = (seqs[di] ?? 0) + 1;
    log.push({ noteId: testNote, device, seq: seqs[di] ?? 0, hlc, wall, app: "test/0", body: { type: "delta", ops } });

    const at = snapshotAt[snapshotsDone];
    if (snapshotsDone < 2 && at !== undefined && opCount >= at) {
      snapshotsDone += 1;
      const si = rng.int(0, 3);
      // A partial view: the writer has received ~70% of the log so far.
      const view = log.filter(() => rng.float() < 0.7);
      if (view.length === 0) continue;
      seqs[si] = (seqs[si] ?? 0) + 1;
      log.push(makeSnapshot(view, devices[si] ?? devA, seqs[si] ?? 0, clocks[si] ?? new HybridClock(), wall));
    }
  }
  return log;
}

describe("order independence (format.md §5.3)", () => {
  for (let seed = 1; seed <= 8; seed++) {
    it(`reconstructs seed ${seed} identically from shuffled revision orders`, () => {
      const rng = new SplitMix64(seed);
      const revisions = randomLog(rng);
      expect(revisions.filter((r) => r.body.type === "snapshot").length).toBe(2);
      const reference = reconstruct(revisions);
      expect(reference.pages.length).toBeGreaterThan(0);
      expect(reference.tagSet.removed.length).toBeGreaterThan(0);
      const refJSON = json(reference);
      for (let i = 0; i < 50; i++) {
        let shuffled = rng.shuffled(revisions);
        // Every fifth permutation also carries duplicates (idempotence).
        if (i % 5 === 0) shuffled = [...shuffled, ...shuffled.slice(0, 10)];
        const state = reconstruct(shuffled);
        expect(state, `permutation ${i}`).toEqual(reference);
        expect(json(state), `permutation ${i}`).toBe(refJSON);
      }

      // Compaction (everything past retention) never changes the visible note.
      const kept = compact(revisions);
      expect(kept.length).toBeLessThan(revisions.length);
      const compacted = reconstruct(kept);
      expect(compacted.pages).toEqual(reference.pages);
      expect(compacted.meta).toEqual(reference.meta);
      expect(compacted.deleted).toBe(reference.deleted);
      expect(compacted.clocks).toEqual(reference.clocks);
      expect(compacted.tagSet).toEqual(reference.tagSet);
      expect(instancesOf(compacted.tagSet, "x0")).toEqual(instancesOf(reference.tagSet, "x0"));
    });
  }
});
