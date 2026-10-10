// Remembering the key behind a passkey (docs/web-viewer.md "Remembering the
// key with a passkey"), against a mocked WebAuthn authenticator.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  IndexedDBKeyStorage, MemoryKeyStorage, PasskeyError, PasskeyVault, type StoredKey, type WebAuthn, describeLocation, maxLocationLength, open,
  recordPlace, seal, userVerified, validRecord, vaultLocation,
} from "../src/vault/passkey.ts";
import { concat } from "../src/vault/bytes.ts";
import { FileListSource, HTTPSource } from "../src/vault/source.ts";
import { IDBFactory } from "fake-indexeddb";
import { UnlockedVault, parseIdentity, parseManifest } from "../src/vault/vault.ts";
import { fixtures, sampleIdentity } from "./support.ts";

const vaultA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const vaultB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const identity = "AGE-SECRET-KEY-PQ-1TESTONLYNOTAREALKEY";
const here = "https://notes.example/vault/";
const elsewhere = "https://evil.example/vault/";

interface MockOptions {
  /** PRF evaluated when the passkey is created. */
  prfAtCreate?: boolean;
  /** `prf.enabled` reported at creation (undefined: not reported). */
  enabled?: boolean | undefined;
  /** PRF evaluated on assertions. */
  prfAtGet?: boolean;
  /** The UV flag in assertions. */
  verified?: boolean;
  /** Throw this from the next call. */
  fail?: DOMException;
}

/** An authenticator: one random secret per credential, PRF = HMAC-SHA256(secret, salt). */
class MockAuthenticator implements WebAuthn {
  readonly secrets = new Map<string, Uint8Array>();
  readonly creates: CredentialCreationOptions[] = [];
  readonly gets: CredentialRequestOptions[] = [];
  constructor(public o: MockOptions = {}) {}

