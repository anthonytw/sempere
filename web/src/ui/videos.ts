// A note's video clips (format.md §8.2.7): listed with their page and
// length; a clip is fetched, decrypted and verified (§8.1.4) only when Play
// is pressed, here or by tapping it on the page, and played in a <video>
// from an object URL. One clip is held at a time: playing another, closing
// the player or leaving the note revokes the URL so the browser can free it.

import { t, tn } from "../i18n/index.ts";
import type { NoteState } from "../format/model.ts";
import { cmpItems } from "../format/registers.ts";
import { type BlobRef, type NoteBlobs, asBlobRef, essence } from "../vault/blobs.ts";
import { blobProblem } from "./errors.ts";
import { h } from "./dom.ts";
import { formatDuration } from "./recordings.ts";

/**
 * Largest clip the viewer plays: the browser holds the whole verified file
 * (no temporary files), so the 1 GiB of §8.4 would risk the tab. Larger clips
 * are shown as their poster; `sempere blobs extract` gets the file.
 */
export const maxVideoBytes = 512 * 1024 * 1024;

/** Media types the viewer hands to <video> (§8.2.7). */
const playable = new Set(["video/mp4", "video/quicktime"]);

/** One clip of the note: the first placement of each item, in page and drawing order. */
export interface VideoEntry {
  item: string;
  page: number;
  clip: BlobRef;
  duration?: number;
  /** `h264`, `hevc` (informational). */
  codec?: string;
}

/** The note's video items in page and drawing order. */
export function videoEntries(state: NoteState): VideoEntry[] {
  const out: VideoEntry[] = [];
  state.pages.forEach((page, i) => {
    for (const item of [...page.items].sort(cmpItems)) {
      if (item.kind !== "video") continue;
      const clip = asBlobRef(item.blob);
      if (!clip) continue;
      out.push({ item: String(item.id), page: i + 1, clip, ...(typeof item.duration === "number" ? { duration: item.duration } : {}),
        ...(typeof item.codec === "string" ? { codec: item.codec } : {}) });
    }
  });
  return out;
}

function problem(e: unknown): string {
  return blobProblem(e, "video", maxVideoBytes) ?? (e instanceof Error ? e.message : String(e));
}

export class VideosPanel {
  readonly root: HTMLElement;
  private readonly player = h("div", { class: "video-player" });
  private readonly status = h("p", { class: "rec-status", attrs: { role: "status" } });
  private url?: string;
  private playing?: string;
  private generation = 0;
  private destroyed = false;
  private readonly entries: VideoEntry[];

  constructor(state: NoteState, private readonly blobs?: NoteBlobs) {
    this.entries = videoEntries(state);
    const rows = this.entries.map((v, i) => h("li", { class: "recording" },
      h("div", { class: "rec-head" },
        h("span", { class: "title", text: t("Video {number}", { number: i + 1 }) }),
        h("span", { class: "sub", text: [t("page {number}", { number: v.page }), v.duration !== undefined ? formatDuration(v.duration) : ""].filter(Boolean).join(" · ") })),
      h("div", { class: "rec-actions" }, h("button", { text: t("Play"), attrs: { type: "button" }, on: { click: () => void this.play(v.item) } }))));
    this.root = h("details", { class: "recordings videos" },
      h("summary", { text: tn("{count} videos", this.entries.length) }),
      h("ul", {}, ...rows), this.status, this.player);
    this.player.hidden = true;
    this.root.hidden = this.entries.length === 0;
  }

  /** Plays the clip of video item `id` (a tap on the page, or Play). */
  async play(id: string): Promise<void> {
    const v = this.entries.find((e) => e.item === id);
    if (!v) return;
    (this.root as HTMLDetailsElement).open = true;
    if (this.playing === id && this.url) {
      void this.player.querySelector("video")?.play().catch(() => undefined);
      return;
    }
    this.close();
    const gen = ++this.generation;
    this.playing = id;
    if (!this.blobs) {
      this.status.textContent = t("The video is not available.");
      return;
    }
    if (!playable.has(essence(v.clip.type))) {
      this.status.textContent = t("This clip's type ({type}) cannot be played here.", { type: v.clip.type });
      return;
    }
    this.status.textContent = t("Decrypting…");
    try {
      const blob = await this.blobs.get(v.clip, maxVideoBytes);
      // Another clip, or another note, may have been chosen meanwhile: nothing is kept then.
      if (this.destroyed || gen !== this.generation) return;
      this.url = URL.createObjectURL(new Blob([blob], { type: essence(v.clip.type) }));
      const video = h("video", { attrs: { controls: "", playsinline: "", preload: "auto" } });
      video.addEventListener("error", () => {
        this.status.textContent = t("This browser cannot play the clip's format ({codec}; HEVC needs Safari, or Chrome or Edge with hardware support). The CLI can extract the file.", { codec: v.codec ?? t("unknown codec") });
      });
      video.src = this.url;
      const close = h("button", { text: t("Close"), attrs: { type: "button" }, on: { click: () => this.close() } });
      this.player.replaceChildren(video, close);
      this.player.hidden = false;
      this.status.textContent = "";
      void video.play().catch(() => undefined);
    } catch (e) {
      if (gen === this.generation) this.status.textContent = problem(e);
    }
  }

  /** Stops the clip and lets the browser free it. */
  close(): void {
    this.generation += 1;
    this.playing = undefined;
    const video = this.player.querySelector("video");
    if (video) {
      video.pause();
      video.removeAttribute("src");
      video.load();
    }
    this.player.replaceChildren();
    this.player.hidden = true;
    if (this.url) URL.revokeObjectURL(this.url);
    this.url = undefined;
    this.status.textContent = "";
  }

  destroy(): void {
    this.destroyed = true;
    this.close();
  }
}
