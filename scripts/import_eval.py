# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "pillow>=10", "scipy>=1.13", "pypdfium2>=4.30"]
# ///
"""Import fidelity evaluation, stage 3: metrics, summary.json and report.html.

Reads what the two gated test stages wrote (see docs/import-notability.md,
"Fidelity evaluation"; run everything with scripts/import-eval.sh):

  <work>/oracle/<id8>/   thumbnails, our first-page renders, page1.pdf, meta.json,
                         and when the backup has Notability's PDF export of the
                         note: notability.pdf, ours-page-NNN.png, src-K.pdf, pages.json
  <work>/canvas/<id8>/   per band: canvas snapshot, PKDrawing image, export PNG

and writes <out>/summary.json, <out>/report.html (self-contained) and the
report's images under <out>/img/. Nothing here reads note titles or text;
notes are named by the first 8 hex digits of their vault id.

    uv run scripts/import_eval.py --work data/eval/work --out data/eval
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import math
import multiprocessing
import statistics
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

PAGE_WIDTH = 612.0  # imported pages are letter width in points

# Ink classification, applied identically to both images of every pair.
DARK_LUM = 170  # luminance below this is ink (Notability's dot paper is >= 181)
CHROMA = 60  # max-min RGB above this is coloured ink or highlighter
PDF_DIFF = 60  # PDF notes: RGB distance from the PDF page (best of a 5x5 neighbourhood)
PDF_NOISE_FRACTION = 0.01  # PDF notes: a thumbnail differing from our PDF render in < 1 % of pixels shows no ink
LOW_RES_CORRELATION = 0.6  # darkness correlation needed when only a low-resolution thumbnail is current

# Flag thresholds (see docs/import-notability.md for the reasoning).
ORACLE_CHAMFER_PT = 1.5  # symmetric mean chamfer distance, points
ORACLE_F1 = 0.80  # 1-pixel-tolerant F1 at the largest thumbnail
ORACLE_RATIO = (0.6, 1.6)  # ink pixel ratio ours / Notability
ORACLE_EDGE_PT = 6.0  # any ink bounding-box edge
CANVAS_F1 = 0.90  # 1-pixel-tolerant F1, canvas vs export, per band
CANVAS_RATIO = (0.75, 1.33)  # ink pixel ratio canvas / export, per band (as CanvasHostRenderingTests)
CANVAS_EDGE_PT = 3.0
MIN_INK_PX = 30  # bands/thumbnails with fewer ink pixels on both sides are "empty"
PDF_F1 = 0.85  # Notability PDF page vs our page, 1-pixel-tolerant F1 (worst inked page)
PDF_CHAMFER_PT = 1.0
PDF_RATIO = (0.7, 1.4)
PDF_EDGE_PT = 4.0
PAPER_RGB = (163, 183, 211)  # Notability's PDF export draws dot/line paper as one page-wide path in this colour


# ---------------------------------------------------------------- images

def load_rgba(path: Path) -> np.ndarray:
    im = Image.open(path)
    if im.mode in ("I;16", "I;16B", "I"):
        im = im.point(lambda v: v / 256).convert("L")
    return np.asarray(im.convert("RGBA")).astype(np.float32)


def over(fg: np.ndarray, bg: np.ndarray) -> np.ndarray:
    """RGBA `fg` composited over RGB `bg` (same size) -> RGB float."""
    a = fg[..., 3:4] / 255.0
    return fg[..., :3] * a + bg * (1 - a)


def white(h: int, w: int) -> np.ndarray:
    return np.full((h, w, 3), 255.0, np.float32)


def fit(img: np.ndarray, h: int, w: int, fill: float) -> np.ndarray:
    """Crops or pads (top-left anchored) to h x w."""
    out = np.full((h, w) + img.shape[2:], fill, img.dtype)
    hh, ww = min(h, img.shape[0]), min(w, img.shape[1])
    out[:hh, :ww] = img[:hh, :ww]
    return out


def ink_mask(rgb: np.ndarray) -> np.ndarray:
    lum = rgb[..., 0] * 0.3 + rgb[..., 1] * 0.59 + rgb[..., 2] * 0.11
    chroma = rgb.max(axis=2) - rgb.min(axis=2)
    return (lum < DARK_LUM) | (chroma > CHROMA)


def pdf_ink_mask(rgb: np.ndarray, bg: np.ndarray) -> np.ndarray:
    """Pixels that differ from the PDF page by more than PDF_DIFF, allowing the
    page a two-pixel misregistration (the smallest distance to any background
    pixel in the 5x5 neighbourhood counts): Notability's own rasterization of
    the page is offset by about a pixel from pdfium's."""
    best = np.full(rgb.shape[:2], np.inf, np.float32)
    pad = np.pad(bg, ((2, 2), (2, 2), (0, 0)), mode="edge")
    h, w = rgb.shape[:2]
    for dy in range(5):
        for dx in range(5):
            d = np.sqrt(((rgb - pad[dy:dy + h, dx:dx + w]) ** 2).sum(axis=2))
            best = np.minimum(best, d)
    return best > PDF_DIFF


