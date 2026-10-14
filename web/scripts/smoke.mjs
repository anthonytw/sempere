// Browser smoke test (not part of `npm test`): serves dist/ and a vault on one
// origin, at /static/ (sempere-index.json) and /dav/ (minimal PROPFIND), and
// drives the viewer in Chromium with Playwright.
// Usage: node scripts/smoke.mjs VAULT_DIR KEY_FILE [SCREENSHOT_DIR [SEARCH_TERM]]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { launchChromium, openVault, serveVault } from "./smoke-lib.mjs";

const [vaultDir, keyFile, shots = ".", term] = process.argv.slice(2);
const { base, close } = await serveVault({ mounts: [
  { prefix: "/static/", vaultDir, propfind: false },
  { prefix: "/dav/", vaultDir, hide: (rel) => rel === "sempere-index.json" },
] });
const key = readFileSync(keyFile, "utf8");

const browser = await launchChromium();
let failures = 0;
for (const mount of ["static", "dav"]) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const problems = [];
  // 404s are expected: rewrap-journal.json, and the index on the WebDAV mount.
  page.on("console", (m) => { if ((m.type() === "error" || m.type() === "warning") && !m.text().includes("404")) problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(String(e)));
  await page.goto(`${base}/`);
  await openVault(page, `${base}/${mount}/`, key);
  const status = await page.textContent(".status");
  const titles = await page.$$eval(".note-list .title", (els) => els.map((e) => e.textContent));
  await page.click(".note-list button.note >> nth=0");
  await page.waitForSelector(".page svg", { timeout: 30000 });
  await page.screenshot({ path: join(shots, `smoke-${mount}.png`) });
  await page.click(".note-list button.note >> nth=-1");
  await page.waitForSelector(".page svg", { timeout: 30000 });
  await page.keyboard.press("Escape");
  await page.click(".zoom-bar button >> nth=0");
  await page.click(".zoom-bar button >> nth=0");
  await page.click(".zoom-bar button >> nth=0");
  await page.waitForTimeout(300);
  await page.screenshot({ path: join(shots, `smoke-${mount}-papers.png`) });
  await page.fill("input[type=search]", term ?? "");
  await page.waitForTimeout(400);
  const hits = await page.$$eval(".note-list .title", (els) => els.map((e) => e.textContent));
  console.log(mount, "|", status, "|", JSON.stringify(titles), `| search ${term ?? "(none)"}:`, JSON.stringify(hits), "| problems:", JSON.stringify(problems));
  if (problems.length || titles.length === 0 || (term && hits.length === 0)) failures++;
  await page.close();
}
await browser.close();
close();
process.exit(failures ? 1 : 0);
