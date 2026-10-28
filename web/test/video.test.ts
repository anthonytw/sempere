// Video items (format.md §8.2.7): decoding and its limits, the poster
// register, the play mark's geometry, the poster's placement, the list of
// clips the viewer offers, and hit testing a tap on a rotated frame. The
// rendering itself is cross-checked with the Swift CLI (items-crosscheck).

import { describe, expect, it } from "vitest";
import { Budget, checkItemChange, decodeItem } from "../src/format/attachments.ts";
import { DecodeError, type JSONObject } from "../src/format/json.ts";
import { applyItemRegister, itemRegisters } from "../src/format/registers.ts";
import { corners, playMarkCommands, posterTransform, prepareItem } from "../src/render/items.ts";
import { resolveItems } from "../src/render/itemsvg.ts";
import { insidePolygon } from "../src/ui/noteview.ts";
import { videoEntries } from "../src/ui/videos.ts";
import { emptyState } from "./builders.ts";

const itemId = "6f1c2d4e-0000-4000-8000-000000000001";
const hashA = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
const hashB = "b023506dad39637be6e6e2ec3a0c31f8c0af3fe9bc060be0223b789cb75e5c00";
const clip = `{"sha256":"${hashA}","size":48211330,"type":"video/mp4"}`;
const poster = `{"sha256":"${hashB}","size":81211,"type":"image/jpeg"}`;

function video(extra: string): string {
  return `{"id":"${itemId}","kind":"video","frame":[72,144,320,180],"z":"a2","blob":${clip}${extra}}`;
}

function decode(s: string): JSONObject {
  return decodeItem(JSON.parse(s), "$.ops[0].item", new Budget());
}

describe("video items (§8.2.7)", () => {
  it("decodes the format's example", () => {
    const v = decode(video(`,"pixelSize":[1920,1080],"duration":42.517,"videoRotation":90,"codec":"hevc","poster":${poster}`));
    expect(v.kind).toBe("video");
    expect(() => decode(video(`,"pixelSize":[4,3],"duration":0,"poster":null`))).not.toThrow();
  });

  it("rejects what the Swift reader rejects", () => {
    for (const bad of [
      video(`,"pixelSize":[4,3]`),
      `{"id":"${itemId}","kind":"video","frame":[0,0,1,1],"z":"a","pixelSize":[4,3],"duration":1}`,
      video(`,"duration":1`),
      video(`,"pixelSize":[4,3],"duration":-1`),
      video(`,"pixelSize":[0,3],"duration":1`),
      video(`,"pixelSize":[4,3],"duration":1,"videoRotation":45`),
      video(`,"pixelSize":[4,3],"duration":1,"videoRotation":90.5`),
      video(`,"pixelSize":[4,3],"duration":1,"poster":"x"`),
      video(`,"pixelSize":[4,3],"duration":1,"codec":7`),
    ]) {
      expect(() => decode(bad), bad).toThrow(DecodeError);
    }
    // A video field on an image is an unknown field there.
    expect(() => decode(`{"id":"${itemId}","kind":"image","frame":[0,0,1,1],"z":"a","blob":${poster},"pixelSize":[1,1],"duration":"x"}`)).not.toThrow();
  });

  it("checks setItem: poster is a register, the clip's fields are immutable", () => {
    expect(() => checkItemChange("poster", null, "$.ops[0].value")).not.toThrow();
    expect(() => checkItemChange("poster", JSON.parse(poster), "$.ops[0].value")).not.toThrow();
    expect(() => checkItemChange("poster", "x", "$.ops[0].value")).toThrow(DecodeError);
    for (const f of ["duration", "videoRotation", "codec", "blob", "pixelSize"]) {
      expect(() => checkItemChange(f, 1, "$.ops[0].value"), f).toThrow(DecodeError);
    }
  });

  it("keeps the poster as a register that null resets", () => {
    const v = decode(video(`,"pixelSize":[4,3],"duration":1,"poster":${poster}`));
    expect(itemRegisters(v).get("poster")).toEqual(JSON.parse(poster));
    applyItemRegister(v, "poster", null);
    expect(v.poster).toBeUndefined();
    expect(itemRegisters(v).get("poster")).toBeNull();
    applyItemRegister(v, "poster", JSON.parse(poster));
    expect(v.poster).toEqual(JSON.parse(poster));
  });
});

describe("drawing a video", () => {
  it("draws the play mark as the format states", () => {
    const [disc, triangle] = playMarkCommands({ x: 0, y: 0, w: 400, h: 200 }, 0);
    expect(disc?.primitive).toEqual({ kind: "circle", center: { x: 200, y: 100 }, radius: 24 });
    expect(disc?.fill?.alpha).toBeCloseTo(128 / 255, 9);
    expect(triangle?.primitive.kind).toBe("path");
    const small = playMarkCommands({ x: 0, y: 0, w: 100, h: 50 }, 90);
    expect(small[0]?.primitive).toEqual({ kind: "circle", center: { x: 50, y: 25 }, radius: 7.5 });
    expect(playMarkCommands({ x: 0, y: 0, w: 0, h: 0 }, 0)).toEqual([]);
  });

  it("maps the whole poster onto the frame, axes scaled independently", () => {
    const it = prepareItem(decode(video(`,"pixelSize":[4,3],"duration":1`)));
    if (typeof it === "string") throw new Error(it);
    const m = posterTransform(it, 160, 90);
    if (typeof m === "string") throw new Error(m);
    expect([m.a, m.b, m.c, m.d, m.tx, m.ty]).toEqual([2, 0, 0, 2, 72, 144]);
    expect(posterTransform(it, 0, 90)).toBe("degenerate placement");
  });

  it("resolves a video to its clip and poster", () => {
    const state = emptyState(0, [{ id: "p", order: "a", strokes: [], items: [decode(video(`,"pixelSize":[4,3],"duration":2.5,"poster":${poster}`))] }]);
    const entries = videoEntries(state);
    expect(entries).toEqual([{ item: itemId, page: 1, clip: JSON.parse(clip) as unknown, duration: 2.5 }]);
    const it = prepareItem(state.pages[0]?.items[0] as JSONObject);
    if (typeof it === "string") throw new Error(it);
    const [r] = resolveItems({ items: [it], options: { paper: true }, drawnPaper: state.meta.paper } as never);
    expect(r?.draw.kind).toBe("video");
    if (r?.draw.kind === "video") expect(r.draw.poster?.sha256).toBe(hashB);
  });

  it("hit-tests taps on rotated frames", () => {
    const c = corners({ x: 0, y: 0, w: 100, h: 50 }, 45);
    expect(insidePolygon({ x: 50, y: 25 }, c)).toBe(true);
    expect(insidePolygon({ x: 2, y: 2 }, c)).toBe(false);
    expect(insidePolygon({ x: 50, y: 25 }, [...c].reverse())).toBe(true);
  });
});
