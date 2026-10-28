"""Handwriting and drawn shapes as Sempere strokes (format.md §5.6), for the demo vault.

Letters come from OFL handwriting fonts: each glyph is rasterized, thinned to its centerline
(scikit-image `skeletonize`) and traced into polylines, with the pen width at each point taken
from the distance to the glyph's edge, so the ink keeps the font's own thick and thin. A seeded
hand then adds what a person does: baseline drift, letter size and slant jitter, a little wobble.
Shapes (lines, arrows, ellipses, curves, highlighter swipes) are drawn with the same pen model.

Everything is seeded, so a rebuilt vault draws the same ink. Output strokes are plain dicts in
the `sempere pages draw` input form.
"""
from __future__ import annotations

import hashlib
import json
import math
import random
from pathlib import Path

import numpy as np
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from skimage.morphology import skeletonize

RASTER = 220  # glyph raster size in pixels per em
# Superscript letters the fonts lack, written as small raised letters.
SUPERSCRIPTS = {"ˣ": "x", "ᵘ": "u", "ⁿ": "n"}


def _rdp(pts, eps):
    """Ramer-Douglas-Peucker simplification of a polyline."""
    if len(pts) < 3:
        return pts
    a, b = np.array(pts[0]), np.array(pts[-1])
    ab = b - a
    n = np.hypot(*ab)
    arr = np.array(pts)
    if n == 0:
        d = np.hypot(*(arr - a).T)
    else:
        d = np.abs(ab[0] * (arr[:, 1] - a[1]) - ab[1] * (arr[:, 0] - a[0])) / n
    i = int(np.argmax(d))
    if d[i] > eps:
        return _rdp(pts[: i + 1], eps)[:-1] + _rdp(pts[i:], eps)
    return [pts[0], pts[-1]]


class GlyphTracer:
    """Centerline strokes of one font's glyphs, in em units (x right, y down, baseline at 0)."""

    def __init__(self, path: Path, cache_dir: Path):
        self.path = Path(path)
        self.font = ImageFont.truetype(str(path), RASTER)
        self.cmap = set(TTFont(str(path)).getBestCmap())
        digest = hashlib.sha256(self.path.read_bytes()).hexdigest()[:16]
        self.cache_file = cache_dir / f"glyphs-{self.path.stem}-{digest}-{RASTER}.json"
        self.cache = json.loads(self.cache_file.read_text()) if self.cache_file.exists() else {}
        self.dirty = False

    def save(self):
        if self.dirty:
            self.cache_file.parent.mkdir(parents=True, exist_ok=True)
            self.cache_file.write_text(json.dumps(self.cache))
            self.dirty = False

    def has(self, ch: str) -> bool:
        return ord(ch) in self.cmap

    def advance(self, text: str) -> float:
        return self.font.getlength(text) / RASTER

    def glyph(self, ch: str):
        if ch not in self.cache:
            self.cache[ch] = self._trace(ch)
            self.dirty = True
        return self.cache[ch]

    def _trace(self, ch: str):
        pad = RASTER // 2
        size = (RASTER * 2 + pad, RASTER * 2)
        img = Image.new("L", size, 0)
        ox, oy = pad // 2, int(RASTER * 1.3)  # baseline origin
        ImageDraw.Draw(img).text((ox, oy), ch, font=self.font, fill=255, anchor="ls")
        mask = np.array(img) > 110
        if not mask.any():
            return []
        mask = ndimage.binary_closing(mask, iterations=1)
        dist = ndimage.distance_transform_edt(mask)
        skel = skeletonize(mask)
        paths = _trace_skeleton(skel)
        # Thickness: typical half-width along the skeleton.
        out = []
        for path in paths:
            pts = [(x, y) for y, x in path]
            simple = _rdp(pts, 0.7)
            if len(simple) < 2 and len(pts) > 1:
                simple = [pts[0], pts[-1]]
            # Half-widths from the distance transform, sampled at the simplified points.
            stroke = [[(x - ox) / RASTER, (y - oy) / RASTER, float(dist[int(y), int(x)]) * 2 / RASTER] for x, y in simple]
            out.append(stroke)
        return _extend_tips(out)


def _neighbors(skel, y, x):
    h, w = skel.shape
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if (dy or dx) and 0 <= y + dy < h and 0 <= x + dx < w and skel[y + dy, x + dx]:
                yield (y + dy, x + dx)


