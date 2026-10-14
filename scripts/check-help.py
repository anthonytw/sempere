#!/usr/bin/env python3
"""Fails when an icon-only control of the app has no tooltip (`.help`).

On a Mac (Catalyst) toolbar and icon buttons show no title, so every one
needs `.help("…")` (TestFlight build 7). This checks the app's SwiftUI
sources (Apps/Sempere/SempereApp and SempereShared by default):

* A control is a `Button`, `Menu`, `Toggle`, `ShareLink` or `PhotosPicker`.
* It shows an icon when its label has one: `systemImage:` in the call's
  arguments, or `Image(systemName:)` / `Label(…, systemImage:)` in its label
  closure (`label: { … }`, or the trailing closure of `Button(action:)` and
  `Toggle(isOn:)`). `ShareLink` shows the system's share icon unless given a
  label.
* It is icon-only unless it sits where SwiftUI shows titles: inside a menu
  (`Menu { … }`, `.contextMenu`, `menu:`), `.swipeActions`, a `Picker`,
  `.confirmationDialog`, `.alert`, `.searchSuggestions`, a `Form` or a
  `List`, or it has `.labelStyle(.titleAndIcon)` / `.labelStyle(.titleOnly)`.
  `.buttonStyle(.bordered)` and `.borderedProminent` show the title too.
  `.labelStyle(.iconOnly)` makes any control icon-only. A view builder whose
  controls only ever appear in such places (a context menu's items, a form's
  section) is marked `// help-lint: titled` on the line above its `{` line.
* An icon-only control passes with a `.help(` modifier in its chain. A
  deliberate exception carries `// help-lint: ignore (why)` on the line the
  control starts on.

Usage: scripts/check-help.py [paths…]   (exit 1 and a list on failures)
       scripts/check-help.py --self-test (the scanner's own cases)
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PATHS = [os.path.join(ROOT, "Apps/Sempere/SempereApp"), os.path.join(ROOT, "Apps/Sempere/SempereShared")]

CONTROLS = ("Button", "Menu", "Toggle", "ShareLink", "PhotosPicker")
# Blocks whose controls SwiftUI shows with their titles (menus, lists, forms, dialogs).
TITLED = {"Menu", "contextMenu", "menu", "swipeActions", "Picker", "confirmationDialog", "alert",
          "searchSuggestions", "Form", "List", "Section", "menuItems"}
TITLED_MARK = "help-lint: titled"
ICON = re.compile(r"systemImage\s*:|Image\s*\(\s*systemName\s*:")


def blank(src):
    """`src` with comments and string contents replaced by spaces (newlines
    kept, so offsets and line numbers stay), interpolations kept as code."""
    out = list(src)
    i, n = 0, len(src)
    def blank_range(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def skip_string(i):
        """i at the opening quote(s); returns the index after the closing ones."""
        if src.startswith('"""', i):
            delim, j = '"""', i + 3
        else:
            delim, j = '"', i + 1
        start = j
        while j < n:
            if src[j] == "\\" and j + 1 < n:
                if src[j + 1] == "(":
                    blank_range(start, j)
                    # Interpolation: code up to the matching paren.
                    depth, k = 1, j + 2
                    while k < n and depth:
                        c = src[k]
                        if c == '"':
                            k = skip_string(k)
                            continue
                        if c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                        k += 1
                    j = k
                    start = j
                    continue
                j += 2
                continue
            if src.startswith(delim, j):
                blank_range(start, j)
                return j + len(delim)
            if delim == '"' and src[j] == "\n":
                blank_range(start, j)
                return j
            j += 1
        blank_range(start, n)
        return n

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank_range(i, j)
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank_range(i, j)
            i = j
        elif c == '"':
            i = skip_string(i)
        else:
            i += 1
    return "".join(out)


PAIRS = {"(": ")", "{": "}", "[": "]"}


