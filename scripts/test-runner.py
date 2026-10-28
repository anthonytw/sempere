#!/usr/bin/env python3
"""Runs a test command, stops it at the first failed test, and reruns each failed test (docs/ci.md "Fail fast").

    scripts/test-runner.py --kind xcodebuild -- xcodebuild test -scheme … [-only-testing:…]
    scripts/test-runner.py --kind swiftpm -- swift test --parallel
    scripts/test-runner.py --self-test

The command's output passes through unchanged. Watching it:

- Fail fast (on by default off CI; SEMPERE_FAIL_FAST=0 turns it off, =1 on): at the first test that ends failed
  (XCTest's `Test Case '-[M.C t]' failed`, Swift Testing's `✘ Test t() failed`, a test runner that crashed in the
  middle of a test), the command is stopped. It runs in a process group of its own: SIGINT to the group
  (xcodebuild cancels the run and quits the app under test), after a grace period SIGTERM, then SIGKILL. The
  runner's own SIGINT and SIGTERM stop the group too. Nothing else is touched.
  (`swift test --parallel` prints a failure only after the whole run, so there it cannot stop early.)
- Reruns (SEMPERE_RERUNS, default 2): each failed test (at most SEMPERE_RERUN_LIMIT, default 3) runs again on its
  own (`-only-testing:` / `swift test --skip-build --filter`), up to that many times. Passing every rerun makes it
  FLAKY (each rerun must show that very test ending passed), failing one, or one that ran no test, makes it
  FAILING; either way the run fails, so a flaky test is fixed, not hidden.
- Stall (off CI, xcodebuild only): an xcodebuild that has printed the end of its whole run (`Test Suite 'All tests'
  passed`, `✔ Test run with N tests`; never a class's `Executed N tests`, and a later `◇ Test run started`
  disarms it) and then nothing for SEMPERE_STALL_SECS (default 180) is stopped: it passes only when a run ended
  passed and no run started after it.

It ends with one line per failed test, `TEST-RESULT FAILING|FLAKY <id> (…)`, and exits 0 only when the command
passed and no test failed.
"""
from __future__ import annotations

import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

XCTEST_FAILED = re.compile(r"Test Case '-\[([\w.]+)\.(\w+) (\w+)\]' failed")
XCTEST_STARTED = re.compile(r"Test Case '-\[([\w.]+)\.(\w+) (\w+)\]' started")
XCTEST_ENDED = re.compile(r"Test Case '-\[([\w.]+)\.(\w+) (\w+)\]' (?:passed|failed|skipped)")
# Swift Testing: `✘ Test name(_:) failed after …` or `✘ Test name() with 3 test cases failed …`.
ST_FAILED = re.compile(r"✘ Test (\w+\([^)]*\))(?: with \d+ test cases?)? failed")
ST_ISSUE = re.compile(r"✘ Test (\w+\([^)]*\))(?: with \d+ test cases?)? recorded an issue at ([\w+.-]+\.swift):(\d+)")
CRASHED = re.compile(r"Restarting after unexpected exit, crash, or test timeout|Test crashed with signal")
# xcodebuild names the test when it knows it: `…crash, or test timeout in Class.test(); summary will …`.
CRASHED_IN = re.compile(r"crash, or test timeout in (\w+)\.(\w+)\(\)")
# xcodebuild's closing list: `Failing tests:` then one `\tClass.test()` per line.
FAILING_LIST_ITEM = re.compile(r"^\t([\w]+)\.(\w+)\(\)\s*$")
# End of a whole run (never a class's `Executed N tests`): the stall watch arms only on these.
RUN_PASSED = re.compile(r"Test Suite '(?:All tests|Selected tests)' passed|✔ Test run with \d+ tests?")
RUN_FAILED = re.compile(r"Test Suite '(?:All tests|Selected tests)' failed|✘ Test run with \d+ tests?|\*\* TEST FAILED")
# A run starting (XCTest's, or Swift Testing's after it, or a relaunch after a crash) disarms it.
RUN_STARTED = re.compile(r"◇ Test run started|Test Suite '(?:All tests|Selected tests)' started")
XCTEST_PASSED = re.compile(r"Test Case '-\[([\w.]+)\.(\w+) (\w+)\]' passed")
ST_PASSED = re.compile(r"✔ Test (\w+\([^)]*\))(?: with \d+ test cases?)? passed")

