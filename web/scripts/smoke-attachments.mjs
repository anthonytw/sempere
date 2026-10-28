// Browser smoke test of attachments (not part of `npm test`): serves dist/
// (with the built CSP also sent as a header) and a vault over a minimal
// WebDAV mount on one origin, opens the note titled "Attachments" in
// Chromium with Playwright, and checks that its images and PDF pages are
// drawn from blob: URLs, that the expected items are placeholders, and that
// a recording plays and its transcript opens, and that the equation's render is
// drawn on a transparent background (not a black box). Fails on any console
// error or CSP violation (a `securitypolicyviolation` listener, `watchCSP`).
// Usage: node scripts/smoke-attachments.mjs VAULT_DIR KEY_FILE [SCREENSHOT_DIR]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { engineNoise, imageAlpha, launchBrowser, openVault, serveVault, watchCSP } from "./smoke-lib.mjs";

const [vaultDir, keyFile, shots = "."] = process.argv.slice(2);
const { base, close } = await serveVault({ mounts: [{ prefix: "/dav/", vaultDir }], csp: true });
const requests = [];

const browser = await launchBrowser();
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
const problems = [];
const cspViolations = await watchCSP(page);
// 404s are expected: the index, and the fixture's missing blob.
page.on("console", (m) => { if ((m.type() === "error" || m.type() === "warning") && !m.text().includes("404") && !engineNoise(m.text())) problems.push(m.text()); });
page.on("pageerror", (e) => problems.push(String(e)));
page.on("request", (r) => requests.push(r.url()));
await page.goto(`${base}/`);
await openVault(page, `${base}/dav/`, readFileSync(keyFile, "utf8"), { webdav: true });
await page.click(".note-list button.note:has(.title:text-is('Attachments'))");
await page.waitForSelector(".page svg", { timeout: 30000 });
// Page 1: two images of the photo, one PNG, the PDF background; page 2 comes into view after scrolling.
try {
  await page.waitForFunction(() => document.querySelectorAll(".page svg image").length >= 4, null, { timeout: 30000 });
} catch (e) {
  await page.screenshot({ path: join(shots, "attachments-failed.png") });
  console.log(JSON.stringify({ problems, list: await page.$$eval(".item-problems li", (els) => els.map((x) => x.textContent)) }, null, 1));
  throw e;
}
await page.screenshot({ path: join(shots, "attachments-p1.png") });
// The equation's render (make-fixture.ts: a 60 × 24 pt PDF, two boxes, no page fill) is drawn on nothing: most of
// it stays clear. pdf.js's own `alpha: false` canvas made it a solid black box in Chromium.
const equationHref = await page.$$eval(".page svg image[width='60'][height='24']", (els) => els.map((e) => e.getAttribute("href")));
const equation = equationHref.length === 1 && equationHref[0] ? await imageAlpha(page, equationHref[0]) : undefined;
const equationOK = !!equation && equation.clear > equation.total / 2 && equation.opaque > 0;
await page.click(".viewport");
for (let i = 0; i < 4; i++) await page.keyboard.press("PageDown");
await page.waitForFunction(() => document.querySelectorAll(".page svg image").length >= 6, null, { timeout: 30000 });
await page.waitForTimeout(500);
await page.screenshot({ path: join(shots, "attachments-p2.png") });
const images = await page.$$eval(".page svg image", (els) => els.map((e) => e.getAttribute("href")?.slice(0, 5)));
const texts = await page.$$eval(".page svg text", (els) => els.map((e) => e.textContent));
const placeholders = await page.$$eval(".item-problems li", (els) => els.map((e) => e.textContent));
await page.click(".recordings summary");
await page.click(".recording >> nth=0 >> button:has-text('Play')");
await page.waitForSelector(".recording audio", { timeout: 30000 });
await page.click(".recording >> nth=0 >> button:has-text('Transcript')");
await page.waitForSelector(".transcript .segments li", { timeout: 30000 });
const segments = await page.$$eval(".transcript .segments li", (els) => els.map((e) => e.textContent));
await page.click(".recording >> nth=1 >> button:has-text('Play')");
await page.waitForFunction(() => /missing/.test(document.querySelectorAll(".rec-status")[1]?.textContent ?? ""), null, { timeout: 30000 });
const missing = await page.$$eval(".rec-status", (els) => els.map((e) => e.textContent));
await page.screenshot({ path: join(shots, "attachments-recordings.png"), fullPage: true });
problems.push(...await cspViolations());
const foreign = requests.filter((u) => !u.startsWith(base) && !u.startsWith("blob:") && !u.startsWith("data:"));
console.log(JSON.stringify({ images, equation, texts, placeholders, segments, missing, foreign, problems }, null, 1));
await browser.close();
close();
// Five placeholders: sticker (unknown kind), missing, HEIC, tampered blob, PDF page 8 of a 7-page PDF (make-fixture.ts).
const ok = images.length >= 6 && images.every((h) => h === "blob:") && placeholders.length === 5 && segments.length === 2
  && texts.some((t) => t?.includes("these lines")) && equationOK && foreign.length === 0 && problems.length === 0;
process.exit(ok ? 0 : 1);
