// The viewer's screens: open a vault, unlock it with a pasted key, then browse
// notebooks, tags and notes, search, and read a note. Read-only throughout.

import { type NoteState } from "../format/model.ts";
import { type NotebookNode, type SearchHit, canonicalNotebook, isWithinNotebook, notebookCounts, notebookTree, refinesQuery,
  search } from "../format/search.ts";
import { tagKey } from "../format/tags.ts";
import { type LoadedNote, type NoteSummary, loadNote, summarize } from "../vault/library.ts";
import { CachingSource, cacheNamespace } from "../vault/cache.ts";
import { type ViewerConfig, loadConfig } from "../vault/config.ts";
import { type ListingProgress, listVault } from "../vault/listing.ts";
import { HTTPSource, type HTTPMode, SourceError, type VaultSource, readOptional } from "../vault/source.ts";
import { type RecipientsStatus, UnlockedVault, VaultError, limits, parseIdentity, parseManifest, readOnlyReasons,
  recipientsWarningText, type VaultManifest } from "../vault/vault.ts";
import { newerSummary } from "../format/newer.ts";
import { clear, formatDate, h } from "./dom.ts";
import { NoteView, hasUnknownPaper } from "./noteview.ts";
import { RecordingsPanel } from "./recordings.ts";
import { VideosPanel } from "./videos.ts";
import { NoteBlobs } from "../vault/blobs.ts";
import { canPickDirectory, fromDrop, fromFileList, pickDirectory } from "./pickers.ts";
import { clearCacheButton, fileCache } from "./caching.ts";
import { passkeyVault, rememberOption, rememberScreen, rememberedCard } from "./passkey.ts";
import { vaultLocation } from "../vault/passkey.ts";
import { type PhraseHit } from "../format/phrasesearch.ts";
import { foldTerm, occurrences, prepare, swiftCompare, trimTerm } from "../format/occurrences.ts";
import { readBlob } from "../vault/blobs.ts";
import { TranscriptSearch, maxHitsShown } from "./transcriptsearch.ts";
import { formatDuration } from "./recordings.ts";
import { KeyFileError, looksArmored, looksWrapped, maxKeyFileBytes, wrappedBytes } from "../vault/keyfile.ts";
import { unwrapKeyInWorker } from "./keyunwrap.ts";
import { PassphraseField, keyFileMessage, storedKeyCard } from "./passphrase.ts";
import { explain } from "./errors.ts";
import { languagePicker } from "./language.ts";
import { t, tn } from "../i18n/index.ts";

type Filter =
  | { kind: "all" } | { kind: "favorites" } | { kind: "deleted" } | { kind: "problems" }
  | { kind: "notebook"; path: string } | { kind: "tag"; key: string; label: string };

/** An error as the user sees it: a sentence in the interface language where the error is known, else its own text. */
function message(e: unknown): string {
  return explain(e);
}

export class App {
  private source?: VaultSource;
  private manifest?: VaultManifest;
  /** Where the vault was opened (`vaultLocation`): what a remembered key is bound to. */
  private location = "";
  private vault?: UnlockedVault;
  private notes = new Map<string, NoteSummary>();
  private loading: ListingProgress & { listed: boolean } = { checked: 0, total: 0, read: 0, toRead: 0, listed: false };
  /** The deployment's `config.json` (docs/web-viewer.md "Hosting"), if any. */
  private config?: ViewerConfig;
  private filter: Filter = { kind: "all" };
  private query = "";
  private hits?: Map<string, SearchHit>;
  /** The last note search: its query, the notes it ran over (in order) and the ids it found. */
  private searched?: { query: string; notes: NoteSummary[]; ids: Set<string> };
  /** Transcript matches per note (only with "Also search recording transcripts"). */
  private transcriptHits = new Map<string, PhraseHit[]>();
  private transcripts?: TranscriptSearch;
  private selected?: string;
  private view?: NoteView;
  private recordings?: RecordingsPanel;
  private videos?: VideosPanel;
  /** Recently opened notes; the list itself keeps summaries only. */
  private readonly cache = new Map<string, LoadedNote>();
  private generation = 0;

