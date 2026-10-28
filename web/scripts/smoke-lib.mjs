// What the browser smoke scripts share (not part of `npm test`): a static server for dist/
// plus vaults over a minimal WebDAV (or plain GET) mount on one origin, Chromium, and the
// steps that open and unlock a vault.
import { createServer } from "node:http";
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, extname } from "node:path";

// PLAYWRIGHT: path to playwright/index.mjs when it is not installed here.
const { chromium, webkit } = await import(process.env.PLAYWRIGHT ?? "playwright");

export const dist = join(import.meta.dirname, "..", "dist");
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json" };

/** CHROMIUM: path to a Chromium to use instead of Playwright's. */
export const launchChromium = () => chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});

/**
 * BROWSER=webkit runs the script in Playwright's WebKit (the desktop Safari approximation of
 * docs/web-viewer.md "Stress tests"); anything else is Chromium. Scripts that use Chromium-only
 * features (CDP: virtual authenticator, touch emulation, heap sampling) call `launchChromium`.
 */
export async function launchBrowser() {
  if (process.env.BROWSER !== "webkit") return launchChromium();
  const browser = await webkit.launch();
  // Chromium's headless default is en-US; WebKit takes the Mac's language, and the scripts read English.
  for (const name of ["newPage", "newContext"]) {
    const original = browser[name].bind(browser);
    browser[name] = (options = {}) => original({ locale: "en-US", ...options });
  }
  return browser;
}

/**
 * True for a console message that is the browser's or Playwright's own, not the page's. In WebKit,
 * Playwright appends a `<style>body {}</style>` to the page for every screenshot (to sync animations:
 * `shouldToggleStyleSheetToSyncAnimations`), and the page's `style-src 'self'` refuses it. `watchCSP`
 * checks every violation, so the console may skip that message.
 */
export const engineNoise = (text) => process.env.BROWSER === "webkit" && text.startsWith("Refused to apply a stylesheet");

/**
 * Collects the page's CSP violations (`securitypolicyviolation`, in every document the page loads) and
 * returns a function that lists them as problems. The one exception is Playwright's own: in WebKit an
 * inline `style-src-elem` violation that happens while `page.screenshot` runs (see `engineNoise`),
 * which real browsers never see. Call it before the page's first `goto`.
 */
export async function watchCSP(page) {
  const seen = [];
  const shots = [];
  await page.exposeFunction("__sempereSmokeCSP", (v) => { seen.push(v); });
  await page.addInitScript(() => {
    document.addEventListener("securitypolicyviolation", (e) => {
      globalThis.__sempereSmokeCSP?.({ at: Date.now(), directive: e.effectiveDirective, blocked: e.blockedURI,
        source: e.sourceFile, line: e.lineNumber, sample: e.sample });
    });
  });
  const screenshot = page.screenshot.bind(page);
  page.screenshot = async (options) => {
    const start = await page.evaluate(() => Date.now());
    try {
      return await screenshot(options);
    } finally {
      // The violation event is a task queued while the style was in: let it run before the window closes.
      const end = await page.evaluate(() => new Promise((r) => setTimeout(() => r(Date.now()), 50))).catch(() => Infinity);
      shots.push([start, end]);
    }
  };
  const playwrights = (v) => process.env.BROWSER === "webkit" && v.directive === "style-src-elem" && v.blocked === "inline"
    && shots.some(([a, b]) => v.at >= a && v.at <= b);
  return async () => {
    await page.evaluate(() => new Promise((r) => setTimeout(r, 50))).catch(() => undefined);
    return seen.filter((v) => !playwrights(v)).map((v) => `CSP violation: ${JSON.stringify(v)}`);
  };
}

/**
 * Draws the `blob:` image `href` (already loaded by the page, so `img-src` allows it) on a canvas in the
 * page and counts its pixels: `clear` (alpha 0), `opaque` (alpha 255), `total`.
 */
