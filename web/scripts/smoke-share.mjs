// Browser smoke test of a share file opened from disk (docs/web-viewer.md "Share files"): not part of `npm test`.
//
//   node scripts/smoke-share.mjs FILE.html PASSPHRASE [shot.png]
//
// Opens FILE as a file: page in Chromium (BROWSER=webkit: WebKit), checks that nothing but the page itself is ever
// requested, that no Content-Security-Policy or Trusted Types violation is reported, that a wrong passphrase gets the
// one sentence and a right one draws the note, and prints how long scrypt took. Exits 1 on any failure.
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { launchBrowser } from "./smoke-lib.mjs";

const [file, passphrase, shot] = process.argv.slice(2);
if (!file || !passphrase) {
  console.error("usage: node scripts/smoke-share.mjs FILE.html PASSPHRASE [shot.png]");
  process.exit(2);
}
const failures = [];
const fail = (m) => { failures.push(m); console.error(`FAIL ${m}`); };

const browser = await launchBrowser();
const context = await browser.newContext({ viewport: { width: 1000, height: 800 }, serviceWorkers: "block" });
const page = await context.newPage();
const requests = [];
context.on("request", (r) => requests.push(r.url()));
page.on("console", (m) => {
  const t = m.text();
  if (/content security policy|trusted type|refused to|violat/i.test(t)) fail(`console: ${t}`);
});
let workers = 0;
page.on("worker", () => { workers++; });
page.on("pageerror", (e) => fail(`page error: ${e.message}`));

const url = pathToFileURL(resolve(file)).href;
await page.goto(url);
await page.waitForSelector("input[type=password]");
if ((await page.title()) !== "Shared note") fail(`title is ${await page.title()}`);

await page.fill("input[type=password]", "not the passphrase");
await page.click("button");
await page.waitForFunction(() => document.querySelector("[role=alert]")?.textContent?.length > 0, null, { timeout: 120_000 });
const wrong = await page.textContent("[role=alert]");
if (wrong !== "That passphrase did not open this note") fail(`wrong passphrase said: ${wrong}`);
if ((await page.inputValue("input[type=password]")) !== "") fail("the passphrase stayed in the field");

const t0 = Date.now();
await page.fill("input[type=password]", passphrase);
await page.click("button");
await page.waitForSelector(".page svg", { timeout: 120_000 });
console.log(`opened in ${Date.now() - t0} ms; ${await page.locator(".page svg").count()} page(s) drawn, title shown: ${await page.textContent("h2")}`);
if ((await page.title()) !== "Shared note") fail(`title after opening is ${await page.title()}`);
if (page.url() !== url) fail(`the address changed to ${page.url()}`);
await page.waitForTimeout(500);
if (shot) await page.screenshot({ path: shot });

const foreign = requests.filter((u) => !u.startsWith("file:") && !u.startsWith("data:") && !u.startsWith("blob:"));
if (foreign.length) fail(`requests beyond the file: ${foreign.join(", ")}`);
await browser.close();
if (failures.length) process.exit(1);
console.log(`scrypt ran in ${workers > 0 ? "a worker" : "the page (no worker started)"}`);
console.log(`ok: ${requests.length} requests, none beyond the file, blob: and data: URLs`);
