#!/usr/bin/env python3
"""Hashes of the package's test targets, and the record of which hashes passed (docs/design/ci-lean.md).

    scripts/ci-hash.py hash --job JOB [TARGET ...]          print `target<TAB>hash` per test target (all when none named)
    scripts/ci-hash.py plan --job JOB --out PLAN [TARGET ...]   decide, per target, to run or to skip (see below)
    scripts/ci-hash.py record --plan PLAN                    record the targets the plan ran as passed (after checks)
    scripts/ci-hash.py check-reads                           fail for a test read the hashes do not cover
    scripts/ci-hash.py skips PLAN                            the names of the targets to skip, one per line
    scripts/ci-hash.py runs PLAN                             the names of the targets to run, one per line
    scripts/ci-hash.py --self-test

A target's hash covers everything its result can be shown to depend on:
  - every file (path and content, symlinks followed and their link text included) of the WHOLE folder of the target and of
    every target in its dependency closure, `exclude` or not (tests read what Package.swift excludes), from
    `swift package dump-package` (or `--package-json FILE`), and of the manifest's `implicit_dependencies` (targets whose
    products the tests run without linking: the CLI tests run the built `sempere`);
  - the manifest's `extra_inputs` for the target: files and folders the tests read from outside their own folders (docs,
    the app's sources, other targets' fixtures, web/ fixtures). `check-reads` finds such reads in Tests/**/*.swift and fails
    for one that is not declared (scripts/test-ci-hash-guard.sh tests the guard against the known reads);
  - Package.swift, Package.resolved, scripts/ci-targets.json, the files the job runs the tests with (JOB_FILES, checked
    against the scripts they invoke by the self-test), the job's name;
  - the toolchain: `swift --version`, OS, kernel release and architecture; macOS build and SDK version; on Linux
    /etc/os-release and the Docker image id ($SEMPERE_CI_IMAGE_ID, set by `ci-linux.sh docker`; the image's id, so a
    moved tag changes the hashes); `--toolchain TEXT` overrides.
Not covered, and bounded by the forced runs (SEMPERE_CI_FORCE_ALL=1: --testflight, --release, and --cli;
there is no scheduled or post-merge full run): tools installed from apt on Linux, the clock, the network, and reads the guard cannot see (a path built at run
time from data). Benchmark targets (`...Benchmarks`) are never planned: they gate nothing.

`plan` prints one line per target on stderr and writes PLAN (tab-separated: run|skip, target, hash, job, commit, why). A target is
skipped only when the store holds a record for exactly that hash under that job: the record names the commit whose run
passed it, and the skip line says so. SEMPERE_CI_FORCE_ALL=1 (or --force) runs everything, and still records.
`record` is called only after the whole test run passed. It recomputes the commit and every hash first and writes, for every
`run` line of PLAN, a file STORE/JOB/TARGET/HASH (JSON: commit, date, host) only if the tree is a clean commit equal to the
planned one, no hash moved during the run, and no SEMPERE_* variable outside ENV_ALLOWED is set (those switch tests on,
off or into another mode: SEMPERE_UPDATE_FIXTURES, SEMPERE_REGENERATE_*, SEMPERE_FUZZ_*, SEMPERE_REQUIRE_* ...); else it
says why and records nothing. STORE is `--store`, else $SEMPERE_CI_PASS_DIR, else ~/.cache/sempere-ci-pass.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import platform
import posixpath
import re
import subprocess
import sys
import tempfile
import zoneinfo
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORMAT = "ci-hash/1"

# The files each job runs its tests with: a change to any of them changes every hash of the job.
COMMON = ["Package.swift", "Package.resolved", "scripts/ci-hash.py", "scripts/ci-targets.json"]
JOB_FILES = {
    "linux-test": COMMON + ["scripts/ci-linux.sh", "scripts/test-offline.sh"],
    "linux-webdav": COMMON + ["scripts/ci-linux.sh", "scripts/test-webdav.sh", "scripts/dav-fault-proxy.py",
                              "scripts/webdav-server-requirements.txt"],
    "mac-package": COMMON + ["scripts/ci-mac-package.sh", "scripts/test-runner.py"],
    # check-removable-importers.sh: build every target without the Notability module, run CLITests. Planned for the one target
    # CLITests (its closure and the built CLI); check-importer-isolation.sh, which the first script runs, is the other input.
    # ci-linux.sh always runs the isolation check itself, even when this job is skipped (it greps every .swift file).
    "linux-removable": COMMON + ["scripts/check-removable-importers.sh", "scripts/check-importer-isolation.sh"],
}
IGNORED_NAMES = {".DS_Store"}

# A passing run is recorded only when no SEMPERE_* variable outside this list is set: the others switch tests on, off or
# into a different mode (SEMPERE_UPDATE_FIXTURES, SEMPERE_REGENERATE_*, SEMPERE_WRITE_*_VECTORS, SEMPERE_FUZZ_*,
# SEMPERE_NOTABILITY_SAMPLES, SEMPERE_REQUIRE_* ...), so the result is not the one the hash names.
ENV_ALLOWED = {
    "SEMPERE_BUILD_JOBS", "SEMPERE_CI_PASS_DIR", "SEMPERE_CI_FORCE_ALL", "SEMPERE_CI_MAC_PACKAGE", "SEMPERE_CI_IMAGE_ID",
    "SEMPERE_LOCAL_CI_CAFFEINATED", "SEMPERE_CI_LINUX_LANE", "SEMPERE_CI_RUN_ID", "SEMPERE_CI_HOST", "SEMPERE_LINUX_BUILD_VOLUME", "SEMPERE_LINUX_IMAGE", "SEMPERE_FAIL_FAST",
    "SEMPERE_RERUNS", "SEMPERE_RERUN_LIMIT", "SEMPERE_STALL_SECS", "SEMPERE_TMP_GUARD_FAIL", "SEMPERE_FORGE_TOKEN",
    "SEMPERE_FORGE_REPO", "SEMPERE_FORGE_URL", "SEMPERE_RUN_TMP",
}


def unsafe_env() -> list[str]:
    return sorted(k for k in os.environ if k.startswith("SEMPERE_") and k not in ENV_ALLOWED)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_package(path: str | None) -> dict:
    if path:
        return json.loads(Path(path).read_text())
    out = subprocess.run(["swift", "package", "dump-package"], cwd=ROOT, check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def toolchain_id() -> str:
    try:
        version = subprocess.run(["swift", "--version"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        version = "no swift"
    parts = [version, platform.system(), platform.release(), platform.machine()]
    if platform.system() == "Darwin":
        for cmd in (["sw_vers", "-productBuildVersion"], ["xcrun", "--show-sdk-version"]):
            try:
                parts.append(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip())
            except (OSError, subprocess.CalledProcessError):
                parts.append("?")
    else:
        try:
            parts.append(Path("/etc/os-release").read_text())
        except OSError:
            parts.append("no os-release")
        parts.append(os.environ.get("SEMPERE_CI_IMAGE_ID", "no image id"))   # ci-linux.sh docker: the image the run used
    return "|".join(parts)


def target_dir(root: Path, t: dict) -> Path:
    if t.get("path"):
        return root / t["path"]
    base = "Tests" if t.get("type") == "test" else "Sources"
    return root / base / t["name"]


def dep_names(t: dict) -> list[str]:
    names = []
    for d in t.get("dependencies", []):
        if "target" in d:
            names.append(d["target"][0])
        elif "byName" in d:
            names.append(d["byName"][0])   # a product name resolves to a package product: not ours, see below
    return names


def closure(targets: dict[str, dict], name: str) -> list[str]:
    seen: list[str] = []
    todo = [name]
    while todo:
        n = todo.pop()
        if n in seen or n not in targets:
            continue
        seen.append(n)
        todo.extend(dep_names(targets[n]))
    return sorted(seen)


def tree_entries(root: Path, base: Path) -> list[tuple[str, str]]:
    """(relative path, digest) for every file under base, following symlinks (the benchmarks' shared helpers are links);
    a link also contributes where it points, so retargeting one changes the hash."""
    entries: list[tuple[str, str]] = []
    if base.is_file():
        files = [base]
    else:
        files = []
        for dirpath, dirnames, filenames in os.walk(base, followlinks=True):
            dirnames.sort()
            for f in sorted(filenames):
                files.append(Path(dirpath) / f)
    for f in files:
        rel = f.relative_to(root).as_posix()
        if f.name in IGNORED_NAMES:
            continue
        try:
            digest = sha(f.read_bytes())
        except OSError as e:
            digest = f"unreadable:{e.errno}"
        link = f"->{os.readlink(f)}" if f.is_symlink() else ""
        entries.append((rel, digest + link))
    return entries


def manifest_extras(manifest: dict, name: str) -> list[str]:
    return manifest.get("extra_inputs", {}).get(name, [])


def target_hash(root: Path, pkg: dict, manifest: dict, job: str, toolchain: str, name: str) -> str:
    targets = {t["name"]: t for t in pkg["targets"]}
    h = hashlib.sha256()

    def add(label: str, value: str) -> None:
        h.update(f"{label}\0{value}\0".encode())

    add("format", FORMAT)
    add("job", job)
    add("target", name)
    add("toolchain", toolchain)
    for rel in JOB_FILES.get(job, COMMON):
        p = root / rel
        add("file:" + rel, sha(p.read_bytes()) if p.is_file() else "absent")
    names = set(closure(targets, name))
    for implicit in manifest.get("implicit_dependencies", {}).get(name, []):
        names.update(closure(targets, implicit))
    for n in sorted(names):
        t = targets[n]
        base = target_dir(root, t)
        add("target-dir", n)
        for rel, digest in tree_entries(root, base) if base.exists() else []:   # the whole folder: tests read what Package.swift excludes
            add(rel, digest)
    for extra in manifest_extras(manifest, name):
        for rel, digest in tree_entries(root, root / extra) if (root / extra).exists() else [(extra, "absent")]:
            add("extra:" + rel, digest)
    return h.hexdigest()


def plannable(pkg: dict, named: list[str]) -> list[str]:
    tests = sorted(t["name"] for t in pkg["targets"] if t.get("type") == "test" and not t["name"].endswith("Benchmarks"))
    for n in named:
        if n not in tests:
            sys.exit(f"ci-hash: no test target named {n} (benchmark targets are never planned)")
    return named or tests


def store_dir(arg: str | None) -> Path:
    return Path(arg or os.environ.get("SEMPERE_CI_PASS_DIR") or Path.home() / ".cache" / "sempere-ci-pass")


def load_manifest(root: Path) -> dict:
    p = root / "scripts" / "ci-targets.json"
    return json.loads(p.read_text()) if p.is_file() else {}


def cmd_hash(a: argparse.Namespace) -> int:
    pkg = load_package(a.package_json)
    manifest = load_manifest(ROOT)
    tc = a.toolchain if a.toolchain is not None else toolchain_id()
    for n in plannable(pkg, a.targets):
        print(f"{n}\t{target_hash(ROOT, pkg, manifest, a.job, tc, n)}")
    return 0


def record_path(store: Path, job: str, target: str, h: str) -> Path:
    return store / job / target / h


def cmd_plan(a: argparse.Namespace) -> int:
    pkg = load_package(a.package_json)
    manifest = load_manifest(ROOT)
    tc = a.toolchain if a.toolchain is not None else toolchain_id()
    store = store_dir(a.store)
    force = a.force or os.environ.get("SEMPERE_CI_FORCE_ALL") == "1"
    lines = []
    for n in plannable(pkg, a.targets):
        h = target_hash(ROOT, pkg, manifest, a.job, tc, n)
        rec = record_path(store, a.job, n, h)
        if a.os_dependent_only and n in manifest.get("logic", []) and not force:
            lines.append(("skip", n, h, f"logic target, left to the Linux job (SEMPERE_CI_MAC_PACKAGE=all runs it here); nothing recorded"))
            continue
        if force:
            lines.append(("run", n, h, "forced (SEMPERE_CI_FORCE_ALL=1)"))
        elif rec.is_file():
            try:
                info = json.loads(rec.read_text())
                why = f"hash {h[:12]} passed at {info['commit']} ({info['date']}, {info.get('host', '?')})"
            except (ValueError, KeyError):
                lines.append(("run", n, h, f"hash {h[:12]}: unreadable record {rec}, run"))
                continue
            lines.append(("skip", n, h, why))
        else:
            lines.append(("run", n, h, f"hash {h[:12]} has no passing record"))
    commit = current_commit()   # what the run is about to test: taken now, not after the run
    Path(a.out).write_text("".join("\t".join((state, n, h, a.job, commit, why)) + "\n" for state, n, h, why in lines))
    for state, n, h, why in lines:
        print(f"ci-hash: {state.upper():4} {n:28} {why}", file=sys.stderr)
    return 0


def read_plan(path: str) -> list[list[str]]:
    return [line.rstrip("\n").split("\t") for line in Path(path).read_text().splitlines() if line.strip()]


def hashes_now(a: argparse.Namespace, job: str, targets: list[str]) -> dict[str, str]:
    pkg = load_package(a.package_json)
    manifest = load_manifest(ROOT)
    tc = a.toolchain if a.toolchain is not None else toolchain_id()
    return {n: target_hash(ROOT, pkg, manifest, job, tc, n) for n in targets}


def cmd_record(a: argparse.Namespace) -> int:
    """Records the `run` lines of the plan as passed, after checking the world is still the one the plan was made on:
    the same clean commit, the same hashes (recomputed now), and no behavior-changing SEMPERE_* variable."""
    store = store_dir(a.store)
    when = datetime.datetime.now(zoneinfo.ZoneInfo("America/New_York")).strftime("%Y-%m-%d %H:%M %Z")
    rows = [r for r in read_plan(a.plan) if r[0] == "run"]
    if not rows:
        return 0
    bad = unsafe_env()
    now_commit = current_commit()
    refusal = None
    if bad:
        refusal = f"these SEMPERE_* variables change what the tests do: {', '.join(bad)}"
    elif now_commit.endswith("+dirty") or now_commit == "unknown" or any(r[4].endswith("+dirty") or r[4] == "unknown" for r in rows):
        refusal = f"the tree is not a clean commit (planned {rows[0][4]}, now {now_commit}); a record must name the commit that passed"
    elif any(r[4] != now_commit for r in rows):
        refusal = f"the commit changed during the run (planned {rows[0][4]}, now {now_commit})"
    else:
        for job in sorted({r[3] for r in rows}):
            now = hashes_now(a, job, [r[1] for r in rows if r[3] == job])
            moved = [r[1] for r in rows if r[3] == job and now[r[1]] != r[2]]
            if moved:
                refusal = f"the inputs of {', '.join(moved)} changed during the run"
                break
    if refusal:
        print(f"ci-hash: not recording anything: {refusal}", file=sys.stderr)
        return 0
    for state, n, h, job, commit, _why in rows:
        p = record_path(store, job, n, h)
        p.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=".rec-")
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps({"commit": commit, "date": when, "host": os.environ.get("SEMPERE_CI_HOST") or platform.node(), "target": n}) + "\n")
        os.replace(tmp, p)
        print(f"ci-hash: recorded {n} {h[:12]} passed at {commit}", file=sys.stderr)
    return 0


_TEST_COMMIT: str | None = None   # the self-test's stand-in for git


def current_commit() -> str:
    if _TEST_COMMIT is not None:
        return _TEST_COMMIT
    def git(*args: str) -> str:
        return subprocess.run(["git", "-c", "safe.directory=*", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    sha_ = git("rev-parse", "HEAD") or "unknown"
    return sha_ + ("+dirty" if git("status", "--porcelain") else "")


# --- The cross-read guard -------------------------------------------------------------------------------------------
# A test that reads a file outside its own folder (a doc, another target's fixtures, the app's sources) makes that file
# an input of the target's result. Package.swift cannot say so, so the hash would miss it. `check-reads` finds the reads
# in Tests/**/*.swift and fails for every one that is not in the target's hash: the target's closure folders, the
# manifest's `extra_inputs`, or a file of JOB_FILES.
#   - #filePath chains: parent^N of the file, plus the literals appended in the chain; when the base leaves the file's own
#     test folder, every string literal of the file that names an existing path under the base counts as a read
#     (this is how `repo.appendingPathComponent("docs/format.md")` in a later line is found).
#   - literals that start with a top-level folder of the repo ("docs/", "Apps/", "Sources/", "web/", "scripts/", ...) or name
#     Package.swift, for a read relative to the working directory.
# It over-approximates: a literal that happens to name an existing path is a read. Declare it, or reword the literal.
TOP_LEVEL_FALLBACK = ("docs", "Apps", "Sources", "web", "scripts", "Tests", "Package.swift", "Package.resolved", "CHANGELOG.md",
                      "changelog.d", "SECURITY.md", "LICENSE", "LICENSE-EXCEPTION")
TOP_LEVEL_IGNORED = {"README.md"}   # tests use "README.md" as an export file name, not as a read of the repo's
_top_cache: dict[str, set[str]] = {}


def top_level(root: Path) -> set[str]:
    """The tracked entries of the repo root (git ls-files, first path component), so a new root file is covered by the
    scan without anyone editing a list; the fixed fallback when there is no git."""
    key = str(root)
    if key not in _top_cache:
        out = subprocess.run(["git", "-c", "safe.directory=*", "ls-files"], cwd=root, capture_output=True, text=True).stdout
        names = {line.split("/")[0] for line in out.splitlines() if line}
        _top_cache[key] = (names or set(TOP_LEVEL_FALLBACK)) - TOP_LEVEL_IGNORED
    return _top_cache[key]
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
FILEPATH = re.compile(r"#filePath")
PARENT = re.compile(r"\.deletingLastPathComponent\(\)|\.resolvingSymlinksInPath\(\)")
APPEND = re.compile(r'\.appendingPathComponent\("((?:[^"\\\n]|\\.)*)"')


def norm(base: str, lit: str) -> str:
    return posixpath.normpath(base + "/" + lit).lstrip("./") if posixpath.normpath(base + "/" + lit) != "." else ""


def literal_path(lit: str) -> str:
    return lit.split("\\(", 1)[0].rstrip("/")


def covered_dirs(root: Path, pkg: dict, manifest: dict, name: str, job_files: list[str]) -> list[str]:
    targets = {t["name"]: t for t in pkg["targets"]}
    names = set(closure(targets, name))
    for implicit in manifest.get("implicit_dependencies", {}).get(name, []):
        names.update(closure(targets, implicit))
    dirs = [target_dir(root, targets[n]).relative_to(root).as_posix() for n in names]
    return dirs + list(manifest_extras(manifest, name)) + list(job_files)


def under(path: str, folder: str) -> bool:
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def reads_of(root: Path, f: Path) -> list[tuple[int, str]]:
    """(line, repo-relative path) for every read of a path outside f's own test folder that f makes."""
    rel = f.relative_to(root)
    own = "/".join(rel.parts[:2])
    text = f.read_text(errors="replace")
    lines = text.splitlines()
    out: list[tuple[int, str]] = []
    literals = [(i + 1, literal_path(m.group(1))) for i, line in enumerate(lines) if not line.lstrip().startswith("//")
                for m in LITERAL.finditer(line)]
    escaping_bases: list[str] = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith("//"):
            continue
        for m in FILEPATH.finditer(line):
            if re.search(r"(StaticString|String)\s*=\s*#filePath|file:\s*#filePath|file: file", line):
                continue   # an assertion helper's default argument
            chunk = line[m.end():]
            if chunk.startswith(")"):   # URL(fileURLWithPath: #filePath)
                chunk = chunk[1:]
            k = i + 1
            while k < len(lines) and lines[k].lstrip().startswith(".") and k < i + 5:
                chunk += lines[k].strip()
                k += 1
            n = 0
            pos = 0
            for pm in PARENT.finditer(chunk):
                if pm.start() != pos:
                    break
                if pm.group(0).startswith(".deleting"):
                    n += 1
                pos = pm.end()
            base = Path(rel.as_posix())
            for _ in range(n):
                base = base.parent
            base_s = base.as_posix()
            if base_s == "." or not (under(base_s, own)):
                escaping_bases.append(base_s if base_s != "." else "")
            for am in APPEND.finditer(chunk[pos:]):
                # every chain, not only those whose base already left the folder: appended "../X" can leave it too
                cand = norm("" if base_s == "." else base_s, literal_path(am.group(1)))
                if cand and not under(cand, own):
                    out.append((i + 1, cand))
    for b in escaping_bases:
        for ln, lit in literals:
            if not lit or lit in (".", "..") or lit.startswith("/") or " " in lit:
                continue
            cand = norm(b, lit)
            if cand and (root / cand).exists():
                out.append((ln, cand))
    for ln, lit in literals:   # a literal with ../ resolved against the file's own folder
        if "../" in lit:
            cand = norm(rel.parent.as_posix(), lit)
            if "/" in cand and not under(cand, own) and (root / cand).exists():
                out.append((ln, cand))
    for ln, lit in literals:
        # a bare folder name ("Tests") is a label, not a read; a path into it, or a root file, is one
        if lit and lit.split("/")[0] in top_level(root) and (root / lit).exists() and not under(lit, own) \
                and ("/" in lit or (root / lit).is_file()):
            out.append((ln, lit))
    return sorted(set(out))


def scan_reads(root: Path, pkg: dict, manifest: dict, with_extras: bool = True) -> list[str]:
    """One message per read that is not in the hash of a test target that runs the file."""
    targets = {t["name"]: t for t in pkg["targets"]}
    problems: list[str] = []
    test_names = plannable(pkg, [])
    m = manifest if with_extras else {k: v for k, v in manifest.items() if k != "extra_inputs"}
    for name in test_names:
        cov = covered_dirs(root, pkg, m, name, COMMON)
        for n in closure(targets, name) + [x for i in manifest.get("implicit_dependencies", {}).get(name, []) for x in closure(targets, i)]:
            t = targets[n]
            d = target_dir(root, t)
            if not str(d.relative_to(root)).startswith("Tests") or not d.exists():
                continue
            for f in sorted(d.rglob("*.swift")):
                for ln, path in reads_of(root, f):
                    if path and not any(under(path, c) for c in cov):
                        problems.append(f"{f.relative_to(root).as_posix()}:{ln}: reads {path}, which is not in the hash of {name}")
    return sorted(set(problems))


def cmd_check_reads(a: argparse.Namespace) -> int:
    pkg = load_package(a.package_json)
    problems = scan_reads(ROOT, pkg, load_manifest(ROOT), not a.without_extras)
    for p in problems:
        print(f"ci-hash: {p}", file=sys.stderr if not a.without_extras else sys.stdout)
    if problems and not a.without_extras:
        print("ci-hash: declare each in scripts/ci-targets.json extra_inputs (docs/design/ci-lean.md)", file=sys.stderr)
        return 1
    print(f"ci-hash: check-reads: {len(problems)} reads outside the hash" + (" (extras ignored)" if a.without_extras else ""), file=sys.stderr)
    return 0


def self_test() -> int:
    # Hermetic: the test stores its records in a folder of its own, whatever store the caller's environment names.
    os.environ.pop("SEMPERE_CI_PASS_DIR", None)
    failures = []

    def check(name: str, ok: bool) -> None:
        print(("ok   " if ok else "FAIL ") + name)
        if not ok:
            failures.append(name)

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        for rel, text in {
            "Package.swift": "pkg", "Package.resolved": "pins", "scripts/ci-hash.py": "x", "scripts/ci-linux.sh": "x",
            "scripts/test-offline.sh": "x", 
            "Sources/A/a.swift": "a", "Sources/B/b.swift": "b", "Sources/C/c.swift": "c",
            "Tests/ATests/t.swift": "t", "Tests/ATests/Fixtures/f.txt": "fx", "Tests/BTests/t.swift": "t",
            "Tests/ABenchmarks/x.swift": "x", "docs/shared.txt": "s",
        }.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        (root / "Tests/BTests/link.swift").symlink_to("t.swift")
        pkg = {"targets": [
            {"name": "A", "type": "regular", "dependencies": [{"target": ["B", None]}, {"product": ["Crypto", "c", None, None]}]},
            {"name": "B", "type": "regular", "dependencies": []},
            {"name": "C", "type": "regular", "dependencies": []},
            {"name": "ATests", "type": "test", "dependencies": [{"byName": ["A", None]}]},
            {"name": "BTests", "type": "test", "dependencies": [{"byName": ["B", None]}]},
            {"name": "ABenchmarks", "type": "test", "dependencies": [{"byName": ["A", None]}]},
        ]}
        manifest: dict = {}

        def hashes(job: str = "linux-test", tc: str = "swift 6", m: dict | None = None) -> dict[str, str]:
            return {n: target_hash(root, pkg, manifest if m is None else m, job, tc, n) for n in plannable(pkg, [])}

        base = hashes()
        check("benchmark targets are not planned", sorted(base) == ["ATests", "BTests"])
        check("hashing is deterministic", hashes() == base)

        def changed(rel: str, text: str, **kw) -> dict[str, str]:
            p = root / rel
            old = p.read_text() if p.exists() else None
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
            try:
                return hashes(**kw)
            finally:
                if old is None:
                    p.unlink()
                else:
                    p.write_text(old)

        h = changed("Sources/B/b.swift", "b2")
        check("a dependency's source changes its dependents and no one else", h["ATests"] != base["ATests"] and h["BTests"] != base["BTests"])
        h = changed("Sources/A/a.swift", "a2")
        check("a source changes only the targets that depend on it", h["ATests"] != base["ATests"] and h["BTests"] == base["BTests"])
        h = changed("Sources/C/c.swift", "c2")
        check("an unrelated target changes nothing", h == base)
        h = changed("Tests/ATests/Fixtures/f.txt", "fx2")
        check("a fixture changes its test target", h["ATests"] != base["ATests"] and h["BTests"] == base["BTests"])
        check("a new file in a dependency changes the hash", changed("Sources/B/new.swift", "n")["BTests"] != base["BTests"])
        check("Package.swift changes every hash", all(changed("Package.swift", "pkg2")[n] != base[n] for n in base))
        check("Package.resolved changes every hash", all(changed("Package.resolved", "pins2")[n] != base[n] for n in base))
        check("the job's script changes every hash", all(changed("scripts/ci-linux.sh", "y")[n] != base[n] for n in base))
        check("the toolchain changes every hash", all(hashes(tc="swift 7")[n] != base[n] for n in base))
        pkg["targets"][3]["exclude"] = ["Fixtures"]   # B2: Package.swift excludes it, the tests still read it
        check("an excluded folder is still hashed", changed("Tests/ATests/Fixtures/f.txt", "fx9")["ATests"] != base["ATests"])
        del pkg["targets"][3]["exclude"]
        check("another job has other hashes", all(hashes(job="mac-package")[n] != base[n] for n in base))
        check("a docs file changes nothing", changed("docs/shared.txt", "s2") == base)
        m = {"extra_inputs": {"ATests": ["docs/shared.txt"]}}
        with_extra = hashes(m=m)
        check("an extra input is in the hash", with_extra["ATests"] != base["ATests"] and with_extra["BTests"] == base["BTests"])
        check("an extra input's change changes it", changed("docs/shared.txt", "s3", m=m)["ATests"] != with_extra["ATests"])
        (root / "Tests/BTests/link.swift").unlink()
        (root / "Tests/BTests/link.swift").symlink_to("t.swift ")  # dangling: retargeted
        check("a retargeted link changes the hash", hashes()["BTests"] != base["BTests"])

        # B3: every script a job's test scripts run is in the job's hash files
        real = Path(__file__).resolve().parent.parent
        for job, scripts in (("linux-test", ["scripts/test-offline.sh"]), ("linux-webdav", ["scripts/test-webdav.sh"]),
                             ("mac-package", ["scripts/test-runner.py"]), ("linux-removable", ["scripts/check-removable-importers.sh"])):
            missing = set()
            for sc in scripts:
                for line in (real / sc).read_text().splitlines():
                    if line.lstrip().startswith("#"):
                        continue
                    missing.update(t for t in re.findall(r"scripts/[A-Za-z0-9_.-]+", line) if t not in JOB_FILES[job] and t != sc)
            check(f"{job}: every script its test scripts run is in the hash ({', '.join(sorted(missing)) or 'none missing'})", not missing)
            check(f"{job}: its hash files exist", all((real / f).exists() for f in JOB_FILES[job]))

        # plan / record / skip
        (root / "Tests/BTests/link.swift").unlink()
        (root / "Tests/BTests/link.swift").symlink_to("t.swift")
        store = root / "store"
        plan = root / "plan.tsv"

        def run_plan(split: bool = False, **env: str) -> list[list[str]]:
            os.environ.pop("SEMPERE_CI_FORCE_ALL", None)
            os.environ.update(env)
            try:
                ns = argparse.Namespace(job="linux-test", out=str(plan), targets=[], store=str(store), force=False, os_dependent_only=split,
                                        package_json=str(root / "pkg.json"), toolchain="swift 6")
                with contextlib_redirect_stderr():
                    cmd_plan(ns)
            finally:
                os.environ.pop("SEMPERE_CI_FORCE_ALL", None)
            return read_plan(str(plan))

        (root / "pkg.json").write_text(json.dumps(pkg))
        global ROOT, _TEST_COMMIT
        saved_root, ROOT = ROOT, root
        _TEST_COMMIT = "abc123"

        def record(commit: str | None = None) -> str:
            """Runs `record`; returns what it said."""
            import contextlib
            import io
            global _TEST_COMMIT
            if commit:
                _TEST_COMMIT = commit
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                cmd_record(argparse.Namespace(plan=str(plan), store=str(store), package_json=str(root / "pkg.json"), toolchain="swift 6"))
            return buf.getvalue()

        try:
            p1 = run_plan()
            check("first plan runs everything", [l[0] for l in p1] == ["run", "run"])
            (root / "scripts/ci-targets.json").write_text(json.dumps({"logic": ["ATests"]}))
            split = run_plan(split=True)
            check("the platform split skips a logic target without a record, runs the rest",
                  [(l[1], l[0]) for l in split] == [("ATests", "skip"), ("BTests", "run")])
            (root / "scripts/ci-targets.json").unlink()
            run_plan()   # the plan file `record` reads
            # B4: a record is refused when the world moved since the plan, and says why
            def count() -> int:
                return sum(1 for _ in store.rglob("*") if _.is_file()) if store.exists() else 0
            run_plan()
            check("the commit moving during the run refuses the record", "commit changed" in record("zzz999") and count() == 0)
            _TEST_COMMIT = "abc123"
            run_plan()
            (root / "Sources/B/b.swift").write_text("b-edited-during-the-run")
            check("an input changing during the run refuses the record", "changed during the run" in record("abc123") and count() == 0)
            (root / "Sources/B/b.swift").write_text("b")
            run_plan()
            check("a dirty tree refuses the record", "not a clean commit" in record("abc123+dirty") and count() == 0)
            _TEST_COMMIT = "abc123"
            os.environ["SEMPERE_UPDATE_FIXTURES"] = "1"
            run_plan()
            check("a behavior-changing SEMPERE_* variable refuses the record",
                  "SEMPERE_UPDATE_FIXTURES" in record("abc123") and count() == 0)
            del os.environ["SEMPERE_UPDATE_FIXTURES"]
            os.environ["SEMPERE_BUILD_JOBS"] = "4"
            run_plan()
            check("an allowed variable does not", "recorded" in record("abc123") and count() == 2)
            del os.environ["SEMPERE_BUILD_JOBS"]
            p2 = run_plan()
            check("second plan skips everything", [l[0] for l in p2] == ["skip", "skip"])
            check("a skip names the commit that passed it", all("abc123" in l[5] and l[2][:12] in l[5] for l in p2))
            check("force runs everything", [l[0] for l in run_plan(SEMPERE_CI_FORCE_ALL="1")] == ["run", "run"])
            (root / "Sources/A/a.swift").write_text("a3")
            p3 = run_plan()
            check("a change reruns exactly the affected target", [(l[1], l[0]) for l in p3] == [("ATests", "run"), ("BTests", "skip")])
            _TEST_COMMIT = "def456"
            run_plan()
            record()
            p4 = run_plan()
            check("only the run target was recorded again", [l[0] for l in p4] == ["skip", "skip"] and "def456" in p4[0][5] and "abc123" in p4[1][5])
            for rec in (store / "linux-test" / "ATests").iterdir():
                rec.write_text("garbage")
            check("an unreadable record is a run, not a skip", run_plan()[0][0] == "run")
        finally:
            ROOT = saved_root
            _TEST_COMMIT = None
    print(f"ci-hash self-test: {'FAILED: ' + ', '.join(failures) if failures else 'all passed'}")
    return 1 if failures else 0


def contextlib_redirect_stderr():
    import contextlib
    import io
    return contextlib.redirect_stderr(io.StringIO())


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("hash", "plan"):
        p = sub.add_parser(name)
        p.add_argument("--job", required=True)
        p.add_argument("--package-json")
        p.add_argument("--toolchain")
        p.add_argument("targets", nargs="*")
        if name == "plan":
            p.add_argument("--out", required=True)
            p.add_argument("--store")
            p.add_argument("--force", action="store_true")
            p.add_argument("--os-dependent-only", action="store_true",
                           help="skip the manifest's logic targets (this platform is not where they are checked)")
    c = sub.add_parser("check-reads")
    c.add_argument("--package-json")
    c.add_argument("--without-extras", action="store_true", help="ignore extra_inputs: list what the guard finds (its own test)")
    r = sub.add_parser("record")
    r.add_argument("--plan", required=True)
    r.add_argument("--package-json")
    r.add_argument("--toolchain")
    r.add_argument("--store")
    for name in ("skips", "runs"):
        sub.add_parser(name).add_argument("plan")
    a = ap.parse_args()
    if a.cmd == "hash":
        return cmd_hash(a)
    if a.cmd == "plan":
        return cmd_plan(a)
    if a.cmd == "check-reads":
        return cmd_check_reads(a)
    if a.cmd == "record":
        return cmd_record(a)
    want = "skip" if a.cmd == "skips" else "run"
    for state, n, *_ in read_plan(a.plan):
        if state == want:
            print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
