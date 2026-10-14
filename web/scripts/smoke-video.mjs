// Browser smoke test of video items (format.md §8.2.7; not part of `npm test`):
// serves dist/ (with the built CSP also sent as a header) and a vault over a
// minimal WebDAV mount on one origin, opens the note titled "Video clips" of
// web/test/fixtures/render.sempere in Chromium with Playwright, and checks
// that posters are drawn from blob: URLs under play marks, that a tap on a
// clip decrypts it into a <video> with a blob: source, that closing revokes
// it, and that a missing clip says so. Fails on any console error or CSP
// violation.
// Usage: node scripts/smoke-video.mjs VAULT_DIR KEY_FILE [SCREENSHOT_DIR]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { launchChromium, openVault, serveVault } from "./smoke-lib.mjs";

const [vaultDir, keyFile, shots = "."] = process.argv.slice(2);
const { base, close } = await serveVault({ mounts: [{ prefix: "/dav/", vaultDir }], csp: true });
const requests = [];

const browser = await launchChromium();
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
const problems = [];
// 404s are expected: rewrap-journal.json, the index, and the fixture's missing blob.
page.on("console", (m) => { if ((m.type() === "error" || m.type() === "warning") && !m.text().includes("404")) problems.push(m.text()); });
page.on("pageerror", (e) => problems.push(String(e)));
page.on("request", (r) => requests.push(r.url()));
await page.goto(`${base}/`);
await openVault(page, `${base}/dav/`, readFileSync(keyFile, "utf8"), { webdav: true });
await page.click(".note-list button.note:has(.title:text-is('Video clips'))");
await page.waitForSelector(".page svg", { timeout: 30000 });
// Three posters (photo, and the PNG twice: one set later by another device), two placeholders, five play marks.
await page.waitForFunction(() => document.querySelectorAll(".page svg image").length >= 3, null, { timeout: 30000 });
const images = await page.$$eval(".page svg image", (els) => els.map((e) => e.getAttribute("href")?.slice(0, 5)));
const marks = await page.$$eval(".page svg circle", (els) => els.length);
await page.screenshot({ path: join(shots, "video-page.png") });
// Tap the first clip on the page: the panel opens and plays it.
const box = await page.$eval(".page svg", (svg) => {
  const r = svg.getBoundingClientRect();
  return { x: r.left, y: r.top, s: r.width / 612 };
});
await page.mouse.click(box.x + (72 + 160) * box.s, box.y + (72 + 90) * box.s);
await page.waitForSelector(".video-player video", { timeout: 30000 });
const src = await page.$eval(".video-player video", (v) => v.getAttribute("src")?.slice(0, 5));
await page.waitForTimeout(800);
const state = await page.$eval(".video-player video", (v) => ({ readyState: v.readyState, error: v.error?.code ?? 0, width: v.videoWidth }));
await page.screenshot({ path: join(shots, "video-playing.png"), fullPage: true });
await page.click(".video-player button:has-text('Close')");
const closed = await page.$$eval(".video-player video", (els) => els.length);
// Video 4's clip was never written: missing.
await page.click(".videos .recording >> nth=3 >> button:has-text('Play')");
await page.waitForFunction(() => /missing/.test(document.querySelector(".videos .rec-status")?.textContent ?? ""), null, { timeout: 30000 });
const missing = await page.$eval(".videos .rec-status", (e) => e.textContent);
const foreign = requests.filter((u) => !u.startsWith(base) && !u.startsWith("blob:") && !u.startsWith("data:"));
console.log(JSON.stringify({ images, marks, src, state, closed, missing, foreign, problems }, null, 1));
await browser.close();
close();
// Chromium builds without proprietary codecs cannot decode H.264 (MEDIA_ERR_SRC_NOT_SUPPORTED, 4): the
// viewer then says so; what matters here is that the verified clip reached the element.
const ok = images.length === 3 && images.every((h) => h === "blob:") && marks === 5 && src === "blob:" && closed === 0
  && foreign.length === 0 && problems.filter((p) => !/MEDIA_ERR|NotSupportedError|no supported source/i.test(p)).length === 0;
process.exit(ok ? 0 : 1);
