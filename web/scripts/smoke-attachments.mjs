// Browser smoke test of attachments (not part of `npm test`): serves dist/
// (with the built CSP also sent as a header) and a vault over a minimal
// WebDAV mount on one origin, opens the note titled "Attachments" in
// Chromium with Playwright, and checks that its images and PDF pages are
// drawn from blob: URLs, that the expected items are placeholders, and that
// a recording plays and its transcript opens. Fails on any console error or
// CSP violation.
// Usage: node scripts/smoke-attachments.mjs VAULT_DIR KEY_FILE [SCREENSHOT_DIR]
import { createServer } from "node:http";
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, extname } from "node:path";
// PLAYWRIGHT: path to playwright/index.mjs when it is not installed here.
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");

const [vaultDir, keyFile, shots = "."] = process.argv.slice(2);
const dist = join(import.meta.dirname, "..", "dist");
const html = readFileSync(join(dist, "index.html"), "utf8");
const csp = (/http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html)?.[1] ?? "").replaceAll("&#39;", "'");
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json" };

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const path = decodeURIComponent(url.pathname);
  const send = (status, body, type = "application/octet-stream") => {
    res.writeHead(status, { "content-type": type, "content-security-policy": csp + "; frame-ancestors 'none'" });
    res.end(body);
  };
  if (path.startsWith("/dav/")) {
    const rel = path.slice(5);
    if (rel.includes("..")) return send(400, "");
    const file = join(vaultDir, rel);
    if (req.method === "PROPFIND") {
      if (!existsSync(file) || !statSync(file).isDirectory()) return send(404, "");
      const items = readdirSync(file).map((n) => `<d:response><d:href>/dav/${rel}${encodeURIComponent(n)}${statSync(join(file, n)).isDirectory() ? "/" : ""}</d:href></d:response>`);
      return send(207, `<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/${rel}</d:href></d:response>${items.join("")}</d:multistatus>`, "application/xml");
    }
    if (!existsSync(file) || statSync(file).isDirectory()) return send(404, "");
    return send(200, readFileSync(file));
  }
  const f = join(dist, path === "/" ? "index.html" : path);
  if (!existsSync(f) || statSync(f).isDirectory()) return send(404, "");
  send(200, readFileSync(f), types[extname(f)] ?? "application/octet-stream");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const requests = [];

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
const problems = [];
// 404s are expected: rewrap-journal.json, the index, and the fixture's missing blob.
page.on("console", (m) => { if ((m.type() === "error" || m.type() === "warning") && !m.text().includes("404")) problems.push(m.text()); });
page.on("pageerror", (e) => problems.push(String(e)));
page.on("request", (r) => requests.push(r.url()));
await page.goto(`${base}/`);
await page.fill("input[type=url]", `${base}/dav/`);
await page.selectOption("select", "webdav");
await page.click("form button[type=submit]");
await page.fill("textarea", readFileSync(keyFile, "utf8"));
await page.click("form:has(textarea) button[type=submit]");
await page.waitForFunction(() => /\d+ notes?( ·|$)/.test(document.querySelector(".status")?.textContent ?? ""), null, { timeout: 30000 });
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
const foreign = requests.filter((u) => !u.startsWith(base) && !u.startsWith("blob:") && !u.startsWith("data:"));
console.log(JSON.stringify({ images, texts, placeholders, segments, missing, foreign, problems }, null, 1));
await browser.close();
server.close();
// Five placeholders: sticker (unknown kind), missing, HEIC, tampered blob, PDF page 8 of a 7-page PDF (make-fixture.ts).
const ok = images.length >= 6 && images.every((h) => h === "blob:") && placeholders.length === 5 && segments.length === 2
  && texts.some((t) => t?.includes("these lines")) && foreign.length === 0 && problems.length === 0;
process.exit(ok ? 0 : 1);
