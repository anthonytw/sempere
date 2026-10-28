#!/usr/bin/env python3
"""Regenerates Fixtures/fonts/harfbuzz.json: HarfBuzz's shaping of the RTL
test strings with the fixture fonts, the reference `TextLayoutTests` compares
the CLI's shaper against (glyph ids in visual order, advances, mark offsets).

Run from the repository root with `uharfbuzz` installed:
    python3 Tests/SempereRenderTests/generate_shaping_fixtures.py
Only the features the CLI's shaper implements are enabled (docs/attachments.md
§6): the Arabic joining forms, `rlig`, `ccmp` and mark positioning; no kerning.
"""
import json
import os

import uharfbuzz as hb

DIR = os.path.join(os.path.dirname(__file__), "Fixtures", "fonts")
CASES = [
    ("arabic.ttf", "مرحبا بالعالم"),
    ("arabic.ttf", "لا إله"),
    ("arabic.ttf", "بِسْمِ اللَّهِ"),
    ("hebrew.ttf", "שָׁלוֹם עולם"),
    ("hebrew.ttf", "בְּרֵאשִׁית"),
]
FEATURES = {"kern": False, "liga": False, "clig": False, "calt": False, "curs": False, "dist": False,
            "mset": False, "rclt": False}


def main():
    out = []
    for font_file, text in CASES:
        blob = hb.Blob.from_file_path(os.path.join(DIR, font_file))
        font = hb.Font(hb.Face(blob))
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(font, buf, FEATURES)
        glyphs = [{"glyph": i.codepoint, "cluster": i.cluster, "advance": p.x_advance, "dx": p.x_offset, "dy": p.y_offset}
                  for i, p in zip(buf.glyph_infos, buf.glyph_positions)]
        out.append({"font": font_file, "text": text, "glyphs": glyphs})
    with open(os.path.join(DIR, "harfbuzz.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
