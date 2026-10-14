// Browser test of the passkey-remembered key (not part of `npm test`): serves
// dist/ and a vault (WebDAV-style, minimal PROPFIND) on http://localhost, and
// drives the viewer in Chromium with a CDP virtual authenticator (CTAP2,
// user verification, PRF). Checks: remember after a pasted unlock, only
// ciphertext in IndexedDB, unlock with the passkey after Lock, Forget, and
// that an authenticator without PRF stores nothing.
// Usage: npm run build && node scripts/smoke-passkey.mjs VAULT_DIR KEY_FILE
import { readFileSync } from "node:fs";
import { enterVault, launchChromium, serveVault, unlocked } from "./smoke-lib.mjs";

const [vaultDir, keyFile] = process.argv.slice(2);
// localhost, not 127.0.0.1: an IP address is not a valid WebAuthn RP ID.
const { base, close } = await serveVault({ mounts: [{ prefix: "/dav/", vaultDir, hide: (rel) => rel === "sempere-index.json" }], host: "localhost" });
const key = readFileSync(keyFile, "utf8");
const secretLine = key.split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-1"));

const browser = await launchChromium();
let failures = 0;
const check = (ok, what) => {
  console.log(ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
};

async function withAuthenticator(options) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("404")) problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(String(e)));
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2", ctap2Version: "ctap2_1", transport: "internal", hasResidentKey: true,
      hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true, ...options,
    },
  });
  return { context, page, cdp, authenticatorId, problems };
}

async function openVault(page) {
  await page.goto(`${base}/`);
  await enterVault(page, `${base}/dav/`, { webdav: true });
  await page.waitForSelector("textarea");
}

const records = (page) => page.evaluate(() => new Promise((resolve, reject) => {
  const r = indexedDB.open("sempere-viewer", 1);
  r.onupgradeneeded = () => r.result.createObjectStore("passkey-keys", { keyPath: "vaultId" });
  r.onerror = () => reject(r.error);
  r.onsuccess = () => {
    const all = r.result.transaction("passkey-keys").objectStore("passkey-keys").getAll();
    all.onsuccess = () => resolve(all.result.map((x) => ({
      keys: Object.keys(x).sort(),
      text: [x.credentialId, x.salt, x.iv, x.ciphertext].map((b) => String.fromCharCode(...new Uint8Array(b instanceof ArrayBuffer ? b : b.buffer))).join("|"),
    })));
    all.onerror = () => reject(all.error);
  };
}));

// 1. With PRF: remember, unlock with the passkey, forget.
{
  const { context, page, cdp, authenticatorId, problems } = await withAuthenticator({ hasPrf: true });
  await openVault(page);
  await page.fill("textarea", key);
  await page.check("form:has(textarea) label.check input");
  await page.click("form:has(textarea) button[type=submit]");
  await page.click("text=Create passkey");
  await unlocked(page);
  check(true, "pasted key unlocked, passkey created");
  const stored = await records(page);
  check(stored.length === 1, `one record stored (${stored.length})`);
  check(JSON.stringify(stored[0]?.keys) === JSON.stringify(["ciphertext", "created", "credentialId", "iv", "location", "salt", "vaultId", "version"]), `record fields ${JSON.stringify(stored[0]?.keys)}`);
  check(!stored[0]?.text.includes(secretLine.slice(0, 24)) && !stored[0]?.text.includes("AGE-SECRET"), "no key text in IndexedDB");
  const { credentials } = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
  check(credentials.length === 1, `one passkey in the authenticator (${credentials.length})`);

  await page.click("text=Lock");
  await openVault(page);
  await page.click("text=Unlock with passkey");
  await unlocked(page);
  check(true, "unlocked with the passkey after Lock");

  await page.click("text=Lock");
  await openVault(page);
  await page.waitForSelector("text=Forget this key");
  await page.click("text=Forget this key");
  await page.waitForSelector("textarea");
  await page.waitForTimeout(300);
  check(await page.locator("text=Unlock with passkey").count() === 0, "forgotten: no passkey button");
  check((await records(page)).length === 0, "forgotten: IndexedDB empty");
  check(problems.length === 0, `no page errors ${JSON.stringify(problems)}`);
  await context.close();
}

// 2. Without PRF: an explanation, nothing stored, the vault still opens.
{
  const { context, page } = await withAuthenticator({ hasPrf: false });
  await openVault(page);
  await page.fill("textarea", key);
  const disabled = await page.isDisabled("form:has(textarea) label.check input");
  if (!disabled) {
    await page.check("form:has(textarea) label.check input");
    await page.click("form:has(textarea) button[type=submit]");
    await page.click("text=Create passkey");
    await page.waitForSelector(".error", { timeout: 30000 });
    const text = await page.textContent(".error");
    check(/PRF/.test(text ?? ""), `explains the missing PRF: ${text}`);
    check((await records(page)).length === 0, "no PRF: nothing stored");
    await page.click("text=Continue without");
    await unlocked(page);
    check(true, "no PRF: vault opens without remembering");
  } else {
    check((await records(page)).length === 0, "no PRF reported up front: option disabled, nothing stored");
  }
  await context.close();
}

await browser.close();
close();
process.exit(failures ? 1 : 0);
