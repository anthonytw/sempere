#!/usr/bin/env python3
"""Deterministically generates sample-note.json (a NoteState, format.md 5.4).

Run: python3 generate_sample_note.py > Fixtures/sample-note.json
Uses a fixed LCG so output never depends on the platform's RNG.
"""
import json, math

state = 12345
def rnd():
    global state
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF
    return state / 0x7FFFFFFF

def uid(n):
    return "00000000-0000-4000-8000-%012x" % n

counter = [0x100]
def next_id():
    counter[0] += 1
    return uid(counter[0])

def r3(v):
    return round(v, 3)

def wave(x0, y0, length, amp, freq, n, w0, w1, o=1.0):
    pts = []
    for i in range(n):
        u = i / (n - 1)
        x = x0 + length * u
        y = y0 + amp * math.sin(freq * u * 2 * math.pi) + (rnd() - 0.5) * 0.6
        w = w0 + (w1 - w0) * math.sin(math.pi * u)
        pts.append([r3(x), r3(y), r3(u * 0.8), r3(w), r3(w), o, r3(0.5 + 0.4 * u), 0, r3(math.pi / 2)])
    return pts

def stroke(tool, color, width, pts, transform=None):
    s = {"id": next_id(), "ink": {"tool": tool, "color": color, "width": width}, "points": pts}
    if transform:
        s["transform"] = transform
    return s

def page(i, strokes):
    return {"id": uid(i), "order": "a%d" % i, "strokes": strokes}

p1 = [
    stroke("pen", "#1A1A1AFF", 2.5, wave(60, 100, 300, 14, 3, 14, 1.2, 3.4)),
    stroke("pen", "#1A1A1AFF", 2.5, wave(60, 148, 220, 10, 2, 11, 1.0, 3.0)),
    stroke("fountainPen", "#1F3FBFFF", 3.0, wave(60, 196, 340, 18, 4, 16, 0.8, 4.2)),
    stroke("monoline", "#B00020FF", 2.0, wave(60, 244, 260, 12, 2.5, 12, 2, 2)),
    stroke("marker", "#FFD600FF", 14.0, wave(60, 292, 200, 4, 1, 8, 14, 14)),
    stroke("pencil", "#444444FF", 2.0, wave(60, 340, 280, 9, 3, 13, 1.5, 2.6, 0.9)),
    stroke("crayon", "#2E7D32FF", 5.0, wave(60, 388, 240, 8, 2, 11, 3.5, 5.5)),
    stroke("watercolor", "#6A1B9AFF", 9.0, wave(60, 436, 300, 11, 2, 12, 6, 10)),
    stroke("pen", "#1A1A1AFF", 3.0, [[300.0, 500.0, 0, 3.0, 3.0, 1.0, 0.5, 0, 1.571]]),
    stroke("pen", "#1A1A1AFF", 2.5, [[100.0, 540.0, 0, 2.0, 2.0, 1.0, 0.5, 0, 1.571],
                                     [180.0, 570.0, 0.1, 3.0, 3.0, 1.0, 0.5, 0, 1.571]]),
]

p2 = [
    stroke("pen", "#000000FF", 2.2, wave(50, 80, 300, 20, 2, 15, 1.4, 3.6)),
    stroke("pen", "#0D47A1FF", 2.2, wave(50, 140, 260, 16, 3, 14, 1.2, 3.2)),
    stroke("fountainPen", "#000000FF", 3.0, wave(50, 200, 330, 22, 3, 17, 0.9, 4.0)),
    stroke("monoline", "#E65100FF", 1.5, wave(50, 260, 200, 10, 2, 10, 1.5, 1.5)),
    stroke("marker", "#00E5FFFF", 12.0, wave(50, 320, 220, 3, 1, 8, 12, 12)),
    stroke("pencil", "#555555FF", 1.8, wave(50, 380, 250, 12, 2, 12, 1.2, 2.4, 0.85)),
    stroke("pen", "#880E4FFF", 2.5, [[400.0, 120.0, 0, 2.5, 2.5, 1.0, 0.5, 0, 1.571],
                                     [420.0, 160.0, 0.1, 2.5, 2.5, 1.0, 0.5, 0, 1.571],
                                     [380.0, 200.0, 0.2, 2.5, 2.5, 1.0, 0.5, 0, 1.571]]),
    stroke("pen", "#000000FF", 2.5, wave(0, 0, 150, 12, 2, 12, 1.5, 3.0), [1, 0, 0, 1, 350, 440]),
    stroke("crayon", "#F57F17FF", 5.0, wave(50, 480, 220, 9, 2, 10, 3.5, 5.5)),
    stroke("pen", "#00000080", 2.5, wave(50, 540, 300, 8, 2, 12, 1.3, 3.1, 0.7)),
]

note = {
    "deleted": False,
    "meta": {
        "title": "Render sample (é & <test>)",
        "tags": ["fixture"],
        "notebook": None,
        "favorite": False,
        "created": "2026-10-04T12:00:00.000Z",
        "paper": {"kind": "ruled", "spacing": 24, "background": "#FFFFFFFF", "lineColor": "#D0D8E8FF"},
        "pageSize": {"width": 450, "height": 600, "infinite": False},
    },
    "pages": [page(1, p1), page(2, p2)],
    "tagSet": {"instances": [{"tag": "fixture", "origin": "17911296000000000-a1b2c3d4-1-0"}], "removed": []},
}
# Page 2 uses grid paper: paper is per-note in the model, so the test overrides
# meta.paper per page when rendering (see SVGGoldenTests).
print(json.dumps(note, indent=1, sort_keys=True))
