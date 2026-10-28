// Image blobs (format.md §8.2.5): what a JPEG or PNG says about itself
// before it is decoded, and the bytes without metadata, as
// Sources/SempereRender/JPEG.swift and PNGDecoder.swift read them. The
// browser decodes the pixels; these checks decide what it is given: only
// JPEG (baseline or progressive Huffman, 8 bits, 1 or 3 components) and
// PNG, within the pixel limits, never anything it would have to sniff.

import { concat } from "../vault/bytes.ts";

export class ImageFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ImageFormatError";
  }
}

/** Limits for untrusted images (Swift `ImageLimits`). */
export const imageLimits = {
  /** Largest image decoded (§8.4). */
  maxPixels: 100_000_000,
  /** Pixels a file may claim per byte of its size, plus an allowance. */
  pixelsPerInputByte: 1024,
  pixelAllowance: 1 << 20,
  /** Largest image blob read (as the CLI's exports). */
  maxBlobBytes: 64 * 1024 * 1024,
};

export interface ImageInfo {
  format: "jpeg" | "png";
  /** Stored (unoriented) size in pixels. */
  width: number;
  height: number;
  /** The media type to hand the browser. */
  type: "image/jpeg" | "image/png";
}

const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

function be16(d: Uint8Array, i: number): number {
  return ((d[i] ?? 0) << 8) | (d[i + 1] ?? 0);
}

function be32(d: Uint8Array, i: number): number {
  return (((d[i] ?? 0) << 24) >>> 0) + (((d[i + 1] ?? 0) << 16) | ((d[i + 2] ?? 0) << 8) | (d[i + 3] ?? 0));
}

type JPEGPart = { kind: "marker"; code: number; body: [number, number]; whole: [number, number] } | { kind: "entropy"; range: [number, number] };

/** The segments of a JPEG, in order, until EOI (Swift `JPEG.walk`). */
function walkJPEG(d: Uint8Array, visit: (p: JPEGPart) => boolean | void): void {
  if (d[0] !== 0xff || d[1] !== 0xd8) throw new ImageFormatError("not a JPEG");
  visit({ kind: "marker", code: 0xd8, body: [2, 2], whole: [0, 2] });
  let i = 2;
  while (i < d.length) {
    if (d[i] !== 0xff) throw new ImageFormatError("JPEG: marker expected");
    const start = i;
    while (i < d.length && d[i] === 0xff) i++;
    if (i >= d.length) throw new ImageFormatError("JPEG: truncated");
    const code = d[i] ?? 0;
    i++;
    if (code === 0xd9) {
      visit({ kind: "marker", code, body: [i, i], whole: [start, i] });
      return;
    }
    if ((code >= 0xd0 && code <= 0xd7) || code === 0x01) {
      if (visit({ kind: "marker", code, body: [i, i], whole: [start, i] }) === false) return;
      continue;
    }
    if (i + 2 > d.length) throw new ImageFormatError("JPEG: truncated segment");
    const len = be16(d, i);
    if (len < 2 || i + len > d.length) throw new ImageFormatError("JPEG: bad segment length");
    if (visit({ kind: "marker", code, body: [i + 2, i + len], whole: [start, i + len] }) === false) return;
    i += len;
    if (code === 0xda) {
      let j = i;
      while (j < d.length) {
        if (d[j] === 0xff && j + 1 < d.length) {
          const n = d[j + 1] ?? 0;
          if (n !== 0 && !(n >= 0xd0 && n <= 0xd7)) break;
        }
        j++;
      }
      if (j > i) visit({ kind: "entropy", range: [i, j] });
      i = j;
    }
  }
}

function checkPixels(width: number, height: number, inputBytes: number, maxPixels: number): void {
  const pixels = width * height;
  const plausible = inputBytes * imageLimits.pixelsPerInputByte + imageLimits.pixelAllowance;
  if (!(width > 0 && height > 0) || pixels > maxPixels || pixels > plausible) {
    throw new ImageFormatError(`image of ${width} × ${height} pixels is over the ${Math.floor(maxPixels / 1_000_000)} MP limit`);
  }
}

function jpegInfo(d: Uint8Array): ImageInfo {
  let info: ImageInfo | undefined;
  walkJPEG(d, (p) => {
    if (p.kind !== "marker") return;
    const [b, e] = p.body;
    switch (p.code) {
      case 0xc0: case 0xc1: case 0xc2: {
        if (e - b < 6) throw new ImageFormatError("JPEG: short frame header");
        if (d[b] !== 8) throw new ImageFormatError(`${d[b]}-bit JPEG cannot be shown`);
        const height = be16(d, b + 1), width = be16(d, b + 3), n = d[b + 5] ?? 0;
        if (n !== 1 && n !== 3) throw new ImageFormatError(n === 4 ? "CMYK JPEG cannot be shown" : `JPEG with ${n} components cannot be shown`);
        if (width === 0) throw new ImageFormatError("JPEG: zero width");
        if (height === 0) throw new ImageFormatError("JPEG with a DNL height cannot be shown");
        info = { format: "jpeg", width, height, type: "image/jpeg" };
        return false;
      }
      case 0xc3: case 0xc5: case 0xc6: case 0xc7: case 0xc9: case 0xca: case 0xcb: case 0xcd: case 0xce: case 0xcf:
        throw new ImageFormatError("lossless, hierarchical or arithmetic-coded JPEG cannot be shown");
      case 0xda:
        throw new ImageFormatError("JPEG: scan before frame header");
    }
  });
  if (!info) throw new ImageFormatError("JPEG: no frame header");
  return info;
}

