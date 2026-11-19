// The title a voice note shows while it stores none (format.md §8.3.1 `captureInfo`, §16.8), as Swift's
// `NoteDisplayTitle.defaultTitle`: the capture's own zone, the source's words, the reader's language.

import { afterEach, describe, expect, it } from "vitest";
import { defaultVoiceTitle, displayTitle, voiceOrigin } from "../src/format/displaytitle.ts";
import { setLocale } from "../src/i18n/index.ts";
import { summarize } from "../src/vault/library.ts";
import type { JSONObject } from "../src/format/json.ts";

afterEach(() => setLocale("en"));

const captured = { device: "0badf00d", recipient: "a".repeat(64) };
const rec = (extra: JSONObject = {}): JSONObject => ({ id: "r1", started: "2026-11-16T19:32:00.000Z", captured, ...extra });

describe("a voice note's default title", () => {
  it("reads the first captured recording, and no other note has one", () => {
    expect(voiceOrigin([{ id: "x", started: "2026-11-16T19:32:00Z" }])).toBeUndefined();
    expect(voiceOrigin([])).toBeUndefined();
    const o = voiceOrigin([{ id: "x", started: "2026-01-01T00:00:00Z" }, rec({ captureInfo: { tz: "America/New_York", source: "watch" } })]);
    expect(o).toEqual({ started: Date.UTC(2026, 10, 16, 19, 32), tz: "America/New_York", source: "watch" });
  });

  it("words the source and shows the capture's own clock", () => {
    const phone = defaultVoiceTitle({ started: Date.UTC(2026, 10, 16, 19, 32), tz: "America/New_York", source: "phone" });
    expect(phone).toMatch(/^Voice note Nov 16, 2026,? 2:32\s?PM$/);
    expect(defaultVoiceTitle({ started: Date.UTC(2026, 10, 16, 19, 32), tz: "Asia/Tokyo", source: "watch" })).toMatch(/^Watch voice note .*4:32\s?AM$/);
    expect(defaultVoiceTitle({ started: Date.UTC(2026, 10, 16, 19, 32), tz: "Not/AZone" })).toMatch(/^Voice note /);
    setLocale("es");
    expect(defaultVoiceTitle({ started: Date.UTC(2026, 10, 16, 19, 32), tz: "Europe/Madrid", source: "phone" })).toMatch(/^Nota de voz 16 nov 2026,? 20:32$/);
  });

  it("never replaces a title that has text", () => {
    const o = voiceOrigin([rec()]);
    expect(displayTitle("Groceries", o)).toBe("Groceries");
    expect(displayTitle("Voice note 2026-11-16 14:32", o)).toBe("Voice note 2026-11-16 14:32");
    expect(displayTitle("  ", o)).toMatch(/^Voice note /);
    expect(displayTitle("", undefined)).toBe("");
  });

  it("is carried by the list row's summary", () => {
    const state = { deleted: false, meta: { title: "", tags: [], favorite: false, created: 0 }, pages: [], recordings: [rec()] };
    const s = summarize({ id: "n1", state, failures: [], hasAttachments: true } as never);
    expect(s.voice?.started).toBe(Date.UTC(2026, 10, 16, 19, 32));
    expect(displayTitle(s.title, s.voice)).toMatch(/^Voice note /);
  });
});
