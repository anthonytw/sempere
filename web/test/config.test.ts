// config.json (docs/web-viewer.md "Hosting"): the server decides the vault.

import { describe, expect, it } from "vitest";
import { ConfigError, loadConfig, parseConfig } from "../src/vault/config.ts";

const base = "https://notes.example.org/viewer/config.json";

function fetcher(status: number, body: string, type = "application/json"): typeof fetch {
  return () => Promise.resolve(new Response(status === 404 ? null : body, { status, headers: { "content-type": type } }));
}

describe("config.json", () => {
  it("resolves the vault against the page and defaults to the configured vault only", () => {
    expect(parseConfig(JSON.stringify({ vault: "./vault/", listing: "webdav" }), base))
      .toEqual({ vault: "https://notes.example.org/viewer/vault/", listing: "webdav", allowOtherVaults: false });
    expect(parseConfig(JSON.stringify({ vault: "https://dav.example.org/v/", allowOtherVaults: true, extra: 1 }), base))
      .toEqual({ vault: "https://dav.example.org/v/", listing: "auto", allowOtherVaults: true });
  });

  it("refuses anything malformed", () => {
    for (const bad of ["", "[]", "null", "{}", JSON.stringify({ vault: "" }), JSON.stringify({ vault: "ftp://x/" }),
      JSON.stringify({ vault: "javascript:alert(1)" }), JSON.stringify({ vault: "https://u:p@x/" }),
      JSON.stringify({ vault: "./vault/?k=1" }), JSON.stringify({ vault: "./vault/", listing: "ftp" }),
      JSON.stringify({ vault: "./vault/", allowOtherVaults: "no" })]) {
      expect(() => parseConfig(bad, base), bad).toThrow(ConfigError);
    }
  });

  it("is absent on a 404 or a dev server's HTML fallback, and fails closed otherwise", async () => {
    expect(await loadConfig(base, fetcher(404, ""))).toBeUndefined();
    expect(await loadConfig(base, fetcher(200, "<!doctype html>", "text/html"))).toBeUndefined();
    expect(await loadConfig(base, fetcher(200, JSON.stringify({ vault: "./vault/" }))))
      .toMatchObject({ vault: "https://notes.example.org/viewer/vault/" });
    await expect(loadConfig(base, fetcher(500, ""))).rejects.toBeInstanceOf(ConfigError);
    await expect(loadConfig(base, fetcher(200, "{not json"))).rejects.toBeInstanceOf(ConfigError);
    await expect(loadConfig(base, fetcher(200, "x".repeat(70_000)))).rejects.toBeInstanceOf(ConfigError);
    await expect(loadConfig(base, () => Promise.reject(new TypeError("offline")))).rejects.toBeInstanceOf(ConfigError);
  });
});
