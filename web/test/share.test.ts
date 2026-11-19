// A share file (docs/design/1.3-share.md, docs/web-viewer.md "Share files"): the payload made by the Swift writer
// (Tests/SempereRenderTests/Fixtures/share/, `SEMPERE_WRITE_SHARE_FIXTURE=1 swift test --filter WebPageShareTests/testFixture`)
// opens with the page's own code, hostile bytes fail with typed errors, and the committed template has the CSP the
// design pins.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { armor } from "age-encryption";
import { afterEach, describe, expect, it } from "vitest";
import { Budget } from "../src/format/attachments.ts";
import { decodeState } from "../src/format/model.ts";
import { ShareBlobs } from "../src/share/blobs.ts";
import { maxBlobs, parsePayload, ShareFormatError } from "../src/share/container.ts";
import { shareContentSecurityPolicy } from "../src/share/csp.ts";
import { ageBytes, decryptShare, maxWorkFactor, ShareOpenError, shareWorkFactor } from "../src/share/open.ts";
import { openShare } from "../src/share/worker.ts";
import { recordingSub } from "../src/ui/recordings.ts";
import { asBlobRef } from "../src/vault/blobs.ts";
import { SplitMix64 } from "./builders.ts";

const root = join(import.meta.dirname, "..", "..");
const dir = join(root, "Tests", "SempereRenderTests", "Fixtures", "share");
const armored = readFileSync(join(dir, "payload.age"), "utf8");
const passphrase = readFileSync(join(dir, "passphrase.txt"), "utf8").trim();
const expected = JSON.parse(readFileSync(join(dir, "payload.json"), "utf8")) as { shareId: string; note: { meta: { title: string }; pages: { items: { id: string; kind: string; blob?: { sha256: string; size: number; type: string } }[] }[] } };
const container = new Uint8Array(readFileSync(join(dir, "payload.bin")));

const code = async (p: Promise<unknown>): Promise<string> => {
  try {
    await p;
  } catch (e) {
    if (e instanceof ShareOpenError || e instanceof ShareFormatError) return `${e.name}:${e instanceof ShareOpenError ? e.code : e.message}`;
    throw e;
  }
  return "ok";
};

afterEach(() => {
  Reflect.deleteProperty(globalThis, "Worker");
});

describe("a share made by the Swift writer", () => {
  it("opens with its passphrase, as a note the viewer's own decoder takes, with every picture hashed", async () => {
    const plain = await decryptShare(armored, passphrase);
    expect(Array.from(plain)).toEqual(Array.from(container));
    const payload = await parsePayload(plain);
    expect(payload.shareId).toBe(expected.shareId);
    expect(payload.note).toEqual(expected.note);
    const state = decodeState(payload.note, "$.note", new Budget());
    expect(state.meta.title).toBe("Shared fixture");
    expect(state.pages[0]?.items.map((i) => i.kind)).toEqual(["text", "image"]);
    // The picture is there under its own hash, and the note view's reader hands it out.
    const ref = asBlobRef(state.pages[0]?.items[1]?.blob);
    if (!ref) throw new Error("the picture has no reference");
    expect(ref.type).toBe("image/jpeg");
    expect(payload.blobs.size).toBe(1);
    const blob = await new ShareBlobs(payload.blobs).get(ref);
    expect(blob.size).toBe(ref.size);
    expect(createHash("sha256").update(new Uint8Array(await blob.arrayBuffer())).digest("hex")).toBe(ref.sha256);
  });

  it("does not open with another passphrase, or with a flipped bit, or cut short", async () => {
    expect(await code(decryptShare(armored, "not the passphrase"))).toBe("ShareOpenError:wrongPassphrase");
    const lines = armored.split("\n");
    const i = Math.floor(lines.length / 2);
    const line = lines[i] ?? "";
    lines[i] = (line[0] === "A" ? "B" : "A") + line.slice(1);
    expect(await code(decryptShare(lines.join("\n"), passphrase))).toBe("ShareOpenError:wrongPassphrase");
    const cut = lines.slice(0, 3).join("\n") + "\n-----END AGE ENCRYPTED FILE-----\n";
    expect(await code(decryptShare(armored.split("\n").slice(0, 3).join("\n") + "\n-----END AGE ENCRYPTED FILE-----\n", passphrase)))
      .toMatch(/^ShareOpenError:(notShare|wrongPassphrase)$/);
    expect(cut.length).toBeGreaterThan(0);
  });

  it("is opened in place when the browser cannot start the worker (a file: page)", async () => {
    class Refusing {
      constructor() {
        throw new Error("workers are not allowed here");
      }
    }
    (globalThis as { Worker?: unknown }).Worker = Refusing;
    const plain = await openShare(armored, passphrase, "/* the page's script */");
    expect(Array.from(plain)).toEqual(Array.from(container));
    // Without the script to copy there is no worker at all.
    expect(Array.from(await openShare(armored, passphrase, undefined))).toEqual(Array.from(container));
  });
});

