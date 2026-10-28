#!/usr/bin/env python3
"""Development helper for the app's String Catalog (docs/localization.md). Not part of the build.

    scripts/l10n.py merge [--table T] FRAGMENT.json [...]
                                                add or replace entries in T.xcstrings (default Localizable;
                                                also InfoPlist, AppShortcuts)
    scripts/l10n.py format                      rewrite the catalogs the way Xcode writes them

A fragment is a JSON object: key -> entry. The key is the English text with its interpolations as
format specifiers (`%lld`, `%@`), exactly as Swift extracts it. An entry has

    "es"       the Spanish text, or {"one": .., "many": .., "other": ..} for a plural, or
               {"iphone": .., "ipad": .., "mac": .., "other": ..} for a device variation
    "en"       only for plurals and device variations (the source text is the key otherwise), same shapes
    "comment"  a note for translators (strongly encouraged for short strings)
    "keep"     true: the string is not translated (an entry that is the same in every language)

Plural entries may mix categories with devices as {"device": {"ipad": {"one": .., "other": ..}, ..}} only
in Xcode; this tool writes one level (plural or device), which is all the app uses.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCALIZATION = ROOT / "Apps/Sempere/Localization"
TABLES = ("Localizable", "InfoPlist", "AppShortcuts")
PLURAL = {"zero", "one", "two", "few", "many", "other"}
DEVICE = {"iphone", "ipad", "mac", "applewatch", "appletv", "applevision", "other"}


def unit(text):
    return {"stringUnit": {"state": "translated", "value": text}}


def localization(value):
    """The `localizations.<lang>` object for a string, a plural dict or a device dict."""
    if isinstance(value, str):
        return unit(value)
    kinds = set(value)
    if kinds <= PLURAL:
        return {"variations": {"plural": {k: unit(v) for k, v in value.items()}}}
    if kinds <= DEVICE:
        return {"variations": {"device": {k: unit(v) for k, v in value.items()}}}
    raise SystemExit(f"unknown variation keys {sorted(kinds)}")


def entry(frag):
    out = {"extractionState": "manual"}
    if "comment" in frag:
        out["comment"] = frag["comment"]
    if frag.get("keep"):
        out["shouldTranslate"] = False
        return out
    locs = {}
    if "en" in frag:
        locs["en"] = localization(frag["en"])
    locs["es"] = localization(frag["es"])
    out["localizations"] = locs
    return out


def load(path):
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def save(path, data):
    # Xcode's own layout: two-space indent, a space before the colon, keys sorted.
    text = json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : "))
    path.write_text(text + "\n", encoding="utf-8")


def merge(table, files):
    catalog = LOCALIZATION / f"{table}.xcstrings"
    data = load(catalog)
    added = replaced = 0
    for f in files:
        frags = json.loads(Path(f).read_text(encoding="utf-8"))
        for key, frag in frags.items():
            if key in data["strings"]:
                replaced += 1
            else:
                added += 1
            data["strings"][key] = entry(frag)
    save(catalog, data)
    print(f"merged: {added} added, {replaced} replaced, {len(data['strings'])} total")


def main(argv):
    if len(argv) >= 3 and argv[1] == "merge":
        args, table = argv[2:], "Localizable"
        if args[0] == "--table":
            table, args = args[1], args[2:]
        if table not in TABLES or not args:
            return main([argv[0]])
        merge(table, args)
    elif len(argv) == 2 and argv[1] == "format":
        for t in TABLES:
            p = LOCALIZATION / f"{t}.xcstrings"
            if p.exists():
                save(p, load(p))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
