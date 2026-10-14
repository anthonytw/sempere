// pdf.js (the viewer's PDF renderer) against format.md §8.2.6 and §8.5.1:
// its unscaled viewport is the effective page (CropBox ∩ MediaBox turned by
// /Rotate), and `cropViewport` draws exactly the requested crop of it, with
// the point mapping of the §8.5.1 tables (`pdfToEffective`). Rendered in
// Node with pdf.js's own canvas dependency.

import { describe, expect, it } from "vitest";
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs";
import { cropViewport, maxPDFPixels } from "../src/ui/pdf.ts";
import { apply, pdfToEffective } from "../src/render/items.ts";

const canvasLib = await import("@napi-rs/canvas").catch(() => undefined);

/** A one-page PDF with a red rectangle at user-space `[40, 40, 120, 80]`. */
function onePage(media: number[], crop: number[] | undefined, rotate: number): Uint8Array {
  const content = "0.7 0.1 0.1 rg 40 40 120 80 re f";
  const objs = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [${media.join(" ")}]${crop ? ` /CropBox [${crop.join(" ")}]` : ""} /Rotate ${rotate} /Contents 4 0 R >>`,
    `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
  ];
  let pdf = "%PDF-1.4\n";
  const offsets: number[] = [];
  objs.forEach((o, i) => {
    offsets.push(pdf.length);
    pdf += `${i + 1} 0 obj\n${o}\nendobj\n`;
  });
  const xref = pdf.length;
  pdf += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("")}`;
  pdf += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return new TextEncoder().encode(pdf);
}

const cases: { media: number[]; crop?: number[]; rotate: number }[] = [
  { media: [0, 0, 400, 300], rotate: 0 },
  { media: [0, 0, 400, 300], crop: [20, 20, 380, 280], rotate: 90 },
  { media: [10, 5, 400, 300], crop: [0, 0, 300, 250], rotate: 180 },
  { media: [0, 0, 400, 300], crop: [30, 10, 390, 290], rotate: 270 },
  { media: [0, 0, 400, 300], rotate: -90 },
];

describe.runIf(canvasLib !== undefined)("pdf.js and the effective page", () => {
  for (const c of cases) {
    it(`maps /Rotate ${c.rotate} with ${c.crop ? "a CropBox" : "the MediaBox"} as §8.5.1 says`, async () => {
      const doc = await getDocument({ data: onePage(c.media, c.crop, c.rotate), verbosity: 0 }).promise;
      const page = await doc.getPage(1);
      const [mx0, my0, mx1, my1] = c.media as [number, number, number, number];
      const [cx0, cy0, cx1, cy1] = (c.crop ?? c.media) as [number, number, number, number];
      const vis = { x0: Math.max(mx0, cx0), y0: Math.max(my0, cy0), x1: Math.min(mx1, cx1), y1: Math.min(my1, cy1) };
      const rot = ((c.rotate % 360) + 360) % 360;
      const bw = vis.x1 - vis.x0, bh = vis.y1 - vis.y0;
      const v1 = page.getViewport({ scale: 1 });
      expect([v1.width, v1.height]).toEqual(rot % 180 === 0 ? [bw, bh] : [bh, bw]);
      // The red rectangle's centre and a point beside it, in effective-page coordinates.
      const m = pdfToEffective(vis, rot);
      const inside = apply(m, { x: 100, y: 80 });
      const outside = apply(m, { x: 200, y: 200 });
      // Render a crop around both points at 2 px/pt and sample them.
      const crop = { x: Math.min(inside.x, outside.x) - 10, y: Math.min(inside.y, outside.y) - 10, w: 0, h: 0 };
      crop.w = Math.abs(inside.x - outside.x) + 20;
      crop.h = Math.abs(inside.y - outside.y) + 20;
      const { viewport, width, height, scale } = cropViewport(page, crop, 2);
      const canvas = (canvasLib as typeof import("@napi-rs/canvas")).createCanvas(width, height);
      await page.render({ canvas: canvas as unknown as HTMLCanvasElement, viewport, background: "#ffffff" }).promise;
      const ctx = canvas.getContext("2d");
      const px = (p: { x: number; y: number }) => [...ctx.getImageData(Math.round((p.x - crop.x) * scale), Math.round((p.y - crop.y) * scale), 1, 1).data];
      expect(px(inside)).toEqual([178, 26, 26, 255]);
      expect(px(outside)).toEqual([255, 255, 255, 255]);
      await doc.loadingTask.destroy();
    });
  }

  it("keeps a crop within the pixel budget", async () => {
    const doc = await getDocument({ data: onePage([0, 0, 400, 300], undefined, 0), verbosity: 0 }).promise;
    const page = await doc.getPage(1);
    const r = cropViewport(page, { x: 0, y: 0, w: 400, h: 300 }, 100);
    expect(r.width * r.height).toBeLessThanOrEqual(maxPDFPixels * 1.01);
    expect(r.scale).toBeLessThan(100);
    await doc.loadingTask.destroy();
  });
});