describe("a share written without dates", () => {
  it("shows no start time on a recording (the epoch is not a date), and one when dates are included", () => {
    expect(recordingSub(0, "1:05", false)).toBe("1:05");
    expect(recordingSub(0, "", false)).toBe("");
    const withDates = recordingSub(Date.UTC(2026, 10, 18, 12), "1:05", true);
    expect(withDates).toMatch(/2026/);
    expect(withDates.endsWith(" · 1:05")).toBe(true);
  });
});

describe("the work factor", () => {
  const header = (stanzas: string[]) => new TextEncoder().encode(`age-encryption.org/v1\n${stanzas.join("\n")}\n--- ${"A".repeat(43)}\n`);
  const scrypt = (n: number) => `-> scrypt ${"A".repeat(22)} ${n}\n${"B".repeat(43)}`;

  it("is read from the header: 18 for a fixture at 10, at most 20 accepted, 21 refused before any work", () => {
    expect(shareWorkFactor(ageBytes(armored))).toBe(10);
    expect(maxWorkFactor).toBe(20);
    expect(shareWorkFactor(header([scrypt(18)]))).toBe(18);
    expect(shareWorkFactor(header([scrypt(20)]))).toBe(20);
    expect(() => shareWorkFactor(header([scrypt(21)]))).toThrow(expect.objectContaining({ code: "workFactor" }));
    expect(() => shareWorkFactor(header([scrypt(99)]))).toThrow(expect.objectContaining({ code: "workFactor" }));
  });

  it("must be one passphrase recipient and nothing else", () => {
    expect(() => shareWorkFactor(header([scrypt(18), scrypt(18)]))).toThrow(expect.objectContaining({ code: "notShare" }));
    expect(() => shareWorkFactor(header([`-> X25519 ${"A".repeat(43)}\n${"B".repeat(43)}`]))).toThrow(expect.objectContaining({ code: "notShare" }));
    expect(() => shareWorkFactor(header([scrypt(0)]))).toThrow(expect.objectContaining({ code: "notShare" }));
    expect(() => shareWorkFactor(new TextEncoder().encode("not an age file"))).toThrow(expect.objectContaining({ code: "notShare" }));
  });

  it("is checked by the opener too: a file at 21 never reaches scrypt", async () => {
    const fake = armor.encode(header([scrypt(21)]));
    expect(await code(decryptShare(fake, "x"))).toBe("ShareOpenError:workFactor");
  });
});

describe("the container is untrusted", () => {
  it("fails with typed errors on every truncation and on mutations, never anything else", async () => {
    for (let n = 0; n < Math.min(container.length, 400); n++) {
      const c = await code(parsePayload(container.subarray(0, n)));
      expect(c === "ok" || c.startsWith("ShareFormatError:"), `${n}: ${c}`).toBe(true);
    }
    // The gzip member and the blob table are the interesting parts: cut and mutate there too.
    const tail = container.length - 100;
    for (let n = tail; n < container.length; n++) {
      const c = await code(parsePayload(container.subarray(0, n)));
      expect(c === "ok" || c.startsWith("ShareFormatError:"), `${n}: ${c}`).toBe(true);
    }
    const rng = new SplitMix64(0x5ee0);
    for (let k = 0; k < 120; k++) {
      const m = container.slice();
      const at = rng.int(0, Math.min(m.length, 300) - 1);
      m[at] = rng.int(0, 255);
      const c = await code(parsePayload(m));
      expect(c === "ok" || c.startsWith("ShareFormatError:"), `${k}: ${c}`).toBe(true);
    }
  });

  it("refuses an attachment whose name is not its hash, a repeated name, a claimed length past the end, and a newer version", async () => {
    const wrong = container.slice();
    wrong[wrong.length - 1] = (wrong[wrong.length - 1] ?? 0) ^ 1;
    expect(await code(parsePayload(wrong))).toMatch(/^ShareFormatError:/);
    // The blob table starts right after the gzip member.
    const view = new DataView(container.buffer, container.byteOffset, container.byteLength);
    const table = 9 + view.getUint32(5);
    const huge = container.slice();
    new DataView(huge.buffer).setBigUint64(table + 4 + 64, 0xffffffffffffffffn);
    expect(await code(parsePayload(huge))).toMatch(/^ShareFormatError:/);
    const twice = new Uint8Array(container.length + (container.length - table));
    twice.set(container);
    twice.set(container.subarray(table), container.length);
    expect(await code(parsePayload(twice))).toMatch(/^ShareFormatError:/);
    const newer = container.slice();
    newer[4] = 2;
    expect(await code(parsePayload(newer))).toBe("ShareFormatError:this share was made by a newer version of Sempere");
    expect(maxBlobs).toBeGreaterThan(200);
  });
});

