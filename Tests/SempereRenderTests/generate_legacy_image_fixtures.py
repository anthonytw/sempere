#!/usr/bin/env python3
"""Regenerates Fixtures/images/legacy-*: GIF and TIFF decoder fixtures (LegacyImages.swift).

Synthetic pictures only. Each `legacy-NAME.gif` / `.tif` has a reference decode
`legacy-NAME.rgba` (raw RGBA8, rows top first, orientation applied) made by
Pillow; the tests compare the Swift decoders against them. For 16-bit grey the
reference is the high byte of each sample, computed here.

Run from the repository root:
    python3 Tests/SempereRenderTests/generate_legacy_image_fixtures.py
Needs Pillow.
"""
import os

from PIL import Image, ImageOps

OUT = os.path.join(os.path.dirname(__file__), "Fixtures", "images")
W, H = 48, 32


def make(mode, f):
    im = Image.new(mode, (W, H))
    im.putdata([f(x, y) for y in range(H) for x in range(W)])
    return im


def rgb(x, y): return ((x * 5 + y) % 256, (y * 7) % 256, (x * y) % 256)
def rgba(x, y): return rgb(x, y) + ((x * 3 + y * 2) % 256,)
def gray(x, y): return (x * 5 + y * 3) % 256
def idx(x, y): return (x + y * 3) % 16


PALETTE = [c for i in range(16) for c in (i * 16, 255 - i * 16, (i * 37) % 256)]


def palette_image():
    im = make("P", idx)
    im.putpalette(PALETTE)
    return im


def write(name, ext, im, **kw):
    path = os.path.join(OUT, f"legacy-{name}.{ext}")
    im.save(path, **kw)
    ref = Image.open(path)
    ref.load()
    ref = ImageOps.exif_transpose(ref) if ext == "tif" else ref
    open(path[: -len(ext)] + "rgba", "wb").write(ref.convert("RGBA").tobytes())


for name, comp in [("rgb-raw", None), ("rgb-lzw", "tiff_lzw"), ("rgb-packbits", "packbits"), ("rgb-deflate", "tiff_adobe_deflate")]:
    write(name, "tif", make("RGB", rgb), format="TIFF", **({} if comp is None else {"compression": comp}))
write("rgba-lzw", "tif", make("RGBA", rgba), format="TIFF", compression="tiff_lzw")
write("gray-lzw", "tif", make("L", gray), format="TIFF", compression="tiff_lzw")
write("palette", "tif", palette_image(), format="TIFF")
write("bilevel", "tif", make("1", lambda x, y: 255 if (x + y) % 3 == 0 else 0), format="TIFF")
ex = Image.Exif()
ex[274] = 6
write("rgb-orient6", "tif", make("RGB", rgb), format="TIFF", exif=ex)
write("plain", "gif", palette_image(), format="GIF")
write("interlaced", "gif", palette_image(), format="GIF", interlace=True)
write("transparent", "gif", palette_image(), format="GIF", transparency=3)

# 16-bit grey: Pillow cannot convert I;16 to RGBA without clamping; the high byte is the reference.
im16 = make("I;16", lambda x, y: (x * 1000 + y * 37) % 65536)
path = os.path.join(OUT, "legacy-gray16.tif")
im16.save(path, format="TIFF")
ref = bytearray()
for y in range(H):
    for x in range(W):
        v = ((x * 1000 + y * 37) % 65536) >> 8
        ref += bytes((v, v, v, 255))
open(os.path.join(OUT, "legacy-gray16.rgba"), "wb").write(bytes(ref))