def match(code, i):
    """Index after the bracket matching the one at `i`."""
    opener, closer = code[i], PAIRS[code[i]]
    depth = 0
    for k in range(i, len(code)):
        if code[k] == opener:
            depth += 1
        elif code[k] == closer:
            depth -= 1
            if depth == 0:
                return k + 1
    return len(code)


def skip_ws(code, i):
    while i < len(code) and code[i] in " \t\r\n":
        i += 1
    return i


def block_heads(code, lines):
    """For every `{`, the name of what opens it: `Menu` for `Menu(…) {` and
    `Menu {`, `contextMenu` for `.contextMenu {`, `label` for `} label: {`.
    A `{` on a line marked `// help-lint: titled` (or right under such a
    comment line) counts as a menu: a view builder whose items are only ever
    shown in menus, lists or forms, which the scan cannot see from inside it."""
    heads = {}
    for m in re.finditer(r"\{", code):
        line = code.count("\n", 0, m.start())
        if TITLED_MARK in lines[line] or (line > 0 and lines[line - 1].strip().startswith("// " + TITLED_MARK)):
            heads[m.start()] = "Menu"
            continue
        k = m.start() - 1
        while k >= 0 and code[k] in " \t\r\n":
            k -= 1
        if k >= 0 and code[k] == ")":
            depth = 0
            while k >= 0:
                if code[k] == ")":
                    depth += 1
                elif code[k] == "(":
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            k -= 1
            while k >= 0 and code[k] in " \t":
                k -= 1
        if k >= 0 and code[k] == ":":
            k -= 1
        end = k + 1
        while k >= 0 and (code[k].isalnum() or code[k] == "_"):
            k -= 1
        heads[m.start()] = code[k + 1:end]
    return heads


def enclosing(code, heads, pos):
    """Names of the blocks around `pos`, innermost last."""
    stack = []
    for k in range(pos):
        c = code[k]
        if c == "{":
            stack.append(heads.get(k, ""))
        elif c == "}" and stack:
            stack.pop()
    return stack


def parse_control(code, start, name):
    """(args, closures, modifiers, end) of the control whose name starts at `start`."""
    i = skip_ws(code, start + len(name))
    args = ""
    if i < len(code) and code[i] == "(":
        j = match(code, i)
        args = code[i + 1:j - 1]
        i = j
    closures = []   # (label or None, body)
    while True:
        j = skip_ws(code, i)
        label = None
        m = re.match(r"([A-Za-z_]\w*)\s*:\s*\{", code[j:])
        if closures and m:
            label = m.group(1)
            j += m.end() - 1
        if j < len(code) and code[j] == "{" and (closures or label or code[i:j].count("\n") == 0):
            k = match(code, j)
            closures.append((label, code[j + 1:k - 1]))
            i = k
        else:
            break
    modifiers = []
    while True:
        j = skip_ws(code, i)
        m = re.match(r"\.([A-Za-z_]\w*)", code[j:])
        if not m:
            break
        mod = m.group(1)
        k = j + m.end()
        text = ""
        k2 = skip_ws(code, k)
        if k2 < len(code) and code[k2] == "(":
            e = match(code, k2)
            text = code[k2 + 1:e - 1]
            k = e
        k2 = skip_ws(code, k)
        if k2 < len(code) and code[k2] == "{" and code[k:k2].count("\n") == 0:
            k = match(code, k2)
        modifiers.append((mod, text))
        i = k
    return args, closures, modifiers, i


def label_text(name, args, closures):
    """The part of the control that is its label."""
    parts = [args if name != "Menu" or "systemImage" in args else ""]
    for label, body in closures:
        if label == "label":
            parts.append(body)
    if closures and closures[0][0] is None:
        first = closures[0][1]
        if name == "Button" and re.search(r"\baction\s*:", args):
            parts.append(first)
        elif name in ("Toggle", "ShareLink", "PhotosPicker") and "systemImage" not in args:
            parts.append(first)
    return " ".join(parts)


