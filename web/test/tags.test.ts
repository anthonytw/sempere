// Tags as an observed-remove set keyed by tag key (format.md §5.4.1), ported
// from Tests/SempereTests/TagMergeTests.swift and TagConvergenceTests.swift:
// concurrent adds all survive, a remove only removes the instances it observed
// (add wins), and spelling is the earliest live instance's.

import { describe, expect, it } from "vitest";
import { cmpName, revisionFilename } from "../src/format/ids.ts";
import { type NoteState, type Op, type Revision, decodeOp, decodeRevision, encodeState, revisionName } from "../src/format/model.ts";
import { reconstruct, tagsOf } from "../src/format/reducer.ts";
import { formatRFC3339 } from "../src/format/rfc3339.ts";
import { normalizedTag, tagKey } from "../src/format/tags.ts";
import { Budget } from "../src/format/attachments.ts";
import {
  HybridClock, LogBuilder, SplitMix64, addTagOp, baseMillis, devA, devB, devC, emptyState, instance, instancesOf,
  makeSnapshot, newNoteOps, op, removeTagOp, setTagsOps, snapshotParts, testNote,
} from "./builders.ts";

function tags(revisions: Revision[]): string[] {
  return reconstruct(revisions).meta.tags;
}

function permutations<T>(xs: T[]): T[][] {
  if (xs.length <= 1) return [xs];
  return xs.flatMap((x, i) => permutations([...xs.slice(0, i), ...xs.slice(i + 1)]).map((rest) => [x, ...rest]));
}

/** Every order of `revisions` gives `expected`, and so does every order with each revision duplicated. */
function expectEveryOrder(revisions: Revision[], expected: string[]): void {
  for (const order of permutations(revisions)) {
    const label = order.map((r) => revisionFilename(revisionName(r))).join(" ");
    expect(tags(order), label).toEqual(expected);
    expect(tags([...order, ...[...order].reverse()]), label).toEqual(expected);
  }
}

function must<T>(v: T | undefined): T {
  if (v === undefined) throw new Error("expected a value");
  return v;
}

describe("tag normalization", () => {
  it("trims, collapses whitespace and matches case-insensitively", () => {
    expect(normalizedTag("  Fall\n  Term ")).toBe("Fall Term");
    expect(normalizedTag(" \t ")).toBe("");
    expect(normalizedTag("Fall  Term")).toBe("Fall Term");
    expect(tagKey(" MATH ")).toBe("math");
    expect(tagKey("Fall  2026")).toBe(tagKey("fall 2026"));
  });

  it("lists one tag per key, spelled by its earliest live instance", () => {
    const o = (hlc: string, seq: number, opIndex: number) => ({ hlc, device: devA, seq, op: opIndex });
    expect(tagsOf({
      instances: [{ tag: "math", origin: o("17596320000000005", 2, 0) }, { tag: "Math", origin: o("17596320000000003", 1, 0) },
        { tag: "exam", origin: o("17596320000000004", 1, 1) }],
      removed: [],
    })).toEqual(["Math", "exam"]);
  });
});

