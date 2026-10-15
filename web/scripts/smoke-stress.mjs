// Browser stress test of large notes (not part of `npm test`; docs/web-viewer.md "Stress tests"):
// opens a 100+ page note and a pageless note with thousands of strokes (the vault of
// scripts/make-stress-fixture.ts), scrolls through each and checks, against budgets:
//   open time          click on the note to its first drawn page
//   frame pacing       requestAnimationFrame intervals while the wheel scrolls (a smoothness proxy)
//   heap and DOM       after a forced GC (Chromium: CDP Performance.getMetrics), at open, at the
//                      end of the scroll and back at the top (no growth: pages and bands go back)
//   scroll anchoring   the page at the top of the view keeps its place on screen when pages load
//                      and their exact heights replace the provisional ones: per wheel step and
//                      across idle measuring, the on-screen jump of that page beyond the wheel's
//                      own distance (c56)
// Prints one `STRESS {json}` line per note, then ok/FAIL lines. BROWSER=webkit runs it in
// Playwright's WebKit (no CDP there: the heap checks are skipped). Budgets are generous (CI runners
// are slow and share cores); BUDGET_SCALE=2 doubles every time and size budget (STRESS_HEAVY=1 does by default), and the
// numbers each run printed are the thing to track.
// Usage: node scripts/smoke-stress.mjs VAULT_DIR KEY_FILE
import { readFileSync } from "node:fs";
import { launchBrowser, openVault, serveVault } from "./smoke-lib.mjs";

const [vaultDir, keyFile] = process.argv.slice(2);
const heavy = process.env.STRESS_HEAVY === "1";
const scale = Number(process.env.BUDGET_SCALE ?? (heavy ? 2 : 1));
const webkit = process.env.BROWSER === "webkit";
const budget = {
  openMs: 2000 * scale,          // click to the first drawn page
  p95FrameMs: 100 * scale,       // 95th percentile frame interval while scrolling
  worstFrameMs: 600 * scale,     // the longest single frame
  heapMB: 400 * scale,           // JS heap after a forced GC, at any checkpoint
  heapGrowthMB: 80 * scale,      // back at the top vs just after opening
  domNodes: 250_000,             // document nodes at any checkpoint
  anchorJumpPx: 1,               // on-screen jump of the anchored page beyond the wheel's distance
};

const { base, close } = await serveVault({ mounts: [{ prefix: "/dav/", vaultDir }] });
let failures = 0;
const check = (ok, what) => { console.log(ok ? "ok  " : "FAIL", what); if (!ok) failures++; };

const browser = await launchBrowser();
const errors = [];
let page, context, cdp;
// The viewer moves a page's `top` in an idle callback and applies the matching pan in the next
// animation frame, so a reading taken between the two shows a jump that is never painted. Readings
// are taken only when no viewer animation-frame callback is pending: `requestAnimationFrame` is
// wrapped to count them, and `window.__quiet(fn, frames)` runs `fn` at the end of the `frames`-th
// quiet frame from now (`fn` returns the value the promise resolves with).
const probeScript = `(() => {
  let outstanding = 0;
  const native = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (cb) => { outstanding++; return native((t) => { try { cb(t); } finally { outstanding--; } sinks(t); }); };
  const waiting = [];
  const sinks = () => { if (outstanding === 0) for (const w of waiting.splice(0)) w(); };
  const tick = () => { sinks(); native(tick); };
  native(tick);
  window.__raf = native;
  // The note views opened so far, weakly: after a forced GC only the open one may be alive.
  const RO = window.ResizeObserver;
  window.__views = [];
  window.ResizeObserver = class extends RO {
    observe(el, options) { if (el.classList?.contains("viewport")) window.__views.push(new WeakRef(el)); super.observe(el, options); }
  };
  window.__quiet = (fn, frames = 2) => new Promise((resolve) => {
    let left = frames;
    const again = () => { if (--left <= 0) resolve(fn()); else waiting.push(again); };
    waiting.push(again);
  });
  window.__quietEach = (fn, ms) => new Promise((resolve) => {
    const end = performance.now() + ms;
    const again = () => { fn(); if (performance.now() < end) waiting.push(again); else resolve(); };
    waiting.push(again);
  });
})();`;

