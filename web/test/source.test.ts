// Vault sources: the static index, PROPFIND listings and HTTP reads, with
// hostile names and sizes (format.md §1, §9).

import { describe, expect, it } from "vitest";
import { FileListSource, HTTPSource, SourceError, parseIndex, propfindNames } from "../src/vault/source.ts";

const enc = new TextEncoder();
const note = "11111111-1111-4111-8111-111111111111";
const rev = "17911308010000000-a1b2c3d4-1.delta.age";

describe("index", () => {
  it("keeps note ids and canonical revision names only", () => {
    const idx = parseIndex(enc.encode(JSON.stringify({
      format: "sempere-index/1",
      notes: {
        [note]: [rev, rev, "17911308010000000-a1b2c3d4-01.delta.age", "../vault.json", 7, "att"],
        "NOT-A-UUID": [rev],
        "11111111-1111-4111-8111-11111111111A": [rev],
      },
    })));
    expect([...idx.notes.keys()]).toEqual([note]);
    expect(idx.notes.get(note)).toEqual([rev]);
  });

  it("refuses other formats and garbage", () => {
    expect(() => parseIndex(enc.encode("{}"))).toThrow(SourceError);
    expect(() => parseIndex(enc.encode("[1]"))).toThrow(SourceError);
    expect(() => parseIndex(enc.encode(JSON.stringify({ format: "sempere-index/2", notes: {} })))).toThrow(/unknown format/);
    expect(() => parseIndex(Uint8Array.of(0xff))).toThrow(SourceError);
  });
});

describe("PROPFIND", () => {
  it("takes the last segment of every href, any prefix, decoded", () => {
    const xml = `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
      <D:response><D:href>/dav/Notes.sempere/notes/</D:href></D:response>
      <D:response><D:href>/dav/Notes.sempere/notes/${note}/</D:href></D:response>
      <D:response><d:href xmlns:d="DAV:">https://host/dav/notes/${note}/${rev}</d:href></D:response>
      <response><href>/a/b%20c</href></response>
      <D:response><D:href>/a/x&amp;y</D:href></D:response>
      <D:response><D:href>/a/%E0%A4%A</D:href></D:response>
    </D:multistatus>`;
    expect(propfindNames(xml)).toEqual(["notes", note, rev, "b c", "x&y"]);
  });
});

function fakeFetch(routes: Record<string, { status: number; body?: string | Uint8Array<ArrayBuffer>; headers?: Record<string, string> }>) {
  const calls: { url: string; method: string }[] = [];
  const f = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = input instanceof URL ? input.href : typeof input === "string" ? input : input.url;
    const method = init?.method ?? "GET";
    calls.push({ url, method });
    const r = routes[`${method} ${url}`] ?? { status: 404 };
    return Promise.resolve(new Response(r.status === 404 ? null : r.body, { status: r.status, headers: r.headers }));
  };
  return { f: f, calls };
}

describe("HTTP source", () => {
  it("refuses non-http URLs and credentials in the URL", () => {
    expect(() => new HTTPSource("file:///etc/")).toThrow(SourceError);
    expect(() => new HTTPSource("javascript:alert(1)")).toThrow(SourceError);
    expect(() => new HTTPSource("https://u:p@host/v/")).toThrow(/credentials/);
  });

  it("lists through sempere-index.json when the server has one", async () => {
    const index = JSON.stringify({ format: "sempere-index/1", notes: { [note]: [rev] } });
    const { f, calls } = fakeFetch({ "GET https://h/v/sempere-index.json": { status: 200, body: index } });
    const src = new HTTPSource("https://h/v", "auto", f);
    expect(await src.listNotes()).toEqual([note]);
    expect(await src.listRevisions(note)).toEqual([rev]);
    expect(calls.filter((c) => c.method === "PROPFIND")).toEqual([]);
  });

  it("falls back to WebDAV and validates what it lists", async () => {
    const dav = (names: string[]) => `<multistatus xmlns="DAV:">${names.map((n) => `<response><href>${n}</href></response>`).join("")}</multistatus>`;
    const { f } = fakeFetch({
      "PROPFIND https://h/v/notes/": { status: 207, body: dav(["/v/notes/", `/v/notes/${note}/`, "/v/notes/junk/"]) },
      [`PROPFIND https://h/v/notes/${note}/`]: { status: 207, body: dav([`/v/notes/${note}/`, `/v/notes/${note}/${rev}`, `/v/notes/${note}/att/`, `/v/notes/${note}/x.age`]) },
    });
    const src = new HTTPSource("https://h/v/", "auto", f);
    expect(await src.listNotes()).toEqual([note]);
    expect(await src.listRevisions(note)).toEqual([rev]);
  });

  it("explains a server that has neither", async () => {
    const { f } = fakeFetch({ "PROPFIND https://h/v/notes/": { status: 405 } });
    await expect(new HTTPSource("https://h/v/", "auto", f).listNotes()).rejects.toThrow(/WebDAV or a sempere-index.json/);
    await expect(new HTTPSource("https://h/v/", "index", f).listNotes()).rejects.toThrow(/sempere vault index/);
  });

  it("bounds reads by the declared and the actual size", async () => {
    const { f } = fakeFetch({
      "GET https://h/v/vault.json": { status: 200, body: "x".repeat(100), headers: { "content-length": "100" } },
      "GET https://h/v/big": { status: 200, body: new Uint8Array(100) },
    });
    const src = new HTTPSource("https://h/v/", "auto", f);
    await expect(src.read("vault.json", 10)).rejects.toThrow(/larger than/);
    await expect(src.read("big", 10)).rejects.toThrow(/larger than/);
    expect((await src.read("big", 100)).length).toBe(100);
    await expect(src.read("missing", 10)).rejects.toMatchObject({ notFound: true });
  });

  it("encodes path segments", async () => {
    const { f, calls } = fakeFetch({});
    await new HTTPSource("https://h/My Vault.sempere/", "auto", f).read("notes/a b/c#d", 10).catch(() => undefined);
    expect(calls[0]?.url).toBe("https://h/My%20Vault.sempere/notes/a%20b/c%23d");
  });
});

describe("file list source", () => {
  it("finds the vault folder and ignores everything else", async () => {
    const file = (s: string) => new File([s], "f");
    const src = FileListSource.fromPaths([
      ["Notes.sempere/vault.json", file("{}")],
      ["Notes.sempere/notes/" + note + "/" + rev, file("r")],
      ["Notes.sempere/notes/" + note + "/att/" + "a".repeat(64) + ".image.age", file("b")],
      ["Notes.sempere/notes/" + note + "/notes.txt", file("t")],
      ["Notes.sempere/backup/vault.json", file("{}")],
      ["Other/vault.json", file("{}")],
    ]);
    expect(src.label).toBe("Notes.sempere");
    expect(await src.listNotes()).toEqual([note]);
    expect(await src.listRevisions(note)).toEqual([rev]);
    expect(new TextDecoder().decode(await src.read("vault.json", 10))).toBe("{}");
    await expect(src.read("nope", 10)).rejects.toMatchObject({ notFound: true });
    expect(() => FileListSource.fromPaths([["a/b.txt", file("x")]])).toThrow(/no vault.json/);
  });
});