def _trace_skeleton(skel):
    """Polylines (lists of (y, x)) along a one-pixel skeleton: edges between endpoints and
    junctions, short spurs pruned, edges through two-way junctions joined, loops kept."""
    pix = set(zip(*np.nonzero(skel)))
    nb = {p: list(_neighbors(skel, *p)) for p in pix}
    deg = {p: len(v) for p, v in nb.items()}
    nodes = {p for p in pix if deg[p] != 2}
    seen = set()
    edges = []
    for n in nodes:
        for m in nb[n]:
            if (n, m) in seen:
                continue
            path = [n, m]
            seen.add((n, m)); seen.add((m, n))
            prev, cur = n, m
            while cur not in nodes:
                nxt = [q for q in nb[cur] if q != prev and (cur, q) not in seen]
                if not nxt:
                    break
                q = nxt[0]
                seen.add((cur, q)); seen.add((q, cur))
                path.append(q)
                prev, cur = cur, q
            edges.append(path)
    # Loops with no node (an "o"): start anywhere on an unvisited pixel.
    for p in pix:
        if deg[p] == 2 and not any((p, q) in seen for q in nb[p]):
            path = [p]
            prev, cur = None, p
            while True:
                nxt = [q for q in nb[cur] if q != prev and (cur, q) not in seen]
                if not nxt:
                    break
                q = nxt[0]
                seen.add((cur, q)); seen.add((q, cur))
                path.append(q)
                prev, cur = cur, q
                if q == p:
                    break
            if len(path) > 3:
                edges.append(path)

    def length(e):
        return sum(math.hypot(e[i][0] - e[i - 1][0], e[i][1] - e[i - 1][1]) for i in range(1, len(e)))

    # Prune spurs: short edges from an endpoint to a junction.
    spur = RASTER * 0.045
    edges = [e for e in edges if not (len(e) > 1 and length(e) < spur and
                                      ((deg[e[0]] == 1 and deg[e[-1]] >= 3) or (deg[e[-1]] == 1 and deg[e[0]] >= 3)))]
    edges = [e for e in edges if length(e) >= 2 or len(edges) == 1]
    return _join_at_junctions(edges)


