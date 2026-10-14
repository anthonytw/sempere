// Merge of placed items and recordings (format.md §5.3, §8.2.2, §8.3.1), ported
// from Tests/SempereTests/AttachmentMergeTests.swift (docs/attachments.md §14, A1).

import { describe, expect, it } from "vitest";
import type { JSONObject } from "../src/format/json.ts";
import type { NoteState, Op, Revision } from "../src/format/model.ts";
import { Budget } from "../src/format/attachments.ts";
import { decodeOp } from "../src/format/model.ts";
import { reconstruct } from "../src/format/reducer.ts";
import { LogBuilder, SplitMix64, devA, devB, devC, newUUID, op, p1, p2, snapshotParts } from "./builders.ts";

const blob = { sha256: "ab".repeat(32), size: 10, type: "image/jpeg" };

function image(id = newUUID(), frame = [72, 144, 216, 288]): JSONObject {
  return { id, kind: "image", layer: 100, frame, z: "a0", blob, pixelSize: [30, 40] };
}

function text(t: string, z = "a1"): JSONObject {
  return { id: newUUID(), kind: "text", layer: 100, frame: [72, 90, 300, 40], z,
    text: { font: "sans", size: 12, color: "#000000FF", runs: [{ t }] } };
}

function recording(id = newUUID(), started = "2026-10-04T16:20:00.000Z"): JSONObject {
  return { id, blob: { sha256: "ef".repeat(32), size: 7, type: "audio/mp4" }, started };
}

const att = {
  addItem: (page: string, item: JSONObject): Op => ({ op: "addItem", page, item }),
  removeItem: (page: string, itemId: string): Op => ({ op: "removeItem", page, itemId }),
  setItem: (page: string, itemId: string, field: string, value: unknown): Op =>
    ({ op: "setItem", page, itemId, field, value }),
  addRecording: (recording: JSONObject): Op => ({ op: "addRecording", recording }),
  removeRecording: (recordingId: string): Op => ({ op: "removeRecording", recordingId }),
  setRecording: (recordingId: string, field: string, value: unknown): Op =>
    ({ op: "setRecording", recordingId, field, value }),
};

const items = (s: NoteState) => s.pages.flatMap((p) => p.items);

/** Every permutation gives the same state. */
function merged(revs: Revision[]): NoteState {
  const ref = reconstruct(revs);
  const perms = (a: Revision[]): Revision[][] => a.length <= 1 ? [a]
    : a.flatMap((x, i) => perms([...a.slice(0, i), ...a.slice(i + 1)]).map((p) => [x, ...p]));
  for (const p of perms(revs)) expect(reconstruct(p)).toEqual(ref);
  return ref;
}

