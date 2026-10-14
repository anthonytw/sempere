#!/usr/bin/env python3
"""Writes the SemperePDF test fixtures (stdlib only; deterministic).

    python3 Tests/SemperePDFTests/generate_fixtures.py

Every page draws asymmetric coloured rectangles (so a flip or a wrong
rotation shows in a pixel comparison), a small Flate RGB image XObject and,
on some pages, a nested Form XObject, so resource copying is exercised.
"""
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Fixtures")


def content(label_rgb, w, h):
    """Content stream for a w x h page: corner marks, a band, an image, a form."""
    r, g, b = label_rgb
    return (
        f"q {r} {g} {b} rg 20 20 {w * 0.3:.1f} {h * 0.2:.1f} re f Q\n"      # bottom-left block
        f"q 0 0 1 rg {w - 60} {h - 40} 40 20 re f Q\n"                      # top-right blue
        f"q 0 0.6 0 RG 4 w 10 {h / 2:.1f} m {w - 10} {h / 2 + 30:.1f} l S Q\n"   # sloped green line
        f"q 80 0 0 60 {w * 0.55:.1f} 40 cm /Im1 Do Q\n"
        "BT /F1 18 Tf 30 " + f"{h - 80}" + " Td (Sempere) Tj ET\n"
    ).encode()


def image_stream():
    # 4 x 3 RGB, rows: red, green, blue fading; Flate with PNG Up predictor.
    rows = []
    for y in range(3):
        row = bytearray([2])   # PNG "Up"
        for x in range(4):
            px = [(255, 0, 0), (0, 200, 0), (0, 0, 255)][y]
            row += bytes(px) if y == 0 else bytes(0 for _ in px)
        rows.append(row)
    # Undo the "Up" encoding for rows 1..2: store raw differences.
    raw = bytearray()
    prev = bytes(12)
    for y in range(3):
        px = bytes(sum(([(255, 0, 0), (0, 200, 0), (0, 0, 255)][y] for _ in range(4)), ()))
        raw.append(2)
        raw += bytes((px[i] - prev[i]) & 0xFF for i in range(12))
        prev = px
    data = zlib.compress(bytes(raw))
    d = ("<< /Type /XObject /Subtype /Image /Width 4 /Height 3 /ColorSpace /DeviceRGB "
         "/BitsPerComponent 8 /Filter /FlateDecode /DecodeParms << /Predictor 12 /Colors 3 /Columns 4 >> "
         f"/Length {len(data)} >>")
    return d.encode(), data


class Builder:
    def __init__(self, version="1.4"):
        self.out = bytearray(f"%PDF-{version}\n%\xe2\xe3\xcf\xd3\n".encode("latin-1"))
        self.offsets = {}

    def obj(self, num, body, stream=None):
        self.offsets[num] = len(self.out)
        self.out += f"{num} 0 obj\n".encode() + body
        if stream is not None:
            self.out += b"\nstream\n" + stream + b"\nendstream"
        self.out += b"\nendobj\n"

    def xref_table(self, nums=None):
        nums = sorted(self.offsets) if nums is None else nums
        pos = len(self.out)
        size = max(self.offsets) + 1
        self.out += b"xref\n0 1\n0000000000 65535 f \n"
        # one subsection per run of consecutive numbers
        runs = []
        for n in nums:
            if runs and runs[-1][-1] == n - 1:
                runs[-1].append(n)
            else:
                runs.append([n])
        for run in runs:
            self.out += f"{run[0]} {len(run)}\n".encode()
            for n in run:
                self.out += f"{self.offsets[n]:010d} 00000 n \n".encode()
        return pos, size

    def trailer(self, pos, extra):
        self.out += f"trailer\n<< {extra} >>\nstartxref\n{pos}\n%%EOF\n".encode()