export const imageAlpha = (page, href) => page.evaluate(async (src) => {
  const img = new Image();
  img.src = src;
  await img.decode();
  const c = document.createElement("canvas");
  c.width = img.naturalWidth;
  c.height = img.naturalHeight;
  const g = c.getContext("2d", { willReadFrequently: true });
  g.drawImage(img, 0, 0);
  const d = g.getImageData(0, 0, c.width, c.height).data;
  let clear = 0, opaque = 0;
  for (let i = 3; i < d.length; i += 4) {
    if (d[i] === 0) clear++;
    else if (d[i] === 255) opaque++;
  }
  return { clear, opaque, total: d.length / 4 };
}, href);

/**
 * Serves dist/ and, under each mount's `prefix`, the files of its `vaultDir`: minimal
 * PROPFIND listings unless `propfind` is false, and 404 for the paths `hide(rel)` names.
 * `csp` also sends the built page's CSP as a header, `latency` delays every response
 * (ms), `onRequest(method, path)` sees each request, and `extraRoutes(path, send)`
 * answers first (return true when it did). `host` is the name `base` uses for the server.
 * Returns `{ base, close }`.
 */
export async function serveVault({ mounts, csp = false, latency = 0, onRequest, extraRoutes, host = "127.0.0.1" }) {
  const policy = csp
    ? (/http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(readFileSync(join(dist, "index.html"), "utf8"))?.[1] ?? "").replaceAll("&#39;", "'")
    : "";
  const server = createServer((req, res) => {
    const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    onRequest?.(req.method, path);
    const send = (status, body, type = "application/octet-stream") => setTimeout(() => {
      res.writeHead(status, { "content-type": type, ...(csp ? { "content-security-policy": `${policy}; frame-ancestors 'none'` } : {}) });
      res.end(body);
    }, latency);
    if (extraRoutes?.(path, send)) return;
    for (const { prefix, vaultDir, propfind = true, hide } of mounts) {
      if (!path.startsWith(prefix)) continue;
      const rel = path.slice(prefix.length);
      if (rel.includes("..")) return send(400, "");
      const file = join(vaultDir, rel);
      if (propfind && req.method === "PROPFIND") {
        if (!existsSync(file) || !statSync(file).isDirectory()) return send(404, "");
        const items = readdirSync(file).map((n) => `<d:response><d:href>${prefix}${rel}${encodeURIComponent(n)}${statSync(join(file, n)).isDirectory() ? "/" : ""}</d:href></d:response>`);
        return send(207, `<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>${prefix}${rel}</d:href></d:response>${items.join("")}</d:multistatus>`, "application/xml");
      }
      if (hide?.(rel) || !existsSync(file) || statSync(file).isDirectory()) return send(404, "");
      return send(200, readFileSync(file));
    }
    const f = join(dist, path === "/" ? "index.html" : path);
    if (!existsSync(f) || statSync(f).isDirectory()) return send(404, "");
    send(200, readFileSync(f), types[extname(f)] ?? "application/octet-stream");
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { base: `http://${host}:${server.address().port}`, close: () => server.close() };
}

/** Waits for the note list's status line ("3 notes") that an unlocked vault shows. */
export const unlocked = (page, timeout = 30000) =>
  page.waitForFunction(() => /\d+ notes?( ·|$)/.test(document.querySelector(".status")?.textContent ?? ""), null, { timeout });

/** From the open screen (already at the viewer's URL) to the key prompt of the vault at `url`. */
export async function enterVault(page, url, { webdav = false } = {}) {
  await page.fill("input[type=url]", url);
  if (webdav) await page.selectOption("select", "webdav");
  await page.click("form button[type=submit]");
}

/** Opens the vault at `url`, pastes `key` and waits for the note list. */
export async function openVault(page, url, key, options) {
  await enterVault(page, url, options);
  await page.fill("textarea", key);
  await page.click("form:has(textarea) button[type=submit]");
  await unlocked(page);
}
