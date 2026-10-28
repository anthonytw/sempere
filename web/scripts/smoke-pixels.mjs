// Browser pixel diff of the viewer's pages against the Swift CLI's SVG export (not part of
// `npm test`; docs/web-viewer.md "Stress tests"). `crosscheck.test.ts` already proves the TypeScript
// renderer writes the CLI's SVG byte for byte; this checks what the browser makes of it: for every
// page of every note with a golden export, the SVG the viewer put in the DOM (paper, ink, banded
// or lazily outlined pageless pages, release and redraw) is serialized and rasterized in the browser
// next to the exported file, and the pixels of the rows that were on screen must agree.
//   GOLDEN_DIR/<note id>.json         the export's JSON (meta.title names the note)
//   GOLDEN_DIR/<note id>/pNNN.svg     the export's page SVGs (`sempere export --format svg`)
// A page with items (text boxes, images, PDF pages, recordings) is skipped: the CLI embeds its own
// font subsets and the viewer uses the browser's (docs/web-viewer.md "Limits"), so those pixels differ
// by design; items-crosscheck.test.ts compares them structurally. Paper and ink are compared.
// Usage: node scripts/smoke-pixels.mjs VAULT_DIR KEY_FILE GOLDEN_DIR [TITLE_REGEX]
// Env: PIXEL_TOLERANCE (per-channel delta that counts as different, default 2),
//      PIXEL_MAX_PIXELS (different pixels allowed per page, default 0: the same engine draws the same
//      geometry the same way, so any difference is a real one),
//      PIXEL_DUMP=dir (writes the viewer's SVG and the golden of each page that differs).
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchBrowser, openVault, serveVault } from "./smoke-lib.mjs";

const [vaultDir, keyFile, goldenDir, only] = process.argv.slice(2);
const tolerance = Number(process.env.PIXEL_TOLERANCE ?? 2);
const maxPixels = Number(process.env.PIXEL_MAX_PIXELS ?? 0);
const { base, close } = await serveVault({ mounts: [{ prefix: "/dav/", vaultDir }] });
let failures = 0;
const check = (ok, what) => { console.log(ok ? "ok  " : "FAIL", what); if (!ok) failures++; };

const browser = await launchBrowser();
const page = await browser.newPage({ viewport: { width: 1400, height: 800 } });
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("404")) errors.push(m.text()); });
const raster = await browser.newPage();   // about:blank: no CSP, so a blob image loads
await raster.goto("about:blank");

/** Rasterizes rows [y0, y1) of both SVG texts at their viewBox size and counts the pixels that differ. */
const compare = (a, b, y0, y1, tol) => raster.evaluate(async ({ a, b, y0, y1, tol }) => {
  const prepare = (text) => {
    const doc = new DOMParser().parseFromString(text, "image/svg+xml");
    const svg = doc.documentElement;
    const [, , w, h] = svg.getAttribute("viewBox").split(/\s+/).map(Number);
    svg.setAttribute("width", String(w));
    svg.setAttribute("height", String(h));
    return { text: new XMLSerializer().serializeToString(svg), w, h };
  };
  const pa = prepare(a), pb = prepare(b);
  if (pa.w !== pb.w || pa.h !== pb.h) return { sizes: [`${pa.w}x${pa.h}`, `${pb.w}x${pb.h}`] };
  const top = Math.max(0, Math.floor(y0)), bottom = Math.min(pa.h, Math.ceil(y1));
  if (bottom <= top) return { total: 0, diff: 0, worst: 0 };
  // Only the rows asked for are drawn: the canvas is that tall and the image is shifted up.
  const draw = async ({ text, w, h }) => {
    const url = URL.createObjectURL(new Blob([text], { type: "image/svg+xml" }));
    const img = new Image();
    img.src = url;
    await img.decode();
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = bottom - top;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, w, bottom - top);
    ctx.drawImage(img, 0, -top, w, h);
    URL.revokeObjectURL(url);
    const data = ctx.getImageData(0, 0, w, bottom - top).data;
    canvas.width = canvas.height = 0;   // give the memory back now
    return data;
  };
  const da = await draw(pa), db = await draw(pb);
  let diff = 0, worst = 0, firstRow = -1;
  for (let i = 0; i < da.length; i += 4) {
    const d = Math.max(Math.abs(da[i] - db[i]), Math.abs(da[i + 1] - db[i + 1]), Math.abs(da[i + 2] - db[i + 2]), Math.abs(da[i + 3] - db[i + 3]));
    if (d > tol) { diff++; if (firstRow < 0) firstRow = top + Math.floor(i / 4 / pa.w); }
    if (d > worst) worst = d;
  }
  return { total: da.length / 4, diff, worst, firstRow };
}, { a, b, y0, y1, tol });

const key = readFileSync(keyFile, "utf8");
await page.goto(`${base}/`);
await openVault(page, `${base}/dav/`, key, { webdav: true });

const notes = readdirSync(goldenDir).filter((f) => f.endsWith(".json") && !f.includes(".summaries.")).map((f) => f.slice(0, -5))
  .map((id) => {
    const note = JSON.parse(readFileSync(join(goldenDir, `${id}.json`), "utf8"));
    const inkOnly = new Set((note.pages ?? []).flatMap((p, i) => ((p.items ?? []).length === 0 ? [i] : [])));
    return { id, title: note.meta?.title, inkOnly, infinite: note.meta?.pageSize?.infinite === true };
  })
  .filter((n) => typeof n.title === "string" && n.inkOnly.size > 0 && (!only || new RegExp(only).test(n.title)));