interface PNGChunk {
  name: string;
  whole: [number, number];
  body: [number, number];
}

function pngChunks(d: Uint8Array): PNGChunk[] {
  if (!pngSignature.every((b, i) => d[i] === b)) throw new ImageFormatError("not a PNG");
  const out: PNGChunk[] = [];
  let i = 8;
  while (i < d.length) {
    if (i + 12 > d.length) throw new ImageFormatError("PNG: truncated chunk");
    const len = be32(d, i);
    if (len > d.length - i - 12) throw new ImageFormatError("PNG: bad chunk length");
    const name = String.fromCharCode(...d.subarray(i + 4, i + 8));
    if (!/^[A-Za-z]{4}$/.test(name)) throw new ImageFormatError("PNG: bad chunk name");
    out.push({ name, whole: [i, i + 12 + len], body: [i + 8, i + 8 + len] });
    i += 12 + len;
    if (name === "IEND") break;
  }
  return out;
}

function pngInfo(d: Uint8Array, chunks: PNGChunk[]): ImageInfo {
  const ihdr = chunks[0];
  if (!ihdr || ihdr.name !== "IHDR" || ihdr.body[1] - ihdr.body[0] !== 13) throw new ImageFormatError("PNG: IHDR");
  const b = ihdr.body[0];
  const width = be32(d, b), height = be32(d, b + 4), depth = d[b + 8] ?? 0, colorType = d[b + 9] ?? 0;
  if (!(width > 0 && height > 0 && width <= 0x7fffffff && height <= 0x7fffffff)) throw new ImageFormatError("PNG: image size");
  const depths: Record<number, number[]> = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
  if (!(depths[colorType] ?? []).includes(depth)) throw new ImageFormatError(`PNG: colour type ${colorType} with bit depth ${depth}`);
  if (d[b + 10] !== 0 || d[b + 11] !== 0 || (d[b + 12] ?? 2) > 1) throw new ImageFormatError("PNG: compression, filter or interlace method");
  return { format: "png", width, height, type: "image/png" };
}

/**
 * What an image blob is, from its first bytes (as the CLI: JPEG and PNG by
 * signature, whatever the reference's `type`). HEIC and anything else is
 * refused: the viewer draws a placeholder (§8.5.2).
 */
export function imageInfo(d: Uint8Array, maxPixels = imageLimits.maxPixels): ImageInfo {
  let info: ImageInfo;
  if (d[0] === 0xff && d[1] === 0xd8) info = jpegInfo(d);
  else if (pngSignature.every((b, i) => d[i] === b)) info = pngInfo(d, pngChunks(d));
  else if (d.length >= 12 && String.fromCharCode(...d.subarray(4, 8)) === "ftyp") {
    throw new ImageFormatError("HEIC images cannot be shown in the viewer (convert it to JPEG in the app)");
  } else throw new ImageFormatError("unsupported image type");
  checkPixels(info.width, info.height, d.length, maxPixels);
  return info;
}

/**
 * The image without metadata (§8.2.5), as the exports strip it: JPEG
 * without APPn other than APP0, APP2 and APP14, without COM and anything
 * after EOI; PNG without ancillary chunks other than tRNS, gAMA, cHRM,
 * sRGB, iCCP and pHYs. Image data is copied byte for byte. Besides privacy,
 * this keeps the browser from applying an orientation stored in the file:
 * the item's `orientation` is the only one that counts.
 */
export function stripMetadata(d: Uint8Array): Uint8Array {
  if (d[0] === 0xff && d[1] === 0xd8) {
    const parts: Uint8Array[] = [];
    let sawEOI = false;
    walkJPEG(d, (p) => {
      if (p.kind === "entropy") {
        parts.push(d.subarray(p.range[0], p.range[1]));
        return;
      }
      if (p.code >= 0xe0 && p.code <= 0xef && p.code !== 0xe0 && p.code !== 0xe2 && p.code !== 0xee) return;
      if (p.code === 0xfe) return;
      if (p.code === 0xd9) sawEOI = true;
      parts.push(d.subarray(p.whole[0], p.whole[1]));
    });
    if (!sawEOI) parts.push(Uint8Array.of(0xff, 0xd9));
    return concat(parts);
  }
  const chunks = pngChunks(d);
  pngInfo(d, chunks);
  const keep = new Set(["tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "pHYs"]);
  const critical = (name: string) => name.charCodeAt(0) < 0x61;
  return concat([d.subarray(0, 8), ...chunks.filter((c) => critical(c.name) || keep.has(c.name)).map((c) => d.subarray(c.whole[0], c.whole[1]))]);
}
