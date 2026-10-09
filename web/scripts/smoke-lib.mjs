// What the browser smoke scripts share (not part of `npm test`): a static server for dist/
// plus vaults over a minimal WebDAV (or plain GET) mount on one origin, Chromium, and the
// steps that open and unlock a vault.
import { createServer } from "node:http";
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, extname } from "node:path";

// PLAYWRIGHT: path to playwright/index.mjs when it is not installed here.
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");

export const dist = join(import.meta.dirname, "..", "dist");
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json" };

/** CHROMIUM: path to a Chromium to use instead of Playwright's. */
export const launchChromium = () => chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});

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
