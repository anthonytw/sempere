// Replacements and concurrent replacements of a stroke (format.md §5.6.1), a
// port of Sources/Sempere/StrokeLineage.swift. A stroke added by the revision
// that removed its `parent` replaces it; when two revisions replace one stroke,
// the greatest `(hlc, device, seq)` wins and the others' strokes, and what
// replaced them in turn, are superseded.

import { type Origin, type RevisionName, cmpNum, cmpStr, originOf, parseOrigin } from "./ids.ts";
import type { LineageRecord, NoteState, Revision } from "./model.ts";

interface Group {
  hlc: string;
  device: string;
  seq: number;
}

interface Entry {
  parent: string;
  group: Group;
  replaces: boolean;
}

function cmpGroup(a: Group, b: Group): number {
  return cmpStr(a.hlc, b.hlc) || cmpStr(a.device, b.device) || cmpNum(a.seq, b.seq);
}

function groupOf(o: Origin): Group {
  return { hlc: o.hlc, device: o.device, seq: o.seq };
}

function groupKey(g: Group): string {
  return `${g.hlc}-${g.device}-${g.seq}`;
}

export interface LineageSnap {
  name: RevisionName;
  state: NoteState;
}

/** The stroke forest of one merge (every stroke with a `parent` known to it). */
export class StrokeLineage {
  readonly entries = new Map<string, Entry>();
  private readonly recordedSuperseded = new Set<string>();

  constructor(snapshots: LineageSnap[], deltas: { name: RevisionName; rev: Revision }[]) {
    for (const s of snapshots) {
      for (const r of s.state.tombstones?.lineage ?? []) {
        // An unreadable record is skipped: at worst a replacement is kept that would have lost.
        const o = parseOrigin(`${r.by}-0`);
        if (o) this.offer(r.stroke, { parent: r.parent, group: groupOf(o), replaces: true });
      }
      for (const id of s.state.tombstones?.superseded ?? []) this.recordedSuperseded.add(id);
      for (const p of s.state.pages) {
        p.strokes.forEach((st, j) => {
          if (st.parent === undefined) return;
          const o = (st.origin !== undefined ? parseOrigin(st.origin) : undefined) ?? originOf(s.name, j);
          this.offer(st.id, { parent: st.parent, group: groupOf(o), replaces: st.replaces === true });
        });
      }
    }
    for (const { name, rev } of deltas) {
      if (rev.body.type !== "delta") continue;
      const removed = new Set<string>();
      for (const op of rev.body.ops) if (op.op === "removeStroke") removed.add(op.strokeId);
      for (const op of rev.body.ops) {
        if (op.op !== "addStroke" || op.stroke.parent === undefined) continue;
        // `replaces` inside an op is ignored: the op list says it.
        this.offer(op.stroke.id, { parent: op.stroke.parent, group: groupOf(originOf(name, 0)),
          replaces: removed.has(op.stroke.parent) });
      }
    }
  }

  private offer(id: string, e: Entry): void {
    const cur = this.entries.get(id);
    if (!cur) {
      this.entries.set(id, e);
      return;
    }
    const c = cmpGroup(e.group, cur.group) || cmpStr(e.parent.toUpperCase(), cur.parent.toUpperCase());
    if (c === 0) {
      if (e.replaces) cur.replaces = true;
    } else if (c < 0) {
      this.entries.set(id, e);
    }
  }

  replaces(id: string): boolean {
    return this.entries.get(id)?.replaces ?? false;
  }

  /** Replaced stroke → group key → [group, members]. */
  private groupsByParent(): Map<string, Map<string, [Group, string[]]>> {
    const groups = new Map<string, Map<string, [Group, string[]]>>();
    for (const [id, e] of this.entries) {
      if (!e.replaces) continue;
      let byGroup = groups.get(e.parent);
      if (!byGroup) {
        byGroup = new Map<string, [Group, string[]]>();
        groups.set(e.parent, byGroup);
      }
      const k = groupKey(e.group);
      const g = byGroup.get(k);
      if (g) g[1].push(id);
      else byGroup.set(k, [e.group, [id]]);
    }
    return groups;
  }

  private static winner(byGroup: Map<string, [Group, string[]]>): [Group, string[]] | undefined {
    let best: [Group, string[]] | undefined;
    for (const g of byGroup.values()) if (!best || cmpGroup(g[0], best[0]) > 0) best = g;
    return best;
  }

  /** Superseded strokes (rules 2 and 3), recorded ones included. */
  superseded(): Set<string> {
    const children = new Map<string, string[]>();
    for (const [id, e] of this.entries) {
      if (!e.replaces) continue;
      const l = children.get(e.parent) ?? [];
      l.push(id);
      children.set(e.parent, l);
    }
    const out = new Set(this.recordedSuperseded);
    const queue = [...this.recordedSuperseded];
    for (const byGroup of this.groupsByParent().values()) {
      if (byGroup.size < 2) continue;
      const win = StrokeLineage.winner(byGroup);
      for (const g of byGroup.values()) {
        if (g === win) continue;
        for (const id of g[1]) if (!out.has(id)) { out.add(id); queue.push(id); }
      }
    }
    for (let x = queue.pop(); x !== undefined; x = queue.pop()) {
      for (const c of children.get(x) ?? []) if (!out.has(c)) { out.add(c); queue.push(c); }
    }
    return out;
  }

  /** `tombstones.lineage` for a snapshot holding `held` (format.md §5.4). */
  records(held: Set<string>, superseded: Set<string>): LineageRecord[] {
    const keep = new Set<string>();
    for (const h of held) {
      for (let e = this.entries.get(h); e?.replaces;) {
        const p = e.parent, pe = this.entries.get(p);
        if (!pe?.replaces || held.has(p) || superseded.has(p) || keep.has(p)) break;
        keep.add(p);
        e = pe;
      }
    }
    for (const byGroup of this.groupsByParent().values()) {
      const win = StrokeLineage.winner(byGroup);
      if (!win || win[1].some((id) => held.has(id) || keep.has(id))) continue;
      const first = win[1].filter((id) => !superseded.has(id)).sort((a, b) => cmpStr(a.toUpperCase(), b.toUpperCase()))[0];
      if (first !== undefined) keep.add(first);
    }
    const out: LineageRecord[] = [];
    for (const id of keep) {
      const e = this.entries.get(id);
      if (e) out.push({ stroke: id, parent: e.parent, by: groupKey(e.group) });
    }
    return out.sort((a, b) => cmpStr(a.stroke, b.stroke));
  }
}