  private readonly sidebar = h("nav", { class: "sidebar", attrs: { "aria-label": t("Notebooks and tags") } });
  private readonly list = h("section", { class: "note-list", attrs: { "aria-label": t("Notes") } });
  private readonly detail = h("main", { class: "detail" });
  private readonly status = h("span", { class: "status", attrs: { role: "status" } });

  constructor(private readonly root: HTMLElement) {}

  start(): void {
    void loadConfig(location.href).then((config) => {
      this.config = config;
      if (config && !config.allowOtherVaults) {
        // The server decides: straight to the key prompt for its vault.
        void this.openSource(new HTTPSource(config.vault, config.listing));
      } else {
        this.showOpen();
      }
    }, (e: unknown) => this.showFatal(message(e)));
  }

  /** A deployment whose config cannot be read: nothing else is offered (fail closed). */
  private showFatal(error: string): void {
    clear(this.root);
    this.root.append(h("div", { class: "welcome" }, h("h1", { text: t("Sempere viewer") }),
      h("p", { class: "error", text: error, attrs: { role: "alert" } }), languagePicker(() => this.showFatal(error))));
  }

  /** True when the deployment allows only its own vault. */
  private get locked(): boolean {
    return this.config !== undefined && !this.config.allowOtherVaults;
  }

  // MARK: - Open

  private showOpen(error?: string, draftUrl?: string): void {
    if (this.locked) return this.showFatal(error ?? t("This viewer opens only its configured vault."));
    const params = new URLSearchParams(location.search);
    const url = h("input", { attrs: { type: "url", placeholder: "https://example.org/Notes.sempere/", autocomplete: "url", spellcheck: "false" } });
    url.value = draftUrl ?? this.config?.vault ?? params.get("vault") ?? "";
    const mode = h("select", { attrs: { "aria-label": t("Listing") } },
      h("option", { text: t("Index file or WebDAV"), attrs: { value: "auto" } }),
      h("option", { text: t("Index file (sempere-index.json)"), attrs: { value: "index" } }),
      h("option", { text: "WebDAV", attrs: { value: "webdav" } }));
    const openURL = (e: Event) => {
      e.preventDefault();
      try {
        void this.openSource(new HTTPSource(url.value.trim(), mode.value as HTTPMode));
      } catch (err) {
        this.showOpen(message(err));
      }
    };
    const dirInput = h("input", { attrs: { type: "file", webkitdirectory: "", multiple: "" }, class: "visually-hidden" });
    dirInput.addEventListener("change", () => {
      if (!dirInput.files || dirInput.files.length === 0) return;
      try {
        void this.openSource(fromFileList(dirInput.files));
      } catch (err) {
        this.showOpen(message(err));
      }
    });
    const pickButton = h("button", {
      text: t("Open a vault folder…"), attrs: { type: "button" },
      on: {
        click: () => {
          if (!canPickDirectory()) {
            dirInput.click();
            return;
          }
          pickDirectory().then((src) => this.openSource(src), (err: unknown) => {
            if (!(err instanceof DOMException && err.name === "AbortError")) this.showOpen(message(err));
          });
        },
      },
    });
    const drop = h("div", { class: "drop", text: t("or drop the vault folder (*.sempere) here") });
    drop.addEventListener("dragover", (e) => {
      e.preventDefault();
      drop.classList.add("over");
    });
    drop.addEventListener("dragleave", () => drop.classList.remove("over"));
    drop.addEventListener("drop", (e) => {
      e.preventDefault();
      drop.classList.remove("over");
      if (!e.dataTransfer) return;
      fromDrop(e.dataTransfer.items).then((src) => this.openSource(src), (err: unknown) => this.showOpen(message(err)));
    });
    clear(this.root);
    this.root.append(h("div", { class: "welcome" },
      h("h1", { text: t("Sempere viewer") }),
      h("p", { class: "lede", text: t("Read an encrypted Sempere vault in this browser. Notes are decrypted here; the key never leaves this tab, and nothing is written anywhere.") }),
      error ? h("p", { class: "error", text: error, attrs: { role: "alert" } }) : null,
      h("form", { class: "card", on: { submit: openURL } },
        h("h2", { text: t("From a web server") }),
        h("label", { text: t("Vault URL") }, url),
        h("label", { text: t("Listing") }, mode),
        h("button", { text: t("Open"), attrs: { type: "submit" } }),
        h("p", { class: "hint", text: t("A static server needs sempere-index.json (sempere vault index); a WebDAV share needs nothing. The URL must be allowed by this page's connect-src (docs/web-viewer.md).") })),
      h("div", { class: "card" },
        h("h2", { text: t("From this computer") }), pickButton, dirInput, drop),
      h("p", { class: "hint" }, clearCacheButton()),
      languagePicker(() => this.showOpen(error, url.value))));
  }

