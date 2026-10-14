// Ports of the validation cases in Tests/SempereTests/AttachmentModelTests.swift
// and the JSONValue limits of UntrustedInputTests.swift (format.md §7, §8, §9).

import { describe, it, expect } from "vitest";
import {
  Budget, checkItemChange, checkRecordingChange, decodeItem, decodeRecording, maxUnknownDepth, maxUnknownValues,
  pathDepth,
} from "../src/format/attachments.ts";
import { DecodeError } from "../src/format/json.ts";

const itemId = "6f1c2d4e-0000-4000-8000-000000000001";
const parentId = "6f1c2d4e-0000-4000-8000-000000000002";
const recId = "6f1c2d4e-0000-4000-8000-000000000003";
const hashA = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
const hashB = "b023506dad39637be6e6e2ec3a0c31f8c0af3fe9bc060be0223b789cb75e5c00";
const itemPath = "$.ops[0].item";
const valuePath = "$.ops[0].value";

function item(s: string, budget = new Budget(), path = itemPath): unknown {
  return decodeItem(JSON.parse(s), path, budget);
}

function recording(s: string, budget = new Budget()): unknown {
  return decodeRecording(JSON.parse(s), "$.ops[0].recording", budget);
}

function expectFails(f: () => unknown, label = ""): void {
  expect(f, label).toThrow(DecodeError);
}

/** An unknown-kind item with `extra` spliced in. */
function unknownItem(extra: string): string {
  return `{"id":"${itemId}","kind":"x","frame":[0,0,1,1],"z":"a"${extra}}`;
}

function nested(levels: number): string {
  return "[".repeat(levels) + "]".repeat(levels);
}

describe("format.md §8 examples", () => {
  it("decodes common fields with an image", () => {
    expect(() => item(`{
      "id": "${itemId}", "kind": "image", "layer": 100, "frame": [72, 144, 288, 216], "rotation": 0, "z": "a0",
      "parent": "${parentId}", "rec": { "id": "${recId}", "at": 12.5 },
      "origin": "17596320000000003-a1b2c3d4-12-4", "clocks": { "frame": "17596320000000003-a1b2c3d4" },
      "blob": { "sha256": "${hashA}", "size": 482113, "type": "image/jpeg" }, "pixelSize": [3024, 4032] }`)).not.toThrow();
  });

  it("decodes a text item", () => {
    expect(() => item(`{ "id": "${itemId}", "kind": "text", "layer": 100, "frame": [72, 90, 300, 40], "z": "a1",
      "text": { "font": "sans", "family": "SF Pro", "size": 12, "color": "#1A1A1AFF", "align": "start", "dir": "auto",
        "lang": "en", "runs": [ { "t": "Lecture 3", "b": true, "size": 18 }, { "t": "\\nlinear maps" } ],
        "breaks": [] } }`)).not.toThrow();
  });

  it("decodes an image with orientation and crop", () => {
    expect(() => item(`{ "id": "${itemId}", "kind": "image", "layer": 100, "frame": [72, 144, 216, 288], "z": "a0",
      "blob": { "sha256": "${hashA}", "size": 482113, "type": "image/jpeg" },
      "pixelSize": [3024, 4032], "orientation": 6, "crop": [0, 0, 3024, 4032] }`)).not.toThrow();
  });

  it("decodes a PDF page", () => {
    expect(() => item(`{ "id": "${itemId}", "kind": "pdfPage", "layer": 0, "frame": [0, 0, 612, 792], "z": "a0",
      "blob": { "sha256": "${hashA}", "size": 1830221, "type": "application/pdf" },
      "pageIndex": 3, "pageSize": [612, 792], "crop": [36, 36, 540, 720] }`)).not.toThrow();
  });

  it("decodes a recording", () => {
    expect(() => recording(`{ "id": "${recId}",
      "blob": { "sha256": "${hashA}", "size": 28311552, "type": "audio/mp4" },
      "started": "2026-10-04T16:20:00.000Z", "duration": 3540.25,
      "codec": "aac", "sampleRate": 48000, "channels": 1, "bitRate": 64000, "title": "Lecture 3",
      "transcript": { "sha256": "${hashB}", "size": 52011, "type": "application/vnd.sempere.transcript+json" } }`))
      .not.toThrow();
  });
});