/** A fresh page with the vault open; `init` runs in the page before the viewer's scripts. */
async function session(init) {
  await context?.close();
  context = await browser.newContext({ viewport: { width: 1400, height: 800 } });
  await context.addInitScript(probeScript);
  if (init) await context.addInitScript(init);
  page = await context.newPage();
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("404")) errors.push(m.text()); });
  cdp = webkit ? undefined : await context.newCDPSession(page);
  await page.goto(`${base}/`);
  await openVault(page, `${base}/dav/`, readFileSync(keyFile, "utf8"), { webdav: true });
}
await session();

/** Heap (MB after a forced GC) and document nodes; heap is -1 without CDP. */
async function memory() {
  if (!cdp) return { heapMB: -1, nodes: await page.evaluate(() => document.getElementsByTagName("*").length) };
  await cdp.send("Performance.enable");
  await cdp.send("HeapProfiler.collectGarbage");
  const { metrics } = await cdp.send("Performance.getMetrics");
  const m = Object.fromEntries(metrics.map((x) => [x.name, x.value]));
  return { heapMB: Math.round(m.JSHeapUsedSize / 1048576), nodes: m.Nodes };
}

const settle = () => page.evaluate(() => window.__quiet(() => 0, 3));

/** The first page whose bottom is below the top of the view: its index and its top on screen. */
const anchorProbe = () => page.evaluate(() => window.__quiet(() => {
  const top = document.querySelector(".viewport").getBoundingClientRect().top;
  const pages = document.querySelectorAll(".page");
  for (let i = 0; i < pages.length; i++) {
    const r = pages[i].getBoundingClientRect();
    if (r.bottom > top + 40) return { i, top: r.top - top };
  }
  return { i: -1, top: 0 };
}));
const pageTop = (i) => page.evaluate((k) => window.__quiet(() => {
  const top = document.querySelector(".viewport").getBoundingClientRect().top;
  return document.querySelectorAll(".page")[k].getBoundingClientRect().top - top;
}), i);

const percentile = (xs, p) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(xs.length * p))] ?? 0;

/** Wheel steps of `dy` (screen px) with the frame intervals and anchor jumps measured. */
async function wheel(steps, dy, { jumps = false } = {}) {
  await page.evaluate(() => {
    window.__frames = [];
    window.__run = true;
    let last = performance.now();
    const tick = (t) => { window.__frames.push(t - last); last = t; if (window.__run) window.__raf(tick); };
    window.__raf(tick);
  });
  const worst = { px: 0, step: -1 };
  for (let k = 0; k < steps; k++) {
    const before = jumps ? await anchorProbe() : undefined;
    await page.mouse.wheel(0, dy);
    if (jumps) {
      await settle();
      const after = await pageTop(before.i);
      const jump = Math.abs(after - before.top + dy);
      if (jump > worst.px) { worst.px = jump; worst.step = k; }
    } else {
      await page.waitForTimeout(16);
    }
  }
  const frames = await page.evaluate(() => { window.__run = false; return window.__frames.slice(2); });
  return { frames, worst };
}

/** Idle: no input for `ms`; the largest on-screen move of the page at the top while pages are measured. */
async function idleDrift(ms) {
  const before = await anchorProbe();
  return page.evaluate(async ({ i, ms }) => {
    const top = () => document.querySelector(".viewport").getBoundingClientRect().top;
    const el = document.querySelectorAll(".page")[i];
    const start = el.getBoundingClientRect().top - top();
    let worst = 0;
    await window.__quietEach(() => { worst = Math.max(worst, Math.abs(el.getBoundingClientRect().top - top() - start)); }, ms);
    return worst;
  }, { i: before.i, ms });
}

async function openNote(title) {
  const t0 = Date.now();
  await page.click(`.note-list button.note:has(.title:text-is('${title}'))`);
  await page.locator(".page svg").first().waitFor({ timeout: 60000 });
  const openMs = Date.now() - t0;
  await page.click(".viewport");
  await page.keyboard.press("1");   // actual size
  const box = await page.locator(".viewport").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await settle();
  return openMs;
}
const noteTitle = (re) => page.$$eval(".note-list .title", (els, src) => els.map((e) => e.textContent).find((t) => new RegExp(src).test(t)), re.source);
const counts = () => page.evaluate(() => ({
  pages: document.querySelectorAll(".page").length,
  drawn: [...document.querySelectorAll(".page")].filter((p) => p.querySelector("svg")).length,
  inkNodes: document.querySelectorAll(".page svg path").length,
}));
const contentHeight = () => page.evaluate(() => parseFloat(document.querySelector(".viewport > div").style.height));
const lockBack = async () => { await page.keyboard.press("Escape"); };

