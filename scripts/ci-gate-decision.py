#!/usr/bin/env python3
"""Should the PR gate's suite jobs run? (docs/ci.md "Skipping the suites", docs/design/ci-lean.md)

    scripts/ci-gate-decision.py --base SHA [--event NAME]      decide for the checked-out HEAD against SHA
    scripts/ci-gate-decision.py --self-test

Prints `run=true|false`, `reason=...` and `tree=<tree id of HEAD>` (GITHUB_OUTPUT format, also to stdout). The suites are
skipped (their steps do not run, their required jobs still conclude success) in two cases only:
  1. every file changed since BASE (renames listed with both paths) is release-neutral (scripts/release-neutral.regex, the one
     definition that scripts/release-sweep-check.sh uses too) and also not a file the tests read, the gate itself or the app
     bundles: nothing under .github/ (a change to the workflow or its actions must run the workflow), nothing in an
     `extra_inputs` entry of scripts/ci-targets.json (docs/format.md and the like are test inputs), nothing matching
     scripts/release-bundled.regex or referenced by the Xcode project (docs/appstore/privacy-policy.md ships in the app). `Help and portability checks` is never
     skipped by this script's caller: it is a minute, and it holds the secret scan of the docs and the tests of the
     release scripts.
  2. an artifact `ci-tree-<tree id>` exists AND the run that uploaded it, fetched from the API (the name and the contents of the
     artifact are never trusted), is a completed, successful push to refs/heads/main of this repository, of the workflow file
     .github/workflows/ci.yml, whose head commit's tree is exactly this tree (needs GH_TOKEN and GITHUB_REPOSITORY;
     `--no-lookup` turns it off). Such a run executed main's reviewed workflow on that tree.
Anything else, any error, a missing BASE, a manual run: run=true.
"""
from __future__ import annotations

import argparse
import json
import os
import posixpath
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


def bundled_regex(root: Path = ROOT) -> re.Pattern[str]:
    return re.compile((root / "scripts/release-bundled.regex").read_text().strip())


def project_paths(root: Path = ROOT) -> set[str]:
    """Repository paths the Xcode project(s) reference from outside the app's own folder (`path = ../../docs/...;`)."""
    found: set[str] = set()
    for pbx in root.glob("Apps/**/project.pbxproj"):
        base = posixpath.dirname(posixpath.dirname(pbx.relative_to(root).as_posix()))   # Apps/Sempere
        for m in re.finditer(r'path = "?((?:\.\./)+[^;"]+)"?;', pbx.read_text(errors="replace")):
            found.add(posixpath.normpath(posixpath.join(base, m.group(1))))
    return found


def testable(path: str, neutral: re.Pattern[str], inputs: list[str], bundled: re.Pattern[str] | None = None,
             project: frozenset[str] | set[str] = frozenset()) -> bool:
    """True when the file can change what a suite job does."""
    if not neutral.match(path):
        return True
    if path.startswith(".github/") or (bundled is not None and bundled.match(path)):
        return True
    if any(path == r or path.startswith(r + "/") for r in project):
        return True
    return any(path == e or path.startswith(e + "/") for e in inputs)


def by_files(changed: list[str], root: Path = ROOT) -> tuple[bool, str]:
    neutral, inputs, bundled, project = neutral_regex(root), extra_inputs(root), bundled_regex(root), project_paths(root)
    hot = [p for p in changed if testable(p, neutral, inputs, bundled, project)]
    if hot:
        return True, "changes testable files: " + " ".join(hot[:8]) + (" ..." if len(hot) > 8 else "")
    return False, f"only release-neutral files changed ({len(changed)})"


def gh_api(path: str) -> dict:
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def tree_passed(tree: str, api=gh_api) -> str | None:
    """The id of a run that passed this tree, or None. `api(path)` returns the parsed JSON of a GitHub API path.

    The artifact `ci-tree-<tree>` is only a pointer to a run. Everything that is trusted comes from the API's own record of that
    run: it is a completed, successful push to main of this repository's .github/workflows/ci.yml (so the workflow that ran was
    main's reviewed one, never a pull request's own copy), and its head commit's tree is the tree asked for.
    """
    repo, token = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GH_TOKEN")
    if not repo or not token or not re.fullmatch(r"[0-9a-f]{40,64}", tree):
        return None
    try:
        repo_id = api(f"repos/{repo}")["id"]
        for art in api(f"repos/{repo}/actions/artifacts?name=ci-tree-{tree}&per_page=20")["artifacts"]:
            if art.get("expired") or art.get("name") != f"ci-tree-{tree}":
                continue
            run_id = art["workflow_run"]["id"]
            run = api(f"repos/{repo}/actions/runs/{run_id}")
            ok = (run.get("id") == run_id and str(run.get("path", "")).split("@")[0] == ".github/workflows/ci.yml"
                  and run.get("event") == "push" and run.get("head_branch") == "main"
                  and run.get("status") == "completed" and run.get("conclusion") == "success"
                  and run.get("repository", {}).get("id") == repo_id
                  and run.get("head_repository", {}).get("id") == repo_id
                  and run.get("head_commit", {}).get("tree_id") == tree)
            if ok:
                return str(run_id)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError, AttributeError):
        return None
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
        changed = [p for p in git("diff", "--no-renames", "--name-only", base, "HEAD", cwd=root).split("\n") if p]
    except subprocess.CalledProcessError:
        return True, "the base commit is not available", tree
    run, why = by_files(changed, root)
    return run, why, tree