@dataclass
class Failure:
    """A failed test: `target/Class/test` (XCTest), `target/Suite/test()` (Swift Testing)."""
    ident: str
    kind: str  # xctest | swift-testing


@dataclass
class Watch:
    kind: str
    default_target: str | None = None
    failures: list[Failure] = field(default_factory=list)
    running: dict[str, str] = field(default_factory=dict)  # XCTest cases started and not ended
    st_files: dict[str, tuple[str, int]] = field(default_factory=dict)  # Swift Testing name -> (file, line)
    in_failing_list: bool = False
    passed: set[str] = field(default_factory=set)  # tests seen ending passed (`xctest:<id>`, `st:<name>`)
    # The stall watch: armed by the end of a run, disarmed by the start of one (Swift Testing runs after XCTest).
    armed: bool = False
    run_passed: bool = False  # a run ended passed, and none started after it
    run_failed: bool = False

    def add(self, failure: Failure | None) -> bool:
        if failure is None or any(f.ident == failure.ident for f in self.failures):
            return False
        self.failures.append(failure)
        return True

    def feed(self, line: str) -> bool:
        """Takes one output line; True when it reports a newly failed test."""
        if RUN_STARTED.search(line):
            self.armed, self.run_passed = False, False
        if RUN_PASSED.search(line):
            self.armed, self.run_passed = True, True
        if RUN_FAILED.search(line):
            self.armed, self.run_failed = True, True
        if m := XCTEST_STARTED.search(line):
            self.running[f"{m[1]}.{m[2]}.{m[3]}"] = self.xctest_ident(m[1], m[2], m[3])
        if m := XCTEST_ENDED.search(line):
            self.running.pop(f"{m[1]}.{m[2]}.{m[3]}", None)
        if m := XCTEST_PASSED.search(line):
            self.passed.add("xctest:" + self.xctest_ident(m[1], m[2], m[3]))
        if m := ST_PASSED.search(line):
            self.passed.add("st:" + m[1])
        if m := XCTEST_FAILED.search(line):
            return self.add(Failure(self.xctest_ident(m[1], m[2], m[3]), "xctest"))
        if m := ST_ISSUE.search(line):
            self.st_files.setdefault(m[1], (m[2], int(m[3])))
            return False
        if m := ST_FAILED.search(line):
            return self.add(self.swift_testing(m[1]))
        if CRASHED.search(line):
            if m := CRASHED_IN.search(line):
                cls, test = m[1], m[2]
                module = next((key.rsplit(".", 2)[0] for key in self.running if key.endswith(f".{cls}.{test}")),
                              self.default_target)
                if module:
                    return self.add(Failure(self.xctest_ident(module, cls, test), "xctest"))
            if self.running:
                return self.add(Failure(list(self.running.values())[-1], "xctest"))
            return False
        if line.startswith("Failing tests:"):
            self.in_failing_list = True
            return False
        if self.in_failing_list:
            m = FAILING_LIST_ITEM.match(line)
            if not m:
                self.in_failing_list = False
                return False
            known = any(f.ident.split("/")[-2:] in ([m[1], m[2]], [m[1], m[2] + "()"]) for f in self.failures)
            if not known and self.default_target:
                ident = f"{self.default_target}/{m[1]}/{m[2]}"
                return self.add(Failure(ident, "xctest"))
        return False

    def stall_result(self) -> int:
        """What a run stopped for a stall returns: passed only when a run ended passed and none started after it."""
        return 0 if self.run_passed and not self.run_failed and not self.failures else 65

    def saw_pass(self, failure: Failure) -> bool:
        """Whether `failure`'s test was seen ending passed (a rerun that ran no test is no pass)."""
        if failure.kind == "xctest":
            return "xctest:" + failure.ident in self.passed
        return "st:" + failure.ident.rsplit("/", 1)[-1] in self.passed

    def xctest_ident(self, module: str, cls: str, test: str) -> str:
        return f"{module}/{cls}/{test}" if self.kind == "xcodebuild" else f"{module}.{cls}/{test}"

    def swift_testing(self, name: str) -> Failure | None:
        base = name.split("(")[0]
        file, line = self.st_files.get(name, (None, 0))
        found = locate(base, file, line)
        if not found:
            print(f"test-runner: could not find the suite of {name}; it is not rerun", flush=True)
            return Failure(f"?/{name}", "swift-testing")
        target, path = found
        return Failure(f"{target}/{'/'.join(path)}/{name}" if self.kind == "xcodebuild"
                       else f"{target}.{'.'.join(path)}/{name}", "swift-testing")


