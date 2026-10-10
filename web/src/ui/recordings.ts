// A note's recordings (format.md §8.3): listed with their title, start and
// length; the audio is fetched only when Play is pressed, and a transcript
// only when it is opened. Both come from verified blobs (§8.1.4); a
// transcript that breaks §8.3.2 is reported like a blob that fails
// verification. Tapping a segment plays the recording from its start.

import { t, tn } from "../i18n/index.ts";
import { type CapturedBy, capturedBy } from "../format/captured.ts";
import type { JSONObject } from "../format/json.ts";
import { parseRFC3339 } from "../format/rfc3339.ts";
import { type Transcript, decodeTranscript, maxTranscriptBytes } from "../format/transcript.ts";
import { type NoteBlobs, asBlobRef, essence } from "../vault/blobs.ts";
import { blobProblem } from "./errors.ts";
import { formatDate, h } from "./dom.ts";

/**
 * Largest recording the viewer plays: a browser holds the whole verified
 * file in memory (no temporary files), so the 1 GiB of §8.4 would risk the
 * tab. 256 MiB is over 8 hours at the app's default 64 kbit/s.
 */
export const maxAudioBytes = 256 * 1024 * 1024;

/** `m:ss` or `h:mm:ss`. */
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "";
  const t = Math.floor(seconds);
  const hh = Math.floor(t / 3600), mm = Math.floor((t % 3600) / 60), ss = t % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return hh > 0 ? `${hh}:${two(mm)}:${two(ss)}` : `${mm}:${two(ss)}`;
}

function problem(e: unknown): string {
  return blobProblem(e, "audio", maxAudioBytes) ?? (e instanceof Error ? e.message : String(e));
}

export class RecordingsPanel {
  readonly root: HTMLElement;
  private readonly urls: string[] = [];
  private destroyed = false;
  /** Plays each recording from its start (by id), for audio items on the page (§8.2.9). */
  private readonly players = new Map<string, { row: HTMLElement; play: () => void; jump: (seconds: number) => void }>();

  /**
   * - Parameter recipients: the vault's recipients, to say which device captured a voice note
   *   (format.md §8.3.1 `captured`); without them a capture's line stays empty.
   */
  constructor(recordings: JSONObject[], private readonly blobs?: NoteBlobs,
              private readonly recipients?: readonly { key: string; label: string }[]) {
    this.root = h("details", { class: "recordings" },
      h("summary", { text: tn("{count} recordings", recordings.length) }),
      h("ul", {}, ...recordings.map((r) => this.row(r))));
    this.root.hidden = recordings.length === 0;
  }

  /** Opens the list at recording `id` and plays it (a tap on its card on the page). */
  play(id: string): void {
    const p = this.players.get(id.toLowerCase());
    if (!p) return;
    (this.root as HTMLDetailsElement).open = true;
    p.row.scrollIntoView?.({ block: "nearest" });
    p.play();
  }

  /**
   * Opens the list at recording `id`, shows its transcript with the segment
   * starting at `seconds` marked, and cues the audio there (a transcript
   * search result). Playing waits for the user's Play.
   */
  jump(id: string, seconds: number): void {
    const p = this.players.get(id.toLowerCase());
    if (!p) return;
    (this.root as HTMLDetailsElement).open = true;
    p.jump(seconds);
  }

  destroy(): void {
    this.destroyed = true;
    for (const u of this.urls) URL.revokeObjectURL(u);
    this.urls.length = 0;
  }