describe("math items (§8.2.8)", () => {
  const base = `"id": "${itemId}", "kind": "math", "frame": [1, 2, 3, 4], "z": "a"`;
  const math = (m: string) => `{ ${base}, "math": { ${m} } }`;
  const ok = `"latex": "x^2", "display": true, "size": 12, "color": "#000000FF"`;
  const render = `"render": { "sha256": "${hashA}", "size": 5, "type": "application/pdf" }`;

  it("accepts the shape of the spec, with unknown fields", () => {
    expect(() => item(math(ok))).not.toThrow();
    expect(() => item(math(`${ok}, ${render}, "renderSize": [40, 20], "engine": "swiftmath-1.7.3", "future": [1]`))).not.toThrow();
    expect(() => item(math(`"latex": "", "display": false, "size": 1000, "color": "#000000"`))).not.toThrow();
    expect(() => item(math(`"latex": "${"x".repeat(8192)}", "display": true, "size": 12, "color": "#000000FF"`))).not.toThrow();
  });

  it("rejects what Swift rejects", () => {
    for (const bad of [
      `{ ${base} }`,
      math(`"latex": "x", "display": true, "size": 0, "color": "#000000FF"`),
      math(`"latex": "x", "display": "yes", "size": 12, "color": "#000000FF"`),
      math(`"latex": "x", "size": 12, "color": "#000000FF"`),
      math(`${ok}, ${render}`),
      math(`${ok}, "renderSize": [1, 1]`),
      math(`${ok}, "render": { "sha256": "${hashA}", "size": 5, "type": "image/png" }, "renderSize": [1, 1]`),
      math(`${ok}, ${render}, "renderSize": [0, 1]`),
      math(`"latex": "a\\u0001b", "display": true, "size": 12, "color": "#000000FF"`),
      math(`"latex": "${"x".repeat(8193)}", "display": true, "size": 12, "color": "#000000FF"`),
    ]) expect(() => item(bad), bad.slice(0, 120)).toThrow();
  });
});

describe("open format (§7)", () => {
  it("keeps unknown kinds, fields and layers", () => {
    expect(() => item(`{ "id": "${itemId}", "kind": "shape", "layer": 250, "frame": [10.5, 20, 30, 40], "z": "b",
      "latex": "e^{i\\\\pi} + 1 = 0", "display": true, "size": 14.25, "color": "#112233FF",
      "text": "not a text object", "crop": "whatever", "pixelSize": [1, 2, 3],
      "render": { "sha256": "${hashA}", "size": 1000, "type": "application/pdf", "pages": 1 },
      "nested": { "a": [1, 2.5, -3e-7, 1e+300, null, false, { "deep": [[[]]] }], "": "" },
      "big": 12345678901234 }`)).not.toThrow();
    // Fields of another kind on a defined kind are unknown there too.
    expect(() => item(`{ "id": "${itemId}", "kind": "image", "layer": 100, "frame": [0, 0, 1, 1], "z": "a",
      "blob": { "sha256": "${hashA}", "size": 1, "type": "image/webp", "exif": { "kept": true } },
      "pixelSize": [1, 1], "pageIndex": "seven", "text": 5, "alt": "a cat" }`)).not.toThrow();
  });

  it("keeps unknown fields on text runs, text and recordings", () => {
    expect(() => item(`{ "id": "${itemId}", "kind": "text", "layer": 100, "frame": [0, 0, 100, 20], "z": "a",
      "text": { "font": "handwriting", "size": 12, "color": "#000000FF", "align": "justify", "dir": "ttb",
        "runs": [ { "t": "x", "link": "https://example.org", "i": true, "u": true, "s": true,
                    "color": "#FF0000FF", "lang": "es" } ], "lineHeight": 1.5 } }`)).not.toThrow();
    expect(() => recording(`{ "id": "${recId}", "blob": { "sha256": "${hashA}", "size": 9, "type": "audio/x-notability" },
      "started": "2026-10-04T16:20:00.000Z", "speakers": ["A", "B"], "markers": [{ "at": 1, "label": "q" }] }`))
      .not.toThrow();
  });

  it("reads any layer value without failing", () => {
    for (const layer of ["0", "65535", "7.0", "65536", "-1", "1.5", "\"0\"", "null", "true", "1e300", "[0]", "{}"]) {
      expect(() => item(unknownItem(`,"layer":${layer}`)), layer).not.toThrow();
    }
    expect(() => item(unknownItem(""))).not.toThrow();
  });

  it("accepts null for optional fields", () => {
    expect(() => item(unknownItem(`,"rotation":null,"parent":null,"rec":null,"origin":null,"clocks":null`))).not.toThrow();
  });
});

