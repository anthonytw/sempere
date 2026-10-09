// Browser smoke test of opening fast (docs/web-viewer.md "Opening fast"), not
// part of `npm test`: serves dist/ and a vault on one origin (/vault/, WebDAV
// PROPFIND or sempere-index.json), with an optional config.json, and drives
// the viewer in Chromium with Playwright. Checks:
//   - with config.json (allowOtherVaults false): straight to the key prompt, no
//     URL field, folder picker or drop zone, and ?vault= ignored;
//   - without it: the ad-hoc open screen;
//   - a second visit (same browser context) requests no revision or blob it
//     fetched before, and lists the same notes;
//   - with sempere-summaries.sealed, even a first visit lists without reading revisions
//     (and, with sempere-index.json and "listing": "index", without PROPFIND).
// Prints first- and second-visit timings (LATENCY_MS adds a delay to every request).
// Usage: node scripts/smoke-cache.mjs VAULT_DIR KEY_FILE
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { launchChromium, serveVault } from "./smoke-lib.mjs";

const [vaultDir, keyFile] = process.argv.slice(2);
const latency = Number(process.env.LATENCY_MS ?? "0");

let config = null;          // config.json body, or null for none
let withSummaries = true;   // serve sempere-summaries.sealed when the vault has one
let log = [];

const { base, close } = await serveVault({
  mounts: [{ prefix: "/vault/", vaultDir, hide: (rel) => rel === "sempere-summaries.sealed" && !withSummaries }],
  latency,
  onRequest: (method, path) => log.push(`${method} ${path}`),
  extraRoutes: (path, send) => path === "/config.json" && (config ? send(200, config, "application/json") : send(404, ""), true),
});
const key = readFileSync(keyFile, "utf8");
const isFileRead = (l) => /^GET \/vault\/notes\/[0-9a-f-]+\/(att\/)?[^/]+\.age$/.test(l);

const failures = [];
const check = (ok, what) => { if (!ok) failures.push(what); };
const results = [];

async function visit(context, label, { query = "", expectPrompt = false } = {}) {
  log = [];
  const page = await context.newPage();
  const problems = [];
  page.on("pageerror", (e) => problems.push(String(e)));
  const t0 = Date.now();
  await page.goto(`${base}/${query}`);
  if (expectPrompt) {
    await page.waitForSelector("textarea", { timeout: 30000 });
    check(await page.$("input[type=url]") === null, `${label}: URL field shown with config.json`);
    check(await page.$(".drop") === null, `${label}: drop zone shown with config.json`);
    check(!(await page.textContent("body")).includes("Open a vault folder"), `${label}: folder picker shown with config.json`);
    check((await page.textContent(".lede")).includes(`${base}/vault/`), `${label}: not the configured vault`);
  } else {
    await page.waitForSelector("input[type=url]", { timeout: 30000 });
    await page.fill("input[type=url]", `${base}/vault/`);
    await page.click("form button[type=submit]");
    await page.waitForSelector("textarea", { timeout: 30000 });
  }
  const tKey = Date.now();
  await page.fill("textarea", key);
  await page.click("form:has(textarea) button[type=submit]");
  await page.waitForSelector(".note-list .title", { timeout: 60000 });
  const tFirstRow = Date.now();
  await page.waitForFunction(() => /^\d+ notes?( ·|$)/.test(document.querySelector(".status")?.textContent ?? ""), null, { timeout: 120000 });
  const tListed = Date.now();
  const titles = await page.$$eval(".note-list .title", (els) => els.map((e) => e.textContent).sort());
  const fileReads = log.filter(isFileRead);
  const requests = log.length;
  const status = await page.textContent(".status");
  // Opening a note decrypts its body.
  await page.click(".note-list button.note >> nth=0");
  await page.waitForSelector(".page svg, .note-header h2", { timeout: 30000 });
  await page.close();
  check(problems.length === 0, `${label}: page errors ${problems.join("; ")}`);
  const r = { label, status, notes: titles.length, unlockToFirstRowMs: tFirstRow - tKey, unlockToListedMs: tListed - tKey,
    totalMs: tListed - t0, requests, revisionAndBlobGETs: fileReads.length };
  results.push(r);
  return { ...r, titles, fileReads };
}

const browser = await launchChromium();
try {
  // 1. Ad-hoc mode (no config.json), no summaries: first and second visit in one profile.
  config = null; withSummaries = false;
  let context = await browser.newContext({ viewport: { width: 1300, height: 850 } });
  const first = await visit(context, "ad hoc, no summaries, first visit");
  const second = await visit(context, "ad hoc, no summaries, second visit (cache)");
  check(first.fileReads.length > 0, "first visit read no revision");
  check(second.fileReads.length === 0, `second visit re-fetched unchanged files: ${second.fileReads.join(", ")}`);
  check(JSON.stringify(first.titles) === JSON.stringify(second.titles), "second visit lists other notes");
  await context.close();

  // 2. config.json mode: straight to the key prompt for the configured vault, ?vault= ignored;
  //    with summaries, even a first visit lists without reading revisions.
  config = JSON.stringify({ vault: "./vault/", listing: "webdav", allowOtherVaults: false }); withSummaries = true;
  const hasSummaries = existsSync(join(vaultDir, "sempere-summaries.sealed"));
  context = await browser.newContext({ viewport: { width: 1300, height: 850 } });
  const s1 = await visit(context, `config.json${hasSummaries ? ", summaries" : ""}, first visit`,
    { query: "?vault=https://elsewhere.example/", expectPrompt: true });
  check(JSON.stringify(s1.titles) === JSON.stringify(first.titles), "config.json mode lists other notes");
  if (hasSummaries) check(s1.fileReads.length === 0, `listing with summaries read revisions: ${s1.fileReads.slice(0, 5).join(", ")}`);
  const s2 = await visit(context, `config.json${hasSummaries ? ", summaries" : ""}, second visit`, { expectPrompt: true });
  check(s2.fileReads.length === 0, "second visit in config.json mode read revisions");
  await context.close();
  if (hasSummaries && existsSync(join(vaultDir, "sempere-index.json"))) {
    config = JSON.stringify({ vault: "./vault/", listing: "index" });
    context = await browser.newContext({ viewport: { width: 1300, height: 850 } });
    const i1 = await visit(context, "config.json, summaries + index, first visit", { expectPrompt: true });
    check(i1.fileReads.length === 0, "index listing with summaries read revisions");
    check(!log.some((l) => l.startsWith("PROPFIND")), "index listing sent PROPFIND");
    await context.close();
  }
} finally {
  await browser.close();
  close();
}
console.table(results.map(({ label, notes, unlockToFirstRowMs, unlockToListedMs, requests, revisionAndBlobGETs }) =>
  ({ label, notes, unlockToFirstRowMs, unlockToListedMs, requests, revisionAndBlobGETs })));
if (failures.length) {
  console.error("FAILED:\n" + failures.join("\n"));
  process.exit(1);
}
console.log("ok");
