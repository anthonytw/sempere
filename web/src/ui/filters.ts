// The sidebar's filters of the note list.

export type Filter =
  | { kind: "all" } | { kind: "favorites" } | { kind: "deleted" } | { kind: "problems" }
  | { kind: "notebook"; path: string } | { kind: "tag"; key: string; label: string };

/**
 * Whether `a` and `b` show the same notes: a tag by its key (`tagKey`), not by the spelling shown,
 * which is whichever the listing met first and can change while the filter is on.
 */
export function sameFilter(a: Filter, b: Filter): boolean {
  if (a.kind === "notebook" && b.kind === "notebook") return a.path === b.path;
  if (a.kind === "tag" && b.kind === "tag") return a.key === b.key;
  return a.kind === b.kind;
}