describe("invalid items", () => {
  const blob = `{"sha256":"${hashA}","size":1,"type":"image/png"}`;
  const base = `"id":"${itemId}","layer":100,"z":"a"`;
  const cases = [
    `{${base},"kind":"text","frame":[0,0,1,1]}`,
    `{${base},"kind":"text","frame":[0,0,1,1],"text":null}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"blob":${blob}}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"pixelSize":[1,1]}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"blob":${blob},"pixelSize":[0,1]}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"blob":${blob},"pixelSize":[1,0.0004]}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"blob":${blob},"pixelSize":[1,1,1]}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"blob":${blob},"pixelSize":[1,1],"orientation":9}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"blob":${blob},"pixelSize":[1,1],"orientation":0}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"blob":${blob},"pixelSize":[1,1],"orientation":1.5}`,
    `{${base},"kind":"image","frame":[0,0,1,1],"blob":${blob},"pixelSize":[1,1],"crop":[0,0,0,1]}`,
    `{${base},"kind":"pdfPage","frame":[0,0,1,1],"blob":${blob},"pageSize":[1,1]}`,
    `{${base},"kind":"pdfPage","frame":[0,0,1,1],"blob":${blob},"pageIndex":-1,"pageSize":[1,1]}`,
    `{${base},"kind":"pdfPage","frame":[0,0,1,1],"blob":${blob},"pageIndex":0}`,
    `{${base},"kind":"x","frame":[0,0,1,0]}`,
    `{${base},"kind":"x","frame":[0,0,1,0.0004]}`,
    `{${base},"kind":"x","frame":[0,0,1,1,1]}`,
    `{${base},"kind":"x","frame":[0,0,1]}`,
    `{${base},"kind":"x","frame":[0,0,1,null]}`,
    `{${base},"kind":"x","frame":null}`,
    `{${base},"kind":"x","frame":[0,0,1,1],"rotation":"90"}`,
    `{${base},"kind":"x","frame":[0,0,1,1],"parent":"nope"}`,
    `{${base},"kind":"x","frame":[0,0,1,1],"rec":{"id":"${recId}"}}`,
    `{${base},"kind":"x","frame":[0,0,1,1],"clocks":{"frame":1}}`,
    `{${base},"kind":null,"frame":[0,0,1,1]}`,
    `{"id":"${itemId}","kind":"x","frame":[0,0,1,1]}`,
    `{"id":"${itemId}","z":"a","frame":[0,0,1,1]}`,
    `{"kind":"x","z":"a","frame":[0,0,1,1]}`,
    `[]`,
  ];
  for (const bad of cases) {
    it(`rejects ${bad.replace(hashA, "…")}`, () => expectFails(() => item(bad)));
  }

  it("rejects bad blob references", () => {
    for (const ref of [
      `{"sha256":"${hashA.toUpperCase()}","size":1,"type":"t"}`,
      `{"sha256":"${hashA.slice(0, -1)}","size":1,"type":"t"}`,
      `{"sha256":"${hashA.slice(0, -1)}g","size":1,"type":"t"}`,
      `{"sha256":"${hashA}","size":-1,"type":"t"}`,
      `{"sha256":"${hashA}","size":1073741825,"type":"t"}`,
      `{"sha256":"${hashA}","size":1.5,"type":"t"}`,
      `{"sha256":"${hashA}","size":1}`,
    ]) {
      expectFails(() => item(`{"id":"${itemId}","kind":"image","frame":[0,0,1,1],"z":"a","blob":${ref},"pixelSize":[1,1]}`), ref);
    }
    expect(() => item(`{"id":"${itemId}","kind":"image","frame":[0,0,1,1],"z":"a",
      "blob":{"sha256":"${hashA}","size":1073741824,"type":"video/mp4"},"pixelSize":[1,1]}`)).not.toThrow();
  });
});

