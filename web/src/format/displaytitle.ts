// The title a voice note is shown under while it stores none (format.md §8.3.1 `captureInfo`, §16.8), the viewer's part
// of Swift's `NoteDisplayTitle.defaultTitle`: the words for the capture's source and the capture's date and time, in the
// capture's own time zone. The viewer does not read Note Insights' files: a derived title reaches it only as the published
// summaries' `shown` (format.md §12.2), which a row prefers (`shownTitle`). Otherwise a title the person typed wins and a
// blank one shows this default (a 1.0 through 1.2 note stored its default, which is shown as stored).

import { locale, t } from "../i18n/index.ts";
import type { JSONObject } from "./json.ts";
import { parseRFC3339 } from "./rfc3339.ts";

/** Where and when a voice note was captured (Swift `VoiceOrigin`). */
export interface VoiceOrigin {
  /** The first captured recording's start, Unix milliseconds. */
  started: number;
  /** The capturing device's time zone (`captureInfo.tz`). */
  tz?: string;
  /** `phone` or `watch` (`captureInfo.source`). */
  source?: string;
}

/** The origin of a note's recordings: the first one that was captured (`captured` present), none for any other note. */
export function voiceOrigin(recordings: readonly JSONObject[]): VoiceOrigin | undefined {
  const r = recordings.find((x) => typeof x.captured === "object" && x.captured !== null);
  if (r === undefined || typeof r.started !== "string") return undefined;
  const started = parseRFC3339(r.started);
  if (started === undefined) return undefined;
  const info = r.captureInfo;
  const o = typeof info === "object" && info !== null && !Array.isArray(info) ? (info as JSONObject) : {};
  const out: VoiceOrigin = { started };
  if (typeof o.tz === "string") out.tz = o.tz;
  if (typeof o.source === "string") out.source = o.source;
  return out;
}

/** "Voice note Nov 16, 2026, 2:32 PM": the words of the source and the capture's date and time in its zone. */
export function defaultVoiceTitle(origin: VoiceOrigin): string {
  const words = origin.source === "watch" ? t("Watch voice note") : t("Voice note");
  const style: Intl.DateTimeFormatOptions = { dateStyle: "medium", timeStyle: "short" };
  let when: string;
  try {
    when = new Date(origin.started).toLocaleString(locale(), origin.tz === undefined ? style : { ...style, timeZone: origin.tz });
  } catch {
    when = new Date(origin.started).toLocaleString(locale(), style);   // an unknown zone name: the reader's
  }
  return `${words} ${when}`;
}

/** The title to show: `stored` when it has text; else, for a voice note, its default; else "" (callers say "Untitled"). */
export function displayTitle(stored: string, origin: VoiceOrigin | undefined): string {
  if (stored.trim() !== "") return stored;
  return origin === undefined ? "" : defaultVoiceTitle(origin);
}

/** A list row's title (format.md §12.2): the published `shown` title (one Note Insights derived), else `displayTitle`. */
export function shownTitle(n: { title: string; voice?: VoiceOrigin; shown?: string }): string {
  return n.shown !== undefined && n.shown.trim() !== "" ? n.shown : displayTitle(n.title, n.voice);
}