def common_objects(b, w=400, h=300, first=1):
    """Catalog 1, Pages 2, page 3 + content 4, font 5, image 6. Returns nothing."""
    b.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    b.obj(2, f"<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 {w} {h}] >>".encode())
    b.obj(3, b"<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> "
             b"/XObject << /Im1 6 0 R >> >> /Contents 4 0 R /Annots [] >>")
    c = zlib.compress(content((1, 0, 0), w, h))
    b.obj(4, f"<< /Length {len(c)} /Filter /FlateDecode >>".encode(), c)
    b.obj(5, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    d, s = image_stream()
    b.obj(6, d, s)


def classic():
    b = Builder()
    common_objects(b)
    pos, size = b.xref_table()
    b.trailer(pos, f"/Size {size} /Root 1 0 R")
    return bytes(b.out)


def rotated():
    # Boxes and /Rotate inherited from the Pages node; a second page overrides them.
    b = Builder()
    b.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    b.obj(2, b"<< /Type /Pages /Kids [7 0 R] /Count 2 /MediaBox [0 0 600 400] "
             b"/CropBox [50 20 550 380] /Rotate 90 /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> >>")
    b.obj(7, b"<< /Type /Pages /Parent 2 0 R /Kids [3 0 R 8 0 R] /Count 2 >>")
    b.obj(3, b"<< /Type /Page /Parent 7 0 R /Contents 4 0 R >>")
    c = content((1, 0.5, 0), 600, 400)
    b.obj(4, f"<< /Length {len(c)} >>".encode(), c)
    b.obj(5, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    d, s = image_stream()
    b.obj(6, d, s)
    c2 = content((0.5, 0, 0.5), 300, 200)
    b.obj(8, b"<< /Type /Page /Parent 7 0 R /MediaBox [0 0 300 200] /Rotate -270 /Contents 9 0 R >>")
    b.obj(9, f"<< /Length 10 0 R >>".encode(), c2)
    b.obj(10, str(len(c2)).encode())
    pos, size = b.xref_table()
    b.trailer(pos, f"/Size {size} /Root 1 0 R")
    return bytes(b.out)


def xref_stream_objstm():
    """PDF 1.5: pages, fonts and the catalog in an object stream; an xref stream with a PNG predictor."""
    b = Builder("1.5")
    w, h = 300, 400
    inner = {
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: b"<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>",
        3: f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h}] /Resources 8 0 R /Contents 4 0 R "
           f"/Group << /S /Transparency /CS /DeviceRGB >> >>".encode(),
        5: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        8: b"<< /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R /Fx 11 0 R >> /ExtGState << /G 12 0 R >> >>",
        9: f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {h} {w}] /Resources 8 0 R /Contents [10 0 R 4 0 R] >>".encode(),
        12: b"<< /Type /ExtGState /ca 0.5 >>",
    }
    header, body = b"", b""
    for n, o in inner.items():
        header += f"{n} {len(body)} ".encode()
        body += o + b"\n"
    stm = zlib.compress(header + body)
    b.obj(7, f"<< /Type /ObjStm /N {len(inner)} /First {len(header)} /Filter /FlateDecode /Length {len(stm)} >>".encode(), stm)
    c = zlib.compress(content((0, 0.7, 0.7), w, h) + b"q /G gs /Fx Do Q\n")
    b.obj(4, f"<< /Length {len(c)} /Filter /FlateDecode >>".encode(), c)
    d, s = image_stream()
    b.obj(6, d, s)
    c10 = b"q 1 0 1 rg 100 100 50 50 re f Q\n"
    b.obj(10, f"<< /Length {len(c10)} >>".encode(), c10)
    fx = b"0.2 0.2 0.2 rg 0 0 30 30 re f"
    b.obj(11, f"<< /Type /XObject /Subtype /Form /BBox [0 0 30 30] /Matrix [1 0 0 1 200 300] /Length {len(fx)} >>".encode(), fx)
    # xref stream (object 13) with W [1 4 2], Flate + PNG Up predictor (12) over 7-byte rows
    entries = {0: (0, 0, 65535)}
    for n in (4, 6, 7, 10, 11):
        entries[n] = (1, b.offsets[n], 0)
    for i, n in enumerate(inner):
        entries[n] = (2, 7, i)
    xpos = len(b.out)
    entries[13] = (1, xpos, 0)
    size = 14
    rows = []
    prev = bytes(7)
    raw = bytearray()
    for n in range(size):
        t, f2, f3 = entries.get(n, (0, 0, 0))
        row = bytes([t]) + struct.pack(">I", f2) + struct.pack(">H", f3)
        raw.append(2)
        raw += bytes((row[i] - prev[i]) & 0xFF for i in range(7))
        prev = row
    data = zlib.compress(bytes(raw))
    b.obj(13, (f"<< /Type /XRef /Size {size} /W [1 4 2] /Root 1 0 R /Filter /FlateDecode "
               f"/DecodeParms << /Predictor 12 /Columns 7 >> /Length {len(data)} >>").encode(), data)
    b.out += f"startxref\n{xpos}\n%%EOF\n".encode()
    return bytes(b.out)


