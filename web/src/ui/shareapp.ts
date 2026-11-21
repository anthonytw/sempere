// The page of a share file (docs/design/1.3-share.md §3.3, docs/web-viewer.md "Share files"): ask for the
// passphrase, open the age ciphertext in the page, and show the one note with the viewer's note view. There is
// no vault, no picker, no network and no storage here; the page's CSP forbids all of them.

import { t, tn } from "../i18n/index.ts";
import { Budget } from "../format/attachments.ts";
import { decodeState } from "../format/model.ts";
import { parsePayload, ShareFormatError } from "../share/container.ts";
import { ShareBlobs } from "../share/blobs.ts";
import { ShareOpenError, ageBytes, shareWorkFactor } from "../share/open.ts";
import { openShare } from "../share/worker.ts";
import { isDecodeError } from "../format/model.ts";
import { NoteView } from "./noteview.ts";
import { RecordingsPanel } from "./recordings.ts";
import { formatDate, h } from "./dom.ts";

/** What the page needs from its surroundings, so tests can drive it. */
export interface ShareHost {
  /** The text of the data block (the age armor). */
  data: string;
  /** This page's own script, for the worker; undefined where it cannot be read. */
  workerSource?: string;
  print(): void;
}

export class ShareApp {
  private view?: NoteView;
  private recordings?: RecordingsPanel;

  constructor(private readonly root: HTMLElement, private readonly host: ShareHost) {}

  start(): void {
    let problem: string | undefined;
    try {
      shareWorkFactor(ageBytes(this.host.data));
    } catch (e) {
      problem = e instanceof ShareOpenError && e.code === "workFactor"
        ? t("This note asks for more memory than this viewer allows. Try another way to open it: the age tool, as docs/web-viewer.md describes.")
        : t("This file is not a Sempere share, or it is damaged.");
    }
    this.askForPassphrase(problem);
  }

  private banner(): HTMLElement {
    return h("p", { class: "share-banner", text: t("Shared from Sempere, read-only. This file does not change the original.") });
  }

  private askForPassphrase(problem?: string): void {
    const input = h("input", { attrs: { type: "password", autocomplete: "off", autocapitalize: "off", spellcheck: "false", "aria-label": t("Passphrase") } });
    const status = h("p", { class: "hint", attrs: { role: "status" } });
    const error = h("p", { class: "error", attrs: { role: "alert" }, text: problem ?? "" });
    const open = h("button", { text: t("Open the note"), attrs: { type: "button" } });
    const run = (): void => {
      const passphrase = input.value;
      if (passphrase.length === 0) return;
      input.value = "";
      input.disabled = true;
      open.disabled = true;
      error.textContent = "";
      status.textContent = t("Decrypting…");
      void this.open(passphrase).catch((e: unknown) => {
        input.disabled = false;
        open.disabled = false;
        status.textContent = "";
        error.textContent = failure(e);
        input.focus();
      });
    };
    open.addEventListener("click", run);
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") run(); });
    // Outside any form element: the CSP forbids form actions, and nothing here is ever sent.
    const card = h("div", { class: "card" }, h("label", {}, t("Passphrase"), input), open, status, error);
    if (problem !== undefined) { input.disabled = true; open.disabled = true; }
    this.root.replaceChildren(h("div", { class: "welcome" }, this.banner(), card));
    if (problem === undefined) input.focus();
  }

  private async open(passphrase: string): Promise<void> {
    const plain = await openShare(this.host.data, passphrase, this.host.workerSource);
    const payload = await parsePayload(plain);
    const state = decodeState(payload.note, "$.note", new Budget());
    const blobs = new ShareBlobs(payload.blobs);
    // A share written without dates carries the epoch for every date (WebPageShare.flatten): show none.
    const hasDates = state.meta.created !== 0;
    const recordings = new RecordingsPanel(state.recordings, blobs, undefined, hasDates);
    this.recordings = recordings;
    this.view?.destroy();
    this.view = new NoteView(state, blobs, undefined, (id) => recordings.play(id));
    // The writer puts the title it shows in the share (a voice note's too, without the capture time unless it carries dates).
    const title = state.meta.title || t("Untitled");
    const m = state.meta;
    this.root.replaceChildren(h("div", { class: "app" },
      h("div", { class: "topbar" }, this.banner(),
        h("button", { class: "secondary", text: t("Print"), attrs: { type: "button" }, on: { click: () => this.host.print() } })),
      h("div", { class: "note-header" },
        h("h2", { text: title }),
        m.tags.length ? h("p", { class: "tags" }, ...m.tags.map((x) => h("span", { class: "tag", text: `#${x}` }))) : null,
        h("p", { class: "sub", text: [m.notebook ? t("Notebook: {name}", { name: m.notebook.replaceAll("/", " › ") }) : "",
          hasDates ? formatDate(state.meta.created) : "",
          tn("{count} pages", state.pages.length)].filter(Boolean).join(" · ") }),
        this.view.problemsEl, recordings.root),
      this.view.root));
  }
}

function failure(e: unknown): string {
  if (e instanceof ShareOpenError) {
    if (e.code === "wrongPassphrase") return t("That passphrase did not open this note");
    if (e.code === "workFactor") return t("This note asks for more memory than this viewer allows. Try another way to open it: the age tool, as docs/web-viewer.md describes.");
    return t("This file is not a Sempere share, or it is damaged.");
  }
  if (e instanceof ShareFormatError) return t("This file is not a Sempere share, or it is damaged.");
  if (isDecodeError(e)) return t("The shared note could not be shown: {detail}", { detail: e.message });
  return t("This browser ran out of memory opening the note. Try a desktop browser.");
}
