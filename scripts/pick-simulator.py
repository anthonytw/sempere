#!/usr/bin/env python3
"""Picks the simulator scripts/app.sh tests on, from `xcrun simctl list devices available --json`.

On the newest iOS runtime (27 or later), among the available devices whose name starts with FAMILY
(iPad, iPhone) and ends with SUFFIX (if given), the first of the family's preferred models below,
the newest of them by model number. The name's sort order is not a choice: "iPad mini" sorts after
"iPad Pro", and the narrowest iPad is not the size the app or the screenshots are made for.

Usage: xcrun simctl list devices available --json | scripts/pick-simulator.py FAMILY [SUFFIX]
       scripts/pick-simulator.py --self-test   (the ranking's own cases)
Prints the udid (and "using NAME (iOS X.Y)" on stderr).
"""

import json
import re
import sys

# Preferred models, best first (a regular expression matched at the start of the name); any other
# model of the family comes after them.
PREFERRED = {
    "iPad": [r"iPad Pro 13-inch", r"iPad Pro 11-inch", r"iPad Air 13-inch", r"iPad Air 11-inch", r"iPad \("],
    "iPhone": [r"iPhone \d+ Pro$", r"iPhone \d+$", r"iPhone \d+ Pro Max$"],
}


def rank(family, name):
    """Larger is better: the preferred tier, then the model number in the name."""
    prefs = PREFERRED.get(family, [])
    tier = next((i for i, p in enumerate(prefs) if re.match(p, name)), len(prefs))
    numbers = [int(n) for n in re.findall(r"\d+", name)]
    return (-tier, numbers, name)


def pick(devices, family, suffix=""):
    """(udid, name, (major, minor)) or None."""
    best = None
    for runtime, devs in devices.items():
        m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
        if not m:
            continue
        version = (int(m.group(1)), int(m.group(2)))
        if version < (27, 0):  # the app targets iPadOS 27 and iOS 27
            continue
        for d in devs:
            if d.get("isAvailable") and d["name"].startswith(family) and d["name"].endswith(suffix):
                key = (version, rank(family, d["name"]))
                if best is None or key > best[0]:
                    best = (key, d["udid"], d["name"], version)
    return None if best is None else best[1:]


def fixture(names_by_runtime):
    return {f"com.apple.CoreSimulator.SimRuntime.iOS-{v.replace('.', '-')}":
            [{"name": n, "udid": n, "isAvailable": True} for n in names] for v, names in names_by_runtime.items()}


SELF_TEST = [
    # (runtimes, family, suffix, expected name)
    ({"27.0": ["iPad mini (A17 Pro)", "iPad Air 13-inch (M4)", "iPad Pro 11-inch (M5)", "iPad Pro 13-inch (M5)", "iPad (A16)"]},
     "iPad", "", "iPad Pro 13-inch (M5)"),
    ({"27.0": ["iPad mini (A17 Pro)", "iPad Air 11-inch (M4)", "iPad (A16)"]}, "iPad", "", "iPad Air 11-inch (M4)"),
    ({"27.0": ["iPad mini (A17 Pro)"]}, "iPad", "", "iPad mini (A17 Pro)"),
    ({"27.0": ["iPad Pro 13-inch (M5)"], "27.1": ["iPad mini (A17 Pro)"]}, "iPad", "", "iPad mini (A17 Pro)"),
    ({"26.4": ["iPad Pro 13-inch (M5)"], "27.0": ["iPad Air 13-inch (M4)"]}, "iPad", "", "iPad Air 13-inch (M4)"),
    ({"27.0": ["iPhone Air", "iPhone 17", "iPhone 17e", "iPhone 18 Pro", "iPhone 18 Pro Max"]}, "iPhone", "", "iPhone 18 Pro"),
    ({"27.0": ["iPhone 9 Pro", "iPhone 18 Pro"]}, "iPhone", "", "iPhone 18 Pro"),
    ({"27.0": ["iPhone 18 Pro", "iPhone 17 Pro Max", "iPhone 18 Pro Max"]}, "iPhone", "Pro Max", "iPhone 18 Pro Max"),
]


def self_test():
    bad = 0
    for i, (runtimes, family, suffix, expected) in enumerate(SELF_TEST):
        got = pick(fixture(runtimes), family, suffix)
        if (got and got[1]) != expected:
            bad += 1
            print(f"self-test {i}: {family} {suffix!r}: expected {expected}, got {got and got[1]}")
    print(f"pick-simulator self-test: {len(SELF_TEST) - bad}/{len(SELF_TEST)} passed")
    return 1 if bad else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    if len(argv) not in (2, 3) or argv[1].startswith("-"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    family, suffix = argv[1], argv[2] if len(argv) == 3 else ""
    found = pick(json.load(sys.stdin)["devices"], family, suffix)
    if found is None:
        print(f"no available {family} simulator on iOS 27 or newer "
              "(xcrun simctl list runtimes; xcodebuild -downloadPlatform iOS)", file=sys.stderr)
        return 1
    udid, name, version = found
    print(f"using {name} (iOS {version[0]}.{version[1]})", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