def hybrid():
    """A classic table for objects 1-6 plus /XRefStm naming an object-stream member (object 8)."""
    b = Builder("1.5")
    b.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    b.obj(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>")
    b.obj(3, b"<< /Type /Page /Parent 2 0 R /Resources 8 0 R /Contents 4 0 R >>")
    c = b"q 0 0 1 rg 10 10 50 50 re f Q BT /F1 12 Tf 20 150 Td (hybrid) Tj ET\n"
    b.obj(4, f"<< /Length {len(c)} >>".encode(), c)
    b.obj(5, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    inner = b"<< /Font << /F1 5 0 R >> >>"
    head = b"8 0 "
    stm = head + inner
    b.obj(6, f"<< /Type /ObjStm /N 1 /First {len(head)} /Length {len(stm)} >>".encode(), stm)
    xs = len(b.out)
    rows = b"".join(bytes([t]) + struct.pack(">I", f2) + bytes([f3]) for t, f2, f3 in [(2, 6, 0)])
    b.obj(7, f"<< /Type /XRef /Size 9 /W [1 4 1] /Index [8 1] /Length {len(rows)} >>".encode(), rows)
    pos, size = b.xref_table([1, 2, 3, 4, 5, 6, 7])
    b.trailer(pos, f"/Size 9 /Root 1 0 R /XRefStm {xs}")
    return bytes(b.out)


def incremental():
    """An original file plus an update that replaces page 1's contents and adds page 2."""
    b = Builder()
    common_objects(b)
    pos, size = b.xref_table()
    b.trailer(pos, f"/Size {size} /Root 1 0 R")
    first = pos
    b.offsets = {}
    c = zlib.compress(b"q 0 0.5 0 rg 50 50 100 100 re f Q\n")
    b.obj(4, f"<< /Length {len(c)} /Filter /FlateDecode >>".encode(), c)
    b.obj(2, b"<< /Type /Pages /Kids [3 0 R 7 0 R] /Count 2 /MediaBox [0 0 400 300] >>")
    b.obj(7, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 8 0 R >>")
    c8 = b"q 1 0 0 rg 0 0 100 100 re f Q\n"
    b.obj(8, f"<< /Length {len(c8)} >>".encode(), c8)
    pos = len(b.out)
    b.out += b"xref\n0 1\n0000000000 65535 f \n2 1\n" + f"{b.offsets[2]:010d} 00000 n \n".encode()
    b.out += b"4 1\n" + f"{b.offsets[4]:010d} 00000 n \n".encode()
    b.out += b"7 2\n" + f"{b.offsets[7]:010d} 00000 n \n{b.offsets[8]:010d} 00000 n \n".encode()
    b.trailer(pos, f"/Size 9 /Root 1 0 R /Prev {first}")
    return bytes(b.out)


def broken():
    """The classic file with every xref offset wrong and a stream /Length too short."""
    b = Builder()
    b.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    b.obj(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 400 300] >>")
    b.obj(3, b"<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> "
             b"/Contents 4 0 R >>")
    c = content((0.2, 0.2, 0.8), 400, 300)
    b.obj(4, b"<< /Length 12 >>", c)
    b.obj(5, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    d, s = image_stream()
    b.obj(6, d, s)
    pos = len(b.out)
    b.out += b"xref\n0 7\n0000000000 65535 f \n"
    for n in range(1, 7):
        b.out += f"{b.offsets[n] + 7:010d} 00000 n \n".encode()
    b.out += f"trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n{pos + 3}\n%%EOF\n".encode()
    return bytes(b.out)


def no_xref():
    """No xref, no trailer, no startxref: the catalog is found by scanning."""
    b = Builder()
    common_objects(b)
    return bytes(b.out)


def encrypted():
    b = Builder()
    common_objects(b)
    b.obj(7, b"<< /Filter /Standard /V 1 /R 2 /O <00> /U <00> /P -4 >>")
    pos, size = b.xref_table()
    b.trailer(pos, f"/Size {size} /Root 1 0 R /Encrypt 7 0 R /ID [<00><00>]")
    return bytes(b.out)


def filters():
    """Page 1 content: ASCII85 over Flate; page 2: LZW; page 3: ASCIIHex + RunLength; page 4: DCT (unsupported)."""
    b = Builder()
    body = b"q 0.9 0.1 0.1 rg 10 10 80 80 re f Q\n" * 3
    b.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    b.obj(2, b"<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R 9 0 R] /Count 4 /MediaBox [0 0 100 100] >>")
    a85 = ascii85(zlib.compress(body))
    b.obj(3, b"<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>")
    b.obj(4, f"<< /Length {len(a85)} /Filter [/ASCII85Decode /FlateDecode] >>".encode(), a85)
    lz = lzw(body)
    b.obj(5, b"<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>")
    b.obj(6, f"<< /Length {len(lz)} /Filter /LZWDecode >>".encode(), lz)
    rl = runlength(body)
    hx = rl.hex().upper().encode() + b">"
    b.obj(7, b"<< /Type /Page /Parent 2 0 R /Contents 8 0 R >>")
    b.obj(8, f"<< /Length {len(hx)} /Filter [/AHx /RL] >>".encode(), hx)
    b.obj(9, b"<< /Type /Page /Parent 2 0 R /Contents 10 0 R >>")
    b.obj(10, b"<< /Length 4 /Filter /DCTDecode >>", b"\xff\xd8\xff\xd9")
    pos, size = b.xref_table()
    b.trailer(pos, f"/Size {size} /Root 1 0 R")
    return bytes(b.out)


def ascii85(data):
    out = bytearray()
    for i in range(0, len(data), 4):
        chunk = data[i:i + 4]
        n = len(chunk)
        v = int.from_bytes(chunk + b"\0" * (4 - n), "big")
        if v == 0 and n == 4:
            out += b"z"
            continue
        digits = []
        for _ in range(5):
            digits.append(v % 85)
            v //= 85
        enc = bytes(d + 33 for d in reversed(digits))
        out += enc[:n + 1]
    return bytes(out) + b"~>"


def lzw(data):
    table = {bytes([i]): i for i in range(256)}
    nxt, width, out_bits = 258, 9, []

    def put(code):
        out_bits.append((code, width))

    put(256)
    w = b""
    for c in data:
        wc = w + bytes([c])
        if wc in table:
            w = wc
            continue
        put(table[w])
        table[wc] = nxt
        nxt += 1
        if nxt + 1 > 511 and width == 9:   # EarlyChange 1
            width = 10
        elif nxt + 1 > 1023 and width == 10:
            width = 11
        w = bytes([c])
    if w:
        put(table[w])
    put(257)
    acc, n, out = 0, 0, bytearray()
    for code, wd in out_bits:
        acc = (acc << wd) | code
        n += wd
        while n >= 8:
            out.append((acc >> (n - 8)) & 0xFF)
            n -= 8
    if n:
        out.append((acc << (8 - n)) & 0xFF)
    return bytes(out)


def runlength(data):
    out = bytearray()
    for i in range(0, len(data), 100):
        chunk = data[i:i + 100]
        out.append(len(chunk) - 1)
        out += chunk
    out += b"\x80"
    return bytes(out)


def equation():
    """A math item's rendering (format.md §8.2.7): one 60 x 24 pt page, marks only in
    #1A1A1A on a transparent page: a bar over the left half and a block on the right."""
    b = Builder()
    b.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    b.obj(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    b.obj(3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 60 24] /Resources << >> /Contents 4 0 R >>")
    c = b"0.102 0.102 0.102 rg 4 10 26 4 re f 36 2 20 20 re f\n"
    b.obj(4, f"<< /Length {len(c)} >>".encode(), c)
    pos, size = b.xref_table()
    b.trailer(pos, f"/Size {size} /Root 1 0 R")
    return bytes(b.out)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in [("classic.pdf", classic), ("rotated.pdf", rotated), ("objstm.pdf", xref_stream_objstm),
                     ("hybrid.pdf", hybrid), ("incremental.pdf", incremental), ("broken-xref.pdf", broken),
                     ("no-xref.pdf", no_xref), ("encrypted.pdf", encrypted), ("filters.pdf", filters),
                     ("equation.pdf", equation)]:
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(fn())


if __name__ == "__main__":
    main()