TEST_DIRS = [ROOT / "Apps" / "Sempere", ROOT / "Tests"]
TYPE_DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*"
                       r"(?:struct|class|enum|actor|extension)\s+(\w+)")


def enclosing_types(text: str, func_line: int) -> list[str]:
    """The type names around line `func_line` (1-based), outermost first, by brace depth."""
    stack: list[tuple[int, str]] = []
    depth = 0
    for number, line in enumerate(text.splitlines(), start=1):
        if number == func_line:
            return [name for _, name in stack]
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', line.split("//")[0])
        if m := TYPE_DECL.match(code):
            stack.append((depth, m[1]))
        depth += code.count("{") - code.count("}")
        while stack and depth <= stack[-1][0]:
            stack.pop()
    return [name for _, name in stack]


def locate(func: str, file: str | None, line: int) -> tuple[str, list[str]] | None:
    """(test target, suite path) of the Swift Testing function `func`, from the issue's file when known."""
    decl = re.compile(rf"\bfunc\s+{re.escape(func)}\s*[(<]")
    candidates: list[Path] = []
    for base in TEST_DIRS:
        if not base.is_dir():
            continue
        for path in base.rglob("*.swift"):
            if file and path.name != file:
                continue
            candidates.append(path)
    if file and not candidates:
        return locate(func, None, 0)
    hits = []
    for path in candidates:
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for number, src in enumerate(text.splitlines(), start=1):
            if decl.search(src):
                hits.append((path, text, number))
    if len(hits) != 1:
        if file and not hits:
            return locate(func, None, 0)
        return None
    path, text, number = hits[0]
    rel = path.relative_to(ROOT).parts
    target = rel[2] if rel[0] == "Apps" else rel[1]
    types = enclosing_types(text, number)
    return (target, types) if types else None


# MARK: - Running


# The command runs in a session (and process group) of its own, so the runner can stop all of it, and only it,
# with os.killpg: never a PID that may have been reused. Set while a command runs, for the signal handlers.
CURRENT: subprocess.Popen | None = None
# Whether the command's output is passed through (the self-test's fake commands are not).
ECHO = True


def signal_group(proc: subprocess.Popen, sig: int) -> None:
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def stop(proc: subprocess.Popen, kind: str) -> None:
    """Ends the command's process group: SIGINT (xcodebuild cancels the run and quits the app under test), then
    SIGTERM, then SIGKILL."""
    for sig, wait in ((signal.SIGINT, 30 if kind == "xcodebuild" else 5), (signal.SIGTERM, 10), (signal.SIGKILL, 5)):
        signal_group(proc, sig)
        try:
            proc.wait(timeout=wait)
            break
        except subprocess.TimeoutExpired:
            continue
    signal_group(proc, signal.SIGTERM)   # anything of the group that outlived its leader


def on_signal(signum: int, _frame) -> None:
    if CURRENT is not None and CURRENT.poll() is None:
        print(f"test-runner: signal {signum}: stopping the run", file=sys.stderr, flush=True)
        stop(CURRENT, "xcodebuild")
    sys.exit(128 + signum)


def run(cmd: list[str], watch: Watch, fail_fast: bool, stall: int | None, drain: float = 3) -> int:
    """Runs `cmd`, passing its output through to `watch`. Returns its exit status (non-zero when stopped)."""
    global CURRENT
    # SIGINT back to its default in the command: a shell starts background jobs with it ignored (xc-lock, local-ci
    # under caffeinate), and a command that ignores it would only stop at SIGTERM, 30 s later.
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
                            preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    CURRENT = proc
    lines: queue.Queue[bytes | None] = queue.Queue()

    def pump() -> None:
        assert proc.stdout is not None
        for raw in iter(proc.stdout.readline, b""):
            lines.put(raw)
        lines.put(None)

    threading.Thread(target=pump, daemon=True).start()
    last_output = time.monotonic()
    stop_at: float | None = None
    exited_at: float | None = None
    result: int | None = None   # set when the runner stopped the command
    while True:
        try:
            raw = lines.get(timeout=0.5)
        except queue.Empty:
            raw = b""
        if raw is None:
            break
        now = time.monotonic()
        if raw:
            last_output = now
            if ECHO:
                sys.stdout.buffer.write(raw)
                sys.stdout.flush()
            if watch.feed(raw.decode("utf-8", errors="replace").rstrip("\n")) and fail_fast and stop_at is None:
                # A moment more for the failure's own lines (its issues, the suite's end), then stop.
                stop_at = now + 3
        if result is None and stop_at is not None and now >= stop_at:
            names = ", ".join(f.ident for f in watch.failures)
            print(f"FAIL-FAST {names} failed: stopping the run (SEMPERE_FAIL_FAST=0 runs every test)", flush=True)
            stop(proc, watch.kind)
            result = proc.returncode or 1
        if result is None and stall and watch.armed and now - last_output >= stall:
            print(f"XCB-STALL xcodebuild silent for {stall}s after the end of its run: stopping it", file=sys.stderr, flush=True)
            stop(proc, watch.kind)
            result = watch.stall_result()
        # The command has exited: what it printed is read for a few seconds more, not until every process that
        # inherited its output closes it.
        if proc.poll() is not None:
            exited_at = exited_at or now
            if now - exited_at >= drain:
                break
    status = proc.wait()
    signal_group(proc, signal.SIGTERM)   # leftovers of the group still holding the output
    CURRENT = None
    return status if result is None else result