function report(name, data) {
  console.log(`STRESS ${JSON.stringify({ browser: webkit ? "webkit" : "chromium", note: name, ...data })}`);
}

async function walk(name, re, { step = 300, steps = 60, growth = true } = {}) {
  const title = await noteTitle(re);
  check(title !== undefined, `${name}: the stress vault has the note`);
  if (title === undefined) return;
  const openMs = await openNote(title);
  const total = await contentHeight();
  const afterOpen = await memory();
  const down = await wheel(steps, step);
  const mid = await memory();
  const end = await page.evaluate(() => { document.querySelector(".viewport").focus(); });
  void end;
  await page.keyboard.press("End");
  await settle();
  const endMem = await memory();
  const endCounts = await counts();
  await page.keyboard.press("Home");
  await settle();
  await page.waitForTimeout(500);
  const top = await memory();
  const topCounts = await counts();
  const p95 = percentile(down.frames, 0.95), worstFrame = Math.max(...down.frames);
  report(name, { contentHeight: Math.round(total), openMs, p95FrameMs: Math.round(p95), worstFrameMs: Math.round(worstFrame), frames: down.frames.length,
    heapMB: { open: afterOpen.heapMB, mid: mid.heapMB, end: endMem.heapMB, top: top.heapMB }, nodes: { open: afterOpen.nodes, mid: mid.nodes, end: endMem.nodes, top: top.nodes },
    drawn: { end: endCounts.drawn, top: topCounts.drawn }, ink: { end: endCounts.inkNodes, top: topCounts.inkNodes } });
  check(openMs < budget.openMs, `${name}: opens in ${openMs} ms (budget ${budget.openMs})`);
  check(p95 < budget.p95FrameMs, `${name}: p95 frame ${Math.round(p95)} ms while scrolling (budget ${budget.p95FrameMs})`);
  check(worstFrame < budget.worstFrameMs, `${name}: worst frame ${Math.round(worstFrame)} ms (budget ${budget.worstFrameMs})`);
  for (const [at, m] of Object.entries({ open: afterOpen, mid, end: endMem, top })) {
    check(m.nodes < budget.domNodes, `${name}: ${m.nodes} document nodes at ${at} (budget ${budget.domNodes})`);
    if (m.heapMB >= 0) check(m.heapMB < budget.heapMB, `${name}: heap ${m.heapMB} MB at ${at} (budget ${budget.heapMB})`);
  }
  if (growth && afterOpen.heapMB >= 0) {
    const grew = top.heapMB - afterOpen.heapMB;
    check(grew < budget.heapGrowthMB, `${name}: heap grew ${grew} MB from open to back at the top (budget ${budget.heapGrowthMB})`);
  }
  return { endCounts, topCounts, afterOpen, endMem, top };
}

const only = process.env.STRESS_ONLY;
const want = (n) => !only || only === n;

// 1. A note of 100+ pages: only the pages around the view are drawn, and the DOM goes back down.
if (want("pages")) {
  const r = await walk("pages", /^Stress: \d+ pages$/);
  if (r) {
    check(r.endCounts.drawn < 12, `pages: at the end ${r.endCounts.drawn} pages are drawn (not all of them)`);
    check(r.topCounts.drawn < 12, `pages: back at the top ${r.topCounts.drawn} pages are drawn`);
    check(r.endMem.nodes < r.afterOpen.nodes * 3, `pages: DOM at the end (${r.endMem.nodes}) stays near the DOM at open (${r.afterOpen.nodes})`);
  }
  await lockBack();
}

// 2. One pageless page with thousands of strokes: only the bands near the view are outlined.
if (want("pageless")) {
  const r = await walk("pageless", /^Stress: pageless \d+$/, { step: 500, steps: 60 });
  if (r) {
    check(r.endCounts.inkNodes > 0, "pageless: the strokes at the end are drawn");
    check(r.endCounts.inkNodes < 20000, `pageless: ${r.endCounts.inkNodes} ink elements at the end (the bands, not all the strokes)`);
    check(r.topCounts.inkNodes < 20000, `pageless: ${r.topCounts.inkNodes} ink elements back at the top`);
  }
  await lockBack();
}

// 2b. Thousands of strokes inside a few screens: one band holds hundreds, the window thousands.
if (want("dense")) {
  const r = await walk("dense", /pageless dense/, { step: 120, steps: 60, growth: false });
  if (r) check(r.endCounts.inkNodes > 0, "dense: the strokes at the end are drawn");
  await lockBack();
}