describe("tag merge", () => {
  // MARK: - Concurrent adds

  it("keeps concurrent adds on two devices", () => {
    const log = new LogBuilder();
    const base = log.delta(devA, 0, newNoteOps("Lecture", ["fall"]));
    const ipad = log.delta(devA, 100, [op.addTag("exam")]);
    const mac = log.delta(devB, 100, [op.addTag("math")]);
    expectEveryOrder([base, ipad, mac], ["fall", "exam", "math"]);

    // Each device snapshots what it has; any mix of snapshots and deltas agrees.
    const snapIpad = log.snapshot(devA, 200, [base, ipad]);
    const snapMac = log.snapshot(devB, 200, [base, mac]);
    expectEveryOrder([snapIpad, mac], ["fall", "exam", "math"]);
    expectEveryOrder([snapIpad, snapMac], ["fall", "exam", "math"]);
    expectEveryOrder([snapMac, base, ipad], ["fall", "exam", "math"]);

    // Compaction: a snapshot of everything, then every delta deleted.
    const all = log.snapshot(devC, 300, [snapIpad, snapMac]);
    expect(tags([all])).toEqual(["fall", "exam", "math"]);
    expect(reconstruct([all]).tagSet).toEqual(reconstruct([base, ipad, mac]).tagSet);
  });

  it("treats case variants as one tag with the first spelling", () => {
    const log = new LogBuilder();
    const a = log.delta(devA, 100, [op.addTag("Math")]);
    const b = log.delta(devB, 150, [op.addTag("math")]);
    expectEveryOrder([a, b], ["Math"]);
    const snapB = log.snapshot(devB, 200, [b]);
    expectEveryOrder([snapB, a], ["Math"]);
    // Same HLC: the device id orders them (aaaaaaaa < bbbbbbbb).
    const c = log.delta(devC, 100, [op.addTag("MATH")]);
    expectEveryOrder([c, b, a], ["Math"]);

    // Removing it by any spelling, observing every instance, removes the key.
    const state = reconstruct([a, b, c]);
    expect(instancesOf(state.tagSet, "mAtH").length).toBe(3);
    const rm = log.delta(devA, 300, [must(removeTagOp("mAtH", state))]);
    expectEveryOrder([a, b, c, rm], []);
  });

  it("replaces the spelling on a respelling", () => {
    const log = new LogBuilder();
    const a = log.delta(devA, 100, [op.addTag("math")]);
    const state = reconstruct([a]);
    const ops = setTagsOps(["Math"], state);
    expect(ops).toEqual([op.removeTag("math", [instance(a)]), op.addTag("Math")]);
    const respell = log.delta(devB, 200, ops);
    expectEveryOrder([a, respell], ["Math"]);
  });

  // MARK: - Add and remove of the same key

  it("lets a concurrent add win over a remove of the same tag", () => {
    const log = new LogBuilder();
    const add = log.delta(devA, 100, [op.addTag("exam")]);
    // The Mac saw A's add and removes the tag at 300.
    const rm = log.delta(devB, 300, [op.removeTag("exam", [instance(add)])]);
    // Meanwhile device C, which had not seen either, added "Exam" at 200.
    const concurrent = log.delta(devC, 200, [op.addTag("Exam")]);
    expectEveryOrder([add, rm], []);
    expectEveryOrder([add, rm, concurrent], ["Exam"]);

    // Same through snapshots on either side.
    const snapRm = log.snapshot(devB, 400, [add, rm]);
    expectEveryOrder([snapRm, concurrent], ["Exam"]);
    const snapAdd = log.snapshot(devC, 400, [concurrent]);
    expectEveryOrder([snapAdd, add, rm], ["Exam"]);

    // A later re-add after a remove is a new instance and stays.
    const reAdd = log.delta(devA, 500, [op.addTag("exam")]);
    expectEveryOrder([add, rm, reAdd], ["exam"]);
  });

  it("keeps a removal permanent through snapshots and compaction", () => {
    const log = new LogBuilder();
    const add = log.delta(devA, 100, [op.addTag("x"), op.addTag("y")]);
    const held = log.snapshot(devC, 150, [add]); // saw the add, not the remove
    const rm = log.delta(devB, 200, [op.removeTag("X", [instance(add, 0)])]);
    expectEveryOrder([add, held, rm], ["y"]);
    const snap = log.snapshot(devB, 300, [add, rm]);
    expect(reconstruct([snap]).tagSet.removed).toEqual([{ key: "x", origin: instance(add, 0) }]);
    // The add's revision arrives again after the remove was compacted away.
    expectEveryOrder([snap, add], ["y"]);
    expectEveryOrder([snap, held], ["y"]);
    // Instances of other keys are never affected, even if listed.
    const wrongKey = log.delta(devC, 400, [op.removeTag("z", [instance(add, 1)])]);
    expectEveryOrder([snap, wrongKey], ["y"]);
  });

  it("removes an instance whose add arrives after the remove", () => {
    const log = new LogBuilder();
    const add = log.delta(devA, 100, [op.addTag("x")]);
    const rm = log.delta(devB, 200, [op.removeTag("x", [instance(add)])]);
    const snap = log.snapshot(devB, 300, [rm]);
    expect(tags([snap])).toEqual([]);
    expectEveryOrder([snap, add], []);
  });

  // MARK: - Algebra

  it("is idempotent and commutative across snapshots", () => {
    const log = new LogBuilder();
    const r1 = log.delta(devA, 100, [op.addTag("a"), op.addTag("b")]);
    const r2 = log.delta(devB, 150, [op.addTag("c"), op.addTag("B")]);
    const r3 = log.delta(devC, 200, [op.removeTag("a", [instance(r1, 0)])]);
    const r4 = log.delta(devA, 250, [op.removeTag("c", [instance(r2, 0)]), op.addTag("d")]);
    const r5 = log.delta(devB, 260, [op.addTag("C")]);
    const all = [r1, r2, r3, r4, r5];
    const reference = reconstruct(all);
    expect(reference.meta.tags).toEqual(["b", "d", "C"]); // listed by earliest live instance
    expectEveryOrder(all, reference.meta.tags);
    // Every split into two snapshots (by different devices) of the two halves.
    for (let mask = 1; mask < (1 << all.length) - 1; mask++) {
      const left = all.filter((_, i) => (mask & (1 << i)) !== 0);
      const right = all.filter((_, i) => (mask & (1 << i)) === 0);
      const l = log.copy();
      const sl = l.snapshot(devA, 1000, left);
      const sr = l.snapshot(devB, 1000, right);
      const merged = reconstruct([sl, sr]);
      expect(merged.meta.tags, `mask ${mask}`).toEqual(reference.meta.tags);
      expect(merged.tagSet, `mask ${mask}`).toEqual(reference.tagSet);
      expect(reconstruct([sr, sl, ...left]), `mask ${mask}`).toEqual(merged);
    }
  });

  it("never shows a blank or unnormalized tag from a writer", () => {
    const log = new LogBuilder();
    const d = log.delta(devA, 100, [op.addTag(""), op.addTag("  \t "), op.addTag("  Fall\n  Term ")]);
    expect(tags([d])).toEqual(["Fall Term"]);
    const snap = log.snapshot(devB, 200, [d]);
    expect(reconstruct([snap]).tagSet.instances.map((i) => i.tag)).toEqual(["Fall Term"]);
    expect(tags([snap, d])).toEqual(["Fall Term"]);
  });

  // MARK: - Wire format (decoding)

  it("decodes tag ops and tag sets", () => {
    const o = { hlc: "17596320000000003", device: devA, seq: 12, op: 4 };
    const base = { hlc: "17596310000000000", device: devB, seq: 1, op: 1 };
    const wire = [{ op: "addTag", tag: "Math" },
      { observed: ["17596320000000003-aaaaaaaa-12-4", "17596310000000000-bbbbbbbb-1-1"], op: "removeTag", tag: "math" }];
    expect(wire.map((w, i) => decodeOp(w, `$[${i}]`, new Budget())))
      .toEqual([op.addTag("Math"), op.removeTag("math", [o, base])]);
    expect(() => decodeOp({ op: "removeTag", tag: "x", observed: ["nope"] }, "$", new Budget())).toThrow();
    // Instance origins name real revisions: seq 0 is malformed.
    expect(() => decodeOp({ op: "removeTag", tag: "x", observed: ["17596310000000000-bbbbbbbb-0-1"] }, "$", new Budget()))
      .toThrow();
    // Tags are not a setMeta field.
    expect(() => decodeOp({ op: "setMeta", field: "tags", value: ["x"] }, "$", new Budget())).toThrow();

    const snap = decodeRevision({
      noteId: testNote, device: devA, seq: 1, hlc: "17596320000000009", wall: "2026-10-04T16:20:00Z", app: "x",
      type: "snapshot", included: {},
      state: {
        deleted: false, pages: [],
        meta: { title: "", tags: [], favorite: false, created: "1970-01-01T00:00:00Z", paper: { kind: "blank" },
          pageSize: { width: 612, height: 792, infinite: false } },
        tagSet: { instances: [{ tag: "Math", origin: "17596320000000003-aaaaaaaa-12-4" }],
          removed: [{ key: "fall", origin: "17596310000000000-bbbbbbbb-1-1" }] },
      },
    });
    expect(snapshotParts(snap).state.tagSet).toEqual({
      instances: [{ tag: "Math", origin: o }], removed: [{ key: "fall", origin: base }],
    });
    // An empty set is still written: snapshot state requires it.
    const empty: NoteState = { ...emptyState(0), tagSet: { instances: [], removed: [] } };
    expect(encodeState(empty, formatRFC3339).tagSet).toEqual({ instances: [], removed: [] });
  });

  it("carries derived tags for recovery and no tags clock", () => {
    const log = new LogBuilder();
    const a = log.delta(devA, 100, [op.addTag("exam"), op.addTag("math")]);
    const snap = log.snapshot(devA, 200, [a]);
    const { state } = snapshotParts(snap);
    expect(state.meta.tags).toEqual(["exam", "math"]);
    expect(state.clocks?.tags).toBeUndefined();
    expect(state.tagSet.instances.map((i) => i.origin)).toEqual([instance(a, 0), instance(a, 1)]);
  });
});