  private async prf(id: Uint8Array, salt: unknown): Promise<Uint8Array> {
    const secret = this.secrets.get(Buffer.from(id).toString("hex"));
    if (!secret) throw new DOMException("unknown credential", "NotAllowedError");
    const key = await crypto.subtle.importKey("raw", secret as Uint8Array<ArrayBuffer>, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return new Uint8Array(await crypto.subtle.sign("HMAC", key, salt as Uint8Array<ArrayBuffer>));
  }

  private credential(id: Uint8Array, ext: unknown, authenticatorData?: Uint8Array): Credential {
    return {
      type: "public-key", id: Buffer.from(id).toString("base64url"), rawId: id.buffer.slice(0),
      response: { authenticatorData: authenticatorData?.buffer.slice(0), clientDataJSON: new ArrayBuffer(0) },
      getClientExtensionResults: () => ext,
    } as unknown as Credential;
  }

  async create(options: CredentialCreationOptions): Promise<Credential | null> {
    this.creates.push(options);
    if (this.o.fail) throw this.o.fail;
    const id = crypto.getRandomValues(new Uint8Array(16));
    this.secrets.set(Buffer.from(id).toString("hex"), crypto.getRandomValues(new Uint8Array(32)));
    const salt = (options.publicKey?.extensions as { prf?: { eval?: { first?: unknown } } }).prf?.eval?.first;
    const prf: Record<string, unknown> = {};
    if (this.o.enabled !== undefined) prf.enabled = this.o.enabled;
    if (this.o.prfAtCreate) prf.results = { first: (await this.prf(id, salt)).buffer };
    return this.credential(id, { prf });
  }

  async get(options: CredentialRequestOptions): Promise<Credential | null> {
    this.gets.push(options);
    if (this.o.fail) throw this.o.fail;
    const allowed = options.publicKey?.allowCredentials?.[0]?.id as Uint8Array;
    const salt = (options.publicKey?.extensions as { prf?: { eval?: { first?: unknown } } }).prf?.eval?.first;
    const data = new Uint8Array(37);
    data[32] = 0x01 | (this.o.verified === false ? 0 : 0x04);
    const ext = this.o.prfAtGet === false ? {} : { prf: { results: { first: (await this.prf(new Uint8Array(allowed), salt)).buffer } } };
    return this.credential(new Uint8Array(allowed), ext, data);
  }
}

async function caught(p: Promise<unknown>): Promise<PasskeyError> {
  try {
    await p;
  } catch (e) {
    if (e instanceof PasskeyError) return e;
    throw e;
  }
  throw new Error("expected a rejection");
}

function contains(hay: Uint8Array, needle: Uint8Array): boolean {
  outer: for (let i = 0; i + needle.length <= hay.length; i++) {
    for (let j = 0; j < needle.length; j++) if (hay[i + j] !== needle[j]) continue outer;
    return true;
  }
  return false;
}

describe("passkey-remembered keys", () => {
  it("remembers a key with PRF at creation and unlocks with one prompt", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: true, enabled: true });
    const storage = new MemoryKeyStorage();
    const pv = new PasskeyVault(auth, storage);
    const record = await pv.remember(identity, vaultA, here, "Notes");
    expect(auth.creates).toHaveLength(1);
    expect(auth.gets).toHaveLength(0);
    expect(record.vaultId).toBe(vaultA);
    expect(storage.records.get(vaultA)).toBe(record);
    expect(await pv.unlock(vaultA, here)).toBe(identity);
    expect(auth.gets).toHaveLength(1);
  });

  it("stores only ciphertext, nonce, salt and credential id: never the key", async () => {
    const storage = new MemoryKeyStorage();
    const record = await new PasskeyVault(new MockAuthenticator({ prfAtCreate: true }), storage).remember(identity, vaultA, here, "Notes");
    expect(Object.keys(record).sort()).toEqual(["created", "credentialId", "ciphertext", "iv", "location", "salt", "vaultId", "version"].sort());
    expect(record.version).toBe(2);
    expect(record.location).toBe(here);
    const plain = new TextEncoder().encode(identity);
    for (const field of [record.credentialId, record.salt, record.iv, record.ciphertext]) {
      expect(contains(field, plain)).toBe(false);
      expect(contains(field, plain.subarray(0, 16))).toBe(false);
    }
    expect(record.ciphertext.length).toBe(plain.length + 16);
    expect(record.salt.length).toBe(32);
    expect(record.iv.length).toBe(12);
  });

  it("requires user verification and asks for PRF with the record's salt", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: true });
    const pv = new PasskeyVault(auth, new MemoryKeyStorage());
    const record = await pv.remember(identity, vaultA, here, "Notes");
    await pv.unlock(vaultA, here);
    const c = auth.creates[0]?.publicKey;
    expect(c?.authenticatorSelection?.userVerification).toBe("required");
    expect(c?.attestation).toBe("none");
    expect((c?.extensions as { prf: { eval: { first: Uint8Array } } }).prf.eval.first).toEqual(record.salt);
    const g = auth.gets[0]?.publicKey;
    expect(g?.userVerification).toBe("required");
    expect(new Uint8Array(g?.allowCredentials?.[0]?.id as Uint8Array)).toEqual(record.credentialId);
    expect((g?.extensions as { prf: { eval: { first: Uint8Array } } }).prf.eval.first).toEqual(record.salt);
  });

  it("evaluates PRF with a second prompt when creation returns none", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: false, enabled: true });
    const pv = new PasskeyVault(auth, new MemoryKeyStorage());
    await pv.remember(identity, vaultA, here, "Notes");
    expect(auth.gets).toHaveLength(1);
    expect(await pv.unlock(vaultA, here)).toBe(identity);
  });

  it("stores nothing without PRF", async () => {
    for (const o of [{ enabled: false }, { enabled: undefined, prfAtGet: false }, { enabled: true, prfAtGet: false }]) {
      const storage = new MemoryKeyStorage();
      const e = await caught(new PasskeyVault(new MockAuthenticator(o), storage).remember(identity, vaultA, here, "Notes"));
      expect(e.code).toBe("unsupported");
      expect(e.message).toMatch(/PRF/);
      expect(storage.records.size).toBe(0);
    }
  });

  it("stores nothing when the prompt is cancelled", async () => {
    const storage = new MemoryKeyStorage();
    const auth = new MockAuthenticator({ prfAtCreate: true, fail: new DOMException("cancelled", "NotAllowedError") });
    expect((await caught(new PasskeyVault(auth, storage).remember(identity, vaultA, here, "Notes"))).code).toBe("cancelled");
    expect(storage.records.size).toBe(0);
  });

  it("refuses an assertion without user verification", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: true });
    const pv = new PasskeyVault(auth, new MemoryKeyStorage());
    await pv.remember(identity, vaultA, here, "Notes");
    auth.o.verified = false;
    expect((await caught(pv.unlock(vaultA, here))).code).toBe("notVerified");
  });

  it("reports a cancelled unlock", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: true });
    const pv = new PasskeyVault(auth, new MemoryKeyStorage());
    await pv.remember(identity, vaultA, here, "Notes");
    auth.o.fail = new DOMException("timed out", "AbortError");
    expect((await caught(pv.unlock(vaultA, here))).code).toBe("cancelled");
  });

  it("a record opens only with its own passkey, vault and bytes", async () => {
    const storage = new MemoryKeyStorage();
    const auth = new MockAuthenticator({ prfAtCreate: true });
    const pv = new PasskeyVault(auth, storage);
    const a = await pv.remember(identity, vaultA, here, "A");
    const b = await pv.remember("AGE-SECRET-KEY-PQ-1OTHER", vaultB, here, "B");
    // A's ciphertext under B's credential and salt (an attacker who can write the store).
    storage.records.set(vaultB, { ...b, ciphertext: a.ciphertext, iv: a.iv });
    expect((await caught(pv.unlock(vaultB, here))).code).toBe("wrongPasskey");
    // A's whole record moved to vault B: the vault id is bound by HKDF and the AAD.
    storage.records.set(vaultB, { ...a, vaultId: vaultB });
    expect((await caught(pv.unlock(vaultB, here))).code).toBe("wrongPasskey");
    // One flipped bit.
    const flipped = new Uint8Array(a.ciphertext);
    flipped[0] = (flipped[0] ?? 0) ^ 1;
    storage.records.set(vaultA, { ...a, ciphertext: flipped });
    expect((await caught(pv.unlock(vaultA, here))).code).toBe("wrongPasskey");
    storage.records.set(vaultA, a);
    expect(await pv.unlock(vaultA, here)).toBe(identity);
  });

  it("a wrong PRF output does not open a record", async () => {
    const id = crypto.getRandomValues(new Uint8Array(16)), salt = crypto.getRandomValues(new Uint8Array(32));
    const prf = crypto.getRandomValues(new Uint8Array(32));
    const record = await seal(identity, prf, { vaultId: vaultA, location: here }, id, salt);
    expect(await open(record, prf)).toBe(identity);
    const other = new Uint8Array(prf);
    other[31] = (other[31] ?? 0) ^ 0x80;
    expect((await caught(open(record, other))).code).toBe("wrongPasskey");
    expect((await caught(open(record, prf.subarray(0, 16)))).code).toBe("unsupported");
  });

  it("remembering again replaces the record; forgetting removes it", async () => {
    const storage = new MemoryKeyStorage();
    const pv = new PasskeyVault(new MockAuthenticator({ prfAtCreate: true }), storage);
    const first = await pv.remember(identity, vaultA, here, "Notes");
    const second = await pv.remember(identity, vaultA, here, "Notes");
    expect(second.credentialId).not.toEqual(first.credentialId);
    expect(storage.records.size).toBe(1);
    expect(await pv.unlock(vaultA, here)).toBe(identity);
    expect((await pv.forget(vaultA))?.credentialId).toEqual(second.credentialId);
    expect(await pv.stored(vaultA)).toBeUndefined();
    expect((await caught(pv.unlock(vaultA, here))).code).toBe("corrupt");
  });

  it("rejects damaged records", () => {
    const good: StoredKey = {
      version: 2, vaultId: vaultA, location: here, credentialId: new Uint8Array(16), salt: new Uint8Array(32),
      iv: new Uint8Array(12), ciphertext: new Uint8Array(40), created: 1,
    };
    const goodV1: StoredKey = { ...good, version: 1 };
    delete goodV1.location;
    expect(validRecord(good, vaultA)).toEqual(good);
    expect(validRecord(goodV1, vaultA)).toEqual(goodV1);
    const bad: unknown[] = [
      null, 3, "x", { ...good, version: 3 }, { ...good, vaultId: vaultB }, { ...good, salt: new Uint8Array(31) },
      { ...good, iv: new Uint8Array(16) }, { ...good, ciphertext: new Uint8Array(16) }, { ...good, ciphertext: new Uint8Array(5000) },
      { ...good, credentialId: new Uint8Array(0) }, { ...good, credentialId: "abc" }, { ...good, created: "now" },
      // Version 2 needs a location; version 1 has none.
      { ...goodV1, version: 2 }, { ...good, location: "" }, { ...good, location: 7 }, { ...good, location: "x".repeat(maxLocationLength + 1) },
      { ...good, version: 1 },
    ];
    for (const b of bad) expect(() => validRecord(b, vaultA)).toThrow(PasskeyError);
    // IndexedDB may hand back ArrayBuffers.
    expect(validRecord({ ...good, salt: good.salt.buffer }, vaultA).salt).toEqual(good.salt);
  });

  it("reads the UV flag", () => {
    const d = new Uint8Array(37);
    expect(userVerified(d)).toBe(false);
    d[32] = 0x05;
    expect(userVerified(d)).toBe(true);
    expect(userVerified(new Uint8Array(10))).toBe(false);
  });

  it("unlocks the sample vault with the remembered key", async () => {
    const manifest = parseManifest(new Uint8Array(readFileSync(join(fixtures, "sample.sempere", "vault.json"))));
    const pv = new PasskeyVault(new MockAuthenticator({ prfAtCreate: true }), new MemoryKeyStorage());
    await pv.remember(sampleIdentity(), manifest.vaultId, here, "sample");
    const vault = await UnlockedVault.unlock(manifest, parseIdentity(await pv.unlock(manifest.vaultId, here)));
    expect(manifest.recipients.map((r) => r.key)).toContain(vault.recipient);
  });
});