describe("attachment merge (docs/attachments.md §14)", () => {
  it("reads a snapshot item or recording whose origin is null as having none (fuzz regression)", () => {
    const log = new LogBuilder();
    const img = image();
    const rec = recording();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), att.addItem(p1, img), att.addRecording(rec)]);
    const snap = log.snapshot(devC, 30, [d0]);
    const { state } = snapshotParts(snap);
    for (const it of state.pages.flatMap((p) => p.items)) it.origin = null;
    for (const r of state.recordings) r.origin = null;
    const s = reconstruct([snap]);
    expect(items(s).map((i) => i.id)).toEqual([img.id]);
    expect(s.recordings.map((r) => r.id)).toEqual([rec.id]);
  });

  it("keeps the higher-stamped frame", () => {
    const log = new LogBuilder();
    const img = image();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), att.addItem(p1, img)]);
    const a = log.delta(devA, 10, [att.setItem(p1, String(img.id), "frame", [1, 1, 10, 10])]);
    const b = log.delta(devB, 20, [att.setItem(p1, String(img.id), "frame", [2, 2, 20, 20])]);
    expect(items(merged([d0, a, b])).map((i) => i.frame)).toEqual([[2, 2, 20, 20]]);
    expect(items(merged([log.snapshot(devC, 30, [d0, b]), a])).map((i) => i.frame)).toEqual([[2, 2, 20, 20]]);
  });

  it("applies a move and a crop on different fields", () => {
    const log = new LogBuilder();
    const img = image();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), att.addItem(p1, img)]);
    const move = log.delta(devA, 10, [att.setItem(p1, String(img.id), "frame", [5, 5, 216, 288])]);
    const crop = log.delta(devB, 5, [att.setItem(p1, String(img.id), "crop", [0, 0, 10, 10])]);
    const got = items(merged([d0, move, crop]))[0];
    expect(got?.frame).toEqual([5, 5, 216, 288]);
    expect(got?.crop).toEqual([0, 0, 10, 10]);
  });

  it("matches item and recording ids written in uppercase as Swift does (bug audit B17)", () => {
    // Readers accept any case and compare UUID values: an op naming the lowercase id reaches the item.
    const upper = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", lower = upper.toLowerCase();
    const recUpper = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", recLower = recUpper.toLowerCase();
    const wire = (o: Op): Op => decodeOp(JSON.parse(JSON.stringify(o)), "$", new Budget());
    const box = { ...text("before"), id: upper, parent: recUpper };
    const card: JSONObject = { id: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", kind: "audio", layer: 100, frame: [1, 2, 3, 4], z: "a2",
      recording: recUpper };
    const log = new LogBuilder();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), wire(att.addItem(p1, box)), wire(att.addItem(p1, card)),
      wire(att.addRecording(recording(recUpper)))]);
    const added = items(reconstruct([d0]));
    expect(added.map((i) => i.id)).toEqual([lower, "cccccccc-cccc-4ccc-8ccc-cccccccccccc"]);
    expect(added[0]?.parent).toBe(recLower);
    expect(added[1]?.recording).toBe(recLower);
    const set = log.delta(devA, 10, [wire(att.setItem(p1, lower, "text", { font: "sans", size: 12, color: "#000000FF", runs: [{ t: "after" }] })),
      wire(att.setRecording(recLower, "title", "Lecture"))]);
    const s1 = reconstruct([d0, set]);
    expect(items(s1)[0]?.text).toMatchObject({ runs: [{ t: "after" }] });
    expect(s1.recordings.map((r) => [r.id, r.title])).toEqual([[recLower, "Lecture"]]);
    const rm = log.delta(devA, 20, [wire(att.removeItem(p1, lower)), wire(att.removeRecording(recLower))]);
    const s2 = reconstruct([d0, set, rm]);
    expect(items(s2).map((i) => i.id)).toEqual(["cccccccc-cccc-4ccc-8ccc-cccccccccccc"]);
    expect(s2.recordings).toEqual([]);
  });

  it("keeps a removed item removed whatever sets it", () => {
    const log = new LogBuilder();
    const img = image();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), att.addItem(p1, img)]);
    const rm = log.delta(devA, 10, [att.removeItem(p1, String(img.id))]);
    const set = log.delta(devB, 20, [att.setItem(p1, String(img.id), "z", "zz")]);
    const s = merged([d0, rm, set]);
    expect(items(s)).toEqual([]);
    expect(s.tombstones?.items).toEqual([img.id]);
  });

  it("leaves a set before its add out of included and applies it later", () => {
    const log = new LogBuilder();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a")]);
    const img = image();
    const add = log.delta(devA, 10, [att.addItem(p1, img)]);
    const set = log.delta(devB, 20, [att.setItem(p1, String(img.id), "rotation", 90)]);
    const snap = log.snapshot(devC, 30, [d0, set]);
    expect(snapshotParts(snap).included.covers(devB, set.seq)).toBe(false);
    expect(items(merged([snap, set, add]))[0]?.rotation).toBe(90);
  });

  it("treats a late set on a compacted removed item as a covered no-op", () => {
    const log = new LogBuilder();
    const img = image();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), att.addItem(p1, img)]);
    const rm = log.delta(devA, 10, [att.removeItem(p1, String(img.id))]);
    const snap = log.snapshot(devA, 20, [d0, rm]);
    const late = log.delta(devB, 5, [att.setItem(p1, String(img.id), "frame", [0, 0, 1, 1])]);
    const next = log.snapshot(devC, 30, [snap, late]);
    expect(snapshotParts(next).included.covers(devB, late.seq)).toBe(true);
    expect(items(reconstruct([next]))).toEqual([]);
  });

  it("re-emits an unknown kind unchanged, with origin and clocks", () => {
    const log = new LogBuilder();
    const odd: JSONObject = { id: newUUID(), kind: "hologram", layer: 4242, frame: [1, 2, 3, 4], z: "q",
      beam: { on: true }, blob, crop: 7 };
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), att.addItem(p1, odd)]);
    const got = { ...items(reconstruct([log.snapshot(devB, 10, [d0])]))[0] };
    expect(Object.keys(got.clocks as object).sort()).toEqual(["beam", "crop", "frame", "rotation", "z"]);
    delete got.origin;
    delete got.clocks;
    expect(got).toEqual(odd);
  });

  it("orders items by (layer, z, id) and recordings by (started, id)", () => {
    const log = new LogBuilder();
    const bg: JSONObject = { id: newUUID(), kind: "pdfPage", layer: 0, frame: [0, 0, 612, 792], z: "z",
      blob: { sha256: "cd".repeat(32), size: 9, type: "application/pdf" }, pageIndex: 0, pageSize: [612, 792] };
    const t1 = text("one", "b"), t2 = text("two", "a");
    const late = recording(newUUID(), "2026-10-04T16:21:00.000Z"), early = recording();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), att.addItem(p1, t1), att.addItem(p1, bg), att.addItem(p1, t2),
      att.addRecording(late), att.addRecording(early)]);
    const s = merged([d0]);
    expect(items(s).map((i) => i.id)).toEqual([bg.id, t2.id, t1.id]);
    expect(s.recordings.map((r) => r.id)).toEqual([early.id, late.id]);
  });

  it("merges recording registers and removes", () => {
    const log = new LogBuilder();
    const rec = recording();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), att.addRecording(rec)]);
    const a = log.delta(devA, 20, [att.setRecording(String(rec.id), "title", "A")]);
    const b = log.delta(devB, 10, [att.setRecording(String(rec.id), "title", "B"),
      att.setRecording(String(rec.id), "speaker", "me")]);
    const s = merged([d0, a, b]);
    expect(s.recordings[0]?.title).toBe("A");
    expect(s.recordings[0]?.speaker).toBe("me");
    const rm = log.delta(devC, 5, [att.removeRecording(String(rec.id))]);
    expect(merged([d0, a, b, rm]).recordings).toEqual([]);
  });

  it("treats a late set on an item of a compacted removed page as a covered no-op", () => {
    const log = new LogBuilder();
    const img = image();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), op.addPage(p2, "b"), att.addItem(p2, img)]);
    const rm = log.delta(devA, 10, [op.removePage(p2)]);
    const snap = log.snapshot(devA, 20, [d0, rm]);
    const late = log.delta(devB, 5, [att.setItem(p2, String(img.id), "rotation", 90)]);
    const next = log.snapshot(devC, 30, [snap, late]);
    expect(snapshotParts(next).included.covers(devB, late.seq)).toBe(true);
    expect(items(merged([snap, late]))).toEqual([]);
  });

  it("removes a removed page's items", () => {
    const log = new LogBuilder();
    const d0 = log.delta(devA, 0, [op.addPage(p1, "a"), op.addPage(p2, "b"), att.addItem(p2, image())]);
    const rm = log.delta(devA, 10, [op.removePage(p2)]);
    expect(items(merged([d0, rm]))).toEqual([]);
  });

  it("reconstructs random logs with items the same in any order", () => {
    const rng = new SplitMix64(7n);
    const rnd = (n: number) => Number(rng.next() % BigInt(n));
    const log = new LogBuilder();
    const devices = [devA, devB, devC];
    const revs: Revision[] = [log.delta(devA, 0, [op.addPage(p1, "a"), op.addPage(p2, "b")])];
    const ids: [string, string][] = [];
    const recs: string[] = [];
    for (let i = 1; i < 60; i++) {
      const page = rnd(2) ? p1 : p2;
      const r = rnd(10);
      let o: Op;
      if (ids.length === 0 || r < 3) {
        const it = rnd(2) ? image() : text(`t${i}`);
        ids.push([page, String(it.id)]);
        o = att.addItem(page, it);
      } else if (r < 4) {
        const [pg, id] = ids[rnd(ids.length)] ?? ["", ""];
        o = att.removeItem(pg, id);
      } else if (r < 7) {
        const [pg, id] = ids[rnd(ids.length)] ?? ["", ""];
        o = rnd(2) ? att.setItem(pg, id, "frame", [rnd(9), rnd(9), 1 + rnd(9), 1 + rnd(9)])
          : att.setItem(pg, id, "note", rnd(2) ? null : `n${i}`);
      } else if (r < 8 || recs.length === 0) {
        const rec = recording();
        recs.push(String(rec.id));
        o = att.addRecording(rec);
      } else if (r < 9) {
        o = att.removeRecording(recs[rnd(recs.length)] ?? "");
      } else {
        o = att.setRecording(recs[rnd(recs.length)] ?? "", "title", `r${i}`);
      }
      revs.push(log.delta(devices[rnd(3)] ?? devA, i * 10 - rnd(25), [o]));
      if (i === 30) revs.push(log.snapshot(devC, i * 10, revs.filter(() => rnd(10) < 7)));
    }
    const ref = reconstruct(revs);
    expect(items(ref).length).toBeGreaterThan(0);
    for (let k = 0; k < 20; k++) {
      const shuffled = [...revs];
      for (let i = shuffled.length - 1; i > 0; i--) {
        const j = rnd(i + 1);
        [shuffled[i], shuffled[j]] = [shuffled[j] as Revision, shuffled[i] as Revision];
      }
      expect(reconstruct(shuffled)).toEqual(ref);
    }
  });
});