def self_test() -> None:
    n, inp, bnd, proj = neutral_regex(), extra_inputs(), bundled_regex(), project_paths()
    cases = {
        "CHANGELOG.md": False, "docs/audits/2026-11/report.md": False, "changelog.d/x.md": False, "README.md": False,
        "scripts/release-build.sh": False, "scripts/test-release-flow.sh": False, "packaging/homebrew/sempere.rb": False,
        "Sources/Sempere/Vault.swift": True, "Package.swift": True, "Apps/Sempere/SempereApp/X.swift": True,
        "scripts/ci-linux.sh": True, "scripts/ci-hash.py": True, "web/src/a.ts": True, "fonts/a.ttf": True,
        ".github/workflows/ci.yml": True, ".github/actions/select-xcode/action.yml": True,
        "docs/format.md": True, "docs/security.md": True, "docs/design/key-hierarchy.md": True, "SECURITY.md": True,
        "docs/settings.schema.json": True, "Tests/SempereTests/Fixtures/a": True,
        "docs/appstore/privacy-policy.md": True, "docs/appstore/screenshots.md": False, "LICENSE": True,
    }
    bad = [(p, want) for p, want in cases.items() if testable(p, n, inp, bnd, proj) != want]
    for p, want in bad:
        print(f"self-test: {p}: expected testable={want}", file=sys.stderr)
    if bad:
        sys.exit(1)
    # Everything the Xcode project bundles from outside Apps/ that the neutral list would let through must be in the bundled list.
    assert "docs/appstore/privacy-policy.md" in proj, proj
    leaks = sorted(p for p in proj if n.match(p) and not bnd.match(p))
    assert not leaks, f"bundled by the Xcode project but release-neutral (add to scripts/release-bundled.regex): {leaks}"
    assert by_files(["CHANGELOG.md", "docs/audits/a.md"])[0] is False
    assert by_files(["CHANGELOG.md", "Sources/x.swift"])[0] is True
    assert by_files([])[0] is False
    stub_tests()
    # git: a real repository, HEAD against a base.
    with tempfile.TemporaryDirectory() as d:
        w = Path(d)
        env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}

        def g(*a: str) -> str:
            return subprocess.run(["git", *a], cwd=w, check=True, capture_output=True, text=True, env=env).stdout.strip()
        g("init", "-q", "-b", "main")
        (w / "scripts").mkdir()
        for f in ("release-neutral.regex", "release-bundled.regex", "ci-targets.json"):
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
        # A file moved out of Sources/ into docs/: both paths are listed, so it is testable (a rename-detecting diff shows only docs/a.swift).
        g("mv", "Sources/a.swift", "docs-a.swift")
        (w / "docs").mkdir()
        g("mv", "docs-a.swift", "docs/a.swift")
        g("-c", "commit.gpgsign=false", "commit", "-q", "-m", "move")
        assert decide(base, "pull_request", lookup=False, root=w)[0] is True
        assert "Sources/a.swift" in decide(base, "pull_request", lookup=False, root=w)[1]
        # the bundled privacy policy
        g("reset", "-q", "--hard", base)
        (w / "docs/appstore").mkdir(parents=True)
        (w / "docs/appstore/privacy-policy.md").write_text("x\n")
        g("add", "-A")
        g("-c", "commit.gpgsign=false", "commit", "-q", "-m", "policy")
        assert decide(base, "pull_request", lookup=False, root=w)[0] is True
    print("self-test: ci-gate-decision ok")


def stub_tests() -> None:
    """tree_passed with a stubbed API: only a successful push to main of ci.yml in this repo, for exactly this tree, counts."""
    tree = "a" * 40
    os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"] = "o/r", "x"
    good = {"id": 7, "path": ".github/workflows/ci.yml", "event": "push", "head_branch": "main", "status": "completed",
            "conclusion": "success", "repository": {"id": 1}, "head_repository": {"id": 1}, "head_commit": {"tree_id": tree}}

    def api_for(run: dict, artifact: dict | None = None):
        art = {"name": f"ci-tree-{tree}", "expired": False, "workflow_run": {"id": 7}}
        art.update(artifact or {})

        def api(path: str) -> dict:
            if path == "repos/o/r":
                return {"id": 1}
            if path.startswith("repos/o/r/actions/artifacts"):
                return {"artifacts": [art]}
            if path == "repos/o/r/actions/runs/7":
                return run
            raise AssertionError(path)
        return api

    assert tree_passed(tree, api_for(good)) == "7"
    for what, change in {
        "another tree": {"head_commit": {"tree_id": "b" * 40}}, "a pull request run": {"event": "pull_request"},
        "another branch": {"head_branch": "topic"}, "another workflow file": {"path": ".github/workflows/other.yml"},
        "a failed run": {"conclusion": "failure"}, "a run in progress": {"status": "in_progress", "conclusion": None},
        "a fork": {"head_repository": {"id": 2}}, "another repository": {"repository": {"id": 2}},
        "no head commit": {"head_commit": None}, "a run with another id": {"id": 8},
    }.items():
        assert tree_passed(tree, api_for({**good, **change})) is None, what
    assert tree_passed(tree, api_for(good, {"expired": True})) is None, "an expired artifact"
    assert tree_passed(tree, api_for(good, {"name": "ci-tree-" + "b" * 40})) is None, "a mislabeled artifact"
    assert tree_passed("zz", api_for(good)) is None

    def broken(path: str) -> dict:
        raise OSError("no network")
    assert tree_passed(tree, broken) is None


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
