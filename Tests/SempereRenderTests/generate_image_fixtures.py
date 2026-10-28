#!/usr/bin/env python3
"""Regenerates Fixtures/images: JPEG and PNG decoder fixtures with reference decodes.

Synthetic pictures only (gradients and shapes), so the fixtures hold no
personal data. Each `NAME.jpg` / `NAME.png` has a reference decode
`NAME.rgba`: raw RGBA8, rows top first, decoded by Pillow (libjpeg-turbo for
JPEG, its own PNG decoder). The tests compare the Swift decoders against them.

Run from the repository root:
    python3 Tests/SempereRenderTests/generate_image_fixtures.py
Needs Pillow (with libjpeg-turbo) and ImageMagick 6 (`convert`) for the
sampling factors Pillow cannot write and for interlaced PNGs.
"""
import os
import struct
import subprocess
import zlib

from PIL import Image, ImageDraw, features

OUT = os.path.join(os.path.dirname(__file__), "Fixtures", "images")


def picture(w, h, mode="RGB"):
    """A deterministic test picture with smooth gradients and hard edges."""
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = ((x * 255) // max(w - 1, 1), (y * 255) // max(h - 1, 1), ((x + y) * 7) % 256)
    if w < 8 or h < 8:
        return im.convert(mode)
    d = ImageDraw.Draw(im)
    d.ellipse([w // 5, h // 5, w * 3 // 5, h * 4 // 5], fill=(220, 30, 40))
    d.rectangle([w // 2, h // 3, w - 3, h // 2], fill=(20, 200, 90))
    d.line([0, h - 1, w - 1, 0], fill=(255, 255, 255), width=2)
    return im.convert(mode)


def reference(path):
    im = Image.open(path)
    im.load()
    return im.convert("RGBA").tobytes()


def write(name, data):
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)


def save_jpeg(name, im, **kw):
    path = os.path.join(OUT, name + ".jpg")
    im.save(path, "JPEG", **kw)
    write(name + ".rgba", reference(path))


def magick_jpeg(name, im, *args):
    src = os.path.join(OUT, name + ".src.png")
    im.save(src)
    path = os.path.join(OUT, name + ".jpg")
    subprocess.run(["convert", src, *args, path], check=True)
    os.remove(src)
    write(name + ".rgba", reference(path))


def save_png(name, im, **kw):
    path = os.path.join(OUT, name + ".png")
    im.save(path, "PNG", **kw)
    write(name + ".rgba", reference(path))


def magick_png(name, im, *args):
    src = os.path.join(OUT, name + ".src.png")
    im.save(src)
    path = os.path.join(OUT, name + ".png")
    subprocess.run(["convert", src, *args, path], check=True)
    os.remove(src)
    write(name + ".rgba", reference(path))


def main():
    assert features.check_feature("libjpeg_turbo"), "Pillow must use libjpeg-turbo"
    os.makedirs(OUT, exist_ok=True)
    base = picture(61, 45)

    # JPEG: sampling factors, progressive, restart intervals, grey, odd and tiny sizes.
    save_jpeg("baseline-444", base, quality=90, subsampling=0)
    save_jpeg("baseline-422", base, quality=90, subsampling=1)
    save_jpeg("baseline-420", base, quality=85, subsampling=2)
    save_jpeg("progressive-420", base, quality=85, subsampling=2, progressive=True)
    save_jpeg("progressive-444", base, quality=95, subsampling=0, progressive=True)
    save_jpeg("restart-420", base, quality=80, subsampling=2, restart_marker_blocks=3)
    save_jpeg("grey", base.convert("L"), quality=90)
    save_jpeg("grey-progressive", base.convert("L"), quality=90, progressive=True)
    save_jpeg("tiny-420", picture(3, 2), quality=90, subsampling=2)
    save_jpeg("wide-420", picture(130, 9), quality=75, subsampling=2)
    magick_jpeg("magick-440", base, "-quality", "88", "-sampling-factor", "1x2")
    magick_jpeg("magick-411", base, "-quality", "88", "-sampling-factor", "4x1")
    magick_jpeg("magick-progressive-restart", base, "-quality", "80", "-interlace", "JPEG",
                "-define", "jpeg:restart-interval=2")
    # Metadata: EXIF (with a GPS IFD), a comment, XMP; stripped on export.
    exif = Image.Exif()
    exif[0x010F] = "SyntheticCam"      # Make
    exif[0x0112] = 6                   # Orientation
    exif[0x8825] = {1: "N", 2: (0.0, 0.0, 0.0)}  # GPS IFD
    path = os.path.join(OUT, "metadata.jpg")
    base.save(path, "JPEG", quality=90, exif=exif, comment=b"synthetic comment",
              xmp=b"<x:xmpmeta xmlns:x='adobe:ns:meta/'/>")
    write("metadata.rgba", reference(path))
    # Quadrants (red, green / blue, yellow): orientation, crop and rotation goldens.
    q = Image.new("RGB", (40, 30))
    qd = ImageDraw.Draw(q)
    for (x0, y0, colour) in ((0, 0, (255, 0, 0)), (20, 0, (0, 255, 0)), (0, 15, (0, 0, 255)), (20, 15, (255, 255, 0))):
        qd.rectangle([x0, y0, x0 + 19, y0 + 14], fill=colour)
    save_jpeg("quadrants", q, quality=95, subsampling=0)
    # CMYK: valid JPEG, unsupported by the format (writers convert it).
    base.convert("CMYK").save(os.path.join(OUT, "cmyk.jpg"), "JPEG", quality=90)

    # PNG: every colour type and bit depth, palettes with transparency, every
    # row filter, Adam7. Encoded here (`png_encode`) so depths Pillow cannot
    # write are covered; the reference is computed from the samples (16-bit
    # reduced to its high byte, low depths scaled to 0-255) and cross-checked
    # with Pillow where Pillow reads the file as 8-bit RGBA unambiguously.
    w, h = 23, 17
    def sample(x, y, c, depth):
        m = (1 << depth) - 1
        return ((x * 37 + y * 101 + c * 59 + (x * y) % 13) * (m // 15 + 1) + c) % (m + 1)
    for depth in (1, 2, 4, 8, 16):
        grey = [[sample(x, y, 0, depth) for x in range(w)] for y in range(h)]
        for interlace in (0, 1):
            name = "grey%d%s" % (depth, "-interlaced" if interlace else "")
            data = png_encode(w, h, depth, 0, [[[v] for v in row] for row in grey], interlace=interlace)
            ref = [[expand(v, depth)] * 3 + [255] for row in grey for v in row]
            emit_png(name, data, ref, check=depth == 8)
    trns_grey = sample(0, 0, 0, 4)
    grey4 = [[[sample(x, y, 0, 4)] for x in range(w)] for y in range(h)]
    emit_png("grey4-trns", png_encode(w, h, 4, 0, grey4, trns=struct.pack(">H", trns_grey)),
             [[expand(p[0], 4)] * 3 + [0 if p[0] == trns_grey else 255] for row in grey4 for p in row], check=False)
    for depth in (8, 16):
        for ct, n in ((2, 3), (4, 2), (6, 4)):
            px = [[[sample(x, y, c, depth) for c in range(n)] for x in range(w)] for y in range(h)]
            for interlace in (0, 1):
                name = "%s%d%s" % ({2: "rgb", 4: "greyalpha", 6: "rgba"}[ct], depth, "-interlaced" if interlace else "")
                ref = []
                for row in px:
                    for p in row:
                        e = [expand(v, depth) for v in p]
                        ref.append(e if ct == 6 else e + [255] if ct == 2 else [e[0]] * 3 + [e[1]])
                emit_png(name, png_encode(w, h, depth, ct, px, interlace=interlace), ref, check=depth == 8)
    rgb16 = [[[sample(x, y, c, 16) for c in range(3)] for x in range(w)] for y in range(h)]
    key = rgb16[2][3]
    emit_png("rgb16-trns", png_encode(w, h, 16, 2, rgb16, trns=struct.pack(">HHH", *key)),
             [[expand(v, 16) for v in p] + [0 if p == key else 255] for row in rgb16 for p in row], check=False)
    for depth in (1, 2, 4, 8):
        n = 1 << depth if depth < 8 else 200
        palette = [((i * 53) % 256, (i * 101) % 256, (i * 197) % 256) for i in range(n)]
        alpha = [(i * 37) % 256 for i in range(n // 2)]   # tRNS shorter than the palette: the rest opaque
        idx = [[[sample(x, y, 0, 8) % n] for x in range(w)] for y in range(h)]
        for interlace in (0, 1):
            name = "palette%d%s" % (depth, "-interlaced" if interlace else "")
            data = png_encode(w, h, depth, 3, idx, interlace=interlace, plte=palette, trns=bytes(alpha))
            ref = [list(palette[p[0]]) + [alpha[p[0]] if p[0] < len(alpha) else 255] for row in idx for p in row]
            emit_png(name, data, ref, check=depth == 8)
    # Pillow-written files: a real encoder's choices, plus ancillary chunks to strip.
    from PIL import PngImagePlugin
    meta = PngImagePlugin.PngInfo()
    meta.add_text("Author", "synthetic")
    meta.add_text("GPS", "0.0 N")
    path = os.path.join(OUT, "pillow-rgb8-text.png")
    base.save(path, "PNG", pnginfo=meta, exif=exif)
    write("pillow-rgb8-text.rgba", reference(path))
    path = os.path.join(OUT, "pillow-rgba8.png")
    base.convert("RGBA").save(path, "PNG")
    write("pillow-rgba8.rgba", reference(path))
    path = os.path.join(OUT, "tiny.png")
    picture(1, 1).save(path, "PNG")
    write("tiny.rgba", reference(path))


def expand(v, depth):
    """A sample of `depth` bits as 8 bits: high byte of 16, scaled up below 8."""
    if depth == 16:
        return v >> 8
    return v * 255 // ((1 << depth) - 1)


def png_chunk(kind, body):
    c = zlib.crc32(kind + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", c)


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def pack_row(row, depth):
    """Samples (a list per pixel) as PNG row bytes."""
    flat = [v for p in row for v in p]
    if depth == 16:
        return b"".join(struct.pack(">H", v) for v in flat)
    if depth == 8:
        return bytes(flat)
    out, acc, bits = bytearray(), 0, 0
    for v in flat:
        acc = acc << depth | v
        bits += depth
        if bits == 8:
            out.append(acc)
            acc, bits = 0, 0
    if bits:
        out.append(acc << (8 - bits))
    return bytes(out)


def filter_rows(rows, bpp):
    """Filters each row with filter type (row index % 5), so all five are exercised."""
    out, prev = bytearray(), bytes(len(rows[0])) if rows else b""
    for i, row in enumerate(rows):
        f = i % 5
        out.append(f)
        for j, x in enumerate(row):
            a = row[j - bpp] if j >= bpp else 0
            b = prev[j]
            c = prev[j - bpp] if j >= bpp else 0
            if f == 0: p = 0
            elif f == 1: p = a
            elif f == 2: p = b
            elif f == 3: p = (a + b) // 2
            else:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                p = a if pa <= pb and pa <= pc else b if pb <= pc else c
            out.append((x - p) & 0xFF)
        prev = row
    return bytes(out)


def png_encode(w, h, depth, ct, px, interlace=0, plte=None, trns=None):
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    bpp = max(1, channels * depth // 8)
    raw = b""
    passes = ADAM7 if interlace else [(0, 0, 1, 1)]
    for x0, y0, dx, dy in passes:
        rows = [pack_row([px[y][x] for x in range(x0, w, dx)], depth) for y in range(y0, h, dy)]
        rows = [r for r in rows if r]
        if rows:
            raw += filter_rows(rows, bpp)
    out = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ct, 0, 0, interlace))
    if plte:
        out += png_chunk(b"PLTE", bytes(v for rgb in plte for v in rgb))
    if trns is not None:
        out += png_chunk(b"tRNS", trns)
    z = zlib.compress(raw, 9)
    out += png_chunk(b"IDAT", z[: len(z) // 2]) + png_chunk(b"IDAT", z[len(z) // 2:])   # split IDAT
    return out + png_chunk(b"IEND", b"")


def emit_png(name, data, ref, check):
    write(name + ".png", data)
    raw = bytes(v for p in ref for v in p)
    if check:
        assert reference(os.path.join(OUT, name + ".png")) == raw, name
    write(name + ".rgba", raw)


if __name__ == "__main__":
    main()
