#!/usr/bin/env python3
"""Prepare a release in the working tree (docs/releasing.md, "B. The release"):

  1. fold the changelog.d/ fragments into [Unreleased] (scripts/changelog-collect.py);
  2. move [Unreleased] into the version's section, headed `## [X.Y.Z] - TODO(user): release date
     (YYYY-MM-DD)` (an undated section that already exists, like 1.0.0's, takes the entries instead),
     and point the compare links at the new tag;
  3. set `sempereVersion` in Sources/SempereCLI/Version.swift and the `--version` assertion in
     Tests/CLITests/CLICommandTests.swift;
  4. set MARKETING_VERSION of every app target (X.Y.Z without a prerelease suffix) unless --no-app;
     it never lowers it (the App Store refuses a version below one it has).

The release date stays `TODO(user)`: the maintainer fills it in, and release.yml refuses a section that
still holds one. Nothing is committed. Stdlib only:

  python3 -I scripts/release-prep.py X.Y.Z [--no-app] [--dry-run] [--root DIR]
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

SECTIONS = ("Added", "Changed", "Fixed", "Removed")
VERSION_RE = re.compile(r"^(\d+\.\d+\.\d+)(-[0-9A-Za-z.]+)?$")  # release.yml's tag rule, without the v
REPO_URL = "https://github.com/anthonytw/sempere"
DATE_TODO = "TODO(user): release date (YYYY-MM-DD)"


class PrepError(Exception):
    pass


def section_end(lines, start):
    return next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))


def link_start(lines):
    """Index of the first link-reference line at the bottom (`[x]: url`), or len(lines)."""
    i = len(lines)
    while i > 0 and (re.match(r"\[[^\]]+\]:\s", lines[i - 1]) or not lines[i - 1].strip()):
        i -= 1
    return i


def subsections(body):
    """[(name, [lines])] of the ### subsections in a section body; text outside them is an error."""
    out, cur = [], None
    for line in body:
        m = re.match(r"###\s+(\S+)\s*$", line)
        if m:
            cur = (m.group(1), [])
            out.append(cur)
        elif cur is None:
            if line.strip():
                raise PrepError(f"[Unreleased] has text outside a ### subsection: {line!r}")
        else:
            cur[1].append(line)
    result = []
    for name, lines in out:
        while lines and not lines[-1].strip():
            lines.pop()
        while lines and not lines[0].strip():
            lines.pop(0)
        if lines:
            result.append((name, lines))
    return result


def fold_into(lines, start, additions):
    """Append each (subsection, lines) to the section headed at lines[start] (as changelog-collect does)."""
    for sec, new in additions:
        end = section_end(lines, start)
        if end == len(lines):
            end = max(start + 1, link_start(lines))
        subs = [i for i in range(start + 1, end) if re.match(r"###\s+" + re.escape(sec) + r"\s*$", lines[i])]
        if subs:
            at = next((i for i in range(subs[-1] + 1, end) if lines[i].startswith("### ")), end)
            while at > subs[-1] + 1 and not lines[at - 1].strip():
                at -= 1
            lines[at:at] = new
        else:
            at = end
            while at > start + 1 and not lines[at - 1].strip():
                at -= 1
            lines[at:at] = ["", f"### {sec}", ""] + new
    return lines


def prepare_changelog(text, version, warnings):
    lines = text.split("\n")
    unrel = next((i for i, l in enumerate(lines) if re.match(r"##\s+\[Unreleased\]", l)), None)
    if unrel is None:
        raise PrepError("CHANGELOG.md has no '## [Unreleased]' heading")
    end = section_end(lines, unrel)
    body_end = min(end, link_start(lines)) if end == len(lines) else end
    entries = subsections(lines[unrel + 1:body_end])
    existing = next((i for i, l in enumerate(lines) if l.startswith(f"## [{version}]")), None)

    if existing is not None:
        if re.search(r" - \d{4}-\d{2}-\d{2}\s*$", lines[existing]):
            raise PrepError(f"CHANGELOG.md already has a dated section for {version}: was it released?")
        del lines[unrel + 1:body_end]          # [Unreleased] keeps its heading, loses its entries
        lines.insert(unrel + 1, "")
        existing = next(i for i, l in enumerate(lines) if l.startswith(f"## [{version}]"))
        fold_into(lines, existing, entries)
        if entries:
            names = ", ".join(sorted({n for n, _ in entries}))
            warnings.append(
                f"[{version}] already existed, undated: the [Unreleased] entries were appended to it ({names}). "
                "Curate that section in the release PR: it becomes the GitHub Release notes and the website's changelog.")
    else:
        if not entries:
            raise PrepError("[Unreleased] is empty: nothing to release (were the fragments collected?)")
        lines[unrel:unrel + 1] = ["## [Unreleased]", "", f"## [{version}] - {DATE_TODO}"]

    # Compare links: [Unreleased] compares from the new tag; the version compares from the previous one.
    ul = next((i for i, l in enumerate(lines) if l.startswith("[Unreleased]: ")), None)
    prev = None
    if ul is not None:
        m = re.search(r"/compare/(v[^.\s][^\s]*?)\.\.\.HEAD\s*$", lines[ul])
        prev = m.group(1) if m else None
        lines[ul] = f"[Unreleased]: {REPO_URL}/compare/v{version}...HEAD"
    if not any(l.startswith(f"[{version}]: ") for l in lines):
        url = f"{REPO_URL}/compare/{prev}...v{version}" if prev and prev != f"v{version}" else f"{REPO_URL}/releases/tag/v{version}"
        if ul is not None:
            lines.insert(ul + 1, f"[{version}]: {url}")
        else:
            while lines and not lines[-1].strip():
                lines.pop()
            lines += ["", f"[Unreleased]: {REPO_URL}/compare/v{version}...HEAD", f"[{version}]: {url}", ""]
    return "\n".join(lines)