describe("the committed template", () => {
  const swift = readFileSync(join(root, "Sources", "SempereShareViewer", "ShareViewerTemplate.swift"), "utf8");
  const html = swift.slice(swift.indexOf('#####"""\n') + 9, swift.lastIndexOf('"""#####'));
  const element = (open: string, close: string) => {
    const a = html.indexOf(open) + open.length;
    return html.slice(a, html.indexOf(close, a));
  };
  const script = element("<script>", "</script>");
  const style = element("<style>", "</style>");
  const hash = (s: string) => createHash("sha256").update(s, "utf8").digest("base64");

  it("carries the policy of the design, pinned to its own script and style", () => {
    const meta = /<meta http-equiv="Content-Security-Policy" content="([^"]*)">/.exec(html);
    expect(meta?.[1]).toBe(shareContentSecurityPolicy(hash(script), hash(style)));
    const policy = shareContentSecurityPolicy("S", "T");
    for (const directive of ["default-src 'none'", "connect-src 'none'", "form-action 'none'", "frame-src 'none'", "object-src 'none'",
      "base-uri 'none'", "worker-src blob:", "require-trusted-types-for 'script'", "trusted-types sempere-share-worker", "img-src data: blob:",
      "media-src blob:", "script-src 'sha256-S'", "style-src 'sha256-T'"]) {
      expect(policy.split("; ")).toContain(directive);
    }
    expect(policy).not.toMatch(/unsafe|https?:|\*/);
  });

  it("is listed in docs/web-viewer.md with its hashes (update the table when the viewer changes)", () => {
    const docs = readFileSync(join(root, "docs", "web-viewer.md"), "utf8");
    const row = /\| 1\.3 \(unreleased\) \|([^\n]*)\n/.exec(docs)?.[1] ?? "";
    // A multi-line Swift string drops the line break before its closing delimiter.
    const page = html.endsWith("\n") ? html.slice(0, -1) : html;
    expect(row).toContain(`sha256-${hash(script)}`);
    expect(row).toContain(`sha256-${hash(style)}`);
    expect(row).toContain(createHash("sha256").update(page, "utf8").digest("hex"));
  });

  it("has no network reference, no form, one script, one style, a title that is not a note's, and the data block", () => {
    expect(html.match(/<script/g)?.length).toBe(2);
    expect(html.match(/<style/g)?.length).toBe(1);
    expect(html).toContain("<title>Shared note</title>");
    expect(html).toContain('<meta name="referrer" content="no-referrer">');
    expect(html).toContain('<script type="text/plain" id="share-data" data-format="sempere-share/1">@@SEMPERE-SHARE-DATA@@</script>');
    expect(html).not.toMatch(/<form|<link rel="stylesheet|<iframe|<img |<base /);
    expect(html).not.toMatch(/(src|href)="https?:/);
    expect(html).not.toContain("</script>" + "</script>");
    // pdf.js stays out: PDF pages are pictures.
    expect(script).not.toContain("getDocument");
    expect(Buffer.byteLength(html)).toBeLessThan(700 * 1024);
  });
});

describe("the page's code", () => {
  const src = (f: string) => readFileSync(join(root, "web", "src", f), "utf8");
  it("never puts the passphrase in the address or in storage, and builds no markup", () => {
    const page = src("ui/shareapp.ts") + src("share/main.ts") + src("share/worker.ts") + src("share/open.ts");
    expect(page).not.toMatch(/location\.|history\.|localStorage|sessionStorage|indexedDB|innerHTML|document\.write/);
    expect(src("ui/shareapp.ts")).toContain('type: "password"');
    expect(src("ui/shareapp.ts")).not.toContain("<form");
  });
});
