#!/usr/bin/env python3
"""Writes Fixtures/qr-vectors.json: reference QR symbols from Project Nayuki's
qrcodegen (pip install qrcodegen), an independent implementation of
ISO/IEC 18004. QRCodeTests compares SempereRender's encoder with them module for
module. Regenerate: python3 Tests/SempereRenderTests/generate_qr_vectors.py
"""
import json, os
from qrcodegen import QrCode, QrSegment

E = {'L': QrCode.Ecc.LOW, 'M': QrCode.Ecc.MEDIUM, 'Q': QrCode.Ecc.QUARTILE, 'H': QrCode.Ecc.HIGH}

def packed(q):
    n = q.get_size()
    bits = [q.get_module(x, y) for y in range(n) for x in range(n)]
    out = bytearray((len(bits) + 7) // 8)
    for i, b in enumerate(bits):
        if b:
            out[i >> 3] |= 0x80 >> (i & 7)
    return out.hex()

# The throwaway fixture key (Tests/SempereTests/Fixtures/sample.key), never a real one.
KEY = "AGE-SECRET-KEY-1JQ4L7CGCHC2TE7JUJ7YG4Y4DREUWFD7Y6U5XKFZ3EYTNY62Z5PES6MWJVN"
# Shape of a post-quantum identity (age-keygen -pq): 77 characters, NOT a real key.
PQ_KEY = "AGE-SECRET-KEY-PQ-15FERYXHRDZ9M6Y09MR8WRERWZGJ6F8NTXVHXYRDLM5AAHN0T09NL4UJY86"
cases = [('alphanumeric', 'HELLO WORLD', 'M', -1), ('alphanumeric', 'HELLO WORLD', 'Q', -1),
         ('alphanumeric', 'AGE-SECRET-KEY-1 $%*+./:', 'H', -1),
         ('byte', PQ_KEY, 'Q', -1), ('byte', PQ_KEY, 'M', -1),
         ('byte', KEY, 'Q', -1), ('byte', KEY, 'M', -1), ('byte', KEY, 'L', -1), ('byte', KEY, 'H', -1)]
cases += [('byte', 'https://age-encryption.org/v1', 'L', m) for m in range(8)]
cases += [('byte', 'x' * 300, 'M', -1),
          ('byte', ''.join(chr(33 + (i * 7) % 90) for i in range(560)), 'M', -1),
          ('byte', 'H' * 1200, 'H', -1),
          ('byte', ''.join(chr(48 + i % 43) for i in range(2300)), 'L', -1)]
out = []
for mode, text, ecc, mask in cases:
    seg = QrSegment.make_bytes(text.encode()) if mode == 'byte' else QrSegment.make_alphanumeric(text)
    q = QrCode.encode_segments([seg], E[ecc], 1, 40, mask, False)
    out.append({'mode': mode, 'text': text, 'ecc': ecc, 'mask': mask, 'version': q.get_version(),
                'chosenMask': q.get_mask(), 'modules': packed(q)})
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'Fixtures', 'qr-vectors.json')
with open(path, 'w') as f:
    json.dump(out, f, indent=1)
    f.write('\n')