def check(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    code = blank(src)
    lines = src.split("\n")
    heads = block_heads(code, lines)
    failures = []
    for m in re.finditer(r"(?<![\w.])(" + "|".join(CONTROLS) + r")\s*[({]", code):
        name = m.group(1)
        args, closures, modifiers, _ = parse_control(code, m.start(), name)
        mods = {mod: text for mod, text in modifiers}
        style = mods.get("labelStyle", "").replace(" ", "")
        line = code.count("\n", 0, m.start()) + 1
        if "help-lint: ignore" in lines[line - 1]:
            continue
        has_icon = bool(ICON.search(label_text(name, args, closures)))
        if name == "ShareLink" and not any(l == "label" for l, _ in closures) and not (closures and closures[0][0] is None):
            has_icon = True
        icon_only = style == ".iconOnly"
        if not icon_only and has_icon and style not in (".titleAndIcon", ".titleOnly"):
            icon_only = not (TITLED & set(enclosing(code, heads, m.start())))
        # A bordered button shows its title next to the icon.
        if mods.get("buttonStyle", "").replace(" ", "") in (".bordered", ".borderedProminent") and style != ".iconOnly":
            icon_only = False
        if icon_only and "help" not in mods:
            failures.append((line, name, lines[line - 1].strip()))
    return failures


SELF_TEST = [
    # (source, expected failing lines)
    ('ToolbarItem {\n    Button("New", systemImage: "plus") { add() }\n}', [2]),
    ('ToolbarItem {\n    Button("New", systemImage: "plus") { add() }\n        .help("New note")\n}', []),
    ('.contextMenu {\n    Button("Delete", systemImage: "trash") { d() }\n}', []),
    ('Menu {\n    Section {\n        Button("A", systemImage: "a") {}\n    }\n} label: {\n    Label("M", systemImage: "m")\n}', [1]),
    ('Form {\n    Button("Reset", systemImage: "arrow") { r() }\n}', []),
    ('Form {\n    Button("Remove", systemImage: "minus") { r() }\n        .labelStyle(.iconOnly)\n}', [2]),
    ('HStack {\n    Button { go() } label: {\n        Image(systemName: "chevron.down")\n    }\n    .buttonStyle(.plain)\n}', [2]),
    ('HStack {\n    Button("Title") { Image(systemName: "x") }\n}', []),
    ('HStack {\n    Button("Done", systemImage: "check") { d() }\n        .buttonStyle(.bordered)\n}', []),
    ('HStack {\n    Button("Go", systemImage: "go") { d() }   // help-lint: ignore (row)\n}', []),
    ('// help-lint: titled\nvar items: some View {\n    Button("Go", systemImage: "go") { d() }\n}', []),
    ('Text("Button(\\"x\\", systemImage: \\"y\\")")', []),
    ('ToolbarItem {\n    Toggle("Text", systemImage: "t", isOn: $on)\n        .toggleStyle(.button)\n}', [2]),
]


def self_test():
    import tempfile
    bad = 0
    for i, (source, expected) in enumerate(SELF_TEST):
        with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
            f.write(source)
        got = [line for line, _, _ in check(f.name)]
        os.unlink(f.name)
        if got != expected:
            bad += 1
            print(f"self-test {i}: expected {expected}, got {got}:\n{source}\n")
    print(f"check-help self-test: {len(SELF_TEST) - bad}/{len(SELF_TEST)} passed")
    return 1 if bad else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    paths = argv[1:] or DEFAULT_PATHS
    files = []
    for p in paths:
        if os.path.isdir(p):
            for d, _, names in os.walk(p):
                files += [os.path.join(d, n) for n in sorted(names) if n.endswith(".swift")]
        elif p.endswith(".swift"):
            files.append(p)
    bad = 0
    for path in sorted(files):
        for line, name, text in check(path):
            bad += 1
            print(f"{os.path.relpath(path, ROOT)}:{line}: icon-only {name} without .help: {text}")
    if bad:
        print(f"\n{bad} icon-only control(s) without a tooltip: add .help(\"…\") (or `// help-lint: ignore (why)`).")
        return 1
    print(f"check-help: {len(files)} files, every icon-only control has .help")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
