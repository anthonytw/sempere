#!/usr/bin/env python3
"""Fails unless a pull request description lists the tests its author ran (docs/ci.md).

The description must have a `## Tests run` section with something in it besides HTML comments
(the template's hints): the targeted tests run beyond the PR gate and their results, or
"None beyond the gate: <why>". Reads the description from $PR_BODY (CI) or stdin.

    scripts/check-tests-run.py < body.md
    scripts/check-tests-run.py --app-changed < body.md   (the PR changes files under Apps/)
    scripts/check-tests-run.py --self-test

With --app-changed the section must also name `local-ci.sh` or a plain `app.sh test-mac` with a result on the same line: the
hosted gate does not run the Mac Catalyst app tests (docs/ci.md), so the author's run of them is the only check of an app
change. A filtered run (`app.sh test-mac -only-testing:...`, `-skip-testing:...`) runs part of them and does not count.
"""
from __future__ import annotations

import os
import re
import sys

HEADING = re.compile(r"^##[ \t]+Tests run[ \t]*#*[ \t]*$", re.IGNORECASE | re.MULTILINE)
NEXT_HEADING = re.compile(r"^#{1,2}[ \t]+\S", re.MULTILINE)
COMMENT = re.compile(r"<!--.*?(-->|\Z)", re.DOTALL)


def problem(body: str) -> str | None:
    """Why the description fails the rule, or None when it passes."""
    body = body.replace("\r\n", "\n")
    match = HEADING.search(body)
    if not match:
        return "the description has no `## Tests run` section"
    rest = body[match.end():]
    end = NEXT_HEADING.search(rest)
    section = COMMENT.sub("", rest[: end.start()] if end else rest)
    # Empty list items and bare placeholders do not count.
    lines = [line.strip() for line in section.splitlines()]
    content = [line for line in lines if line and line not in {"-", "*", "- [ ]", "TODO", "TBD"}]
    if not content:
        return "the `## Tests run` section is empty"
    return None


LOCAL_CI = re.compile(r"local-ci\.sh")
APP_MAC = re.compile(r"app\.sh\s+test-mac(?![-\w])")
FILTERED = re.compile(r"-(only|skip)-testing\b")
APP_RESULT = re.compile(r"pass|green|ok\b|fail|flak", re.IGNORECASE)


def app_problem(body: str) -> str | None:
    """With the PR touching Apps/: the Tests run section must name a Mac app run and its result on one line."""
    match = HEADING.search(body)
    if not match:
        return None   # problem() already reports it
    rest = body[match.end():]
    end = NEXT_HEADING.search(rest)
    section = COMMENT.sub("", rest[: end.start()] if end else rest)
    for line in section.splitlines():
        # local-ci.sh runs the whole app suite; test-mac counts only unfiltered.
        ran = LOCAL_CI.search(line) or (APP_MAC.search(line) and not FILTERED.search(line))
        if ran and APP_RESULT.search(line):
            return None
    return ("the PR changes files under Apps/, so `## Tests run` must name a run of `scripts/local-ci.sh` or a plain "
            "`scripts/app.sh test-mac` (not a filtered `-only-testing` one) and its result on the same line")


def self_test() -> None:
    cases = {
        "": False,
        "## What and why\nStuff\n": False,
        "## Tests run\n\n## Checks\n- [ ] x\n": False,
        "## Tests run\n<!-- hint\nmore hint -->\n\n## Checks\n": False,
        "## Tests run\n-\n": False,
        "## Tests run\n- `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/MacItemUITests`: passed\n": True,
        "## tests run\r\nNone beyond the gate: docs only.\r\n": True,
        "## Tests run\n<!-- hint -->\nNone beyond the gate: CI scripts only.\n## Checks\n": True,
        "## Tests run\n### Mac\n- smoke: passed\n": True,
        "### Tests run\n- x\n": False,
        "## Tests run\n<!-- unterminated hint\n": False,
    }
    app_cases = {
        "## Tests run\nNone beyond the gate: docs only.\n": False,
        "## Tests run\n- `scripts/app.sh test-mac-ui -only-testing:X`: passed\n": False,
        "## Tests run\n- `scripts/local-ci.sh`: passed in 5 min\n": True,
        "## Tests run\n- `scripts/app.sh test-mac`: passed\n": True,
        "## Tests run\n- `scripts/app.sh test-mac`\n": False,
        "## Tests run\n<!-- scripts/local-ci.sh: passed -->\n- x\n": False,
        "## Tests run\n- `scripts/app.sh test-mac -only-testing:SempereAppTests/FooTests`: passed\n": False,
        "## Tests run\n- `scripts/app.sh test-mac -only-testing:SempereAppTests/FooTests -only-testing:A/B`: passed\n": False,
        "## Tests run\n- `scripts/app.sh test-mac -skip-testing:SempereAppTests/FooTests`: passed\n": False,
        "## Tests run\n- `scripts/app.sh test-mac -only-testing:X`: passed\n- `scripts/app.sh test-mac`: passed\n": True,
        "## Tests run\n- `scripts/app.sh test-mac -only-testing:X`: passed\n- `scripts/app.sh test-mac`\n": False,
        "## Tests run\n- `scripts/app.sh test-mac`: 1200 tests, 0 failures, green\n": True,
        "## Tests run\n- `scripts/app.sh test-mac` passed\n": True,
        "## Tests run\n- `scripts/local-ci.sh`: all steps ok\n- `scripts/app.sh test-mac -only-testing:X`: passed\n": True,
        "## Tests run\n- `scripts/app.sh test-mac-ui`: passed\n": False,
    }
    failed = 0
    for body, ok in app_cases.items():
        if (app_problem(body) is None) != ok:
            failed += 1
            print(f"self-test (app): expected {'pass' if ok else 'fail'} for {body!r}", file=sys.stderr)
    for body, ok in cases.items():
        got = problem(body) is None
        if got != ok:
            failed += 1
            print(f"self-test: expected {'pass' if ok else 'fail'} for {body!r}", file=sys.stderr)
    if failed:
        sys.exit(1)
    print(f"self-test: {len(cases) + len(app_cases)} cases passed")


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    app = sys.argv[1:] == ["--app-changed"]
    if sys.argv[1:] and not app:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    body = os.environ["PR_BODY"] if "PR_BODY" in os.environ else sys.stdin.read()
    why = problem(body) or (app_problem(body) if app else None)
    if why:
        print(f"::error::{why}. List the targeted tests you ran beyond the PR gate and their results, "
              "or write \"None beyond the gate: <why>\" (CLAUDE.md, docs/ci.md).")
        sys.exit(1)
    print("The description lists the tests run.")


if __name__ == "__main__":
    main()