check(notes.length > 0, `${notes.length} golden notes to compare`);

let pagesCompared = 0;
for (const { id, title, inkOnly, infinite } of notes) {
  const goldens = new Map();
  for (const f of existsSync(join(goldenDir, id)) ? readdirSync(join(goldenDir, id)) : []) {
    const m = /^p(\d+)\.svg$/.exec(f);
    if (m && inkOnly.has(Number(m[1]) - 1)) goldens.set(Number(m[1]) - 1, readFileSync(join(goldenDir, id, f), "utf8"));
  }
  const esc = title.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
  const entry = page.locator(`.note-list button.note:has(.title:text-is('${esc}'))`);
  if ((await entry.count()) === 0) { console.log(`skip ${title}: not in the note list (deleted)`); continue; }
  await entry.click();
  await page.waitForSelector(".page svg", { timeout: 60000 });
  await page.click(".viewport");
  await page.keyboard.press("1");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.keyboard.press("Home");
  const stats = new Map();   // page index -> { diff, total, worst, firstRow, sizes, svg } over every row compared
  const settle = () => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 60)))));
  const transform = () => page.evaluate(() => document.querySelector(".viewport > div").style.transform);

  /** Steps the view with `key`, comparing every row of every drawn page that is on screen and not yet compared in this sweep. */
  async function sweep(key, maxSteps) {
    const covered = new Map();   // page index -> [first, last] row compared (the view moves steadily: one interval)
    for (let step = 0; step < maxSteps; step++) {
      await settle();
      // Every drawn page now: its serialized SVG and the rows of it that are on screen.
      const drawn = await page.evaluate(() => {
        const vp = document.querySelector(".viewport").getBoundingClientRect();
        const out = [];
        document.querySelectorAll(".page").forEach((el, i) => {
          const svg = el.querySelector("svg");
          const r = el.getBoundingClientRect();
          if (!svg || r.bottom < vp.top || r.top > vp.bottom) return;
          const scale = r.width / Number(svg.getAttribute("width"));
          out.push({ i, y0: (Math.max(vp.top, r.top) - r.top) / scale, y1: (Math.min(vp.bottom, r.bottom) - r.top) / scale,
            svg: new XMLSerializer().serializeToString(svg) });
        });
        return out;
      });
      for (const d of drawn) {
        const golden = goldens.get(d.i);
        if (golden === undefined || d.svg.includes("blob:")) continue;
        const done = covered.get(d.i);
        const ranges = !done ? [[d.y0, d.y1]] : [[d.y0, Math.min(d.y1, done[0])], [Math.max(d.y0, done[1]), d.y1]].filter(([lo, hi]) => hi - lo >= 1);
        covered.set(d.i, done ? [Math.min(done[0], d.y0), Math.max(done[1], d.y1)] : [d.y0, d.y1]);
        for (const [lo, hi] of ranges) {
          const r = await compare(d.svg, golden, lo, hi, tolerance);
          const st = stats.get(d.i) ?? { diff: 0, total: 0, worst: 0, firstRow: -1, sizes: undefined, svg: d.svg, golden };
          st.diff += r.diff ?? 0;
          st.total += r.total ?? 0;
          st.worst = Math.max(st.worst, r.worst ?? 0);
          if (r.diff > 0 && st.firstRow < 0) { st.firstRow = r.firstRow; st.svg = d.svg; }
          st.sizes ??= r.sizes;
          stats.set(d.i, st);
        }
      }
      const before = await transform();
      await page.keyboard.press(key);
      await settle();
      if (before === (await transform())) break;
    }
  }
  await sweep("PageDown", 20000);
  // Back up: bands that left the view come in again, strokes with lower numbers after higher ones (a few screens' worth is
  // enough to see the order kept, and keeps the heavy vault's run short).
  if (infinite) await sweep("PageUp", 120);
  for (const [i, r] of [...stats].sort((a, b) => a[0] - b[0])) {
    const { svg, golden } = r;
    const frac = r.sizes ? 1 : r.total === 0 ? 0 : r.diff / r.total;
    pagesCompared++;
    if (process.env.PIXEL_DUMP && (r.sizes || r.diff > maxPixels)) {
      mkdirSync(process.env.PIXEL_DUMP, { recursive: true });
      writeFileSync(join(process.env.PIXEL_DUMP, `${id}-p${i + 1}-viewer.svg`), svg);
      writeFileSync(join(process.env.PIXEL_DUMP, `${id}-p${i + 1}-golden.svg`), golden);
    }
    check(!r.sizes && r.diff <= maxPixels, `${title} p${i + 1}: ${r.sizes ? `sizes differ ${r.sizes.join(" vs ")}` : `${r.diff} of ${r.total} pixels differ (${(frac * 100).toFixed(4)}%, worst delta ${r.worst}${r.firstRow >= 0 ? `, first at row ${r.firstRow}` : ""})`}`);
  }
  check(stats.size > 0 || goldens.size === 0, `${title}: ${stats.size} of ${goldens.size} pages compared`);
}
check(pagesCompared > 0, `${pagesCompared} pages compared`);
check(errors.length === 0, `no errors: ${errors.slice(0, 3).join("; ")}`);
await browser.close();
close();
if (failures) process.exit(1);
console.log("all passed");