  private async openSource(src: VaultSource): Promise<void> {
    this.status.textContent = "";
    let manifest: VaultManifest;
    try {
      manifest = parseManifest(await src.read("vault.json", limits.manifestBytes));
    } catch (e) {
      this.showOpen(e instanceof SourceError && e.notFound ? t("{label} has no vault.json: is it a Sempere vault?", { label: src.label }) : message(e));
      return;
    }
    this.location = vaultLocation(src);
    // Encrypted revisions and blobs fetched over HTTP are kept in the browser (write-once files),
    // under the vault's key state: a recipient change or a finished rewrap drops the old copies (P4).
    if (src instanceof HTTPSource) {
      let journal: Uint8Array | undefined;
      try {
        journal = await readOptional(src, "rewrap-journal.json", limits.manifestBytes);
      } catch {
        journal = undefined;
      }
      const caching = new CachingSource(src, await fileCache(),
        await cacheNamespace(src.label, manifest.vaultId, manifest.vaultSecret, journal));
      await caching.dropOtherNamespaces();
      this.source = caching;
    } else {
      this.source = src;
    }
    this.manifest = manifest;
    this.showUnlock();
  }

  // MARK: - Unlock

  private showUnlock(error?: string): void {
    const m = this.manifest, src = this.source;
    if (!m || !src) return this.showOpen();
    const key = h("textarea", {
      attrs: { rows: "4", placeholder: "AGE-SECRET-KEY-PQ-1…", autocomplete: "off", autocapitalize: "off", spellcheck: "false", "aria-label": t("Key") },
    });
    const button = h("button", { text: t("Unlock"), attrs: { type: "submit" } });
    const unlock = async (text: string): Promise<string> => {
      const identity = parseIdentity(text);
      const journal = await readOptional(src, "rewrap-journal.json", limits.manifestBytes);
      this.vault = await UnlockedVault.unlock(m, identity, journal);
      return identity;
    };
    const failed = (err: unknown) =>
      this.showUnlock(err instanceof VaultError || err instanceof SourceError ? explain(err)
        : err instanceof KeyFileError ? keyFileMessage(err) : t("Unlocking failed: {detail}", { detail: message(err) }));
    // The identity unlocked the vault: remember it with a passkey if asked (never the passphrase), then open.
    const opened = (identity: string, remember: boolean) => {
      const pv = passkeyVault();
      if (remember && pv) {
        clear(this.root);
        this.root.append(rememberScreen(pv, identity, m.vaultId, this.location, src.label, () => this.showMain()));
      } else {
        this.showMain();
      }
    };
    const remember = rememberOption();
    // A locked key: pasted (a paper kit's armored passphrase copy) or chosen as a file.
    const passphrase = new PassphraseField();
    let chosen: { name: string; file: Uint8Array } | undefined;
    const fileName = h("span", { class: "hint" });
    const lockedPaste = (): Uint8Array | undefined => {
      if (!looksArmored(key.value)) return undefined;
      try {
        return wrappedBytes(key.value);
      } catch {
        return new Uint8Array(0);
      }
    };
    key.addEventListener("input", () => {
      if (key.value.trim() !== "") {
        chosen = undefined;
        fileName.textContent = "";
      }
      passphrase.show(chosen?.file ?? lockedPaste());
    });
    const fileInput = h("input", { attrs: { type: "file", accept: ".age,.txt,.key,text/plain" }, class: "visually-hidden" });
    fileInput.addEventListener("change", () => {
      const f = fileInput.files?.[0];
      fileInput.value = "";
      if (!f) return;
      if (f.size > maxKeyFileBytes) return this.showUnlock(t("{name} is not a key file (larger than 64 KiB).", { name: f.name }));
      void f.arrayBuffer().then((buf) => {
        const bytes = new Uint8Array(buf);
        if (looksWrapped(bytes)) {
          chosen = { name: f.name, file: wrappedBytes(bytes) };
          key.value = "";
          fileName.textContent = ` ${t("{name} (locked with a passphrase)", { name: f.name })}`;
          passphrase.show(chosen.file);
          passphrase.focus();
        } else {
          chosen = undefined;
          fileName.textContent = "";
          key.value = new TextDecoder().decode(bytes);
          passphrase.show(undefined);
        }
      }).catch((err: unknown) => failed(err));
    });
    const chooseFile = h("button", {
      text: t("Choose a key file…"), class: "secondary", attrs: { type: "button" }, on: { click: () => fileInput.click() },
    });
    const submit = async (e: Event) => {
      e.preventDefault();
      button.disabled = true;
      button.textContent = t("Unlocking…");
      try {
        // A damaged armored paste throws here, with the hint to check the kit's lines.
        const locked = chosen?.file ?? (looksArmored(key.value) ? wrappedBytes(key.value) : undefined);
        let text: string;
        if (locked) {
          if (passphrase.isEmpty()) return this.showUnlock(t("Enter the passphrase."));
          const pass = passphrase.take();
          key.value = "";
          text = await unwrapKeyInWorker(locked, pass);
        } else {
          text = key.value;
          key.value = "";
        }
        opened(await unlock(text), remember.checked());
      } catch (err) {
        failed(err);
      }
    };
    const pv = passkeyVault();
    const remembered = pv ? rememberedCard(pv, m.vaultId, this.location,
      (text) => unlock(text).then(() => this.showMain(), (err: unknown) => {
        failed(err instanceof VaultError ? t("The remembered key no longer opens this vault ({detail}). Forget it and paste the key.", { detail: explain(err) }) : err);
        throw err;
      }),
      (msg) => this.showUnlock(msg), () => this.showUnlock()) : null;
    const stored = storedKeyCard(src, m, async (identity, rememberIt) => {
      try {
        opened(await unlock(identity), rememberIt);
      } catch (err) {
        failed(err);
      }
    }, (msg) => this.showUnlock(msg));
    clear(this.root);
    this.root.append(h("div", { class: "welcome" },
      h("h1", { text: t("Unlock vault") }),
      h("p", { class: "lede" }, `${t("Vault")} `, h("code", { text: src.label }), ` · ${tn("{count} keys", m.recipients.length)}`),
      error ? h("p", { class: "error", text: error, attrs: { role: "alert" } }) : null,
      remembered,
      stored,
      h("form", { class: "card", on: { submit: (e) => void submit(e) } },
        h("label", { text: t("Paste your key (the AGE-SECRET-KEY-PQ-1… line, the whole key file, or a recovery kit's passphrase-locked copy)") }, key),
        h("div", { class: "row" }, chooseFile, fileName, fileInput),
        passphrase.element,
        remember.element,
        h("div", { class: "row" }, button,
          this.locked ? null : h("button", { text: t("Back"), attrs: { type: "button" }, class: "secondary", on: { click: () => this.showOpen() } })),
        h("p", { class: "hint", text: t("The key is kept in this tab's memory only: never sent, and stored only if you ask for a passkey (then encrypted under it). A passphrase is used once and never stored. Closing the tab or Lock forgets the key.") })),
      h("p", { class: "hint" }, clearCacheButton()),
      languagePicker(() => this.showUnlock(error))));
    key.focus();
  }

