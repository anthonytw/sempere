#!/usr/bin/env python3
"""Fails unless a pull request description lists the tests its author ran (docs/ci.md).

The description must have a `## Tests run` section with something in it besides HTML comments
(the template's hints): the targeted tests run beyond the PR gate and their results, or
"None beyond the gate: <why>". Reads the description from $PR_BODY (CI) or stdin.

    scripts/check-tests-run.py < body.md
    scripts/check-tests-run.py --self-test
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
    failed = 0
    for body, ok in cases.items():
        got = problem(body) is None
        if got != ok:
            failed += 1
            print(f"self-test: expected {'pass' if ok else 'fail'} for {body!r}", file=sys.stderr)
    if failed:
        sys.exit(1)
    print(f"self-test: {len(cases)} cases passed")


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if sys.argv[1:]:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    body = os.environ["PR_BODY"] if "PR_BODY" in os.environ else sys.stdin.read()
    why = problem(body)
    if why:
        print(f"::error::{why}. List the targeted tests you ran beyond the PR gate and their results, "
              "or write \"None beyond the gate: <why>\" (CLAUDE.md, docs/ci.md).")
        sys.exit(1)
    print("The description lists the tests run.")


if __name__ == "__main__":
    main()