// MARK: - Property: tags converge (TagConvergenceTests.swift)

interface Device {
  id: string;
  skew: number;
  clock: HybridClock;
  seq: number;
  view: Map<string, Revision>;
}

const pool = ["Math", "math", "MATH", "exam", "Exam", "fall term", "Fall  Term", "x", "y"];

function key(r: Revision): string {
  return revisionFilename(revisionName(r));
}

function viewState(d: Device): NoteState | undefined {
  return d.view.size === 0 ? undefined : reconstruct([...d.view.values()]);
}

/**
 * Four devices with skewed clocks each write from their own partial view
 * (per-tag adds and removes, whole-set edits),
 * exchange random subsets of what they hold, and snapshot their views.
 */
function simulate(seed: number) {
  const rng = new SplitMix64(seed);
  const devices: Device[] = [devA, devB, devC, "dddddddd"].map((id) => ({
    id, skew: rng.int(-40_000, 40_001), clock: new HybridClock(), seq: 0, view: new Map<string, Revision>(),
  }));
  const counts = { removes: 0, snapshots: 0, syncs: 0 };
  for (let step = 1; step <= 140; step++) {
    const di = rng.int(0, devices.length);
    const dev = must(devices[di]);
    const wall = baseMillis + step * 1000 + dev.skew;
    const state = viewState(dev);
    const have = state?.meta.tags ?? [];
    const r = rng.float();
    let ops: Op[] = [];
    if (r < 0.28) {
      const tag = rng.pick(pool);
      if (state && rng.float() < 0.8) {
        const o = addTagOp(tag, state);
        ops = o ? [o] : [];
      } else {
        ops = [op.addTag(normalizedTag(tag))]; // a writer that did not check
      }
    } else if (r < 0.48) {
      if (state) {
        const o = removeTagOp(rng.pick([...have, ...pool]).toUpperCase(), state);
        if (o) {
          ops = [o];
          counts.removes += 1;
        }
      }
    } else if (r < 0.64) {
      if (state) ops = setTagsOps(pool.filter(() => rng.float() < 0.3), state);
    } else if (r < 0.86) {
      const from = rng.int(0, devices.length);
      if (from === di) continue;
      for (const [name, rev] of must(devices[from]).view) {
        if (rng.float() < 0.6) {
          dev.view.set(name, rev);
          dev.clock.observe(rev.hlc, wall);
        }
      }
      counts.syncs += 1;
      continue;
    } else {
      if (dev.view.size === 0) continue;
      dev.seq += 1;
      const snap = makeSnapshot([...dev.view.values()], dev.id, dev.seq, dev.clock, wall);
      dev.view.set(key(snap), snap);
      counts.snapshots += 1;
      continue;
    }
    if (ops.length === 0) continue;
    dev.seq += 1;
    const hlc = dev.clock.tick(wall);
    const rev: Revision = { noteId: testNote, device: dev.id, seq: dev.seq, hlc, wall, app: "test/0", body: { type: "delta", ops } };
    dev.view.set(key(rev), rev);
  }
  const all = new Map<string, Revision>();
  for (const d of devices) for (const [k, v] of d.view) if (!all.has(k)) all.set(k, v);
  const sorted = [...all.values()].sort((a, b) => cmpName(revisionName(a), revisionName(b)));
  return { all: sorted, devices, counts };
}

