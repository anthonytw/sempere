#!/usr/bin/env python3
"""Picks the simulator scripts/app.sh tests on, from `xcrun simctl list devices available --json`.

On the newest iOS runtime (27 or later), among the available devices whose name starts with FAMILY
(iPad, iPhone) and ends with SUFFIX (if given), the first of the family's preferred models below,
the newest of them by model number. The name's sort order is not a choice: "iPad mini" sorts after
"iPad Pro", and the narrowest iPad is not the size the app or the screenshots are made for.

FAMILY "Watch" picks an Apple Watch on the newest watchOS runtime (27 or later) the same way (the watch app's
simulator tests, `scripts/app.sh test-watch`).

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
    # The biggest screen first: the watch UI is laid out for it (the Ultra's, then the largest Series).
    "Watch": [r"Apple Watch Ultra", r"Apple Watch Series \d+ \(46mm\)", r"Apple Watch Series \d+ \(4[0-9]mm\)", r"Apple Watch SE"],
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
        m = re.search(r"SimRuntime\.watchOS-(\d+)-(\d+)" if family == "Watch" else r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
        if not m:
            continue
        version = (int(m.group(1)), int(m.group(2)))
        if version < (27, 0):  # the apps target iPadOS 27, iOS 27 and watchOS 27
            continue
        for d in devs:
            if d.get("isAvailable") and d["name"].startswith("Apple Watch" if family == "Watch" else family) and d["name"].endswith(suffix):
                key = (version, rank(family, d["name"]))
                if best is None or key > best[0]:
                    best = (key, d["udid"], d["name"], version)
    return None if best is None else best[1:]


def fixture(names_by_runtime, os_name="iOS"):
    return {f"com.apple.CoreSimulator.SimRuntime.{os_name}-{v.replace('.', '-')}":
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


WATCH_SELF_TEST = [
    ({"27.2": ["Apple Watch SE 3 (40mm)", "Apple Watch Series 12 (42mm)", "Apple Watch Series 12 (46mm)", "Apple Watch Ultra 4 (49mm)"]},
     "Apple Watch Ultra 4 (49mm)"),
    ({"27.2": ["Apple Watch SE 3 (40mm)", "Apple Watch Series 12 (42mm)", "Apple Watch Series 12 (46mm)"]},
     "Apple Watch Series 12 (46mm)"),
    ({"26.4": ["Apple Watch Ultra 3 (49mm)"], "27.0": ["Apple Watch SE 3 (44mm)"]}, "Apple Watch SE 3 (44mm)"),
]


def self_test():
    bad = 0
    for i, (runtimes, expected) in enumerate(WATCH_SELF_TEST):
        got = pick(fixture(runtimes, "watchOS"), "Watch")
        if (got and got[1]) != expected:
            bad += 1
            print(f"watch self-test {i}: expected {expected}, got {got and got[1]}")
    # An iOS runtime is never a watch's.
    if pick(fixture({"27.0": ["Apple Watch Ultra 4 (49mm)"]}), "Watch") is not None:
        bad += 1
        print("watch self-test: an iOS runtime was picked for a watch")
    for i, (runtimes, family, suffix, expected) in enumerate(SELF_TEST):
        got = pick(fixture(runtimes), family, suffix)
        if (got and got[1]) != expected:
            bad += 1
            print(f"self-test {i}: {family} {suffix!r}: expected {expected}, got {got and got[1]}")
    print(f"pick-simulator self-test: {len(SELF_TEST) + len(WATCH_SELF_TEST) + 1 - bad}/{len(SELF_TEST) + len(WATCH_SELF_TEST) + 1} passed")
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
        platform = "watchOS" if family == "Watch" else "iOS"
        print(f"no available {family} simulator on {platform} 27 or newer "
              f"(xcrun simctl list runtimes; xcodebuild -downloadPlatform {platform})", file=sys.stderr)
        return 1
    udid, name, version = found
    print(f"using {name} ({'watchOS' if family == 'Watch' else 'iOS'} {version[0]}.{version[1]})", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