/**
 * Security review P3: `vault.json` is unauthenticated before the unlock, so a
 * server can claim any vault's id. A record is bound to where the vault was
 * opened and offered only there.
 */
describe("remembered keys are bound to the vault's location", () => {
  afterEach(() => vi.unstubAllGlobals());

  /** A record as viewers before the location binding wrote it (version 1), built here from the old construction. */
  async function legacyRecord(auth: MockAuthenticator, storage: MemoryKeyStorage, vaultId: string, text: string): Promise<StoredKey> {
    // A credential the mock knows: create one through the authenticator.
    const cred = await auth.create({ publicKey: { extensions: { prf: { eval: { first: new Uint8Array(32) } } } } } as unknown as CredentialCreationOptions);
    const credentialId = new Uint8Array((cred as unknown as { rawId: ArrayBuffer }).rawId);
    const salt = crypto.getRandomValues(new Uint8Array(32));
    const assertion = await auth.get({ publicKey: { allowCredentials: [{ type: "public-key", id: credentialId }], extensions: { prf: { eval: { first: salt } } } } } as unknown as CredentialRequestOptions);
    const prf = new Uint8Array((assertion as unknown as { getClientExtensionResults: () => { prf: { results: { first: ArrayBuffer } } } })
      .getClientExtensionResults().prf.results.first);
    const enc = new TextEncoder();
    const join = (...parts: Uint8Array[]) => concat(parts) as Uint8Array<ArrayBuffer>;
    const zero = Uint8Array.of(0);
    const info = join(enc.encode("sempere-viewer/1 passkey key-wrap"), zero, enc.encode(vaultId), zero, credentialId);
    const aad = join(enc.encode("sempere-viewer/1"), zero, enc.encode(vaultId), zero, credentialId);
    const ikm = await crypto.subtle.importKey("raw", prf, "HKDF", false, ["deriveKey"]);
    const key = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info },
      ikm, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad }, key, enc.encode(text)));
    const record: StoredKey = { version: 1, vaultId, credentialId, salt, iv, ciphertext, created: 1234 };
    await storage.put(record);
    auth.gets.length = 0;
    auth.creates.length = 0;
    return record;
  }

  it("refuses a record of another location before any prompt", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: true });
    const pv = new PasskeyVault(auth, new MemoryKeyStorage());
    await pv.remember(identity, vaultA, here, "Notes");
    const used: string[] = [];
    const e = await caught(pv.unlock(vaultA, elsewhere, (id) => { used.push(id); return Promise.resolve(); }));
    expect(e.code).toBe("otherLocation");
    expect(e.message).toContain(here);
    expect(auth.gets).toHaveLength(0);
    expect(used).toEqual([]);
    const stored = await pv.stored(vaultA);
    expect(stored && recordPlace(stored, elsewhere)).toBe("other");
    expect(await pv.unlock(vaultA, here)).toBe(identity);
  });

  it("binds the location in the ciphertext: a record edited to another location does not open", async () => {
    const storage = new MemoryKeyStorage();
    const pv = new PasskeyVault(new MockAuthenticator({ prfAtCreate: true }), storage);
    const record = await pv.remember(identity, vaultA, here, "Notes");
    storage.records.set(vaultA, { ...record, location: elsewhere });
    expect((await caught(pv.unlock(vaultA, elsewhere))).code).toBe("wrongPasskey");
    // Nor downgraded to version 1 (bound to the id only).
    const v1: StoredKey = { ...record, version: 1 };
    delete v1.location;
    storage.records.set(vaultA, v1);
    expect((await caught(pv.unlock(vaultA, here))).code).toBe("wrongPasskey");
  });

  it("opens a version 1 record and binds it to the location where it opened the vault", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: true });
    const storage = new MemoryKeyStorage();
    const pv = new PasskeyVault(auth, storage);
    const old = await legacyRecord(auth, storage, vaultA, identity);
    expect(recordPlace(old, here)).toBe("legacy");
    expect(await pv.unlock(vaultA, here)).toBe(identity);
    expect(auth.gets).toHaveLength(1);
    const bound = await pv.stored(vaultA);
    if (!bound) throw new Error("no record");
    expect(bound.version).toBe(2);
    expect(bound.location).toBe(here);
    expect(bound.credentialId).toEqual(old.credentialId);
    expect(bound.salt).toEqual(old.salt);
    expect(bound.created).toBe(old.created);
    expect(bound.iv).not.toEqual(old.iv);
    // Now only here: one prompt, no rewrite.
    expect(await pv.unlock(vaultA, here)).toBe(identity);
    expect((await caught(pv.unlock(vaultA, elsewhere))).code).toBe("otherLocation");
  });

  it("leaves a version 1 record unbound when its key does not open the vault there", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: true });
    const storage = new MemoryKeyStorage();
    const pv = new PasskeyVault(auth, storage);
    await legacyRecord(auth, storage, vaultA, identity);
    const refused = pv.unlock(vaultA, elsewhere, () => Promise.reject(new Error("not a recipient")));
    await expect(refused).rejects.toThrow("not a recipient");
    expect((await pv.stored(vaultA))?.version).toBe(1);
    expect(await pv.unlock(vaultA, here)).toBe(identity);
    expect((await pv.stored(vaultA))?.location).toBe(here);
  });

  it("still unlocks when the rewrite cannot be stored, and binds at the next unlock", async () => {
    const auth = new MockAuthenticator({ prfAtCreate: true });
    const storage = new MemoryKeyStorage();
    const pv = new PasskeyVault(auth, storage);
    await legacyRecord(auth, storage, vaultA, identity);
    const put = storage.put.bind(storage);
    storage.put = () => Promise.reject(new Error("quota"));
    expect(await pv.unlock(vaultA, here)).toBe(identity);
    expect((await pv.stored(vaultA))?.version).toBe(1);
    storage.put = put;
    expect(await pv.unlock(vaultA, here)).toBe(identity);
    expect((await pv.stored(vaultA))?.version).toBe(2);
  });

  it("remembering at a new location replaces the record and signals the old passkey unknown", async () => {
    const signalled: { rpId: string; credentialId: string }[] = [];
    vi.stubGlobal("location", { hostname: "viewer.example" });
    vi.stubGlobal("PublicKeyCredential", { signalUnknownCredential: (o: { rpId: string; credentialId: string }) => {
      signalled.push(o);
      return Promise.resolve();
    } });
    const storage = new MemoryKeyStorage();
    const pv = new PasskeyVault(new MockAuthenticator({ prfAtCreate: true }), storage);
    const first = await pv.remember(identity, vaultA, here, "Notes");
    expect(signalled).toEqual([]);
    await pv.remember(identity, vaultA, elsewhere, "Notes");
    expect(storage.records.size).toBe(1);
    expect(signalled).toEqual([{ rpId: "viewer.example", credentialId: Buffer.from(first.credentialId).toString("base64url") }]);
    expect((await caught(pv.unlock(vaultA, here))).code).toBe("otherLocation");
    expect(await pv.unlock(vaultA, elsewhere)).toBe(identity);
  });

  it("refuses to remember for an empty or oversized location", async () => {
    const pv = new PasskeyVault(new MockAuthenticator({ prfAtCreate: true }), new MemoryKeyStorage());
    for (const where of ["", "x".repeat(maxLocationLength + 1)]) {
      expect((await caught(pv.remember(identity, vaultA, where, "Notes"))).code).toBe("unsupported");
    }
  });

  it("names a location by the vault's normalised URL, or as a local folder", () => {
    const a = vaultLocation(new HTTPSource("https://notes.example/vault?x=1#y"));
    expect(a).toBe("https://notes.example/vault/");
    expect(vaultLocation(new HTTPSource("https://notes.example/vault/"))).toBe(a);
    expect(vaultLocation(new HTTPSource("https://notes.example:8443/vault/"))).not.toBe(a);
    const local = vaultLocation(new FileListSource("My Vault", []));
    expect(local).toBe(vaultLocation(new FileListSource("Other", [])));
    expect(local).not.toBe(a);
    expect(describeLocation(local)).toMatch(/folder/);
    expect(describeLocation(a)).toBe(a);
  });
});