function tagState(revisions: Revision[]) {
  const s = reconstruct(revisions);
  return { tags: s.meta.tags, set: s.tagSet };
}

describe("tag convergence (format.md §5.3, §5.4.1)", () => {
  it("converges whatever the order, snapshots and compaction", () => {
    const total = { removes: 0, snapshots: 0 };
    let nonEmpty = 0;
    for (let seed = 1; seed <= 40; seed++) {
      const rng = new SplitMix64(seed * 7919);
      const { all, devices, counts } = simulate(seed);
      total.removes += counts.removes;
      total.snapshots += counts.snapshots;
      const deltas = all.filter((r) => r.body.type === "delta");
      // The reference: a replay of every delta, no snapshot at all.
      const reference = tagState(deltas);
      if (reference.tags.length > 0) nonEmpty += 1;
      // Display tags are one per key.
      expect(new Set(reference.tags.map(tagKey)).size, `seed ${seed}`).toBe(reference.tags.length);

      // Every revision, in any order, with duplicates: snapshots change nothing.
      for (let i = 0; i < 12; i++) {
        let order = rng.shuffled(all);
        if (i % 3 === 0) order = [...order, ...order.slice(0, 5)];
        expect(tagState(order), `seed ${seed} order ${i}`).toEqual(reference);
      }

      // Compaction: every delta some snapshot covers is deleted.
      const snaps = all.filter((r) => r.body.type === "snapshot").map((r) => snapshotParts(r).included);
      const compacted = all.filter((r) => r.body.type === "snapshot" || !snaps.some((inc) => inc.covers(r.device, r.seq)));
      expect(tagState(rng.shuffled(compacted)), `seed ${seed} compacted`).toEqual(reference);

      // Every device's partial view, snapshotted by another device and merged with the rest, still agrees.
      const log = new LogBuilder();
      for (const d of devices) {
        if (d.view.size === 0) continue;
        const snap = log.snapshot("eeeeeeee", 999_000, [...d.view.values()]);
        const rest = rng.shuffled(all.filter((r) => !d.view.has(key(r))));
        expect(tagState([snap, ...rest]), `seed ${seed} view of ${d.id}`).toEqual(reference);
      }
    }
    // The generator exercises what it claims to.
    expect(total.removes).toBeGreaterThan(100);
    expect(total.snapshots).toBeGreaterThan(100);
    expect(nonEmpty).toBeGreaterThan(20);
    // About 2 s idle; vitest's default 5 s fails it on a busy runner.
  }, 60_000);
});

