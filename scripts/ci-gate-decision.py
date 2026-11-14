#!/usr/bin/env python3
"""Should the PR gate's suite jobs run? (docs/ci.md "Skipping the suites", docs/design/ci-lean.md)

    scripts/ci-gate-decision.py --base SHA [--event NAME]      decide for the checked-out HEAD against SHA
    scripts/ci-gate-decision.py --self-test

Prints `run=true|false`, `reason=...` and `tree=<tree id of HEAD>` (GITHUB_OUTPUT format, also to stdout). The suites are
skipped (their steps do not run, their required jobs still conclude success) in two cases only:
  1. every file changed since BASE is release-neutral (scripts/release-neutral.regex, the one definition that
     scripts/release-sweep-check.sh uses too) and also not a file the tests read or the gate itself: nothing under
     .github/ (a change to the workflow or its actions must run the workflow), and nothing in an `extra_inputs` entry of
     scripts/ci-targets.json (docs/format.md and the like are test inputs). `Help and portability checks` is never
     skipped by this script's caller: it is a minute, and it holds the secret scan of the docs and the tests of the
     release scripts.
  2. an artifact `ci-tree-<tree id>` exists, uploaded by a full, green run of this workflow in this repository for a
     commit with exactly this tree (needs GH_TOKEN and GITHUB_REPOSITORY; `--no-lookup` turns it off).
Anything else, any error, a missing BASE, a manual run: run=true.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def neutral_regex(root: Path = ROOT) -> re.Pattern[str]:
    return re.compile((root / "scripts/release-neutral.regex").read_text().strip())


def extra_inputs(root: Path = ROOT) -> list[str]:
    data = json.loads((root / "scripts/ci-targets.json").read_text())
    return sorted({p.rstrip("/") for paths in data.get("extra_inputs", {}).values() for p in paths})


def testable(path: str, neutral: re.Pattern[str], inputs: list[str]) -> bool:
    """True when the file can change what a suite job does."""
    if not neutral.match(path):
        return True
    if path.startswith(".github/"):
        return True
    return any(path == e or path.startswith(e + "/") for e in inputs)


def by_files(changed: list[str], root: Path = ROOT) -> tuple[bool, str]:
    neutral, inputs = neutral_regex(root), extra_inputs(root)
    hot = [p for p in changed if testable(p, neutral, inputs)]
    if hot:
        return True, "changes testable files: " + " ".join(hot[:8]) + (" ..." if len(hot) > 8 else "")
    return False, f"only release-neutral files changed ({len(changed)})"


def tree_passed(tree: str) -> str | None:
    """The run that passed this tree, from the artifact `ci-tree-<tree>` of a run of this repository, or None."""
    repo, token = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GH_TOKEN")
    if not repo or not token or not re.fullmatch(r"[0-9a-f]{40,64}", tree):
        return None
    try:
        repo_id = subprocess.run(["gh", "api", f"repos/{repo}", "--jq", ".id"], check=True, capture_output=True, text=True).stdout.strip()
        out = subprocess.run(["gh", "api", f"repos/{repo}/actions/artifacts?name=ci-tree-{tree}&per_page=20",
                              "--jq", ".artifacts[] | select(.expired == false) | [.workflow_run.head_repository_id, .workflow_run.id] | @tsv"],
                             check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    for line in out.splitlines():
        head_repo, run = line.split("\t")
        if head_repo == repo_id:   # never a fork's run: its workflow file is its own
            return run
    return None


def decide(base: str | None, event: str, lookup: bool = True, root: Path = ROOT) -> tuple[bool, str, str]:
    tree = git("rev-parse", "HEAD^{tree}", cwd=root).strip()
    if event == "workflow_dispatch":
        return True, "manual run", tree
    if lookup:
        run = tree_passed(tree)
        if run:
            return False, f"this exact tree ({tree[:12]}) passed a full run: {run}", tree
    if not base or re.fullmatch(r"0+", base):
        return True, "no base commit to compare with", tree
    try:
        changed = [p for p in git("diff", "--name-only", base, "HEAD", cwd=root).split("\n") if p]
    except subprocess.CalledProcessError:
        return True, "the base commit is not available", tree
    run, why = by_files(changed, root)
    return run, why, tree


def self_test() -> None:
    n, inp = neutral_regex(), extra_inputs()
    cases = {
        "CHANGELOG.md": False, "docs/audits/2026-11/report.md": False, "changelog.d/x.md": False, "README.md": False,
        "scripts/release-build.sh": False, "scripts/test-release-flow.sh": False, "packaging/homebrew/sempere.rb": False,
        "Sources/Sempere/Vault.swift": True, "Package.swift": True, "Apps/Sempere/SempereApp/X.swift": True,
        "scripts/ci-linux.sh": True, "scripts/ci-hash.py": True, "web/src/a.ts": True, "fonts/a.ttf": True,
        ".github/workflows/ci.yml": True, ".github/actions/select-xcode/action.yml": True,
        "docs/format.md": True, "docs/security.md": True, "docs/design/key-hierarchy.md": True, "SECURITY.md": True,
        "docs/settings.schema.json": True, "Tests/SempereTests/Fixtures/a": True,
    }
    bad = [(p, want) for p, want in cases.items() if testable(p, n, inp) != want]
    for p, want in bad:
        print(f"self-test: {p}: expected testable={want}", file=sys.stderr)
    if bad:
        sys.exit(1)
    assert by_files(["CHANGELOG.md", "docs/audits/a.md"])[0] is False
    assert by_files(["CHANGELOG.md", "Sources/x.swift"])[0] is True
    assert by_files([])[0] is False
    # git: a real repository, HEAD against a base.
    with tempfile.TemporaryDirectory() as d:
        w = Path(d)
        env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}

        def g(*a: str) -> str:
            return subprocess.run(["git", *a], cwd=w, check=True, capture_output=True, text=True, env=env).stdout.strip()
        g("init", "-q", "-b", "main")
        (w / "scripts").mkdir()
        for f in ("release-neutral.regex", "ci-targets.json"):
            (w / "scripts" / f).write_text((ROOT / "scripts" / f).read_text())
        (w / "CHANGELOG.md").write_text("a\n")
        (w / "Sources").mkdir()
        (w / "Sources/a.swift").write_text("a\n")
        g("add", "-A")
        g("-c", "commit.gpgsign=false", "commit", "-q", "-m", "base")
        base = g("rev-parse", "HEAD")
        (w / "CHANGELOG.md").write_text("b\n")
        g("add", "-A")
        g("-c", "commit.gpgsign=false", "commit", "-q", "-m", "docs")
        assert decide(base, "pull_request", lookup=False, root=w)[0] is False
        assert decide(None, "pull_request", lookup=False, root=w)[0] is True
        assert decide("0" * 40, "push", lookup=False, root=w)[0] is True
        assert decide(base, "workflow_dispatch", lookup=False, root=w)[0] is True
        assert decide("1" * 40, "pull_request", lookup=False, root=w)[0] is True
        (w / "Sources/a.swift").write_text("b\n")
        g("add", "-A")
        g("-c", "commit.gpgsign=false", "commit", "-q", "-m", "code")
        assert decide(base, "pull_request", lookup=False, root=w)[0] is True
    print("self-test: ci-gate-decision ok")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base")
    ap.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME", "pull_request"))
    ap.add_argument("--no-lookup", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return
    try:
        run, why, tree = decide(a.base, a.event, lookup=not a.no_lookup)
    except Exception as e:   # any doubt runs the suites
        run, why, tree = True, f"decision failed ({e})", ""
    lines = [f"run={'true' if run else 'false'}", f"reason={why}", f"tree={tree}"]
    print("\n".join(lines))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