  private row(rec: JSONObject): HTMLElement {
    const title = typeof rec.title === "string" && rec.title.trim() !== "" ? rec.title : t("Recording");
    const started = typeof rec.started === "string" ? parseRFC3339(rec.started) : undefined;
    const duration = typeof rec.duration === "number" ? formatDuration(rec.duration) : "";
    const ref = asBlobRef(rec.blob);
    const transcriptRef = asBlobRef(rec.transcript);
    const status = h("p", { class: "rec-status", attrs: { role: "status" } });
    const player = h("div", { class: "rec-player" });
    const transcriptEl = h("div", { class: "transcript" });
    let loading: Promise<HTMLAudioElement | undefined> | undefined;

    const loadAudio = (): Promise<HTMLAudioElement | undefined> => {
      loading ??= (async () => {
        if (!ref || !this.blobs) {
          status.textContent = t("The audio is not available.");
          return undefined;
        }
        if (!essence(ref.type).startsWith("audio/")) {
          status.textContent = t("This recording's type ({type}) cannot be played here.", { type: ref.type });
          return undefined;
        }
        status.textContent = t("Decrypting…");
        try {
          const blob = await this.blobs.get(ref, maxAudioBytes);
          // The note may have been closed meanwhile: then nothing is kept.
          if (this.destroyed) return undefined;
          const url = URL.createObjectURL(new Blob([blob], { type: essence(ref.type) }));
          this.urls.push(url);
          const a = h("audio", { attrs: { controls: "", preload: "auto" } });
          a.addEventListener("error", () => {
            status.textContent = t("This browser cannot play the recording's audio format.");
          });
          a.src = url;
          player.replaceChildren(a);
          status.textContent = "";
          return a;
        } catch (e) {
          status.textContent = problem(e);
          loading = undefined;
          return undefined;
        }
      })();
      return loading;
    };

    const play = h("button", {
      text: t("Play"), attrs: { type: "button" }, on: {
        click: () => {
          void loadAudio().then((a) => a?.play().catch(() => undefined));
        },
      },
    });
    player.append(play);

    const seek = (t: number) => {
      void loadAudio().then((a) => {
        if (!a) return;
        a.currentTime = t;
        void a.play().catch(() => undefined);
      });
    };

    let transcriptLoaded: Promise<void> | undefined;
    const loadTranscript = (): Promise<void> => {
      if (!transcriptRef || !this.blobs) return Promise.resolve();
      transcriptLoaded ??= (async () => {
        transcriptEl.replaceChildren(h("p", { class: "sub", text: t("Decrypting…") }));
        try {
          const b = await this.blobs?.get(transcriptRef, maxTranscriptBytes);
          if (!b) return;
          const t = decodeTranscript(new Uint8Array(await b.arrayBuffer()), String(rec.id).toLowerCase());
          transcriptEl.replaceChildren(...transcriptView(t, seek));
        } catch (e) {
          transcriptEl.replaceChildren(h("p", { class: "error", text: t("The transcript cannot be shown: {detail}", { detail: problem(e) }) }));
        }
      })();
      return transcriptLoaded;
    };
    const setTranscriptOpen = (open: boolean) => {
      transcriptEl.hidden = !open;
      showTranscript?.setAttribute("aria-expanded", String(open));
      if (open) void loadTranscript();
    };
    const showTranscript = transcriptRef ? h("button", {
      text: t("Transcript"), attrs: { type: "button", "aria-expanded": "false" }, on: {
        click: () => setTranscriptOpen(transcriptEl.hidden !== false || transcriptLoaded === undefined),
      },
    }) : null;
    const jump = (seconds: number) => {
      setTranscriptOpen(true);
      void loadTranscript().then(() => {
        if (this.destroyed) return;
        for (const li of transcriptEl.querySelectorAll<HTMLElement>("li.found")) li.classList.remove("found");
        const seg = [...transcriptEl.querySelectorAll<HTMLElement>("li[data-start]")].find((li) => Number(li.dataset.start) === seconds);
        seg?.classList.add("found");
        (seg ?? row).scrollIntoView?.({ block: "center" });
      });
      void loadAudio().then((a) => {
        if (!a) return;
        const cue = () => {
          a.currentTime = seconds;
        };
        if (a.readyState >= 1) cue();
        else a.addEventListener("loadedmetadata", cue, { once: true });
      });
    };

    // A voice note adopted from the inbox says which device captured it, as the app does: its title and
    // notebook are the capturing device's choice (security review 2026-10, C2 and S10).
    const captured = h("span", { class: "sub captured", attrs: { role: "note" } });
    captured.hidden = true;
    if (this.recipients) {
      void capturedBy(rec, this.recipients).then((by) => {
        if (!by || this.destroyed) return;
        captured.textContent = capturedText(by);
        captured.hidden = false;
      });
    }
    const row = h("li", { class: "recording" },
      h("div", { class: "rec-head" },
        h("span", { class: "title", text: title }),
        h("span", { class: "sub", text: [formatDate(started), duration].filter(Boolean).join(" · ") }),
        captured),
      h("div", { class: "rec-actions" }, player, showTranscript),
      status, transcriptEl);
    this.players.set(String(rec.id).toLowerCase(), {
      row, play: () => void loadAudio().then((a) => a?.play().catch(() => undefined)), jump,
    });
    return row;
  }
}

/** The line under a captured recording's title (the app's `capturedBy`). */
export function capturedText(by: CapturedBy): string {
  switch (by.kind) {
    case "unverified": return t("Voice note from an unverified device");
    case "removed": return t("Voice note from a device no longer in this vault");
    case "device": return t("Voice note from {name}", { name: by.label === "" ? t("Device") : by.label });
  }
}

/** Most segments listed at once; a longer transcript says how many are left out. */
const maxSegmentsShown = 5_000;

function transcriptView(tr: Transcript, seek: (seconds: number) => void): HTMLElement[] {
  const shown = tr.segments.slice(0, maxSegmentsShown);
  const list = h("ol", { class: "segments" }, ...shown.map((seg) => {
    const text = h("span", { class: "seg-text" });
    if (seg.words && seg.words.length > 0) {
      // Words the recogniser doubted (confidence under 0.5) are marked (§8.3.2).
      seg.words.forEach((w, i) => {
        if (i > 0) text.append(" ");
        text.append(w.c !== undefined && w.c < 0.5 ? h("span", { class: "doubtful", text: w.t, title: t("confidence {value}", { value: w.c }) }) : w.t);
      });
    } else {
      text.textContent = seg.text;
    }
    return h("li", { attrs: { "data-start": String(seg.start) } }, h("button", {
      class: "seg-time", text: formatDuration(seg.start), title: t("Play from here"), attrs: { type: "button" },
      on: { click: () => seek(seg.start) },
    }), text);
  }));
  const out = [h("p", { class: "sub", text: [tr.language, tr.engine].filter(Boolean).join(" · ") }), list];
  if (tr.segments.length > shown.length) out.push(h("p", { class: "sub", text: tn("{count} more segments not shown.", tr.segments.length - shown.length) }));
  return out;
}
