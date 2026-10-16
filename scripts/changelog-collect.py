#!/usr/bin/env python3
"""Fold changelog.d/*.md fragments into CHANGELOG.md's [Unreleased] section, then delete them.

A fragment is `### Added|Changed|Fixed|Removed` followed by bullets (changelog.d/README.md).
Bullets go at the end of the last matching subsection of [Unreleased]; a missing subsection is
appended after the last one. Existing content is kept. Stdlib only: python3 -I scripts/changelog-collect.py
  --dir DIR        fragments directory (default changelog.d)
  --file FILE      changelog (default CHANGELOG.md)
  --dry-run        print the result, change nothing
"""
import argparse
import re
import sys
from pathlib import Path

SECTIONS = ("Added", "Changed", "Fixed", "Removed")


def parse_fragment(path):
    """Return {section: [bullet lines]} or raise ValueError."""
    out, cur = {}, None
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"###\s+(\S+)\s*$", line)
        if m:
            if m.group(1) not in SECTIONS:
                raise ValueError(f"{path}: unknown section '{m.group(1)}' (use {', '.join(SECTIONS)})")
            cur = out.setdefault(m.group(1), [])
        elif cur is None:
            if line.strip():
                raise ValueError(f"{path}: text before the first '### Section' heading")
        else:
            cur.append(line)
    for sec, lines in out.items():
        while lines and not lines[-1].strip():
            lines.pop()
        while lines and not lines[0].strip():
            lines.pop(0)
        if not lines:
            raise ValueError(f"{path}: section '{sec}' is empty")
    if not out:
        raise ValueError(f"{path}: no '### Section' heading")
    return out


def fold(text, additions):
    """additions: list of (section, lines). Returns the new changelog text."""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if re.match(r"##\s+\[Unreleased\]", l)), None)
    if start is None:
        raise ValueError("no '## [Unreleased]' heading")
    for sec, new in additions:
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
        subs = [i for i in range(start + 1, end) if re.match(r"###\s+" + sec + r"\s*$", lines[i])]
        if subs:
            nxt = next((i for i in range(subs[-1] + 1, end) if lines[i].startswith("### ")), end)
            at = nxt
            while at > subs[-1] + 1 and not lines[at - 1].strip():
                at -= 1
            lines[at:at] = new
        else:
            at = end
            while at > start + 1 and not lines[at - 1].strip():
                at -= 1
            lines[at:at] = ["", f"### {sec}", ""] + new
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default="changelog.d")
    ap.add_argument("--file", default="CHANGELOG.md")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    frags = sorted(p for p in Path(a.dir).glob("*.md") if p.name.lower() != "readme.md")
    if not frags:
        print("no fragments")
        return 0
    try:
        additions = []
        for p in frags:
            parsed = parse_fragment(p)
            additions += [(s, parsed[s]) for s in SECTIONS if s in parsed]
        new = fold(Path(a.file).read_text(encoding="utf-8"), additions)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if a.dry_run:
        print(new, end="")
        return 0
    Path(a.file).write_text(new, encoding="utf-8")
    for p in frags:
        p.unlink()
    print(f"folded {len(frags)} fragment(s) into {a.file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
