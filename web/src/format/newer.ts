// Newer content (format.md §7): format identifiers, and what a reader could
// not show of revisions a newer version wrote. Mirrors Swift
// `SempereFormat.major(of:)` and `NewerContent` (Sources/Sempere/NewerContent.swift).

import { t, tn } from "../i18n/index.ts";

/** The major version this viewer reads. */
export const formatMajor = 1;
/** The extensions (format.md §2) this viewer knows. */
export const knownFeatures: ReadonlySet<string> = new Set(["attachments", "recipients-tag", "signed-secret-link", "markers-tag"]);

/** Longest name kept, in characters (§9). */
export const maxNameLength = 64;
/** Most distinct names kept per map (§9). */
export const maxNames = 32;
/** The name everything beyond `maxNames` is counted under. */
export const otherName = "…";

/** The major of `sempere/<major>` (1 … 999 999 999, no leading zeros); undefined otherwise. */
export function majorOf(identifier: string): number | undefined {
  const m = /^sempere\/([1-9][0-9]{0,8})$/.exec(identifier);
  return m ? Number(m[1]) : undefined;
}

/** True for an identifier of a later major than this viewer's. */
export function isNewerFormat(identifier: string): boolean {
  return (majorOf(identifier) ?? 0) > formatMajor;
}

/** What a newer version wrote and what could not be shown (format.md §7.4). */
export interface NewerContent {
  revisions: number;
  unreadable: number;
  skippedOps: Record<string, number>;
  skippedElements: number;
  formats: Record<string, number>;
  features: Record<string, number>;
}

export function emptyNewer(): NewerContent {
  return { revisions: 0, unreadable: 0, skippedOps: {}, skippedElements: 0, formats: {}, features: {} };
}

/**
 * Adds `n` to `map[key]` as an own property: names come from the vault, and
 * one like `constructor` or `__proto__` must count like any other, not read
 * or set what `Object.prototype` holds under it.
 */
function bump(map: Record<string, number>, key: string, n: number): void {
  const value = (Object.hasOwn(map, key) ? (map[key] ?? 0) : 0) + n;
  Object.defineProperty(map, key, { value, writable: true, enumerable: true, configurable: true });
}

/** Counts `n` more under `name`: cut to `maxNameLength`, or `otherName` once `maxNames` are kept. */
export function countName(map: Record<string, number>, name: string, n = 1): void {
  const key = [...name].slice(0, maxNameLength).join("");
  if (!Object.hasOwn(map, key) && Object.keys(map).length >= maxNames) {
    bump(map, otherName, n);
    return;
  }
  bump(map, key, n);
}

function mergeNames(from: Record<string, number>, into: Record<string, number>): void {
  for (const k of Object.keys(from).sort()) if (k !== otherName) countName(into, k, from[k] ?? 0);
  if (Object.hasOwn(from, otherName)) bump(into, otherName, from[otherName] ?? 0);
}

export function mergeNewer(into: NewerContent, from: NewerContent): void {
  into.revisions += from.revisions;
  into.unreadable += from.unreadable;
  into.skippedElements += from.skippedElements;
  mergeNames(from.skippedOps, into.skippedOps);
  mergeNames(from.formats, into.formats);
  mergeNames(from.features, into.features);
}

/** One line: "1 newer revision (sempere/2), 3 ops skipped (moveStroke ×1, …)". */
export function newerSummary(n: NewerContent): string {
  const parts: string[] = [];
  if (n.revisions > 0) {
    const f = [...Object.keys(n.formats).sort(), ...Object.keys(n.features).sort().map((x) => t("feature {name}", { name: x }))].join(", ");
    parts.push(`${tn("{count} newer revisions", n.revisions)}${f ? ` (${f})` : ""}`);
  }
  if (n.unreadable > 0) parts.push(tn("{count} unreadable newer revisions", n.unreadable));
  const ops = Object.values(n.skippedOps).reduce((a, b) => a + b, 0);
  if (ops > 0) {
    const names = Object.keys(n.skippedOps).sort().map((k) => `${k} ×${n.skippedOps[k]}`).join(", ");
    parts.push(`${tn("{count} ops skipped", ops)} (${names})`);
  }
  if (n.skippedElements > 0) parts.push(tn("{count} snapshot elements skipped", n.skippedElements));
  return parts.join(", ");
}

/**
 * The version markers of a revision object (§7.1): true when newer, false
 * when not; throws a message for a malformed marker (§7.2).
 */
export function revisionMarkersNewer(o: Record<string, unknown>): boolean {
  const format = o.format, features = o.features;
  if (format !== undefined && (typeof format !== "string" || majorOf(format) === undefined)) {
    throw new Error("bad format marker");
  }
  if (features !== undefined && (!Array.isArray(features) || features.some((f) => typeof f !== "string"))) {
    throw new Error("bad features marker");
  }
  if (typeof format === "string" && isNewerFormat(format)) return true;
  return Array.isArray(features) && features.some((f) => !knownFeatures.has(f as string));
}

/** Why a vault is read-only from its manifest (§7.2 markers 1, 2); empty when not. */
export function manifestReadOnlyReasons(format: string, features: string[]): string[] {
  const out: string[] = [];
  if (isNewerFormat(format)) out.push(t("the vault uses format {format}, newer than this viewer's sempere/{major}", { format, major: formatMajor }));
  const unknown = [...new Set(features.filter((f) => !knownFeatures.has(f)))].sort();
  if (unknown.length) out.push(t("the vault uses format extensions this viewer does not know: {features}", { features: unknown.join(", ") }));
  return out;
}
