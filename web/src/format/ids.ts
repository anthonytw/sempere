// Clock values, device ids, stamps, origins, revision names and `included`
// (format.md §5, §5.3, §5.5), as Sources/Sempere/Clock.swift and Revision.swift.
// HLCs (17 digits) and device ids (8 lowercase hex) are fixed-width ASCII, so
// string order is their numeric order.

/** The largest `seq` a reader accepts: 2^53 − 1. */
export const maxSeq = Number.MAX_SAFE_INTEGER;

export const zeroHLC = "00000000000000000";
export const zeroDevice = "00000000";

export function isHLC(s: string): boolean {
  return /^[0-9]{17}$/.test(s);
}

export function isDeviceID(s: string): boolean {
  return /^[0-9a-f]{8}$/.test(s);
}

/** Three-way comparison of strings by UTF-16 code units (equal to byte order for ASCII). */
export function cmpStr(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/**
 * Byte-wise (UTF-8, i.e. code point) order, as Swift's
 * `utf8.lexicographicallyPrecedes`. Differs from UTF-16 order only for
 * characters above U+FFFF against U+E000…U+FFFF.
 */
export function cmpUTF8(a: string, b: string): number {
  if (a === b) return 0;
  const ia = a[Symbol.iterator](), ib = b[Symbol.iterator]();
  for (;;) {
    const x = ia.next(), y = ib.next();
    if (x.done) return y.done ? 0 : -1;
    if (y.done) return 1;
    const cx = x.value.codePointAt(0) ?? 0, cy = y.value.codePointAt(0) ?? 0;
    if (cx !== cy) return cx < cy ? -1 : 1;
  }
}

export function cmpNum(a: number, b: number): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** `(hlc, device)`: the LWW timestamp of an op (format.md §5.2). */
export interface Stamp {
  hlc: string;
  device: string;
}

export const zeroStamp: Stamp = { hlc: zeroHLC, device: zeroDevice };

export function parseStamp(s: string): Stamp | undefined {
  const p = s.split("-");
  if (p.length !== 2) return undefined;
  const [hlc, device] = p as [string, string];
  return isHLC(hlc) && isDeviceID(device) ? { hlc, device } : undefined;
}

export function stampString(s: Stamp): string {
  return `${s.hlc}-${s.device}`;
}

export function cmpStamp(a: Stamp, b: Stamp): number {
  return cmpStr(a.hlc, b.hlc) || cmpStr(a.device, b.device);
}

export type RevisionKind = "delta" | "snapshot";

/** `<hlc>-<device>-<seq>.<delta|snapshot>.age` (format.md §5). */
export interface RevisionName {
  hlc: string;
  device: string;
  seq: number;
  kind: RevisionKind;
}

function decimal(s: string, allowZero: boolean): number | undefined {
  if (!/^[0-9]+$/.test(s)) return undefined;
  if (s.length > 1 && s.startsWith("0")) return undefined;
  if (s === "0" && !allowZero) return undefined;
  const v = Number(s);
  return Number.isSafeInteger(v) ? v : undefined;
}

/** Parses a revision file base name; rejects non-canonical or out-of-range `seq`. */
export function parseRevisionName(filename: string): RevisionName | undefined {
  const dot = filename.split(".");
  if (dot.length !== 3 || dot[2] !== "age") return undefined;
  const kind = dot[1];
  if (kind !== "delta" && kind !== "snapshot") return undefined;
  const dash = (dot[0] ?? "").split("-");
  if (dash.length !== 3) return undefined;
  const [hlc, device, s] = dash as [string, string, string];
  if (!isHLC(hlc) || !isDeviceID(device)) return undefined;
  const seq = decimal(s, false);
  if (seq === undefined || seq > maxSeq) return undefined;
  return { hlc, device, seq, kind };
}

export function revisionFilename(n: RevisionName): string {
  return `${n.hlc}-${n.device}-${n.seq}.${n.kind}.age`;
}

/** Total order `(hlc, device, seq, kind)`. */
export function cmpName(a: RevisionName, b: RevisionName): number {
  return cmpStr(a.hlc, b.hlc) || cmpStr(a.device, b.device) || cmpNum(a.seq, b.seq) || cmpStr(a.kind, b.kind);
}

export function nameStamp(n: RevisionName): Stamp {
  return { hlc: n.hlc, device: n.device };
}

/** `"<hlc>-<device>-<seq>-<op>"`: which op added a page, stroke or tag instance. */
export interface Origin {
  hlc: string;
  device: string;
  seq: number;
  op: number;
}

/** Parses a page, stroke or tag instance origin; `seq` must be at least 1. */
export function parseOrigin(s: string): Origin | undefined {
  const p = s.split("-");
  if (p.length !== 4) return undefined;
  const [hlc, device, seqS, opS] = p as [string, string, string, string];
  if (!isHLC(hlc) || !isDeviceID(device)) return undefined;
  const seq = decimal(seqS, true), op = decimal(opS, true);
  if (seq === undefined || op === undefined) return undefined;
  if (seq < 1) return undefined;
  return { hlc, device, seq, op };
}

export function originString(o: Origin): string {
  return `${o.hlc}-${o.device}-${o.seq}-${o.op}`;
}

export function originOf(n: RevisionName, op: number): Origin {
  return { hlc: n.hlc, device: n.device, seq: n.seq, op };
}

export function cmpOrigin(a: Origin, b: Origin): number {
  return cmpStr(a.hlc, b.hlc) || cmpStr(a.device, b.device) || cmpNum(a.seq, b.seq) || cmpNum(a.op, b.op);
}

/** One device's coverage: every `seq ≤ upTo` plus `extra` (sorted, all > upTo + 1). */
export interface IncludedEntry {
  upTo: number;
  extra: number[];
}

function lowerBound(a: number[], v: number): number {
  let lo = 0, hi = a.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if ((a[mid] ?? 0) < v) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

export function normalizeEntry(upTo: number, extra: number[]): IncludedEntry {
  let u = Math.max(upTo, 0);
  const set = new Set(extra.filter((e) => e > u));
  while (set.delete(u + 1)) u += 1;
  return { upTo: u, extra: [...set].sort((a, b) => a - b) };
}

export function entryCovers(e: IncludedEntry, seq: number): boolean {
  if (seq < 1) return false;
  if (seq <= e.upTo) return true;
  const i = lowerBound(e.extra, seq);
  return i < e.extra.length && e.extra[i] === seq;
}

/** The revisions a snapshot reflects (format.md §5.3), per device. */
export class Included {
  readonly entries = new Map<string, IncludedEntry>();

  covers(device: string, seq: number): boolean {
    const e = this.entries.get(device);
    return e !== undefined && entryCovers(e, seq);
  }

  insert(device: string, seq: number): void {
    if (seq < 1) return;
    const e = this.entries.get(device) ?? { upTo: 0, extra: [] };
    if (entryCovers(e, seq)) {
      this.entries.set(device, e);
      return;
    }
    if (seq !== e.upTo + 1) {
      e.extra.splice(lowerBound(e.extra, seq), 0, seq);
      this.entries.set(device, e);
      return;
    }
    e.upTo = seq;
    let absorbed = 0;
    while (absorbed < e.extra.length && e.extra[absorbed] === e.upTo + 1) {
      e.upTo += 1;
      absorbed += 1;
    }
    e.extra.splice(0, absorbed);
    this.entries.set(device, e);
  }

  union(other: Included): Included {
    const out = new Included();
    for (const [d, e] of this.entries) out.entries.set(d, { upTo: e.upTo, extra: [...e.extra] });
    for (const [d, e] of other.entries) {
      const mine = out.entries.get(d) ?? { upTo: 0, extra: [] };
      out.entries.set(d, normalizeEntry(Math.max(mine.upTo, e.upTo), [...mine.extra, ...e.extra]));
    }
    return out;
  }

  /** JSON form: device → `{upTo, extra}`, devices sorted. */
  toJSON(): Record<string, IncludedEntry> {
    const out: Record<string, IncludedEntry> = {};
    for (const d of [...this.entries.keys()].sort()) {
      const e = this.entries.get(d);
      if (e) out[d] = { extra: [...e.extra], upTo: e.upTo };
    }
    return out;
  }
}