def classify(cmd: list[str], failure: Failure, kind: str, reruns: int, target: str | None, stall: int | None) -> str:
    """Reruns `failure` on its own up to `reruns` times: the `TEST-RESULT` line."""
    again = rerun_command(cmd, failure, kind) if reruns > 0 else None
    if again is None:
        return f"TEST-RESULT FAILING {failure.ident} (not rerun)"
    for attempt in range(1, reruns + 1):
        print(f"RERUN {attempt}/{reruns} {failure.ident}", flush=True)
        watch = Watch(kind=kind, default_target=target)
        code = run(again, watch, fail_fast=False, stall=stall)
        if code != 0 or watch.failures:
            return f"TEST-RESULT FAILING {failure.ident} (failed again on rerun {attempt})"
        if not watch.saw_pass(failure):
            return f"TEST-RESULT FAILING {failure.ident} (rerun ran no test)"
    return f"TEST-RESULT FLAKY {failure.ident} (failed once, then passed {reruns} reruns)"


def rerun_command(cmd: list[str], failure: Failure, kind: str) -> list[str] | None:
    if failure.ident.startswith("?/"):
        return None
    if kind == "swiftpm":
        swift = cmd[0]
        if failure.kind == "xctest":
            pattern = "^" + re.escape(failure.ident) + "$"
        else:
            pattern = re.escape(failure.ident.split("(")[0]) + r"\("
        return [swift, "test", "--skip-build", "--filter", pattern]
    out: list[str] = []
    skip_next = False
    for arg in cmd:
        if skip_next:
            skip_next = False
            continue
        if arg.startswith(("-only-testing:", "-skip-testing:")) or arg in ("-retry-tests-on-failure", "-run-tests-until-failure"):
            continue
        if arg in ("-only-testing", "-skip-testing", "-resultBundlePath", "-test-iterations"):
            skip_next = True
            continue
        out.append(arg)
    return out + [f"-only-testing:{failure.ident}"]


def main() -> int:
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    kind = "xcodebuild"
    target = None
    while args and args[0] != "--":
        flag = args.pop(0)
        if flag == "--kind" and args:
            kind = args.pop(0)
        elif flag == "--target" and args:
            target = args.pop(0)
        else:
            print(__doc__, file=sys.stderr)
            return 2
    if not args or kind not in ("xcodebuild", "swiftpm"):
        print(__doc__, file=sys.stderr)
        return 2
    cmd = args[1:]
    on_ci = os.environ.get("CI") == "true"
    fail_fast = {"0": False, "1": True}.get(os.environ.get("SEMPERE_FAIL_FAST", ""), not on_ci)
    reruns = int(os.environ.get("SEMPERE_RERUNS", "2"))
    limit = int(os.environ.get("SEMPERE_RERUN_LIMIT", "3"))
    stall = int(os.environ.get("SEMPERE_STALL_SECS", "180")) if kind == "xcodebuild" and not on_ci else None
    if target is None and kind == "xcodebuild":
        named = [a.split(":", 1)[1].split("/")[0] for a in cmd if a.startswith("-only-testing:")]
        target = named[0] if named else ("SempereAppUITests" if "SempereScreenshots" in cmd else "SempereAppTests")
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    watch = Watch(kind=kind, default_target=target)
    status = run(cmd, watch, fail_fast, stall)
    if not watch.failures:
        return status
    results = [classify(cmd, failure, kind, reruns, target, stall) for failure in watch.failures[:limit]]
    for failure in watch.failures[limit:]:
        results.append(f"TEST-RESULT FAILING {failure.ident} (not rerun: over SEMPERE_RERUN_LIMIT)")
    print("\n".join(results), flush=True)
    return status or 1