def render_pdf_page(path: Path, page: int, w: int, h: int) -> np.ndarray | None:
    try:
        import pypdfium2 as pdfium
    except ImportError:
        return None
    try:
        doc = pdfium.PdfDocument(str(path))
        p = doc[max(page - 1, 0)]
        pw, ph = p.get_size()
        bm = p.render(scale=w / pw, fill_color=(255, 255, 255, 255))
        im = bm.to_pil().convert("RGB")
        # Notability lays the page out at the document width; height follows its aspect.
        im = im.resize((w, max(1, round(w * ph / pw))), Image.LANCZOS)
        arr = np.asarray(im).astype(np.float32)
        return fit(arr, h, w, 255.0)
    except Exception as e:  # a broken PDF is reported, not fatal
        print(f"warning: PDF render failed: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------- metrics

def compare(a: np.ndarray, b: np.ndarray, pt_per_px: float, search: int = 0) -> dict:
    """Metrics of mask `a` (ours / canvas) against `b` (reference)."""
    na, nb = int(a.sum()), int(b.sum())
    m: dict = {"inkA": na, "inkB": nb}
    if na < MIN_INK_PX and nb < MIN_INK_PX:
        m["empty"] = True
        return m
    m["ratio"] = na / nb if nb else math.inf
    inter = int((a & b).sum())
    union = int((a | b).sum())
    m["iou"] = inter / union if union else 1.0
    st = np.ones((3, 3), bool)
    da, db = ndimage.binary_dilation(a, st), ndimage.binary_dilation(b, st)
    prec = float((a & db).sum() / na) if na else 0.0
    rec = float((b & da).sum() / nb) if nb else 0.0
    m["precision1"], m["recall1"] = prec, rec
    m["f1"] = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    if na and nb:
        dtb = ndimage.distance_transform_edt(~b) * pt_per_px
        dta = ndimage.distance_transform_edt(~a) * pt_per_px
        ab, ba = dtb[a], dta[b]
        m["chamfer"] = float((ab.mean() + ba.mean()) / 2)
        m["chamferAB"], m["chamferBA"] = float(ab.mean()), float(ba.mean())
        m["chamfer95"] = float(max(np.percentile(ab, 95), np.percentile(ba, 95)))
        ya, xa = np.nonzero(a)
        yb, xb = np.nonzero(b)
        m["edges"] = [float((xa.min() - xb.min()) * pt_per_px), float((ya.min() - yb.min()) * pt_per_px),
                      float((xa.max() - xb.max()) * pt_per_px), float((ya.max() - yb.max()) * pt_per_px)]
    else:
        m["chamfer"] = math.inf
    if search and na and nb:
        best = (m["iou"], 0, 0)
        for dy in range(-search, search + 1):
            for dx in range(-search, search + 1):
                s = np.roll(np.roll(a, dy, 0), dx, 1)
                u = (s | b).sum()
                iou = (s & b).sum() / u if u else 0
                if iou > best[0] + 1e-9:
                    best = (float(iou), dx, dy)
        m["bestShiftIoU"], m["residualOffset"] = best[0], [best[1] * pt_per_px, best[2] * pt_per_px]
    return m


def clean(o):
    """JSON-safe: infinities and NaN become null."""
    if isinstance(o, float):
        return o if math.isfinite(o) else None
    if isinstance(o, dict):
        return {k: clean(v) for k, v in o.items()}
    if isinstance(o, list):
        return [clean(v) for v in o]
    return o


# ---------------------------------------------------------------- stage: oracle

def darkness(rgb: np.ndarray, bg: np.ndarray | None) -> np.ndarray:
    """Per-pixel ink strength: distance from the background (white or the PDF page)."""
    if bg is None:
        return 255 - (rgb[..., 0] * 0.3 + rgb[..., 1] * 0.59 + rgb[..., 2] * 0.11)
    return np.sqrt(((rgb - bg) ** 2).sum(axis=2))


def correlation(a: np.ndarray, b: np.ndarray) -> float | None:
    """Pearson correlation of two darkness maps, each blurred by one pixel
    (sub-pixel tolerance); meaningful at every thumbnail size."""
    a = ndimage.gaussian_filter(a, 1.0).ravel()
    b = ndimage.gaussian_filter(b, 1.0).ravel()
    if a.std() < 1e-6 or b.std() < 1e-6:
        return None
    return float(np.corrcoef(a, b)[0, 1])


LOW_RES = 288  # thumbnails narrower than this (thumb, 2x, 3x) are too coarse for mask metrics


def oracle_note(d: Path) -> tuple[dict, dict]:
    meta = json.loads((d / "meta.json").read_text())
    res: dict = {"thumbs": {}}
    pdf = meta.get("pdf")
    per_thumb_images: dict = {}
    for t in sorted(meta["thumbs"], key=lambda t: -t["width"]):
        name, w, h = t["name"], t["width"], t["height"]
        ours_path = d / ("ours-" + name)
        if not ours_path.exists():
            continue
        thumb_rgb = over(fit(load_rgba(d / name), h, w, 255.0), white(h, w))
        ours = fit(load_rgba(ours_path), h, w, 0.0)
        bg = None
        method = "paper"
        if pdf and (d / "page1.pdf").exists():
            bg = render_pdf_page(d / "page1.pdf", pdf.get("page", 1), w, h)
            if bg is None:
                method = "paper (PDF not rendered)"
        if bg is not None:
            method = "pdf-diff"
            ours_rgb = over(ours, bg)
            a, b = pdf_ink_mask(ours_rgb, bg), pdf_ink_mask(thumb_rgb, bg)
        else:
            ours_rgb = over(ours, white(h, w))
            a, b = ink_mask(ours_rgb), ink_mask(thumb_rgb)
        pt = PAGE_WIDTH / w
        m = compare(a, b, pt, search=4 if w >= LOW_RES else 0)
        m["method"], m["size"] = method, [w, h]
        m["darknessCorrelation"] = correlation(darkness(ours_rgb, bg), darkness(thumb_rgb, bg))
        m["inkFractionB"] = m["inkB"] / (w * h)
        res["thumbs"][name] = m
        per_thumb_images[name] = {"ours": ours_rgb, "thumb": thumb_rgb, "a": a, "b": b}
    names = list(res["thumbs"])  # largest first
    if not names:
        return meta, res | {"_images": {}}
    # The primary thumbnail is the largest one that shows ink, preferring
    # full-resolution ones: Notability leaves some sizes stale (blank paper)
    # while others are current.
    shows = [n for n in names if res["thumbs"][n]["inkB"] >= MIN_INK_PX]
    hires = [n for n in shows if res["thumbs"][n]["size"][0] >= LOW_RES]
    res["primary"] = (hires or shows or names)[0]
    res["lowResOnly"] = not hires and bool(shows)
    res["staleThumbs"] = [n for n in names if res["thumbs"][n]["inkB"] < MIN_INK_PX <= res["thumbs"][n]["inkA"]]
    return meta, res | {"_images": per_thumb_images[res["primary"]]}


# ---------------------------------------------------------------- stage: canvas

def canvas_note(d: Path) -> dict:
    info = json.loads((d / "bands.json").read_text())
    bands = []
    worst_img = None
    worst_key = None
    for band in info["bands"]:
        n = band["name"]
        ex = load_rgba(d / f"{n}-export.png")
        cv = load_rgba(d / f"{n}-canvas.png")
        pk = load_rgba(d / f"{n}-pk.png")
        h, w = min(ex.shape[0], cv.shape[0], pk.shape[0]), min(ex.shape[1], cv.shape[1], pk.shape[1])
        # The canvas snapshot's last pixel row can be the host background (a
        # fractional band height): drop it from every image.
        h -= 1
        ex_rgb = over(ex[:h, :w], white(h, w))
        cv_rgb = over(cv[:h, :w], white(h, w))
        pk_rgb = over(pk[:h, :w], white(h, w))
        e, c, p = ink_mask(ex_rgb), ink_mask(cv_rgb), ink_mask(pk_rgb)
        pt = PAGE_WIDTH / w
        m = {"band": band["band"], "page": band["page"],
             "canvasShift": band["canvasTop"] - band["top"],
             "canvas": compare(c, e, pt), "pk": compare(p, e, pt), "canvasVsPk": compare(c, p, pt)}
        bands.append(m)
        cm = m["canvas"]
        if not cm.get("empty"):
            key = cm.get("f1", 0)
            if worst_key is None or key < worst_key:
                worst_key = key
                worst_img = {"canvas": cv_rgb, "export": ex_rgb, "a": c, "b": e, "band": band["band"]}
    return {"bands": bands, "_images": worst_img}


# ---------------------------------------------------------------- stage: Notability's PDF export

def notability_page_without_ink(doc, index: int, width: int) -> np.ndarray:
    """Page `index` of Notability's PDF export with its ink removed: the
    export draws the page content (the source PDF page, re-embedded) first
    and the ink last, as filled paths, so the trailing run of path objects
    is dropped (ink is filled, never stroked: a stroked path there belongs
    to the page). Rendering this and the full page with the same renderer
    and fonts makes their difference exactly the ink."""
    import ctypes
    import pypdfium2.raw as raw
    page = doc[index]
    pw, _ = page.get_size()
    objs = list(page.get_objects(max_depth=1))

    def is_ink(obj) -> bool:
        if obj.type != 2:
            return False
        mode, stroke = ctypes.c_int(), ctypes.c_int()
        raw.FPDFPath_GetDrawMode(obj, mode, stroke)
        return mode.value != 0 and not stroke.value

    k = len(objs)
    while k > 0 and is_ink(objs[k - 1]):
        k -= 1
    for obj in objs[k:]:
        page.remove_obj(obj)
    page.gen_content()
    bm = page.render(scale=width / pw, fill_color=(255, 255, 255, 255))
    return np.asarray(bm.to_pil().convert("RGB")).astype(np.float32)


def notability_page(doc, index: int, width: int, strip_paper: bool) -> tuple[np.ndarray, float]:
    """Page `index` of Notability's own PDF export at `width` pixels, and its
    height/width. With `strip_paper` the page-wide paper path (PAPER_RGB),
    the white background image tiles and the invisible OCR text are removed
    first, so only ink (and any images we do not import) is left."""
    import ctypes
    import pypdfium2.raw as raw
    page = doc[index]
    pw, ph = page.get_size()
    if strip_paper:
        for obj in list(page.get_objects(max_depth=1)):
            kill = obj.type in (1, 3)  # text (invisible handwriting OCR), images (white paper tiles)
            if obj.type == 2:
                r, g, b, a = (ctypes.c_uint() for _ in range(4))
                fill = (r.value, g.value, b.value) if raw.FPDFPageObj_GetFillColor(obj, r, g, b, a) else None
                lb, bb, rb, tb = (ctypes.c_float() for _ in range(4))
                raw.FPDFPageObj_GetBounds(obj, lb, bb, rb, tb)
                kill = fill == PAPER_RGB and rb.value - lb.value > 0.8 * pw and tb.value - bb.value > 0.8 * ph
            if kill:
                page.remove_obj(obj)
        page.gen_content()
    bm = page.render(scale=width / pw, fill_color=(255, 255, 255, 255))
    arr = np.asarray(bm.to_pil().convert("RGB")).astype(np.float32)
    return arr, ph / pw


SPECK_PX = 8  # connected difference blobs smaller than this are rasterization noise, not ink


def despeckle(mask: np.ndarray) -> np.ndarray:
    labels, n = ndimage.label(mask, structure=np.ones((3, 3), bool))
    if n == 0:
        return mask
    sizes = np.bincount(labels.ravel())
    keep = sizes >= SPECK_PX
    keep[0] = False
    return keep[labels]


def pdf_pages_note(d: Path, img_dir: Path) -> dict | None:
    """Every page of Notability's PDF export against our export page of the
    same number (one `breakHeight` each): paper pages with the paper removed
    from Notability's page and ink masks on both; pages on a PDF with both
    composited on the source PDF page and the difference masks."""
    if not (d / "notability.pdf").exists() or not (d / "pages.json").exists():
        return None
    import pypdfium2 as pdfium
    info = json.loads((d / "pages.json").read_text())
    layout = info.get("pdfLayout") or []
    ours_pages = sorted(d.glob("ours-page-*.png"))
    try:
        doc = pdfium.PdfDocument(str(d / "notability.pdf"))
    except Exception as e:
        return {"error": f"cannot open Notability PDF: {e}"}
    n_theirs, n_ours = len(doc), len(ours_pages)
    pages = []
    worst = None
    pt = None
    for i in range(max(n_theirs, n_ours)):
        ours = load_rgba(ours_pages[i]) if i < n_ours else None
        w = ours.shape[1] if ours is not None else (load_rgba(ours_pages[0]).shape[1] if ours_pages else 918)
        pt = PAGE_WIDTH / w
        on_pdf = i < len(layout) and layout[i] is not None
        if i < n_theirs:
            theirs, aspect = notability_page(doc, i, w, strip_paper=not on_pdf)
        else:
            theirs, aspect = None, None
        h = ours.shape[0] if ours is not None else theirs.shape[0]
        theirs = fit(theirs, h, w, 255.0) if theirs is not None else white(h, w)
        ours = fit(ours, h, w, 0.0) if ours is not None else np.zeros((h, w, 4), np.float32)
        bg = src = None
        if on_pdf:
            k, src_page = layout[i]
            src = render_pdf_page(d / f"src-{k}.pdf", src_page, w, h)
        if on_pdf and i < n_theirs:
            # The page under the ink as Notability exported it (same fonts and
            # renderer as its full page); see notability_page_without_ink.
            bg = fit(notability_page_without_ink(pdfium.PdfDocument(str(d / "notability.pdf")), i, w), h, w, 255.0)
        elif on_pdf:
            bg = src
        if bg is not None:
            ours_rgb = over(ours, bg)
            a = despeckle(pdf_ink_mask(ours_rgb, bg))
            b = pdf_ink_mask(theirs, bg)
            if src is not None and bg is not src:
                # Trailing filled shapes of the PDF page (slide arrows) are
                # stripped with the ink; the source PDF has them, so Notability
                # ink must differ from both. Font rasterization differences
                # against the source only appear in one of the two.
                b &= pdf_ink_mask(theirs, src)
            b = despeckle(b)
            method = "pdf-diff"
        else:
            ours_rgb = over(ours, white(h, w))
            a, b = ink_mask(ours_rgb), ink_mask(theirs)
            method = "paper-stripped" if not on_pdf else "pdf (source not rendered)"
        m = compare(a, b, pt)
        m.update({"page": i + 1, "method": method, "onPDF": on_pdf, "missingTheirs": i >= n_theirs,
                  "missingOurs": i >= n_ours})
        if aspect is not None and n_ours:
            m["heightDeltaPt"] = (aspect * PAGE_WIDTH) - h * pt
        pages.append(m)
        if not m.get("empty"):
            key = m.get("f1", 0)
            if worst is None or key < worst[0]:
                worst = (key, i + 1, ours_rgb, theirs, a, b)
    inked = [p for p in pages if not p.get("empty")]
    res = {"pagesTheirs": n_theirs, "pagesOurs": n_ours, "pages": pages, "inkedPages": len(inked),
           # Paper pages inserted into a note made from a PDF: pages of two heights.
           "mixedPageSizes": any(x is None for x in layout) and any(x is not None for x in layout)}
    if inked:
        f1 = [p.get("f1", 0) for p in inked]
        res.update({
            "f1Min": min(f1), "f1Median": statistics.median(f1),
            "chamferMax": max((p.get("chamfer") or 0) for p in inked),
            "chamferMedian": statistics.median([(p.get("chamfer") or 0) for p in inked]),
            "ratioMin": min(p.get("ratio", 0) for p in inked), "ratioMax": max(p.get("ratio", 0) for p in inked),
            "maxEdge": max((max((abs(e) for e in p.get("edges", [])), default=0) for p in inked), default=0),
        })
    if worst is not None:
        _, page, o, t, a, b = worst
        res["worstPage"] = page
        files = []
        for k, (cap, arr) in enumerate([(f"ours (SempereRender), page {page}", o), (f"Notability PDF, page {page}", t),
                                         ("overlay of ink masks", overlay(a, b))]):
            f = img_dir / f"{d.name}-pdf-{k}.png"
            Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(f)
            files.append((cap, f.name))
        res["_files"] = files
    return res


def pdf_flags(p: dict) -> list[str]:
    if p is None:
        return []
    if p.get("error"):
        return ["pdf-unreadable"]
    flags = []
    for page in p["pages"]:
        if page.get("empty"):
            continue
        if page["missingTheirs"]:
            flags.append("pdf-ink-beyond-last-page")
        elif page["missingOurs"] or page.get("inkA", 0) < MIN_INK_PX:
            flags.append("pdf-content-not-imported")
    if p.get("inkedPages"):
        if p["f1Min"] < PDF_F1:
            flags.append("pdf-f1")
        if p["chamferMax"] > PDF_CHAMFER_PT:
            flags.append("pdf-chamfer")
        if not (PDF_RATIO[0] <= p["ratioMin"] and p["ratioMax"] <= PDF_RATIO[1]):
            flags.append("pdf-ratio")
        if p["maxEdge"] > PDF_EDGE_PT:
            flags.append("pdf-bbox")
    return sorted(set(flags))


# ---------------------------------------------------------------- flags

def oracle_flags(meta: dict, res: dict) -> list[str]:
    """Flags for the oracle comparison. Content the importer cannot carry is
    flagged by kind (`has-media`, `pdf-template`) so outliers explain
    themselves; geometry flags are `oracle-*`."""
    flags = []
    if meta.get("media"):
        flags.append("has-media")
    if (meta.get("paperIdentifier") or "").startswith("TemplatePDF"):
        flags.append("pdf-template")
    if not res["thumbs"]:
        return flags + ["no-thumbnail"]
    m = res["thumbs"][res["primary"]]
    if res.get("staleThumbs"):
        flags.append("stale-thumbnails")
    if m["inkB"] < MIN_INK_PX and m["inkA"] < MIN_INK_PX:
        return flags  # nothing on page 1 on either side: consistent
    if m["inkB"] < MIN_INK_PX:
        return flags + ["thumbnails-all-blank"]  # every thumbnail stale
    if m["inkA"] < MIN_INK_PX:
        # Notability shows something on page 1 that we have no ink for.
        if meta["strokesOnPage1"] == 0 and m["inkFractionB"] < PDF_NOISE_FRACTION and m["method"] == "pdf-diff":
            return flags  # PDF rasterization noise only
        return flags + ["thumbnail-content-not-imported"]
    if res.get("lowResOnly"):
        flags.append("low-res-thumbnail-only")
        c = m.get("darknessCorrelation")
        if c is None or c < LOW_RES_CORRELATION:
            flags.append("oracle-correlation")
        return flags
    if (m.get("chamfer") or math.inf) > ORACLE_CHAMFER_PT:
        flags.append("oracle-chamfer")
    if m.get("f1", 0) < ORACLE_F1:
        flags.append("oracle-f1")
    r = m.get("ratio", 0)
    if not (ORACLE_RATIO[0] <= r <= ORACLE_RATIO[1]):
        flags.append("oracle-ratio")
    if any(abs(e) > ORACLE_EDGE_PT for e in m.get("edges", [])):
        flags.append("oracle-bbox")
    return flags


INFO_FLAGS = {"stale-thumbnails", "has-media", "pdf-template", "low-res-thumbnail-only"}  # context, not failures


def categorize(row: dict, flags: list[str]) -> str:
    """A first guess at the root cause of a flagged note, from its flags and
    content; the report's investigation section confirms or corrects it."""
    failing = [f for f in flags if f not in INFO_FLAGS]
    if not failing:
        return ""
    if any(f.startswith("canvas-") for f in failing):
        return "canvas conversion"
    pdf = row.get("pdf") or {}
    if any(f.startswith("pdf-") for f in failing):
        bad = [p for p in pdf.get("pages", []) if not p.get("empty")
               and (p.get("f1", 0) < PDF_F1 or (p.get("chamfer") or 0) > PDF_CHAMFER_PT
                    or not PDF_RATIO[0] <= p.get("ratio", 0) <= PDF_RATIO[1])]
        if pdf.get("mixedPageSizes"):
            return "format limit: paper pages inserted in a PDF note (one breakHeight; ink placed right)"
        if bad and all(max(p.get("inkA", 0), p.get("inkB", 0)) < 64 for p in bad):
            return "measurement: PDF rasterization specks"
        if "has-media" in flags:
            return "unsupported: images"
        if row.get("markers") and bad and all(p.get("f1", 0) >= 0.9 and p.get("ratio", 0) > 1 for p in bad):
            # Notability draws highlighters behind the PDF's text; we draw on top.
            return "measurement: highlighter over PDF text"
        return "importer geometry (suspected, PDF)"
    if "thumbnails-all-blank" in failing:
        return "stale thumbnail"
    if "thumbnail-content-not-imported" in failing and row["pdfPages"] and (
            row["strokesOnPage1"] == 0 or (row.get("oracle") or {}).get("method") == "pdf-diff"):
        return "PDF page raster differs (no ink on page 1)"
    o = row.get("oracle") or {}
    if set(failing) <= {"oracle-bbox"} and (o.get("f1") or 0) >= 0.95 and (o.get("chamfer") or 9) <= 0.5:
        # Shapes agree; one faint stroke end sits on either side of the mask threshold.
        return "measurement: faint ink at the mask threshold"
    if "has-media" in flags:
        return "unsupported: images"
    if row.get("typedChars"):
        return "unsupported: typed text"
    if row.get("bundle") and row.get("pdfs") and not row["pdfPages"]:
        return "unsupported: PDF pages of an .ntb (the PDF is not in the bundle)"
    if o.get("method") == "pdf-diff" and (o.get("precision1") or 0) >= 0.95:
        # All our ink is on the thumbnail; the rest is the PDF page, which
        # Notability rasterized differently from pdfium.
        return "measurement: thumbnail's PDF raster differs"
    if "pdf-template" in flags:
        return "unsupported: PDF template paper"
    if "stale-thumbnails" in flags or "low-res-thumbnail-only" in failing:
        return "stale thumbnail (suspected)"
    return "importer geometry (suspected)"


def canvas_flags(c: dict) -> list[str]:
    flags = set()
    for b in c["bands"]:
        m = b["canvas"]
        if m.get("empty"):
            continue
        if m.get("f1", 0) < CANVAS_F1:
            flags.add("canvas-f1")
        r = m.get("ratio", 0)
        if not (CANVAS_RATIO[0] <= r <= CANVAS_RATIO[1]):
            flags.add("canvas-ratio")
        if any(abs(e) > CANVAS_EDGE_PT for e in m.get("edges", [])):
            flags.add("canvas-bbox")
        if abs(b["canvasShift"]) > 0.5:
            flags.add("canvas-scroll")
    return sorted(flags)


# ---------------------------------------------------------------- report

def png_data_uri(rgb: np.ndarray, max_w: int = 420) -> str:
    im = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))
    if im.width > max_w:
        im = im.resize((max_w, max(1, round(im.height * max_w / im.width))), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def overlay(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Ours/canvas only: red; reference only: blue; both: black."""
    out = white(*a.shape)
    out[a & ~b] = (220, 40, 40)
    out[b & ~a] = (40, 90, 230)
    out[a & b] = (20, 20, 20)
    return out


def fmt(v, nd=2):
    if v is None:
        return "–"
    if isinstance(v, float):
        if not math.isfinite(v):
            return "∞"
        return f"{v:.{nd}f}"
    return str(v)


def pct(values, q):
    v = sorted(x for x in values if x is not None and math.isfinite(x))
    if not v:
        return None
    k = (len(v) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def dist(values) -> dict:
    v = [x for x in values if x is not None and math.isfinite(x)]
    if not v:
        return {"n": 0}
    return {"n": len(v), "min": min(v), "p10": pct(v, 0.1), "median": statistics.median(v), "mean": statistics.fmean(v),
            "p90": pct(v, 0.9), "max": max(v)}


def histogram(values, edges) -> list[int]:
    v = [x for x in values if x is not None and math.isfinite(x)]
    counts = [0] * (len(edges) - 1)
    for x in v:
        for i in range(len(edges) - 1):
            if edges[i] <= x < edges[i + 1] or (i == len(edges) - 2 and x == edges[-1]):
                counts[i] += 1
                break
    return counts


CSS = """
:root{--bg:#fbfbfa;--fg:#1d1d1f;--mut:#6b6b70;--line:#e2e2e0;--bad:#b3261e;--warn:#9a6700;--ok:#1a7f37;--card:#fff}
@media (prefers-color-scheme: dark){:root{--bg:#161618;--fg:#ececee;--mut:#9b9ba0;--line:#2c2c30;--bad:#ff8a80;--warn:#e3b341;--ok:#56d364;--card:#1f1f22}}
body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:1280px;margin:auto}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}p,li{color:var(--fg)}.mut{color:var(--mut)}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums;font-size:12.5px}
th,td{border-bottom:1px solid var(--line);padding:4px 6px;text-align:right;white-space:nowrap}th{position:sticky;top:0;background:var(--bg)}
td:first-child,th:first-child,td.l,th.l{text-align:left}.bad{color:var(--bad);font-weight:600}.warn{color:var(--warn)}
.wrap{overflow-x:auto}.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin:12px 0}
.imgs{display:flex;gap:8px;flex-wrap:wrap}.imgs figure{margin:0}.imgs img{border:1px solid var(--line);background:#fff;max-width:100%;image-rendering:auto}
figcaption{font-size:11.5px;color:var(--mut)}code{font-size:12px}.kv{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:6px 18px}
"""


def write_report(out: Path, summary: dict, rows: list[dict], gallery: list[dict]) -> None:
    agg = summary["aggregate"]
    th = summary["thresholds"]
    h = ["<!doctype html><html lang=en><head><meta charset=utf-8>",
         "<meta name=viewport content='width=device-width,initial-scale=1'>",
         "<title>Import fidelity</title><style>", CSS, "</style></head><body>",
         "<h1>Notability import fidelity</h1>",
         f"<p class=mut>{summary['generated']} · {agg['notes']} imported notes · {agg['bands']} canvas bands. "
         "Local report: notes are named by the first 8 hex digits of their vault id.</p>"]
    h.append("<h2>Aggregate</h2><div class='card kv'>")
    for k, v in agg["display"].items():
        h.append(f"<div><span class=mut>{k}</span><br><b>{v}</b></div>")
    h.append("</div>")
    h.append("<h2>Root-cause categories (flagged notes)</h2><div class=card><ul>")
    for k, v in agg["categories"].items():
        h.append(f"<li>{k}: {v}</li>")
    h.append("</ul></div>")
    h.append("<h2>Flags</h2><div class=card><ul>")
    for k, v in sorted(agg["flagCounts"].items(), key=lambda kv: -kv[1]):
        h.append(f"<li><code>{k}</code>: {v}</li>")
    h.append("</ul><p class=mut>Thresholds: " + ", ".join(f"{k} {v}" for k, v in th.items()) + "</p></div>")
    if agg.get("histograms"):
        h.append("<h2>Distributions</h2><div class=card>")
        for name, hist in agg["histograms"].items():
            h.append(f"<p><b>{name}</b><br><code>")
            for label, n in hist:
                h.append(f"{label}: {'█' * n} {n}<br>")
            h.append("</code></p>")
        h.append("</div>")
    h.append("<h2>Per note (worst first)</h2><div class=wrap><table><tr>"
             "<th class=l>note</th><th>pages</th><th>strokes</th><th>PDF</th>"
             "<th>N.pdf pages</th><th>N.pdf F1 min</th><th>N.pdf F1 med</th><th>N.pdf chamfer max</th>"
             "<th>thumb</th><th>method</th>"
             "<th>IoU</th><th>F1±1px</th><th>chamfer pt</th><th>ratio</th><th>max edge pt</th><th>offset pt</th>"
             "<th>canvas F1 min</th><th>canvas F1 med</th><th>canvas IoU min</th><th>canvas IoU med</th>"
             "<th>canvas ratio range</th><th class=l>category</th><th class=l>flags</th></tr>")
    for r in rows:
        o = r.get("oracle") or {}
        c = r.get("canvasSummary") or {}
        cls = "bad" if r["failing"] else ""
        off = o.get("residualOffset")
        h.append(
            f"<tr><td><a href='#n{r['id8']}'>{r['id8']}</a></td><td>{r['bands']}</td><td>{r['strokes']}</td>"
            f"<td>{r['pdfPages'] or ''}</td>"
            f"<td>{(r.get('pdf') or {}).get('pagesTheirs', '–')}</td><td>{fmt((r.get('pdf') or {}).get('f1Min'))}</td>"
            f"<td>{fmt((r.get('pdf') or {}).get('f1Median'))}</td><td>{fmt((r.get('pdf') or {}).get('chamferMax'))}</td>"
            f"<td>{o.get('thumb', '–')}</td><td class=l>{o.get('method', '')}</td>"
            f"<td>{fmt(o.get('iou'))}</td><td>{fmt(o.get('f1'))}</td><td>{fmt(o.get('chamfer'))}</td>"
            f"<td>{fmt(o.get('ratio'))}</td><td>{fmt(o.get('maxEdge'), 1)}</td>"
            f"<td>{fmt(off[0], 1) + ', ' + fmt(off[1], 1) if off else '–'}</td>"
            f"<td>{fmt(c.get('f1Min'))}</td><td>{fmt(c.get('f1Median'))}</td>"
            f"<td>{fmt(c.get('iouMin'))}</td><td>{fmt(c.get('iouMedian'))}</td>"
            f"<td>{fmt(c.get('ratioMin'))}–{fmt(c.get('ratioMax'))}</td>"
            f"<td class='l {cls}'>{r['category']}</td><td class=l>{' '.join(r['flags'])}</td></tr>")
    h.append("</table></div>")
    h.append("<h2>Images: worst and flagged notes</h2><p class=mut>Overlay: red = ours / canvas only, "
             "blue = Notability / export only, black = both.</p>")
    for g in gallery:
        h.append(f"<div class=card id='n{g['id8']}'><b>{g['id8']}</b> <span class=mut>{' '.join(g['flags'])}</span>")
        for title, figs in g["sets"]:
            h.append(f"<p class=mut>{title}</p><div class=imgs>")
            for cap, uri in figs:
                h.append(f"<figure><img src='{uri}' alt='{cap}'><figcaption>{cap}</figcaption></figure>")
            h.append("</div>")
        h.append("</div>")
    h.append("</body></html>")
    (out / "report.html").write_text("".join(h))


# ---------------------------------------------------------------- main

def save_set(img_dir: Path, name: str, figs: list) -> list:
    out = []
    for k, (cap, arr) in enumerate(figs):
        f = img_dir / f"{name}-{k}.png"
        Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(f)
        out.append((cap, f.name))
    return out


def process_note(job) -> dict:
    """All metrics of one note (oracle, Notability PDF pages, canvas); images
    for the report are written to `img_dir` and listed in `_sets`."""
    d, canvas_dir, img_dir = job
    id8 = d.name
    meta, ores = oracle_note(d)
    oimg = ores.pop("_images")
    row = {"id8": id8, "strokes": meta["strokes"], "markers": meta["markers"], "dashed": meta["dashed"],
           "pdfPages": meta["pdfPages"], "media": meta["media"], "bands": meta["bands"],
           "strokesOnPage1": meta["strokesOnPage1"], "formatVersion": meta["formatVersion"],
           "documentWidth": meta["documentWidth"], "oracleThumbs": ores["thumbs"], "_sets": [],
           "typedChars": meta.get("typedChars", 0), "pdfs": meta.get("pdfs", 0),
           "bundle": any(t["name"] == "thumbnail.png" for t in meta["thumbs"])}
    flags = oracle_flags(meta, ores)
    if ores["thumbs"]:
        name = ores["primary"]
        m = ores["thumbs"][name]
        row["staleThumbs"] = ores["staleThumbs"]
        row["oracle"] = {"thumb": name, "method": m.get("method"), "iou": m.get("iou"), "f1": m.get("f1"),
                         "chamfer": m.get("chamfer"), "chamfer95": m.get("chamfer95"), "ratio": m.get("ratio"),
                         "edges": m.get("edges"), "maxEdge": max((abs(e) for e in m.get("edges", [])), default=None),
                         "residualOffset": m.get("residualOffset"), "bestShiftIoU": m.get("bestShiftIoU"),
                         "precision1": m.get("precision1"), "recall1": m.get("recall1"),
                         "empty": m.get("empty", False), "lowResOnly": ores.get("lowResOnly", False),
                         "darknessCorrelation": m.get("darknessCorrelation")}
    if oimg:
        row["_sets"].append(("Import vs Notability thumbnail (page 1)", save_set(img_dir, f"{id8}-oracle", [
            ("ours (SempereRender, page 1)", oimg["ours"]), ("Notability thumbnail", oimg["thumb"]),
            ("overlay of ink masks", overlay(oimg["a"], oimg["b"]))])))
    pdf = pdf_pages_note(d, img_dir)
    if pdf is not None:
        files = pdf.pop("_files", None)
        row["pdf"] = pdf
        if not pdf.get("error"):
            # Notability's PDF shows every page as it is now; the thumbnails
            # only page 1, often stale. Thumbnail flags become context.
            row["oracleFlags"] = flags
            flags = [f for f in flags if f in INFO_FLAGS]
        flags += pdf_flags(pdf)
        if files:
            row["_sets"].insert(0, (f"Import vs Notability's PDF export (worst page, {pdf.get('worstPage')})", files))
    if (canvas_dir / id8 / "bands.json").exists():
        c = canvas_note(canvas_dir / id8)
        cimg = c.pop("_images")
        row["canvasBands"] = c["bands"]
        inked = [m["canvas"] for m in c["bands"] if not m["canvas"].get("empty")]
        pk = [m["pk"] for m in c["bands"] if not m["pk"].get("empty")]
        row["canvasSummary"] = {
            "bands": len(c["bands"]), "inkedBands": len(inked),
            "iouMin": min((m["iou"] for m in inked), default=None),
            "iouMedian": statistics.median([m["iou"] for m in inked]) if inked else None,
            "f1Min": min((m["f1"] for m in inked), default=None),
            "f1Median": statistics.median([m["f1"] for m in inked]) if inked else None,
            "ratioMin": min((m["ratio"] for m in inked), default=None),
            "ratioMax": max((m["ratio"] for m in inked), default=None),
            "chamferMax": max((m.get("chamfer", 0) for m in inked), default=None),
            "pkF1Min": min((m["f1"] for m in pk), default=None),
        }
        flags += canvas_flags(c)
        if cimg:
            row["_sets"].append(("Canvas vs export (worst band)", save_set(img_dir, f"{id8}-canvas", [
                (f"canvas, band {cimg['band']}", cimg["canvas"]), ("export (SempereRender)", cimg["export"]),
                ("overlay of ink masks", overlay(cimg["a"], cimg["b"]))])))
    elif canvas_dir.is_dir():  # the canvas stage ran but skipped this note
        flags.append("canvas-missing")
    row["flags"] = flags
    # Worst-first: flagged notes, then by the lowest of PDF, oracle and canvas F1.
    of1 = (row.get("oracle") or {}).get("f1")
    pf1 = (row.get("pdf") or {}).get("f1Min")
    cf1 = (row.get("canvasSummary") or {}).get("f1Min")
    score = min([v for v in (pf1, of1, cf1) if v is not None] or [1.0])
    row["failing"] = [f for f in flags if f not in INFO_FLAGS]
    row["category"] = categorize(row, flags)
    row["_score"] = (0 if row["failing"] else 1, score)
    return clean(row)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--gallery", type=int, default=20, help="worst notes to show images for (plus every flagged one)")
    ap.add_argument("--jobs", type=int, default=0, help="worker processes (default: one per CPU)")
    args = ap.parse_args()
    oracle_dir, canvas_dir = args.work / "oracle", args.work / "canvas"
    if not oracle_dir.is_dir():
        print(f"no {oracle_dir}: run the oracle stage first", file=sys.stderr)
        return 2
    import_report = json.loads((args.work / "import.json").read_text()) if (args.work / "import.json").exists() else {}

    img_dir = args.out / "img"
    img_dir.mkdir(parents=True, exist_ok=True)
    notes = sorted(p for p in oracle_dir.iterdir() if (p / "meta.json").exists())
    jobs = [(d, canvas_dir, img_dir) for d in notes]
    rows = []
    with multiprocessing.Pool(args.jobs or None) as pool:
        for i, row in enumerate(pool.imap_unordered(process_note, jobs, chunksize=1)):
            rows.append(row)
            print(f"[{i + 1}/{len(notes)}] {row['id8']} {' '.join(row['flags'])}", file=sys.stderr)

    rows.sort(key=lambda r: r["_score"])
    for r in rows:
        r.pop("_score")

    # Aggregates over notes with ink on both sides of the oracle.
    def has_ink_both(r):
        m = r["oracleThumbs"].get(r["oracle"]["thumb"], {})
        return m.get("inkA", 0) >= MIN_INK_PX and m.get("inkB", 0) >= MIN_INK_PX

    scored = [r for r in rows if r.get("oracle") and has_ink_both(r) and not r["oracle"]["lowResOnly"]]
    paper = [r for r in scored if not r["pdfPages"]]
    pdfs = [r for r in scored if r["pdfPages"]]
    bands = [b for r in rows for b in r.get("canvasBands", [])]
    inked_bands = [b["canvas"] for b in bands if not b["canvas"].get("empty")]
    pdf_rows = [r for r in rows if r.get("pdf") and r["pdf"].get("inkedPages")]
    pdf_pages = [p for r in pdf_rows for p in r["pdf"]["pages"] if not p.get("empty") and p.get("f1") is not None]
    flag_counts: dict[str, int] = {}
    for r in rows:
        for f in r["flags"]:
            flag_counts[f] = flag_counts.get(f, 0) + 1
    agg = {
        "notes": len(rows), "import": import_report, "oracleScored": len(scored),
        "oracleScoredPaper": len(paper), "oracleScoredPDF": len(pdfs),
        "oracleIoU": dist([r["oracle"]["iou"] for r in scored]),
        "oracleF1": dist([r["oracle"]["f1"] for r in scored]),
        "oracleChamfer": dist([r["oracle"]["chamfer"] for r in scored]),
        "oracleRatio": dist([r["oracle"]["ratio"] for r in scored]),
        "oracleMaxEdge": dist([r["oracle"]["maxEdge"] for r in scored]),
        "oracleF1Paper": dist([r["oracle"]["f1"] for r in paper]),
        "oracleF1PDF": dist([r["oracle"]["f1"] for r in pdfs]),
        "oracleChamferPaper": dist([r["oracle"]["chamfer"] for r in paper]),
        "oracleChamferPDF": dist([r["oracle"]["chamfer"] for r in pdfs]),
        "bands": len(bands), "inkedBands": len(inked_bands),
        "canvasIoU": dist([m["iou"] for m in inked_bands]),
        "canvasF1": dist([m["f1"] for m in inked_bands]),
        "canvasRatio": dist([m["ratio"] for m in inked_bands]),
        "canvasChamfer": dist([m.get("chamfer") for m in inked_bands]),
        "pkF1": dist([b["pk"]["f1"] for b in bands if not b["pk"].get("empty")]),
        "canvasVsPkF1": dist([b["canvasVsPk"]["f1"] for b in bands if not b["canvasVsPk"].get("empty")]),
        "pdfNotes": len([r for r in rows if r.get("pdf")]), "pdfNotesInked": len(pdf_rows),
        "pdfPagesInked": len(pdf_pages),
        "pdfPageF1": dist([p["f1"] for p in pdf_pages]),
        "pdfPageChamfer": dist([p.get("chamfer") for p in pdf_pages]),
        "pdfPageRatio": dist([p.get("ratio") for p in pdf_pages]),
        "pdfNoteF1Min": dist([r["pdf"]["f1Min"] for r in pdf_rows]),
        "pdfNoteChamferMax": dist([r["pdf"]["chamferMax"] for r in pdf_rows]),
        "pdfPageF1Paper": dist([p["f1"] for p in pdf_pages if not p["onPDF"]]),
        "pdfPageF1OnPDF": dist([p["f1"] for p in pdf_pages if p["onPDF"]]),
        "flagCounts": flag_counts,
        "flaggedNotes": sum(1 for r in rows if r["failing"]),
        "categories": {c: sum(1 for r in rows if r["category"] == c) for c in sorted({r["category"] for r in rows if r["category"]})},
    }

    def d(x, nd=3):
        return "–" if not x.get("n") else f"{x['median']:.{nd}f} (p10 {x['p10']:.{nd}f}, min {x['min']:.{nd}f})"

    agg["display"] = {
        "notes imported / skipped / failed": f"{import_report.get('imported', '?')} / {import_report.get('skipped', '?')} / {import_report.get('failed', '?')}",
        "notes with Notability's PDF (inked)": f"{agg['pdfNotes']} ({agg['pdfNotesInked']})",
        "Notability PDF pages compared (inked)": str(agg["pdfPagesInked"]),
        "PDF page F1±1px median": d(agg["pdfPageF1"]),
        "PDF page chamfer pt": "–" if not agg["pdfPageChamfer"].get("n") else
        f"{agg['pdfPageChamfer']['median']:.2f} (p90 {agg['pdfPageChamfer']['p90']:.2f}, max {agg['pdfPageChamfer']['max']:.2f})",
        "PDF page ink ratio median": d(agg["pdfPageRatio"]),
        "PDF worst page per note, F1 median": d(agg["pdfNoteF1Min"]),
        "oracle-scored notes (paper / PDF)": f"{len(scored)} ({len(paper)} / {len(pdfs)})",
        "oracle F1±1px median": d(agg["oracleF1"]),
        "oracle IoU median": d(agg["oracleIoU"]),
        "oracle chamfer pt median": "–" if not agg["oracleChamfer"].get("n") else
        f"{agg['oracleChamfer']['median']:.2f} (p90 {agg['oracleChamfer']['p90']:.2f}, max {agg['oracleChamfer']['max']:.2f})",
        "oracle ink ratio median": d(agg["oracleRatio"]),
        "canvas bands (inked)": f"{len(bands)} ({len(inked_bands)})",
        "canvas vs export F1±1px": d(agg["canvasF1"]),
        "canvas vs export IoU": d(agg["canvasIoU"]),
        "canvas / export ink ratio": "–" if not agg["canvasRatio"].get("n") else
        f"{agg['canvasRatio']['median']:.3f} ({agg['canvasRatio']['min']:.3f}–{agg['canvasRatio']['max']:.3f})",
        "PKDrawing.image vs export F1": d(agg["pkF1"]),
        "canvas vs PKDrawing.image F1": d(agg["canvasVsPkF1"]),
        "flagged notes": str(agg["flaggedNotes"]),
    }
    edges = [0, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95, 1.0001]
    agg["histograms"] = {
        "oracle F1±1px (notes)": [(f"{edges[i]:.2f}–{min(edges[i + 1], 1):.2f}", n)
                                  for i, n in enumerate(histogram([r["oracle"]["f1"] for r in scored], edges))],
        "Notability PDF page F1±1px (pages)": [(f"{edges[i]:.2f}–{min(edges[i + 1], 1):.2f}", n)
                                               for i, n in enumerate(histogram([p["f1"] for p in pdf_pages], edges))],
        "canvas vs export F1±1px (bands)": [(f"{edges[i]:.2f}–{min(edges[i + 1], 1):.2f}", n)
                                            for i, n in enumerate(histogram([m["f1"] for m in inked_bands], edges))],
    }
    ch_edges = [0, 0.25, 0.5, 0.75, 1, 1.5, 2, 4, 1e9]
    agg["histograms"]["oracle chamfer pt (notes)"] = [
        (f"{ch_edges[i]}–{ch_edges[i + 1] if ch_edges[i + 1] < 1e9 else '∞'}", n)
        for i, n in enumerate(histogram([r["oracle"]["chamfer"] for r in scored], ch_edges))]

    thresholds = {"oracle chamfer pt": ORACLE_CHAMFER_PT, "oracle F1": ORACLE_F1, "oracle ratio": ORACLE_RATIO,
                  "oracle edge pt": ORACLE_EDGE_PT, "canvas F1": CANVAS_F1, "canvas ratio": CANVAS_RATIO,
                  "canvas edge pt": CANVAS_EDGE_PT, "ink: lum <": DARK_LUM, "ink: chroma >": CHROMA,
                  "PDF diff >": PDF_DIFF, "empty below px": MIN_INK_PX, "PDF page F1": PDF_F1,
                  "PDF page chamfer pt": PDF_CHAMFER_PT, "PDF page ratio": PDF_RATIO, "PDF page edge pt": PDF_EDGE_PT}
    import datetime
    summary = {"generated": datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z"),
               "thresholds": {k: list(v) if isinstance(v, tuple) else v for k, v in thresholds.items()},
               "aggregate": agg, "notes": rows}
    args.out.mkdir(parents=True, exist_ok=True)

    # Gallery: the worst N plus every flagged note (images already in img/).
    pick = [r for r in rows if r["failing"]]
    for r in rows[: args.gallery]:
        if r not in pick:
            pick.append(r)
    gallery = []
    for r in pick:
        sets = [(title, [(cap, png_data_uri(load_rgba(img_dir / f)[..., :3])) for cap, f in files])
                for title, files in r["_sets"]]
        gallery.append({"id8": r["id8"], "flags": r["flags"], "sets": sets})
    for r in rows:
        r.pop("_sets", None)
    (args.out / "summary.json").write_text(json.dumps(clean(summary), indent=1))
    write_report(args.out, summary, rows, gallery)
    print(json.dumps(clean(agg["display"]), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