// 2c. Zoomed far out, a page's whole height is near the viewport: all its strokes are outlined at once.
if (want("pageless")) {
  const title = await noteTitle(/^Stress: pageless \d+$/);
  await openNote(title);
  const t0 = Date.now();
  for (let k = 0; k < 8; k++) {
    await page.keyboard.down("Control");
    await page.mouse.wheel(0, 300);
    await page.keyboard.up("Control");
  }
  await settle();
  const zoomMs = Date.now() - t0;
  const m = await memory();
  const c = await counts();
  report("zoomout", { zoomMs, heapMB: m.heapMB, nodes: m.nodes, ink: c.inkNodes });
  check(zoomMs < budget.openMs, `zoomout: all of the pageless page at the minimum zoom in ${zoomMs} ms (budget ${budget.openMs})`);
  check(m.nodes < budget.domNodes, `zoomout: ${m.nodes} document nodes (budget ${budget.domNodes})`);
  if (m.heapMB >= 0) check(m.heapMB < budget.heapMB, `zoomout: heap ${m.heapMB} MB (budget ${budget.heapMB})`);
  await lockBack();
}

// 2d. Switching notes frees the note view left behind (a view that stays alive keeps its whole DOM).
if (cdp && want("pages")) {
  await cdp.send("HeapProfiler.collectGarbage");
  await page.waitForTimeout(300);
  await cdp.send("HeapProfiler.collectGarbage");
  const { total, alive } = await page.evaluate(() => ({ total: window.__views.length, alive: window.__views.filter((w) => w.deref()).length }));
  report("views", { total, alive });
  check(total >= 4 && alive <= 1, `views: ${alive} of ${total} note views still alive after switching notes (at most the open one)`);
}

// 3. Scroll anchoring (c56): pageless pages whose exact heights differ from the provisional one
// (one chunk). Two sessions make the height changes happen where the check can see them: with idle
// measuring switched off, pages change height only when they are drawn, so after a jump down
// scrolling up draws pages above the top of the view with new heights; with idle measuring held back, a jump far down
// lands on provisional heights and the measuring that follows changes every height above the view.
const anchorPages = [
  { name: "drawn", init: "window.requestIdleCallback = () => 0;", ms: 500 },
  { name: "idle", init: "window.requestIdleCallback = (f) => setTimeout(f, 700);", ms: 3500 },
];
for (const { name, init, ms } of want("anchor") ? anchorPages : []) {
  await session(init);
  const deep = await noteTitle(/deep pages/);
  check(deep !== undefined, `anchor/${name}: the stress vault has the deep-pages note`);
  if (deep === undefined) continue;
  await openNote(deep);
  let drift = 0, down = { worst: { px: 0, step: -1 } }, up = down, jump = { px: 0 };
  if (name === "idle") {
    // Jump far down at once (about page 40 at provisional heights), then watch the page there while pages above are measured.
    await page.mouse.wheel(0, 40000);
    await settle();
    drift = await idleDrift(ms);
  } else {
    // Jump far down (about page 40 at provisional heights); every page above is still provisional, and scrolling
    // back up draws each of them above the top of the view before it comes on screen.
    await page.mouse.wheel(0, 40000);
    await settle();
    up = await wheel(heavy ? 80 : 30, -700, { jumps: true });
    down = await wheel(heavy ? 60 : 20, 1500, { jumps: true });
    drift = await idleDrift(ms);
  }
  const px = (x) => Math.round(x * 100) / 100;
  report(`anchor/${name}`, { idleDriftPx: px(drift), downJumpPx: px(down.worst.px), upJumpPx: px(up.worst.px) });
  check(drift <= budget.anchorJumpPx, `anchor/${name}: the page at the top drifts ${drift.toFixed(2)} px while idle (budget ${budget.anchorJumpPx})`);
  check(down.worst.px <= budget.anchorJumpPx, `anchor/${name}: scrolling down, worst jump ${down.worst.px.toFixed(2)} px at step ${down.worst.step} (budget ${budget.anchorJumpPx})`);
  check(up.worst.px <= budget.anchorJumpPx, `anchor/${name}: scrolling up, worst jump ${up.worst.px.toFixed(2)} px at step ${up.worst.step} (budget ${budget.anchorJumpPx})`);
  void jump;
}

check(errors.length === 0, `no page errors: ${errors.slice(0, 3).join("; ")}`);
await browser.close();
close();
if (failures) process.exit(1);
console.log("all passed");