def self_test() -> int:
    problems = []
    w = Watch(kind="xcodebuild", default_target="SempereAppUITests")
    assert not w.feed("Test Case '-[SempereAppUITests.PhoneParityUITests testUnlock]' started.")
    if not w.feed("Test Case '-[SempereAppUITests.PhoneParityUITests testUnlock]' failed (8.1 seconds)."):
        problems.append("XCTest failure not seen")
    if w.failures[-1].ident != "SempereAppUITests/PhoneParityUITests/testUnlock":
        problems.append(f"XCTest id {w.failures[-1].ident}")
    w.feed("Test Case '-[SempereAppUITests.PhoneCanvasUITests testATap]' started.")
    if not w.feed("Restarting after unexpected exit, crash, or test timeout; summary will include totals"):
        problems.append("crash not seen")
    if w.failures[-1].ident != "SempereAppUITests/PhoneCanvasUITests/testATap":
        problems.append(f"crash id {w.failures[-1].ident}")
    w.feed("Test Case '-[SempereAppUITests.SearchHighlightUITests testA]' started.")
    w.feed("Test Case '-[SempereAppUITests.SearchHighlightUITests testB]' started.")
    w.feed("Restarting after unexpected exit, crash, or test timeout in SearchHighlightUITests.testA(); summary will include totals")
    if w.failures[-1].ident != "SempereAppUITests/SearchHighlightUITests/testA":
        problems.append(f"named crash blamed on {w.failures[-1].ident}, not the test the line names (S2)")
    w.feed("Failing tests:")
    if w.feed("\tPhoneParityUITests.testUnlock()"):
        problems.append("a listed failure already seen was added again")
    if not w.feed("\tSearchHighlightUITests.testSteps()") or w.failures[-1].ident != "SempereAppUITests/SearchHighlightUITests/testSteps":
        problems.append("listed failure not added")
    s = Watch(kind="swiftpm")
    if not s.feed("Test Case '-[SempereWebDAVTests.EpochInterleavingTests testInvariantsHoldOverMemoryTargets]' failed (3.0 seconds)."):
        problems.append("swiftpm XCTest failure not seen")
    if s.failures[-1].ident != "SempereWebDAVTests.EpochInterleavingTests/testInvariantsHoldOverMemoryTargets":
        problems.append(f"swiftpm id {s.failures[-1].ident}")
    st = Watch(kind="xcodebuild", default_target="SempereAppTests")
    st.feed("✘ Test outboundConnectionsAreRefused() recorded an issue at OfflineModeTests.swift:32:9: Expectation failed: r != 0")
    if not st.feed("✘ Test outboundConnectionsAreRefused() failed after 0.006 seconds with 1 issue."):
        problems.append("Swift Testing failure not seen")
    elif st.failures[-1].ident != "SempereAppTests/OfflineModeTests/outboundConnectionsAreRefused()":
        problems.append(f"Swift Testing id {st.failures[-1].ident}")
    if not st.feed("✘ Test screenFits(_:in:) with 21 test cases failed after 62.4 seconds with 1 issue."):
        problems.append("parameterized Swift Testing failure not seen")
    elif st.failures[-1].ident != "SempereAppTests/PseudoLanguageLayoutTests/screenFits(_:in:)":
        problems.append(f"parameterized id {st.failures[-1].ident}")
    nested = "struct Outer {\n    @Suite struct Inner {\n        @Test func a() {}\n    }\n    @Test func b() {}\n}\n"
    if enclosing_types(nested, 3) != ["Outer", "Inner"] or enclosing_types(nested, 5) != ["Outer"]:
        problems.append(f"nesting {enclosing_types(nested, 3)} {enclosing_types(nested, 5)}")
    cmd = ["xcodebuild", "test", "-scheme", "S", "-only-testing:A/B", "-skip-testing:A/C", "-resultBundlePath", "x.xcresult",
           "-retry-tests-on-failure", "-test-iterations", "2", "CODE_SIGNING_ALLOWED=NO"]
    again = rerun_command(cmd, Failure("A/B/testX", "xctest"), "xcodebuild")
    if again != ["xcodebuild", "test", "-scheme", "S", "CODE_SIGNING_ALLOWED=NO", "-only-testing:A/B/testX"]:
        problems.append(f"rerun command {again}")
    problems += self_test_commands()
    for p in problems:
        print(f"self-test: {p}", file=sys.stderr)
    if problems:
        return 1
    print("self-test: passed")
    return 0