def _join_at_junctions(edges):
    """Join edges end to end where they meet, preferring the straightest continuation, so a
    letter is a few long strokes rather than many short ones."""
    def direction(e, at_start):
        k = min(len(e) - 1, 8)
        if at_start:
            a, b = e[k], e[0]
        else:
            a, b = e[-1 - k], e[-1]
        v = np.array(b, float) - np.array(a, float)
        n = np.hypot(*v)
        return v / n if n else v

    changed = True
    while changed:
        changed = False
        ends = {}
        for i, e in enumerate(edges):
            if e[0] == e[-1] and len(e) > 2:
                continue
            for at_start in (True, False):
                p = e[0] if at_start else e[-1]
                # Junction pixels differ by a pixel between edges: key on a 3 px cell.
                ends.setdefault((p[0] // 3, p[1] // 3), []).append((i, at_start))
        best = None
        for key, lst in ends.items():
            if len(lst) < 2:
                continue
            for a in range(len(lst)):
                for b in range(a + 1, len(lst)):
                    (i, si), (j, sj) = lst[a], lst[b]
                    if i == j:
                        continue
                    da, db = direction(edges[i], si), direction(edges[j], sj)
                    straight = -float(da @ db)  # 1 when they continue each other
                    if straight > 0.35 and (best is None or straight > best[0]):
                        best = (straight, i, si, j, sj)
        if best:
            _, i, si, j, sj = best
            a = edges[i][::-1] if si else edges[i]
            b = edges[j] if sj else edges[j][::-1]
            merged = a + b[1:]
            edges = [e for k, e in enumerate(edges) if k not in (i, j)] + [merged]
            changed = True
    return edges


def _extend_tips(strokes):
    """The centerline stops half a pen width short of each free end: extend those ends."""
    ends = []
    for s in strokes:
        ends.append(tuple(round(v, 3) for v in s[0][:2]))
        ends.append(tuple(round(v, 3) for v in s[-1][:2]))
    out = []
    for s in strokes:
        s = [list(p) for p in s]
        if len(s) >= 2 and s[0][:2] != s[-1][:2]:
            for at_start in (True, False):
                p, q = (s[0], s[1]) if at_start else (s[-1], s[-2])
                shared = sum(1 for e in ends if abs(e[0] - p[0]) < 0.02 and abs(e[1] - p[1]) < 0.02) > 1
                if shared:
                    continue
                v = np.array(p[:2]) - np.array(q[:2])
                n = np.hypot(*v)
                if n == 0:
                    continue
                ext = p[2] * 0.45
                tip = [p[0] + v[0] / n * ext, p[1] + v[1] / n * ext, p[2] * 0.7]
                if at_start:
                    s.insert(0, tip)
                else:
                    s.append(tip)
        out.append(s)
    return out


def _smooth(poly, passes=1):
    if len(poly) < 3:
        return poly
    for _ in range(passes):
        poly = [poly[0]] + [[(poly[i - 1][k] + 2 * poly[i][k] + poly[i + 1][k]) / 4 for k in range(len(poly[i]))]
                            for i in range(1, len(poly) - 1)] + [poly[-1]]
    return poly


def _resample(poly, step):
    """Points about `step` apart along a polyline of [x, y, w] (w interpolated)."""
    if len(poly) < 2:
        return poly
    out = [poly[0]]
    carry = 0.0
    for a, b in zip(poly, poly[1:]):
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        if seg == 0:
            continue
        d = step - carry
        while d <= seg:
            u = d / seg
            out.append([a[k] + (b[k] - a[k]) * u for k in range(3)])
            d += step
        carry = seg - (d - step)
    if math.hypot(out[-1][0] - poly[-1][0], out[-1][1] - poly[-1][1]) > step * 0.3:
        out.append(poly[-1])
    return out


def rgba(hex6: str, alpha: int = 255) -> str:
    return "#" + hex6.lstrip("#").upper() + f"{alpha:02X}"


class Hand:
    """A seeded writer: `text`, `paragraph` and shapes append strokes to `self.strokes`."""

    def __init__(self, fonts: dict[str, GlyphTracer], seed: int, page: int = 1, font: str = "caveat"):
        self.fonts = fonts
        self.font = font
        self.rand = random.Random(seed)
        self.strokes: list[dict] = []
        self.page = page
        self.clock = 0.0

    # -- the pen -------------------------------------------------------------------------
    def _emit(self, pts, color, width, tool="pen", opacity=1.0, wobble=0.0, step=2.0, taper=True, widths=None):
        """pts: [[x, y]] or [[x, y, w]] in page points."""
        poly = [list(p) + ([width] if len(p) == 2 else []) for p in pts]
        if widths is not None:
            poly = [[p[0], p[1], w] for p, w in zip(poly, widths)]
        poly = _resample(poly, step) if len(poly) > 1 else poly
        total = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(poly, poly[1:])) or 1
        phase = self.rand.random() * 6.28
        dist = 0.0
        out = []
        for i, p in enumerate(poly):
            if i:
                dist += math.hypot(p[0] - poly[i - 1][0], p[1] - poly[i - 1][1])
            wob = (math.sin(dist / 17 + phase) + 0.4 * math.sin(dist / 5.3 + 2 * phase)) * wobble
            edge = min(1.0, (dist + 1.5) / 6, (total - dist + 1.5) / 6) if taper else 1.0
            w = max(0.35, p[2] * (0.75 + 0.25 * edge))
            t = self.clock + dist / 260
            out.append([round(p[0] + wob * 0.5, 3), round(p[1] + wob, 3), round(t, 3), round(w, 3), round(w, 3),
                        opacity, round(0.25 + 0.5 * edge, 3), 0.6, 1.1])
        self.clock += total / 260 + 0.08
        self.strokes.append({"page": self.page, "ink": {"tool": tool, "color": color, "width": round(width, 3)},
                             "points": out})

    # -- writing ---------------------------------------------------------------------------
    # Characters the fonts lack, drawn as shapes: (width in em, drawing function).
    def _special(self, ch, x, y, size, color, weight):
        w = 1.6 * weight * size / 22
        if ch in "→←↔":
            a, b = (x + 0.08 * size, x + 0.82 * size)
            yy = y - 0.28 * size
            if ch == "←":
                a, b = b, a
            self.arrow(a, yy, b, yy, color, w, head=0.28 * size)
            if ch == "↔":
                self.arrow(b, yy, a, yy, color, w, head=0.28 * size)
            return 0.95
        if ch == "★":
            self.star(x + 0.4 * size, y - 0.32 * size, 0.36 * size, color, w)
            return 0.85
        if ch == "✓":
            self._emit([[x + 0.05 * size, y - 0.3 * size], [x + 0.3 * size, y - 0.02 * size],
                        [x + 0.8 * size, y - 0.75 * size]], color, w * 1.2, taper=False, step=1.5)
            return 0.9
        if ch == "∫":
            self.param(lambda t: [x + 0.3 * size + 0.12 * size * math.sin(t * 1.4) - 0.1 * size * t,
                                  y + 0.2 * size - 0.9 * size * (t + 1) / 2], -1, 1, 30, color, w)
            return 0.55
        if ch == "Δ":
            self.polyline([[x + 0.05 * size, y], [x + 0.32 * size, y - 0.62 * size], [x + 0.6 * size, y],
                           [x + 0.03 * size, y + 0.01 * size]], color, w, taper=False, wobble=0.1)
            return 0.7
        return None

    def text(self, s: str, x: float, y: float, size: float = 22, font: str | None = None, color: str = "#1E2A44FF",
             weight: float = 1.0, slant: float = 0.0, drift: float = 0.035, tool: str = "pen") -> float:
        """Writes `s` with its baseline starting at (x, y); `size` is the font size in points.
        Returns the width written."""
        name = font or self.font
        r = self.rand
        base_tilt = (r.random() - 0.5) * 0.012
        cx = x
        for ch in s:
            tracer = self.fonts[name]
            if not tracer.has(ch):
                tracer = next((t for t in self.fonts.values() if t.has(ch)), None)
            jy = (r.random() - 0.5) * 2 * drift * size + (cx - x) * base_tilt
            if ch.isspace():
                cx += self.fonts[name].advance(" ") * size
                continue
            if tracer is None and ch in SUPERSCRIPTS:
                cx += self.text(SUPERSCRIPTS[ch], cx, y + jy - 0.42 * size, size * 0.62, name, color, weight, slant,
                                drift, tool)
                continue
            if tracer is None:
                adv = self._special(ch, cx, y + jy, size, color, weight)
                if adv is None:
                    print(f"warning: no glyph for {ch!r}", flush=True)
                    adv = 0.5
                cx += adv * size
                continue
            sc = 1 + (r.random() - 0.5) * 0.07
            rot = (r.random() - 0.5) * 0.06
            cr, sr = math.cos(rot), math.sin(rot)
            for stroke in tracer.glyph(ch):
                pts = []
                for px, py, pw in stroke:
                    ex, ey = px * sc, py * sc
                    ex, ey = ex * cr - ey * sr, ex * sr + ey * cr
                    ex -= ey * slant
                    pts.append([cx + ex * size, y + jy + ey * size, max(0.45, pw * size * weight)])
                pts = _smooth(pts, 1)
                if len(pts) == 1:
                    p = pts[0]
                    pts = [p, [p[0] + 0.3, p[1] + 0.3, p[2]]]
                med = sorted(p[2] for p in pts)[len(pts) // 2]
                self._emit(pts, color, med, tool=tool, wobble=size / 260, step=max(1.2, size / 16), taper=False)
            cx += tracer.advance(ch) * size
        return cx - x

    def width(self, s: str, size: float, font: str | None = None) -> float:
        t = self.fonts[font or self.font]
        total = 0.0
        for ch in s:
            if t.has(ch) or ch.isspace():
                total += t.advance(ch)
            elif ch in SUPERSCRIPTS:
                total += t.advance(SUPERSCRIPTS[ch]) * 0.62
            else:
                alt = next((u for u in self.fonts.values() if u.has(ch)), None)
                total += alt.advance(ch) if alt else {"→": 0.95, "←": 0.95, "↔": 0.95, "★": 0.85, "✓": 0.9,
                                                      "∫": 0.55, "Δ": 0.7}.get(ch, 0.5)
        return total * size

    def paragraph(self, s: str, x: float, y: float, w: float, size: float = 20, leading: float = 1.45, **kw) -> float:
        """Wraps `s` into lines at most `w` wide; returns the baseline y after the last line."""
        for raw in s.split("\n"):
            line = ""
            for word in raw.split(" "):
                cand = (line + " " + word).strip()
                if line and self.width(cand, size, kw.get("font")) > w:
                    self.text(line, x, y, size, **kw)
                    y += size * leading
                    line = word
                else:
                    line = cand
            if line:
                self.text(line, x, y, size, **kw)
            y += size * leading
        return y

    # -- shapes ----------------------------------------------------------------------------
    def _j(self, a=1.0):
        return (self.rand.random() - 0.5) * 2 * a

    def line(self, x1, y1, x2, y2, color="#1E2A44FF", width=1.6, **kw):
        mx, my = (x1 + x2) / 2 + self._j(1.2), (y1 + y2) / 2 + self._j(1.2)
        self._emit(_smooth([[x1, y1], [mx, my], [x2, y2]] if True else [], 0), color, width, wobble=0.3, **kw)

    def polyline(self, pts, color="#1E2A44FF", width=1.6, **kw):
        self._emit(pts, color, width, wobble=kw.pop("wobble", 0.3), **kw)

    def arrow(self, x1, y1, x2, y2, color="#1E2A44FF", width=1.6, head=9):
        self.line(x1, y1, x2, y2, color, width)
        a = math.atan2(y2 - y1, x2 - x1)
        self._emit([[x2 - head * math.cos(a - 0.42), y2 - head * math.sin(a - 0.42)], [x2, y2],
                    [x2 - head * math.cos(a + 0.42), y2 - head * math.sin(a + 0.42)]], color, width, taper=False, step=1.5)

    def ellipse(self, cx, cy, rx, ry, color="#1E2A44FF", width=1.6, rot=0.0, start=None, turns=1.04, wobble=0.25,
                dashed=False, **kw):
        start = self.rand.uniform(-math.pi, math.pi) if start is None else start
        n = max(24, int((rx + ry) * turns * 1.2))
        pts = []
        cr, sr = math.cos(rot), math.sin(rot)
        for i in range(n + 1):
            a = start + turns * 2 * math.pi * i / n
            k = 1 + 0.012 * math.sin(3 * a + cx)
            ex, ey = math.cos(a) * rx * k, math.sin(a) * ry * k
            pts.append([cx + ex * cr - ey * sr, cy + ex * sr + ey * cr])
        if dashed:
            seg = max(3, n // 36)
            for i in range(0, n, seg * 2):
                self._emit(pts[i:i + seg + 1], color, width, wobble=0, taper=False, step=1.5, **kw)
        else:
            self._emit(pts, color, width, wobble=wobble, taper=False, **kw)

    def curve(self, f, x0, x1, color="#1E2A44FF", width=1.6, n=None, **kw):
        n = n or max(8, int(abs(x1 - x0) / 2.5))
        self._emit([[x0 + (x1 - x0) * i / n, f(x0 + (x1 - x0) * i / n)] for i in range(n + 1)], color, width,
                   wobble=kw.pop("wobble", 0.2), **kw)

    def param(self, f, t0, t1, n=120, color="#1E2A44FF", width=1.6, **kw):
        self._emit([f(t0 + (t1 - t0) * i / n) for i in range(n + 1)], color, width, wobble=kw.pop("wobble", 0.2), **kw)

    def rect(self, x, y, w, h, color="#1E2A44FF", width=1.6):
        j = self._j
        self._emit([[x + j(), y + j()], [x + w + j(), y + j()], [x + w + j(), y + h + j()], [x + j(), y + h + j()],
                    [x + j(1.5), y + j(1.5) - 1]], color, width, taper=False, wobble=0.25)

    def underline(self, x, y, w, color="#C23B3BFF", width=2.0):
        self._emit([[x + w * i / 24, y + math.sin(i / 3) * 1.3 + i / 24 * 1.6] for i in range(25)], color, width)

    def highlight(self, x, y, w, h=16, color="#FFD83D66"):
        self._emit([[x, y + h / 2], [x + w, y + h / 2 + self._j(1.5)]], color, h, tool="marker", taper=False, step=6,
                   wobble=0.15)

    def dot(self, x, y, r=2.2, color="#1E2A44FF"):
        self._emit([[x - r * 0.3, y], [x + r * 0.3, y + 0.2]], color, r * 2, taper=False, step=0.5)

    def star(self, cx, cy, r, color="#C23B3BFF", width=1.6):
        p = []
        for i in range(6):
            a = -math.pi / 2 + ((i * 2) % 5) * 2 * math.pi / 5
            p.append([cx + math.cos(a) * r, cy + math.sin(a) * r])
        self._emit(p, color, width, taper=False, step=1.5)

    def checkbox(self, x, y, s=13, checked=False, color="#2E7D4FFF"):
        self.rect(x, y, s, s, color, 1.4)
        if checked:
            self._emit([[x + 2, y + s * 0.5], [x + s * 0.42, y + s - 2], [x + s + 3, y - 4]], color, 2.0, taper=False,
                       step=1.5)
