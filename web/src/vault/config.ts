// Deploy-time configuration (docs/web-viewer.md "Hosting"): `config.json`
// next to index.html lets the server decide which vault the viewer shows.
// It holds no secret. Without it the viewer opens any vault the user names.

import { type HTTPMode } from "./source.ts";

export const configFileName = "config.json";
export const maxConfigBytes = 64 * 1024;

export interface ViewerConfig {
  /** The vault's URL, resolved against the page (`./vault/` → same origin). */
  vault: string;
  listing: HTTPMode;
  /** False (the default): only `vault` can be opened; no URL field, folders or `?vault=`. */
  allowOtherVaults: boolean;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

/** Parses `config.json`; throws `ConfigError` for anything malformed (the viewer then refuses to run). */
export function parseConfig(text: string, base: string): ViewerConfig {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    throw new ConfigError(`${configFileName} is not JSON`);
  }
  if (typeof json !== "object" || json === null || Array.isArray(json)) throw new ConfigError(`${configFileName} is not an object`);
  const o = json as Record<string, unknown>;
  if (typeof o.vault !== "string" || o.vault.trim() === "") throw new ConfigError(`${configFileName}: "vault" must be a URL`);
  let url: URL;
  try {
    url = new URL(o.vault.trim(), base);
  } catch {
    throw new ConfigError(`${configFileName}: "vault" is not a valid URL`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new ConfigError(`${configFileName}: "vault" must be http(s)`);
  if (url.username || url.password || url.search || url.hash) {
    throw new ConfigError(`${configFileName}: "vault" must not carry credentials, a query or a fragment`);
  }
  const listing = o.listing ?? "auto";
  if (listing !== "auto" && listing !== "index" && listing !== "webdav") {
    throw new ConfigError(`${configFileName}: "listing" must be "webdav", "index" or "auto"`);
  }
  const allow = o.allowOtherVaults ?? false;
  if (typeof allow !== "boolean") throw new ConfigError(`${configFileName}: "allowOtherVaults" must be true or false`);
  return { vault: url.href, listing, allowOtherVaults: allow };
}

/**
 * Fetches `config.json` beside the page. Undefined when there is none (404,
 * or a dev server answering with its HTML page); a config that exists but
 * cannot be read or parsed throws, so a locked-down deployment fails closed.
 */
export async function loadConfig(base: string, fetcher: typeof fetch = fetch.bind(globalThis)): Promise<ViewerConfig | undefined> {
  const url = new URL(configFileName, base);
  let res: Response;
  try {
    res = await fetcher(url, { cache: "no-cache", credentials: "same-origin" });
  } catch (e) {
    throw new ConfigError(`cannot fetch ${configFileName}: ${e instanceof Error ? e.message : String(e)}`);
  }
  if (res.status === 404 || res.status === 410) return undefined;
  if (!res.ok) throw new ConfigError(`cannot fetch ${configFileName}: HTTP ${res.status}`);
  if ((res.headers.get("content-type") ?? "").includes("text/html")) return undefined;
  const body = await res.arrayBuffer();
  if (body.byteLength > maxConfigBytes) throw new ConfigError(`${configFileName} is larger than ${maxConfigBytes} bytes`);
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(body);
  } catch {
    throw new ConfigError(`${configFileName} is not UTF-8`);
  }
  return parseConfig(text, url.href);
}
