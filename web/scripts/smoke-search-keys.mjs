// Browser test of passphrase-wrapped keys and transcript search (CI's web job;
// not part of `npm test`). Serves dist/ (with its CSP and Trusted Types) and
// vaults over a minimal WebDAV on http://localhost and drives the viewer in
// Chromium. Checks:
// - the vault's stored key file: a wrong passphrase is refused, the right one
//   unlocks (scrypt in the key worker, created through its Trusted Types policy);
// - a recovery kit's armored passphrase copy pasted in the key field;
// - remembering a passphrase-unlocked key with a passkey (virtual authenticator
//   with PRF), then unlocking with the passkey; nothing but ciphertext stored;
// - transcript search: off by default, then matches in transcripts listed under
//   their notes, unreadable transcripts reported, and a match opening the
//   recording with its segment marked;
// - no CSP or Trusted Types violation, no page error.
// Usage: npm run build && node scripts/smoke-search-keys.mjs
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { enterVault, launchChromium, serveVault, unlocked } from "./smoke-lib.mjs";

const web = join(import.meta.dirname, "..");
const fixtures = join(web, "..", "Tests", "SempereTests", "Fixtures");
const vaults = { sample: join(fixtures, "sample.sempere"), search: join(web, "test", "fixtures", "search.sempere") };
const kit = readFileSync(join(web, "test", "fixtures", "paper-kit-passphrase.txt"), "utf8");
const secretLine = readFileSync(join(fixtures, "sample.key"), "utf8").split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-1"));
// localhost, not 127.0.0.1: an IP address is not a valid WebAuthn RP ID.
const hideIndex = (rel) => rel === "sempere-index.json";
const { base, close } = await serveVault({
  mounts: Object.entries(vaults).map(([name, vaultDir]) => ({ prefix: `/dav/${name}/`, vaultDir, hide: hideIndex })),
  host: "localhost",
});

const browser = await launchChromium();
let failures = 0;
const check = (ok, what) => {
  console.log(ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
};

async function newPage(authenticator) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const problems = [];
  page.on("console", (msg) => { if (msg.type() === "error" && !msg.text().includes("404")) problems.push(msg.text()); });
  page.on("pageerror", (e) => problems.push(String(e)));
  if (authenticator) {
    const cdp = await context.newCDPSession(page);
    await cdp.send("WebAuthn.enable");
    await cdp.send("WebAuthn.addVirtualAuthenticator", {
      options: {
        protocol: "ctap2", ctap2Version: "ctap2_1", transport: "internal", hasResidentKey: true,
        hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true, hasPrf: true,
      },
    });
  }
  return { context, page, problems };
}

async function openVault(page, name) {
  await page.goto(`${base}/`);
  await enterVault(page, `${base}/dav/${name}/`, { webdav: true });
  await page.waitForSelector("textarea");
}

const storedCard = (page) => page.locator("form.card", { hasText: "Unlock with your passphrase" });
// Lock reloads the page (back to the open screen); the vault is opened again.
const lock = async (page, name) => {
  await page.click("button:has-text('Lock')");
  await page.waitForSelector("input[type=url]");
  await openVault(page, name);
};