def replace_once(path, text, pattern, repl, what, minimum=1, maximum=1):
    new, n = re.subn(pattern, repl, text, flags=re.M)
    if not minimum <= n <= maximum:
        raise PrepError(f"{path}: expected {what} {'once' if maximum == 1 else 'at least once'}, found {n}")
    return new


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version")
    ap.add_argument("--no-app", action="store_true", help="leave the app's MARKETING_VERSION alone")
    ap.add_argument("--dry-run", action="store_true", help="print what would change, write nothing")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    a = ap.parse_args()

    version = a.version[1:] if a.version.startswith("v") else a.version
    m = VERSION_RE.match(version)
    if not m:
        print(f"error: '{a.version}' is not X.Y.Z or X.Y.Z-prerelease", file=sys.stderr)
        return 2
    marketing = m.group(1)
    root = Path(a.root)
    changelog = root / "CHANGELOG.md"
    version_swift = root / "Sources/SempereCLI/Version.swift"
    cli_test = root / "Tests/CLITests/CLICommandTests.swift"
    pbxproj = root / "Apps/Sempere/Sempere.xcodeproj/project.pbxproj"
    collector = Path(__file__).resolve().parent / "changelog-collect.py"

    try:
        # Before anything is written: never lower the app's version.
        if not a.no_app:
            project = pbxproj.read_text(encoding="utf-8")
            current = set(re.findall(r"MARKETING_VERSION = ([^;]+);", project))
            key = lambda v: tuple(int(x) for x in re.findall(r"\d+", v)[:3])
            higher = [v for v in current if key(v) > key(marketing)]
            if higher:
                raise PrepError(f"the app's MARKETING_VERSION is {max(higher, key=key)}; {marketing} would lower it "
                                "(use a higher version, or --no-app for a CLI-only release)")

        # 1. Fragments. A dry run asks the collector for the folded text without deleting anything.
        cmd = [sys.executable, "-I", str(collector), "--dir", str(root / "changelog.d"), "--file", str(changelog)]
        frags = [p for p in (root / "changelog.d").glob("*.md") if p.name.lower() != "readme.md"]
        if a.dry_run and frags:
            r = subprocess.run(cmd + ["--dry-run"], capture_output=True, text=True)
            if r.returncode:
                raise PrepError(r.stderr.strip() or "changelog-collect.py failed")
            text = r.stdout
        else:
            if not a.dry_run:
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode:
                    raise PrepError(r.stderr.strip() or "changelog-collect.py failed")
                print(r.stdout.strip())
            text = changelog.read_text(encoding="utf-8")

        # 2. The version's section.
        warnings = []
        changes = {changelog: prepare_changelog(text, version, warnings)}

        # 3. The CLI version and its test.
        changes[version_swift] = replace_once(
            version_swift, version_swift.read_text(encoding="utf-8"),
            r'^(let sempereVersion = ")[^"]*(")', rf"\g<1>{version}\g<2>", "`let sempereVersion = \"…\"`")
        changes[cli_test] = replace_once(
            cli_test, cli_test.read_text(encoding="utf-8"),
            r'(\["--version"\].*"sempere )[^"]+(")', rf"\g<1>{version}\g<2>", "the --version assertion")

        # 4. The app's marketing version (every target and configuration; release-check.sh wants them equal).
        if not a.no_app:
            changes[pbxproj] = replace_once(
                pbxproj, project,
                r"(MARKETING_VERSION = )[^;]+(;)", rf"\g<1>{marketing}\g<2>", "MARKETING_VERSION",
                maximum=10**6)
    except (PrepError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    for path, new in changes.items():
        old = path.read_text(encoding="utf-8")
        if old == new:
            continue
        if a.dry_run:
            import difflib
            sys.stdout.writelines(difflib.unified_diff(
                old.splitlines(True), new.splitlines(True), str(path.relative_to(root)), str(path.relative_to(root))))
        else:
            path.write_text(new, encoding="utf-8")
            print(f"updated {path.relative_to(root)}")
    if a.dry_run:
        print("dry run: nothing written")
    else:
        app = "" if a.no_app else f"; app MARKETING_VERSION = {marketing}"
        print(f"prepared {version} (CLI version{app}).")
        print(f"Next, by hand: replace the TODO(user) in the [{version}] heading of CHANGELOG.md with the release")
        print("date (YYYY-MM-DD), review the section, then commit and open the release PR (docs/releasing.md).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