describe("IndexedDB storage of remembered keys", () => {
  const record = (vaultId: string): StoredKey => ({
    version: 2, vaultId, location: here, credentialId: new Uint8Array([1, 2, 3]), salt: new Uint8Array(32),
    iv: new Uint8Array(12), ciphertext: new Uint8Array(40), created: 7,
  });

  it("creates no database until a key is remembered", async () => {
    const factory = new IDBFactory();
    const storage = new IndexedDBKeyStorage(factory);
    expect(await storage.get(vaultA)).toBeUndefined();
    await storage.delete(vaultA);
    expect((await factory.databases()).map((d) => d.name)).toEqual([]);
    await storage.put(record(vaultA));
    expect((await factory.databases()).map((d) => d.name)).toEqual(["sempere-viewer"]);
    // Another tab (a new connection) reads it.
    const other = new IndexedDBKeyStorage(factory);
    expect((await other.get(vaultA))?.location).toBe(here);
    expect(await other.get(vaultB)).toBeUndefined();
    await other.delete(vaultA);
    expect(await storage.get(vaultA)).toBeUndefined();
  });

  it("reads version 1 records written by older viewers", async () => {
    const factory = new IDBFactory();
    // The old viewer's database: version 1, the same store, a record without a location.
    await new Promise<void>((resolve, reject) => {
      const r = factory.open("sempere-viewer", 1);
      r.onupgradeneeded = () => r.result.createObjectStore("passkey-keys", { keyPath: "vaultId" });
      r.onsuccess = () => {
        const v1: StoredKey = { ...record(vaultA), version: 1 };
        delete v1.location;
        const tx = r.result.transaction("passkey-keys", "readwrite");
        tx.objectStore("passkey-keys").put(v1);
        tx.oncomplete = () => { r.result.close(); resolve(); };
        tx.onerror = () => reject(tx.error ?? new Error("put failed"));
      };
      r.onerror = () => reject(r.error ?? new Error("open failed"));
    });
    const pv = new PasskeyVault(new MockAuthenticator(), new IndexedDBKeyStorage(factory));
    const stored = await pv.stored(vaultA);
    expect(stored?.version).toBe(1);
    expect(stored && recordPlace(stored, here)).toBe("legacy");
  });
});