describe("text content (§8.2.4, §8.4)", () => {
  function textItem(content: string): string {
    return `{"id":"${itemId}","kind":"text","frame":[0,0,1,1],"z":"a","text":${content}}`;
  }
  function content(runs: string, size = "12", breaks?: string): string {
    return `{"font":"sans","size":${size},"color":"#000000FF","runs":${runs}${breaks === undefined ? "" : `,"breaks":${breaks}`}}`;
  }

  it("accepts content at the limits", () => {
    expect(() => item(textItem(content("[]", "1000")))).not.toThrow();
    expect(() => item(textItem(content("[]", "12", "null")))).not.toThrow();
    expect(() => item(textItem(content(`[{"t":"${"a".repeat(65_536)}"}]`)))).not.toThrow();
    const runs = "[" + Array<string>(1000).fill(`{"t":"a"}`).join(",") + "]";
    const breaks = "[" + Array.from({ length: 10_000 }, (_, i) => i + 1).join(",") + "]";
    expect(() => item(textItem(content(runs, "12", breaks)))).not.toThrow();
    expect(() => item(textItem(`{"font":"sans","size":12,"color":"112233","runs":[]}`))).not.toThrow();
    expect(() => item(textItem(`{"font":"sans","size":12,"color":"#+12233","runs":[]}`))).not.toThrow();
    expect(() => item(textItem(content(`[{"t":"a\\tb\\nc"}]`)))).not.toThrow();
  });

  const manyRuns = "[" + Array<string>(1001).fill(`{"t":"a"}`).join(",") + "]";
  const longRun = `[{"t":"${"é".repeat(32_769)}"}]`;
  const splitLong = `[{"t":"${"a".repeat(40_000)}"},{"t":"${"a".repeat(30_000)}"}]`;
  const manyBreaks = "[" + Array.from({ length: 10_001 }, (_, i) => i + 1).join(",") + "]";
  const bad: [string, string][] = [
    ["too many runs", content(manyRuns)],
    ["too long", content(longRun)],
    ["too long across runs", content(splitLong)],
    ["too many breaks", content("[]", "12", manyBreaks)],
    ["fractional break", content("[]", "12", "[1.5]")],
    ["size 0", content("[]", "0")],
    ["size rounds to 0", content("[]", "0.0004")],
    ["size above 1000", content("[]", "1000.001")],
    ["negative size", content("[]", "-1")],
    ["run size 0", content(`[{"t":"a","size":0}]`)],
    ["run without t", content(`[{"b":true}]`)],
    ["run bold not bool", content(`[{"t":"a","b":1}]`)],
    ["run bad colour", content(`[{"t":"a","color":"red"}]`)],
    ["NUL", content(`[{"t":"a\\u0000b"}]`)],
    ["ESC", content(`[{"t":"a\\u001b"}]`)],
    ["CR", content(`[{"t":"a\\r\\nb"}]`)],
    ["no runs", `{"font":"sans","size":12,"color":"#000000FF"}`],
    ["null runs", `{"font":"sans","size":12,"color":"#000000FF","runs":null}`],
    ["no font", `{"size":12,"color":"#000000FF","runs":[]}`],
    ["bad colour", `{"font":"sans","size":12,"color":"#12345","runs":[]}`],
    ["negative colour", `{"font":"sans","size":12,"color":"-1234567","runs":[]}`],
    ["no colour", `{"font":"sans","size":12,"runs":[]}`],
  ];
  for (const [label, c] of bad) {
    it(`rejects ${label}`, () => expectFails(() => item(textItem(c))));
  }
});