def self_test_commands() -> list[str]:
    """Fake commands (this Python printing what xcodebuild prints) through `run` and `classify`."""
    problems: list[str] = []

    def fake(*lines: str, sleep: float = 0, code: int = 0, orphan: bool = False) -> list[str]:
        body = "import subprocess, sys, time\n"
        if orphan:   # a child that keeps the output open after the command exits
            body += "subprocess.Popen(['sleep', '30'])\n"
        body += "".join(f"print({line!r}, flush=True)\n" for line in lines)
        body += f"time.sleep({sleep})\nsys.exit({code})\n"
        return [sys.executable, "-c", body]

    import contextlib
    import io
    global ECHO
    ECHO = False
    quiet = contextlib.redirect_stdout(io.StringIO())
    stall = 2
    cases = [
        # B1: a class summary is not the end of the run: a hang after it is a failure, not a pass.
        # (Not armed: no stall stop, so the run lasts until the command exits, 6 s here, not the 2 s of a stall.)
        ("hang after a class's Executed line", fake("Test Suite 'FooTests' passed at 2026-10-25 10:00:00.000.",
         "\t Executed 3 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds", sleep=6),
         lambda r, w: not w.armed and w.stall_result() != 0 and time.monotonic() - began >= 5),
        # Hung after the whole run passed: stopped, passed.
        ("hang after All tests passed", fake("Test Suite 'All tests' passed at 2026-10-25 10:00:00.000.", sleep=30),
         lambda r, w: r == 0),
        # Swift Testing starts after XCTest's summary: no stall stop while it runs (here 4 s), its own end decides.
        ("Swift Testing after XCTest's summary", fake("Test Suite 'All tests' passed at 2026-10-25 10:00:00.000.",
         "◇ Test run started.", sleep=4), lambda r, w: r == 0 and not w.armed),
        ("hang after a Swift Testing run started", fake("Test Suite 'All tests' passed at 2026-10-25 10:00:00.000.",
         "◇ Test run started.", "✘ Test run with 3 tests failed after 1.0 seconds with 1 issue.", sleep=30),
         lambda r, w: r != 0),
    ]
    for name, cmd, ok in cases:
        watch = Watch(kind="xcodebuild", default_target="T")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            began = time.monotonic()
            result = run(cmd, watch, fail_fast=False, stall=stall)
        if not ok(result, watch) or time.monotonic() - began > 20:
            problems.append(f"stall: {name}: returned {result}")
    # S4: the command exits while a child it left holds the output: the run ends within the drain, not after it.
    with quiet:
        began = time.monotonic()
        result = run(fake("Test Suite 'All tests' passed at 2026-10-25 10:00:00.000.", orphan=True),
                     Watch(kind="xcodebuild"), fail_fast=False, stall=None, drain=1)
    if result != 0 or time.monotonic() - began > 8:
        problems.append(f"an orphan holding the output kept the run waiting {time.monotonic() - began:.0f} s (S4)")
    # S1: a rerun must show the very test passing; one that ran nothing is FAILING, one that passed it FLAKY.
    failure = Failure("T/C/testA", "xctest")
    with quiet:
        none = classify(fake("** TEST SUCCEEDED **"), failure, "xcodebuild", 2, "T", None)
        passed = classify(fake("Test Case '-[T.C testA]' passed (0.1 seconds)."), failure, "xcodebuild", 2, "T", None)
        st = classify(fake("✔ Test stOne() passed after 0.1 seconds."), Failure("T/S/stOne()", "swift-testing"),
                      "xcodebuild", 2, "T", None)
    if "FAILING" not in none or "ran no test" not in none:
        problems.append(f"a rerun that ran no test: {none} (S1)")
    if "FLAKY" not in passed or "FLAKY" not in st:
        problems.append(f"reruns that passed the test: {passed} / {st} (S1)")
    ECHO = True
    return problems


if __name__ == "__main__":
    sys.exit(main())
