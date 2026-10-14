// The browser's ciphertext cache in the UI: opened once per tab, and a
// "Clear cached data" button (docs/web-viewer.md "Opening fast").

import { FileCache, IndexedDBFileStore, MemoryFileStore } from "../vault/cache.ts";
import { locale, t } from "../i18n/index.ts";
import { h } from "./dom.ts";

let shared: Promise<FileCache> | undefined;

/** The tab's cache: IndexedDB, or memory where IndexedDB is missing or refused (private windows). */
export function fileCache(): Promise<FileCache> {
  shared ??= (typeof indexedDB === "undefined" ? Promise.reject(new Error("no IndexedDB")) : IndexedDBFileStore.open())
    .then((store) => new FileCache(store), () => new FileCache(new MemoryFileStore()));
  return shared;
}

export function formatBytes(n: number): string {
  if (n < 1024 * 1024) return `${Math.ceil(n / 1024).toLocaleString(locale())} KiB`;
  return `${(n / (1024 * 1024)).toLocaleString(locale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 })} MiB`;
}

/** A button that empties the cache (every vault's), saying how much it held. */
export function clearCacheButton(): HTMLButtonElement {
  const button = h("button", {
    text: t("Clear cached data"), class: "secondary", attrs: { type: "button" },
    title: t("Delete the encrypted vault files this browser keeps to open faster (nothing decrypted is ever kept)"),
  });
  void fileCache().then((c) => c.size()).then(({ bytes }) => {
    if (bytes > 0) button.textContent = t("Clear cached data ({size})", { size: formatBytes(bytes) });
  });
  button.addEventListener("click", () => {
    button.disabled = true;
    void fileCache().then((c) => c.clear()).finally(() => {
      button.textContent = t("Cached data cleared");
    });
  });
  return button;
}