describe("setItem (§8.2.2)", () => {
  it("refuses immutable and snapshot-only fields", () => {
    for (const field of ["id", "kind", "layer", "parent", "rec", "blob", "pixelSize", "orientation", "pageIndex",
      "pageSize", "origin", "clocks"]) {
      expectFails(() => checkItemChange(field, null, valuePath), field);
    }
  });

  it("refuses null for required registers", () => {
    for (const field of ["frame", "z", "text"]) expectFails(() => checkItemChange(field, null, valuePath), field);
  });

  it("refuses wrong types and ranges", () => {
    const cases: [string, string][] = [
      ["frame", "[0,0,0,10]"], ["frame", "[0,0,10]"], ["frame", "[0,0,1,1,1]"], ["frame", "\"x\""],
      ["frame", "[0,0,0.0004,1]"], ["rotation", "\"90\""], ["z", "1"], ["crop", "[0,0,-1,1]"], ["crop", "{}"],
      ["text", "\"plain\""], ["text", `{"font":"sans","size":0,"color":"#000000FF","runs":[]}`],
    ];
    for (const [field, value] of cases) {
      expectFails(() => checkItemChange(field, JSON.parse(value), valuePath), `${field} ${value}`);
    }
  });

  it("accepts valid registers and any unknown field", () => {
    const cases: [string, unknown][] = [
      ["frame", [0, 0, 1, 1]], ["rotation", 90], ["rotation", null], ["z", "b"], ["crop", null], ["crop", [1, 1, 2, 2]],
      ["text", { font: "sans", size: 12, color: "#000000FF", runs: [{ t: "x", link: { a: [1] } }], extra: true }],
      ["alt", "a cat"], ["alt", null], ["whatever", { a: [1, 2, { b: null }] }],
    ];
    for (const [field, value] of cases) {
      expect(() => checkItemChange(field, value, valuePath), field).not.toThrow();
    }
  });

  it("bounds the value like any unknown field", () => {
    // The value sits at depth 3 ($.ops[0].value): 21 more levels fit.
    expect(() => checkItemChange("x", JSON.parse(nested(maxUnknownDepth - 3 + 1)), valuePath)).not.toThrow();
    expectFails(() => checkItemChange("x", JSON.parse(nested(maxUnknownDepth - 3 + 2)), valuePath));
    const budget = new Budget();
    budget.remaining = 2;
    expectFails(() => checkItemChange("x", [1, 2], valuePath, budget));
    expect(budget.remaining).toBe(0);
  });
});

describe("setRecording (§8.3.1)", () => {
  it("refuses immutable fields", () => {
    for (const field of ["id", "blob", "started", "duration", "codec", "sampleRate", "channels", "bitRate", "parent",
      "origin", "clocks"]) {
      expectFails(() => checkRecordingChange(field, null, valuePath), field);
    }
  });

  it("refuses wrong types", () => {
    for (const [field, value] of [["title", "5"], ["transcript", "\"x\""],
      ["transcript", `{"sha256":"AB","size":1,"type":"t"}`]] as const) {
      expectFails(() => checkRecordingChange(field, JSON.parse(value), valuePath), `${field} ${value}`);
    }
  });

  it("accepts registers, null and unknown fields", () => {
    const cases: [string, unknown][] = [
      ["title", "Lecture"], ["title", null], ["transcript", null],
      ["transcript", { sha256: hashB, size: 1, type: "application/vnd.sempere.transcript+json", x: [1] }],
      ["speakers", ["A"]],
    ];
    for (const [field, value] of cases) {
      expect(() => checkRecordingChange(field, value, valuePath), field).not.toThrow();
    }
  });
});

describe("invalid recordings", () => {
  const blob = `"blob":{"sha256":"${hashA}","size":9,"type":"audio/mp4"}`;
  const started = `"started":"2026-10-04T16:20:00.000Z"`;
  const cases = [
    `{${blob},${started}}`,
    `{"id":"${recId}",${started}}`,
    `{"id":"${recId}",${blob}}`,
    `{"id":"${recId}",${blob},"started":"yesterday"}`,
    `{"id":"${recId}",${blob},"started":null}`,
    `{"id":"${recId}","blob":{"sha256":"${hashA}","size":-1,"type":"audio/mp4"},${started}}`,
    `{"id":"${recId}",${blob},${started},"duration":"1"}`,
    `{"id":"${recId}",${blob},${started},"sampleRate":4.5}`,
    `{"id":"${recId}",${blob},${started},"title":5}`,
    `{"id":"${recId}",${blob},${started},"transcript":"x"}`,
    `{"id":"${recId}",${blob},${started},"parent":"nope"}`,
    `{"id":"${recId}",${blob},${started},"clocks":{"title":null}}`,
  ];
  for (const bad of cases) {
    it(`rejects ${bad.replace(hashA, "…")}`, () => expectFails(() => recording(bad)));
  }

  it("accepts null optional fields", () => {
    expect(() => recording(`{"id":"${recId}",${blob},${started},"duration":null,"title":null,"transcript":null}`))
      .not.toThrow();
  });
});