  // MARK: - Main

  private showMain(): void {
    const src = this.source;
    if (!src) return;
    const searchBox = h("input", { attrs: { type: "search", placeholder: t("Search titles, tags and handwriting"), "aria-label": t("Search") } });
    // Drawn again after a language change: the box shows the search the list is filtered by.
    searchBox.value = this.query;
    const vault = this.vault;
    this.transcripts?.stop();
    this.transcripts = vault ? new TranscriptSearch(
      async (id) => (this.cache.get(id) ?? await loadNote(src, vault, id)).state,
      (id) => (ref, max) => readBlob(src, vault, id, ref, max),
      () => {
        this.transcripts?.index(this.liveIds());
        this.runSearch();
        this.renderList();
      }) : undefined;
    let timer: number | undefined;
    searchBox.addEventListener("input", () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        this.query = searchBox.value;
        this.runSearch();
        this.renderList();
      }, 150);
    });
    clear(this.root);
    this.root.append(h("div", { class: "app" },
      h("header", { class: "topbar" },
        h("strong", { text: "Sempere" }), h("span", { class: "vault-label", text: src.label, title: src.label }), this.status,
        clearCacheButton(), languagePicker(() => this.changedLanguage()),
        h("button", { text: t("Lock"), class: "secondary", attrs: { type: "button" }, title: t("Forget the key and close the vault"), on: { click: () => this.lock() } })),
      ...recipientsWarning(this.vault?.recipientsStatus),
      h("div", { class: "columns" }, this.sidebar,
        h("div", { class: "list-column" }, h("div", { class: "search" }, searchBox, this.transcripts?.element), this.list),
        this.detail)));
    this.detail.replaceChildren(h("p", { class: "empty", text: t("Select a note.") }));
    void this.loadAll();
  }

  /**
   * The language changed while the vault is open: the main screen is drawn again in it (the notes
   * and the key stay in memory; the list is read again from the browser's cache) and the note that
   * was open is reopened.
   */
  private changedLanguage(): void {
    const open = this.selected;
    this.showMain();
    if (open !== undefined && this.notes.has(open)) void this.open(open);
  }

  private lock(): void {
    this.generation++;
    this.transcripts?.stop();
    this.vault = undefined;
    this.notes.clear();
    this.cache.clear();
    this.view?.destroy();
    this.videos?.destroy();
    // A reload drops every reference to the key and decrypted notes.
    location.reload();
  }

  private async loadAll(): Promise<void> {
    const src = this.source, vault = this.vault;
    if (!src || !vault) return;
    const gen = ++this.generation;
    let lastRender = 0;
    const render = (force = false) => {
      if (!force && performance.now() - lastRender < 250) return;
      lastRender = performance.now();
      this.updateStatus();
      this.runSearch();
      this.renderSidebar();
      this.renderList();
    };
    this.updateStatus();
    try {
      // The published summaries first (format.md §12), then only the notes that changed.
      await listVault(src, vault, {
        provisional: (rows) => {
          for (const r of rows) this.notes.set(r.id, r);
          render(true);
        },
        row: (r) => {
          this.notes.set(r.id, r);
          render();
        },
        gone: (id) => this.notes.delete(id),
        progress: (p) => {
          this.loading = { ...p, listed: false };
          render();
        },
        current: () => gen === this.generation,
      });
    } catch (e) {
      if (gen === this.generation) this.status.textContent = t("Cannot list notes: {detail}", { detail: message(e) });
      return;
    }
    if (gen !== this.generation) return;
    this.loading.listed = true;
    this.transcripts?.index(this.liveIds());
    render(true);
  }

  private updateStatus(): void {
    const { checked, total, read, toRead, listed } = this.loading;
    const problems = [...this.notes.values()].filter((n) => n.error !== undefined || n.failures > 0).length;
    const count = listed ? total : this.notes.size;
    // Each count is its own sentence (plural forms differ by language), joined like a list.
    const parts: string[] = listed
      ? [tn("{count} notes", count), ...(problems ? [tn("{count} with problems", problems)] : [])]
      : [read < toRead ? t("Decrypting {read} of {toRead} changed notes… ({checked} of {total} checked)", { read, toRead, checked, total })
        : total > 0 ? t("Checking {checked} of {total} notes…", { checked, total }) : t("Listing notes…")];
    // Content of a newer format version (format.md §7.3): shown as far as understood.
    const newer = (this.manifest ? readOnlyReasons(this.manifest) : []).length > 0
      || [...this.notes.values()].some((n) => n.newer);
    if (newer) parts.push(t("written partly by a newer Sempere"));
    this.status.textContent = parts.join(" · ");
    this.status.title = this.manifest ? readOnlyReasons(this.manifest).join("; ") : "";
  }

  private visible(n: NoteSummary): boolean {
    const f = this.filter;
    switch (f.kind) {
      case "deleted": return n.deleted;
      case "problems": return n.error !== undefined || n.failures > 0;
      default: if (n.deleted) return false;
    }
    switch (f.kind) {
      case "all": return true;
      case "favorites": return n.favorite;
      case "notebook": return isWithinNotebook(n.notebook, f.path);
      case "tag": return n.tags.some((t) => tagKey(t) === f.key);
    }
  }

  private setFilter(f: Filter): void {
    this.filter = f;
    this.renderSidebar();
    this.renderList();
  }

  private renderSidebar(): void {
    const all = [...this.notes.values()];
    const live = all.filter((n) => !n.deleted);
    const isActive = (f: Filter) => JSON.stringify(f) === JSON.stringify(this.filter);
    const item = (label: string, f: Filter, count?: number) =>
      h("li", {}, h("button", {
        class: isActive(f) ? "active" : "", attrs: { type: "button" }, on: { click: () => this.setFilter(f) },
      }, h("span", { class: "label", text: label }), count !== undefined ? h("span", { class: "count", text: String(count) }) : null));
    const notebooks = live.map((n) => n.notebook);
    const counts = notebookCounts(notebooks);
    const tree = (nodes: NotebookNode[]): HTMLElement => h("ul", {}, ...nodes.map((n) => {
      const li = item(n.name, { kind: "notebook", path: n.path }, counts.get(n.path) ?? 0);
      if (n.children.length) li.append(tree(n.children));
      return li;
    }));
    const tags = new Map<string, { label: string; count: number }>();
    for (const n of live) {
      for (const t of n.tags) {
        const k = tagKey(t);
        const cur = tags.get(k);
        if (cur) cur.count++;
        else tags.set(k, { label: t, count: 1 });
      }
    }
    const tagList = [...tags.entries()].sort((a, b) => a[1].label.localeCompare(b[1].label));
    const problems = all.filter((n) => n.error !== undefined || n.failures > 0).length;
    clear(this.sidebar);
    this.sidebar.append(
      h("ul", {}, item(t("All notes"), { kind: "all" }, live.length), item(t("Favorites"), { kind: "favorites" }, live.filter((n) => n.favorite).length)),
      h("h3", { text: t("Notebooks") }), tree(notebookTree(notebooks)),
      h("h3", { text: t("Tags") }), h("ul", {}, ...tagList.map(([k, v]) => item(`#${v.label}`, { kind: "tag", key: k, label: v.label }, v.count))),
      h("h3", { text: t("Other") }),
      h("ul", {}, item(t("Deleted"), { kind: "deleted" }, all.length - live.length), problems ? item(t("Problems"), { kind: "problems" }, problems) : null));
  }

  /** Notes that are not deleted, for the transcript search. */
  private liveIds(): string[] {
    return [...this.notes.values()].filter((n) => !n.deleted).map((n) => n.id);
  }

  private runSearch(): void {
    if (this.query.trim() === "") {
      this.hits = undefined;
      this.searched = undefined;
    } else {
      // While typing narrows the last search over the same notes, only its hits can still match.
      const notes = [...this.notes.values()];
      const last = this.searched;
      const same = last !== undefined && last.notes.length === notes.length && last.notes.every((n, i) => n === notes[i]);
      const candidates = same && refinesQuery(last.query, this.query) ? notes.filter((n) => last.ids.has(n.id)) : notes;
      const found = search(this.query, candidates);
      this.searched = { query: this.query, notes, ids: new Set(found.map((hit) => hit.id)) };
      this.hits = new Map(found.map((hit) => [hit.id, hit]));
    }
    this.transcriptHits = this.hits && this.transcripts ? this.transcripts.hits(this.query) : new Map<string, PhraseHit[]>();
  }

  private renderList(): void {
    let notes = [...this.notes.values()].filter((n) => this.visible(n));
    const hits = this.hits;
    const spoken = this.transcriptHits;
    if (hits) {
      // Notes the note search ranks first, then notes found only in a transcript (the CLI's order: title, id).
      const rank = new Map([...hits.keys()].map((id, i) => [id, i]));
      notes = notes.filter((n) => hits.has(n.id) || spoken.has(n.id)).sort((a, b) =>
        (rank.get(a.id) ?? Infinity) - (rank.get(b.id) ?? Infinity)
        || swiftCompare(a.title.toLowerCase(), b.title.toLowerCase()) || swiftCompare(a.id, b.id));
    } else {
      notes.sort((a, b) => (b.modified ?? 0) - (a.modified ?? 0) || a.title.localeCompare(b.title));
    }
    clear(this.list);
    if (notes.length === 0) {
      this.list.append(h("p", { class: "empty", text: !this.loading.listed ? t("Loading…") : hits ? t("No matches.") : t("No notes here.") }));
      return;
    }
    this.list.append(h("ul", {}, ...notes.map((n) => {
      const hit = hits?.get(n.id);
      const meta = [canonicalNotebook(n.notebook), ...n.tags.map((t) => `#${t}`)].filter(Boolean).join("  ");
      const badges: string[] = [];
      if (n.error !== undefined) badges.push(t("unreadable"));
      else if (n.failures > 0) badges.push(tn("{count} unreadable revisions", n.failures));
      if (n.newer) badges.push(t("newer version"));
      return h("li", {}, h("button", {
        class: n.id === this.selected ? "note active" : "note", attrs: { type: "button" },
        on: { click: () => void this.open(n.id, hit?.page?.number) },
      },
      h("span", { class: "title", text: n.title || t("Untitled") }),
      h("span", { class: "sub", text: [formatDate(n.modified), tn("{count} pages", n.pageCount)].filter(Boolean).join(" · ") }),
      meta ? h("span", { class: "sub", text: meta }) : null,
      hit?.snippet ? this.snippet(hit) : null,
      badges.length ? h("span", { class: "badge", text: badges.join(" · ") }) : null),
      this.spokenHits(n.id, spoken.get(n.id)));
    })));
  }

  private snippet(hit: SearchHit): HTMLElement {
    const sn = hit.snippet;
    const el = h("span", { class: "snippet" });
    if (!sn) return el;
    if (hit.page) el.append(h("span", { class: "page-ref", text: t("p. {number}: ", { number: hit.page.number }) }));
    // A match only inside an equation: a marker, never the LaTeX source (Swift `NoteSearch.equationMarker`).
    if (sn.isEquation) {
      el.append(h("span", { class: "equation-marker", text: t("[equation]") }));
      return el;
    }
    let at = 0;
    for (const [a, b] of sn.matches) {
      if (a < at) continue;
      el.append(sn.text.slice(at, a), h("mark", { text: sn.text.slice(a, b) }));
      at = b;
    }
    el.append(sn.text.slice(at));
    return el;
  }

  /** A note's transcript matches, each a button that opens the recording at that time. */
  private spokenHits(id: string, hits: PhraseHit[] | undefined): HTMLElement | null {
    if (!hits || hits.length === 0) return null;
    const term = foldTerm(trimTerm(this.query));
    const shown = hits.slice(0, maxHitsShown);
    return h("ul", { class: "spoken-hits", attrs: { "aria-label": t("Matches in recording transcripts") } },
      ...shown.map((hit) => {
        const text = h("span", { class: "snippet" });
        const folded = prepare(hit.snippet);
        let at = 0;
        for (const [a, b] of occurrences(folded, term)) {
          const from = folded.offsets[a] ?? 0, to = folded.offsets[b] ?? 0;
          text.append(hit.snippet.slice(at, from), h("mark", { text: hit.snippet.slice(from, to) }));
          at = to;
        }
        text.append(hit.snippet.slice(at));
        const where = `${hit.recordingTitle?.trim() || t("Recording")} ${formatDuration(hit.start ?? 0)}`;
        return h("li", {}, h("button", {
          class: "spoken-hit", attrs: { type: "button" }, title: t("Play {where}", { where }),
          on: { click: () => void this.open(id, undefined, { recording: hit.recordingId ?? "", start: hit.start ?? 0 }) },
        }, h("span", { class: "page-ref", text: `🎙 ${where}: ` }), text));
      }),
      hits.length > shown.length ? h("li", { class: "sub", text: tn("{count} more in transcripts", hits.length - shown.length) }) : null);
  }

  private async open(id: string, page?: number, at?: { recording: string; start: number }): Promise<void> {
    const src = this.source, vault = this.vault;
    if (!src || !vault) return;
    this.selected = id;
    this.renderList();
    const gen = this.generation;
    this.view?.destroy();
    this.view = undefined;
    this.recordings?.destroy();
    this.recordings = undefined;
    this.videos?.destroy();
    this.videos = undefined;
    this.detail.replaceChildren(h("p", { class: "empty", text: t("Decrypting…") }));
    let note = this.cache.get(id);
    if (!note) {
      try {
        note = await loadNote(src, vault, id);
      } catch (e) {
        note = { id, error: message(e), failures: [], revisionCount: 0, hasAttachments: false };
      }
      this.cache.set(id, note);
      while (this.cache.size > 8) this.cache.delete(this.cache.keys().next().value ?? "");
      // What the revisions say wins over a published summary (format.md §12.3).
      if (gen === this.generation && this.notes.has(id)) {
        this.notes.set(id, summarize(note));
        this.renderSidebar();
      }
    }
    if (gen !== this.generation || this.selected !== id) return;
    this.renderNote(note, page, at);
  }

  private renderNote(note: LoadedNote, page?: number, at?: { recording: string; start: number }): void {
    const state: NoteState | undefined = note.state;
    const warnings: HTMLElement[] = [];
    if (note.failures.length) {
      warnings.push(h("details", { class: "warning" },
        h("summary", { text: t("{failed} of {total} revisions could not be read; the note is shown without them.", { failed: note.failures.length, total: note.revisionCount }) }),
        h("ul", {}, ...note.failures.map((f) => h("li", {}, h("code", { text: f.file }), ` ${f.message}`)))));
    }
    if (!state) {
      this.detail.replaceChildren(h("div", { class: "note-header" }, h("h2", { text: t("This note cannot be opened") }),
        h("p", { class: "error", text: note.error ?? t("unknown error") })), ...warnings);
      return;
    }
    if (note.newer) {
      warnings.push(h("p", { class: "warning", text:
        t("Parts of this note were written by a newer version of Sempere ({summary}); it is shown as far as this viewer understands it.", { summary: newerSummary(note.newer) }) }));
    }
    if (state.deleted) warnings.push(h("p", { class: "warning", text: t("This note is deleted (it stays in the vault until restored in the app).") }));
    if (hasUnknownPaper(state)) warnings.push(h("p", { class: "warning", text: t("Some paper was made by a newer app; it is shown as blank paper.") }));
    const m = state.meta;
    const notebook = canonicalNotebook(m.notebook);
    const meta = [notebook ? t("Notebook: {name}", { name: notebook.replaceAll("/", " › ") }) : "", t("Created {date}", { date: formatDate(m.created) }),
      tn("{count} pages", state.pages.length)].filter(Boolean).join(" · ");
    const blobs = this.source && this.vault ? new NoteBlobs(this.source, this.vault, note.id) : undefined;
    const videos = new VideosPanel(state, blobs);
    this.videos = videos;
    const recordings = new RecordingsPanel(state.recordings, blobs);
    this.recordings = recordings;
    this.view = new NoteView(state, blobs, (id) => void videos.play(id), (id) => recordings.play(id));
    this.detail.replaceChildren(
      h("div", { class: "note-header" },
        h("h2", { text: m.title || t("Untitled") }), h("p", { class: "sub", text: meta }),
        m.tags.length ? h("p", { class: "tags" }, ...m.tags.map((t) => h("span", { class: "tag", text: `#${t}` }))) : null,
        ...warnings, this.view.problemsEl, this.recordings.root, videos.root),
      this.view.root);
    if (page !== undefined) requestAnimationFrame(() => requestAnimationFrame(() => this.view?.showPage(page)));
    if (at) recordings.jump(at.recording, at.start);
  }
}

/** A banner when vault.json's device list does not check (format.md §2.1). */
function recipientsWarning(status: RecipientsStatus | undefined): HTMLElement[] {
  const text = recipientsWarningText(status);
  return text ? [h("p", { class: "warning", attrs: { role: "alert" }, text })] : [];
}