try {
  // --- The vault's stored key file.
  {
    const { context, page, problems } = await newPage(false);
    await openVault(page, "sample");
    const card = storedCard(page);
    await card.waitFor({ timeout: 10000 });
    check(await card.isVisible(), "the stored key file is offered");
    await card.locator("input[type=password]").fill("not the passphrase");
    await card.locator("button[type=submit]").click();
    await page.waitForSelector("p.error", { timeout: 30000 });
    check((await page.textContent("p.error")).includes("Wrong passphrase"), `a wrong passphrase is refused (${await page.textContent("p.error")})`);
    const again = storedCard(page);
    await again.waitFor();
    await again.locator("input[type=password]").fill("sempere-test");
    await again.locator("button[type=submit]").click();
    await unlocked(page, 60000);
    check(true, "the right passphrase unlocks");
    const stored = await page.evaluate(async () => (await indexedDB.databases()).map((d) => d.name));
    check(!stored.includes("sempere-viewer") || await page.evaluate(() => new Promise((resolve) => {
      const r = indexedDB.open("sempere-viewer");
      r.onsuccess = () => {
        const db = r.result;
        if (!db.objectStoreNames.contains("passkey-keys")) return resolve(true);
        const all = db.transaction("passkey-keys").objectStore("passkey-keys").getAll();
        all.onsuccess = () => resolve(all.result.length === 0);
      };
    })), "nothing is remembered unless asked");

    // --- A recovery kit's armored copy, pasted.
    await lock(page, "sample");
    await page.fill("textarea", kit);
    await page.dispatchEvent("textarea", "input");
    const field = page.locator("input[aria-label='Passphrase of the key']");
    check(await field.isVisible(), "pasting a locked key shows the passphrase field");
    await field.fill("sempere-test");
    await page.click("form.card:has(textarea) button[type=submit]");
    await unlocked(page, 60000);
    check(true, "a pasted recovery kit copy unlocks with its passphrase");
    check(problems.length === 0, `no errors (CSP, Trusted Types, pages): ${problems.join(" | ")}`);
    await context.close();
  }

  // --- Passphrase, then remember with a passkey.
  {
    const { context, page, problems } = await newPage(true);
    await openVault(page, "sample");
    const card = storedCard(page);
    await card.waitFor({ timeout: 10000 });
    const box = card.locator("input[type=checkbox]");
    await page.waitForFunction(() => !document.querySelector("form.card input[type=checkbox]")?.disabled);
    await box.check();
    await card.locator("input[type=password]").fill("sempere-test");
    await card.locator("button[type=submit]").click();
    await page.waitForSelector("button:has-text('Create passkey')", { timeout: 30000 });
    await page.click("button:has-text('Create passkey')");
    await unlocked(page, 60000);
    const records = await page.evaluate(() => new Promise((resolve) => {
      const r = indexedDB.open("sempere-viewer");
      r.onsuccess = () => {
        const all = r.result.transaction("passkey-keys").objectStore("passkey-keys").getAll();
        all.onsuccess = () => resolve(all.result);
      };
    }));
    const text = JSON.stringify(records);
    check(records.length === 1 && !text.includes("sempere-test") && !text.includes("AGE-SECRET-KEY"),
      "the passkey record holds neither the passphrase nor the key");
    await lock(page, "sample");
    await page.click("button:has-text('Unlock with passkey')");
    await unlocked(page, 60000);
    check(true, "the key unlocked with a passphrase unlocks with the passkey after Lock");
    check(problems.length === 0, `no errors: ${problems.join(" | ")}`);
    await context.close();
  }

  // --- Transcript search.
  {
    const { context, page, problems } = await newPage(false);
    await openVault(page, "search");
    await page.fill("textarea", secretLine);
    await page.click("form.card:has(textarea) button[type=submit]");
    await unlocked(page, 60000);
    await page.fill("input[type=search]", "nass");
    await page.waitForTimeout(400);
    check((await page.locator(".note-list .spoken-hit").count()) === 0, "transcripts are not searched by default");
    check((await page.textContent(".note-list")).includes("No matches"), "a word only in a transcript finds nothing by default");
    await page.check(".transcript-search input[type=checkbox]");
    await page.waitForFunction(() => /transcripts? searched/.test(document.querySelector(".transcript-search [role=status]")?.textContent ?? ""), null, { timeout: 60000 });
    const status = await page.textContent(".transcript-search [role=status]");
    check(status.includes("3 transcripts searched"), `transcripts read (${status.trim()})`);
    check((await page.textContent(".transcript-search details summary")).includes("2 transcripts could not be read"), "unreadable transcripts are reported");
    const hit = page.locator(".spoken-hit");
    await hit.first().waitFor();
    check((await hit.count()) === 1 && (await hit.first().textContent()).includes("Spät 1:00:01"), `a transcript-only word lists its recording and time (${await hit.first().textContent()})`);
    await page.fill("input[type=search]", "café");
    await page.waitForTimeout(400);
    const rows = await page.locator(".spoken-hits").evaluateAll((uls) => uls.map((u) => u.textContent));
    check(rows.some((r) => r.includes("Walk to the café 0:00")) && rows.some((r) => r.includes("Recording 0:12")), `matches listed under their notes (${rows.length} notes)`);
    check((await page.locator(".spoken-hit mark").first().textContent()).toLowerCase().startsWith("caf"), "the match is marked in the snippet");
    await page.locator(".spoken-hit", { hasText: "0:04" }).first().click();
    await page.waitForSelector(".transcript li.found", { timeout: 30000 });
    const found = await page.textContent(".transcript li.found");
    check(found.includes("Naïve readers"), `the recording opens at the matching segment (${found.slice(0, 40)})`);
    check(await page.locator(".recordings audio").count() === 1, "the audio is loaded, cued at the segment");
    check(problems.length === 0, `no errors: ${problems.join(" | ")}`);
    await context.close();
  }
} catch (e) {
  console.log("FAIL", e);
  failures++;
} finally {
  await browser.close();
  close();
}
console.log(failures ? `${failures} failure(s)` : "all passed");
process.exit(failures ? 1 : 0);