describe("Unicode details that must match Swift", () => {
  it("lowercases Σ to σ everywhere, as Swift does (no final sigma)", () => {
    const log = new LogBuilder();
    const a = log.delta(devA, 100, [op.addTag("οδοσ")]);
    const b = log.delta(devB, 150, [op.addTag("ΟΔΟΣ")]);
    expect(tags([a, b])).toEqual(["οδοσ"]);
    const rm = log.delta(devB, 200, [op.removeTag("ΟΔΟΣ", [instance(a)])]);
    expect(tags([a, rm])).toEqual([]);
    expect(tagKey("ΟΔΟΣ")).toBe("οδοσ");
  });

  it("splits on whole characters: a space with a combining mark is whitespace", () => {
    expect(normalizedTag("a ́b")).toBe("a b");
    expect(normalizedTag(" a\r\nb　c ")).toBe("a b c");
  });

  it("orders canonically equal page keys by id", () => {
    const id1 = "00000000-0000-4000-8000-000000000001", id2 = "00000000-0000-4000-8000-000000000002";
    const add = new LogBuilder().delta(devA, 0, [op.addPage(id2, "é"), op.addPage(id1, "é")]);
    expect(reconstruct([add]).pages.map((p) => p.id)).toEqual([id1, id2]);
  });
});
