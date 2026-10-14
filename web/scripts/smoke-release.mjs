// Browser smoke test of page release (not part of `npm test`): opens the 12-page note "Papers & tools"
// at actual size in a short viewport, steps to the end and back, and checks that pages far from the
// viewport go back to their placeholders (the SVG DOM stays bounded), that the pages around the
// viewport are drawn again when they come back, and that nothing failed on the way.
// Usage: node scripts/smoke-release.mjs VAULT_DIR KEY_FILE
import { readFileSync } from "node:fs";
import { launchChromium, openVault, serveVault } from "./smoke-lib.mjs";

const [vaultDir, keyFile] = process.argv.slice(2);
const { base, close } = await serveVault({ mounts: [{ prefix: "/dav/", vaultDir }] });
let failures = 0;
const check = (ok, what) => { console.log(ok ? "ok  " : "FAIL", what); if (!ok) failures++; };

const browser = await launchChromium();
const page = await browser.newPage({ viewport: { width: 1000, height: 500 } });
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("404")) errors.push(m.text()); });
await page.goto(`${base}/`);
await openVault(page, `${base}/dav/`, readFileSync(keyFile, "utf8"), { webdav: true });
await page.click(".note-list button.note:has(.title:text-is('Papers & tools <test>'))");
await page.waitForSelector(".page svg", { timeout: 30000 });
await page.click(".viewport");
await page.keyboard.press("1");   // actual size: a page is taller than the viewport
const counts = () => page.evaluate(() => ({
  drawn: [...document.querySelectorAll(".page")].map((p, i) => (p.querySelector("svg") ? i + 1 : 0)).filter(Boolean),
  nodes: document.querySelectorAll(".page svg *").length,
}));
let most = 0, mostNodes = 0;
for (let i = 0; i < 40; i++) {
  await page.keyboard.press("PageDown");
  await page.waitForTimeout(50);
  const c = await counts();
  most = Math.max(most, c.drawn.length);
  mostNodes = Math.max(mostNodes, c.nodes);
}
const end = await counts();
check(end.drawn.includes(12), `the last page is drawn at the end (${end.drawn.join(",")})`);
check(!end.drawn.includes(1), "the first page went back to its placeholder");
check(most < 12, `at most ${most} of 12 pages drawn at once (largest SVG: ${mostNodes} nodes)`);
await page.keyboard.press("Home");
await page.waitForFunction(() => document.querySelector(".page svg") !== null && document.querySelectorAll(".page")[0]?.querySelector("svg") !== null, null, { timeout: 30000 });
const top = await counts();
check(top.drawn.includes(1) && !top.drawn.includes(12), `back at the top, page 1 is drawn again (${top.drawn.join(",")})`);
const problems = await page.$$eval(".item-problems li", (els) => els.map((e) => e.textContent));
check(new Set(problems).size === problems.length, `no problem is listed twice after redrawing (${problems.length})`);
check(errors.length === 0, `no errors: ${errors.join("; ")}`);
await browser.close();
close();
if (failures) process.exit(1);
console.log("all passed");