describe("unknown-field limits (JSONValue, §9)", () => {
  it("counts path depth like Swift's coding path", () => {
    expect(pathDepth("$")).toBe(0);
    expect(pathDepth("$.ops[3].item")).toBe(3);
    expect(pathDepth("$.state.pages[0].items[2]")).toBe(5);
  });

  it("refuses an unknown field nested deeper than the limit", () => {
    // The item sits at depth 3, its field at 4: 21 levels of arrays reach 24.
    expect(() => item(unknownItem(`,"x":${nested(maxUnknownDepth - 3)}`))).not.toThrow();
    expectFails(() => item(unknownItem(`,"x":${nested(maxUnknownDepth - 2)}`)));
    // Deeper in the document, less room.
    const deepPath = "$.state.pages[0].items[2]";
    expect(() => item(unknownItem(`,"x":${nested(maxUnknownDepth - 5)}`), new Budget(), deepPath)).not.toThrow();
    expectFails(() => item(unknownItem(`,"x":${nested(maxUnknownDepth - 4)}`), new Budget(), deepPath));
    // Hundreds of levels fail without overflowing the stack.
    const hostile = `{"a":`.repeat(500) + "1" + "}".repeat(500);
    expectFails(() => item(unknownItem(`,"x":${hostile}`)));
  });

  it("bounds unknown fields on runs, blobs, recordings and the layer", () => {
    const textAt = (depth: number) => `{"id":"${itemId}","kind":"text","frame":[0,0,1,1],"z":"a",
      "text":{"font":"sans","size":12,"color":"#000000FF","runs":[{"t":"a","x":${nested(depth)}}]}}`;
    // A run's field: item 3, text 4, runs 5, run 6, field 7.
    expect(() => item(textAt(maxUnknownDepth - 6))).not.toThrow();
    expectFails(() => item(textAt(maxUnknownDepth - 5)));
    const blobAt = (depth: number) => `{"id":"${itemId}","kind":"image","frame":[0,0,1,1],"z":"a","pixelSize":[1,1],
      "blob":{"sha256":"${hashA}","size":1,"type":"image/png","x":${nested(depth)}}}`;
    expect(() => item(blobAt(maxUnknownDepth - 4))).not.toThrow();
    expectFails(() => item(blobAt(maxUnknownDepth - 3)));
    expectFails(() => item(unknownItem(`,"layer":${nested(maxUnknownDepth - 2)}`)));
    const rec = (depth: number) => `{"id":"${recId}","blob":{"sha256":"${hashA}","size":9,"type":"audio/mp4"},
      "started":"2026-10-04T16:20:00.000Z","x":${nested(depth)}}`;
    expect(() => recording(rec(maxUnknownDepth - 3))).not.toThrow();
    expectFails(() => recording(rec(maxUnknownDepth - 2)));
  });

  it("stops at the per-file value budget", () => {
    const fits = "[" + Array<string>(maxUnknownValues - 1).fill("1").join(",") + "]";
    const budget = new Budget();
    expect(() => item(unknownItem(`,"x":${fits}`), budget)).not.toThrow();
    expect(budget.remaining).toBe(0);
    // The same file has nothing left; a fresh budget does.
    expectFails(() => item(unknownItem(`,"y":1`), budget));
    expect(() => item(unknownItem(`,"x":${fits}`))).not.toThrow();
    const leaves = Array<string>(maxUnknownValues + 10).fill("\"\"").join(",");
    const huge = "[".repeat(maxUnknownDepth - 6) + leaves + "]".repeat(maxUnknownDepth - 6);
    expectFails(() => item(unknownItem(`,"x":${huge}`)));
  });

  it("counts layers and known fields correctly", () => {
    const budget = new Budget();
    item(unknownItem(`,"layer":[0,[1]],"x":{"a":null}`), budget);
    // layer: 4 values; x: 2 values. Known typed fields cost nothing.
    expect(budget.remaining).toBe(maxUnknownValues - 6);
    const b2 = new Budget();
    recording(`{"id":"${recId}","blob":{"sha256":"${hashA}","size":9,"type":"audio/mp4","k":1},
      "started":"2026-10-04T16:20:00.000Z","x":[true]}`, b2);
    expect(b2.remaining).toBe(maxUnknownValues - 3);
  });

  it("refuses a non-finite number in an unknown field", () => {
    expectFails(() => decodeItem({ id: itemId, kind: "x", frame: [0, 0, 1, 1], z: "a", x: [Infinity] }, itemPath,
      new Budget()));
  });
});
