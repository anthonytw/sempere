// Remembering the key on this device behind a passkey (docs/web-viewer.md
// "Remembering the key with a passkey"). Opt-in. A WebAuthn credential with
// the PRF extension gives a 32-byte secret only after user verification, on
// this origin's RP ID; HKDF turns it into an AES-256-GCM key that encrypts
// the identity. IndexedDB holds the ciphertext, its nonce, the PRF salt and
// the credential id, never the key or anything it can be derived from without
// the authenticator. Without PRF nothing is stored: there is no weaker mode.
//
// A record is bound to where the vault was opened (its URL, or "a folder on
// this computer"), not only to the vault id: `vault.json` is unauthenticated
// before the unlock, so any server can claim a vault's id. A record is offered
// for one-prompt unlock only at its own location (security review P3).
// Records of version 1 (vault id only) are bound to the location of their
// first unlock, and rewritten as version 2 then.

import { HTTPSource, type VaultSource } from "./source.ts";
import { t } from "../i18n/index.ts";
import { concat } from "./bytes.ts";

/** Why a passkey could not remember or unlock the key. */
export type PasskeyErrorCode =
  | "unsupported"     // no WebAuthn, or the browser or authenticator has no PRF
  | "cancelled"       // the user closed the prompt, or it timed out
  | "notVerified"     // the authenticator did not verify the user
  | "wrongPasskey"    // the PRF output does not open the stored key
  | "corrupt"         // the stored record is malformed
  | "otherLocation"   // the record was remembered for this vault id at another location
  | "storage";        // IndexedDB failed

export class PasskeyError extends Error {
  constructor(readonly code: PasskeyErrorCode, message: string) {
    super(message);
    this.name = "PasskeyError";
  }
}

/** One remembered key: what IndexedDB holds for a vault. */
export interface StoredKey {
  /** 2: bound to `location`; 1 (older viewers): bound to the vault id only. */
  version: 1 | 2;
  /** The vault (`vault.json`'s `vaultId`): one remembered key per vault. */
  vaultId: string;
  /**
   * Where the vault was opened when the key was remembered (`vaultLocation`):
   * bound by HKDF and the AAD, and shown to the user. Absent in version 1.
   */
  location?: string;
  credentialId: Uint8Array;
  /** The PRF input, random per record. Not secret. */
  salt: Uint8Array;
  /** AES-GCM nonce. */
  iv: Uint8Array;
  /** The identity text, AES-256-GCM encrypted (tag appended). */
  ciphertext: Uint8Array;
  /** When it was stored (ms since 1970), shown to the user. */
  created: number;
}

/** Where records live: IndexedDB in the browser, a map in tests. */
export interface KeyStorage {
  get(vaultId: string): Promise<StoredKey | undefined>;
  put(record: StoredKey): Promise<void>;
  delete(vaultId: string): Promise<void>;
}

/** The two WebAuthn calls, so tests can mock the authenticator. */
export interface WebAuthn {
  create(options: CredentialCreationOptions): Promise<Credential | null>;
  get(options: CredentialRequestOptions): Promise<Credential | null>;
}

const label = "sempere-viewer/1";
const labelV2 = "sempere-viewer/2";
const encoder = new TextEncoder();

/** The longest location a record may carry (UTF-16 code units). */
export const maxLocationLength = 4096;

/** What a record is bound to: the vault id, and (version 2) where it was opened. */
export interface Binding {
  vaultId: string;
  /** Undefined only for version 1 records. */
  location?: string;
}

/** Each part prefixed with its length (32-bit big-endian), so no two bindings encode alike. */
function framed(...parts: Uint8Array[]): Uint8Array {
  return concat(parts.flatMap((p) => {
    const n = new Uint8Array(4);
    new DataView(n.buffer).setUint32(0, p.length);
    return [n, p];
  }));
}

/** HKDF info: binds the wrapping key to this purpose, the vault, its location and the credential. */
function info(b: Binding, credentialId: Uint8Array): Uint8Array {
  if (b.location === undefined) {
    return concat([encoder.encode(`${label} passkey key-wrap`), Uint8Array.of(0), encoder.encode(b.vaultId), Uint8Array.of(0), credentialId]);
  }
  return concat([encoder.encode(`${labelV2} passkey key-wrap`), Uint8Array.of(0),
    framed(encoder.encode(b.vaultId), encoder.encode(b.location), credentialId)]);
}

/** AES-GCM additional data: a record cannot be moved to another vault, location or credential. */
function aad(b: Binding, credentialId: Uint8Array): Uint8Array {
  if (b.location === undefined) {
    return concat([encoder.encode(label), Uint8Array.of(0), encoder.encode(b.vaultId), Uint8Array.of(0), credentialId]);
  }
  return concat([encoder.encode(labelV2), Uint8Array.of(0), framed(encoder.encode(b.vaultId), encoder.encode(b.location), credentialId)]);
}

/**
 * How a record relates to the location the vault was opened from: its own
 * (`same`), another (`other`: not offered), or unknown (`legacy`, version 1:
 * bound to this location at its first unlock).
 */
export function recordPlace(record: StoredKey, location: string): "same" | "other" | "legacy" {
  if (record.location === undefined) return "legacy";
  return record.location === location ? "same" : "other";
}

function buf(b: Uint8Array): Uint8Array<ArrayBuffer> {
  return (b.buffer instanceof ArrayBuffer && b.byteOffset === 0 && b.byteLength === b.buffer.byteLength
    ? b : new Uint8Array(b)) as Uint8Array<ArrayBuffer>;
}

function bytes(v: unknown): Uint8Array | undefined {
  if (v instanceof Uint8Array) return v;
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  return undefined;
}

/** The AES-256-GCM key for a PRF output (32 bytes from the authenticator). */
export async function wrappingKey(prf: Uint8Array, binding: Binding, credentialId: Uint8Array): Promise<CryptoKey> {
  if (prf.length < 32) throw new PasskeyError("unsupported", "the authenticator returned a short PRF output");
  const ikm = await crypto.subtle.importKey("raw", buf(prf), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: buf(info(binding, credentialId)) },
    ikm, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

/**
 * Encrypts `identity` for a record bound to `binding` (version 2 with a
 * location; version 1 without, which only tests write now). A fresh IV each
 * time, so re-sealing under the same PRF output never reuses one.
 */
export async function seal(identity: string, prf: Uint8Array, binding: Binding, credentialId: Uint8Array,
  salt: Uint8Array, now = Date.now()): Promise<StoredKey> {
  const key = await wrappingKey(prf, binding, credentialId);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: buf(aad(binding, credentialId)) }, key, buf(encoder.encode(identity))));
  const { vaultId, location } = binding;
  return location === undefined ? { version: 1, vaultId, credentialId, salt, iv, ciphertext, created: now }
    : { version: 2, vaultId, location, credentialId, salt, iv, ciphertext, created: now };
}

/** Decrypts a record's identity. A wrong PRF output or an altered record fails. */
export async function open(record: StoredKey, prf: Uint8Array): Promise<string> {
  const binding: Binding = { vaultId: record.vaultId, location: record.location };
  const key = await wrappingKey(prf, binding, record.credentialId);
  let plain: ArrayBuffer;
  try {
    plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: buf(record.iv), additionalData: buf(aad(binding, record.credentialId)) },
      key, buf(record.ciphertext));
  } catch {
    throw new PasskeyError("wrongPasskey", "this passkey does not open the remembered key: forget it and paste the key");
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(plain);
  } catch {
    throw new PasskeyError("corrupt", "the remembered key is not text");
  }
}

/** Checks a value read from storage; anything else is `corrupt`. */
export function validRecord(v: unknown, vaultId: string): StoredKey {
  const o = v as Partial<Record<keyof StoredKey, unknown>> | null;
  const credentialId = bytes(o?.credentialId), salt = bytes(o?.salt), iv = bytes(o?.iv), ciphertext = bytes(o?.ciphertext);
  const location = o?.location;
  const locationOK = o?.version === 1 ? location === undefined
    : o?.version === 2 && typeof location === "string" && location.length > 0 && location.length <= maxLocationLength;
  if (!o || !locationOK || o.vaultId !== vaultId || !credentialId || credentialId.length === 0 || credentialId.length > 1023
    || !salt || salt.length !== 32 || !iv || iv.length !== 12 || !ciphertext || ciphertext.length < 17 || ciphertext.length > 4096
    || typeof o.created !== "number") {
    throw new PasskeyError("corrupt", "the remembered key's record is damaged: forget it and paste the key");
  }
  return typeof location === "string"
    ? { version: 2, vaultId, location, credentialId, salt, iv, ciphertext, created: o.created }
    : { version: 1, vaultId, credentialId, salt, iv, ciphertext, created: o.created };
}

// MARK: - WebAuthn

interface PRFOutputs {
  enabled?: boolean;
  results?: { first?: unknown };
}

function prfOutput(cred: PublicKeyCredential): { enabled?: boolean; first?: Uint8Array } {
  const ext = cred.getClientExtensionResults() as { prf?: PRFOutputs };
  return { enabled: ext.prf?.enabled, first: bytes(ext.prf?.results?.first) };
}

/** True when the authenticator data says the user was verified (flag UV, bit 2). */
export function userVerified(authenticatorData: ArrayBuffer | Uint8Array): boolean {
  const d = bytes(authenticatorData);
  return d !== undefined && d.length >= 37 && ((d[32] ?? 0) & 0x04) !== 0;
}

function cancelled(e: unknown): PasskeyError {
  if (e instanceof PasskeyError) return e;
  if (e instanceof DOMException && (e.name === "NotAllowedError" || e.name === "AbortError")) {
    return new PasskeyError("cancelled", "the passkey prompt was cancelled or timed out");
  }
  if (e instanceof DOMException && e.name === "NotSupportedError") {
    return new PasskeyError("unsupported", "this browser or authenticator cannot create such a passkey");
  }
  return new PasskeyError("unsupported", `passkey error: ${e instanceof Error ? e.message : String(e)}`);
}

const noPRF = "this browser or passkey provider does not support the PRF extension, which keeps the key encrypted "
  + "under a secret only the passkey can produce. Nothing was stored; paste the key each time instead.";

/** The browser's WebAuthn, or undefined when there is none (an insecure context, an old browser). */
export function browserWebAuthn(): WebAuthn | undefined {
  if (typeof window === "undefined" || !window.isSecureContext || typeof PublicKeyCredential === "undefined"
    || !navigator.credentials) return undefined;
  return {
    create: (o) => navigator.credentials.create(o),
    get: (o) => navigator.credentials.get(o),
  };
}

/**
 * What the browser says about PRF before any prompt: false when it reports
 * no PRF (`getClientCapabilities`), true when it reports it, undefined when
 * it cannot tell (the ceremony then decides).
 */
export async function browserReportsPRF(): Promise<boolean | undefined> {
  const pkc = (globalThis as { PublicKeyCredential?: { getClientCapabilities?: () => Promise<Record<string, boolean>> } }).PublicKeyCredential;
  if (!pkc?.getClientCapabilities) return undefined;
  try {
    const caps = await pkc.getClientCapabilities();
    return caps["extension:prf"];
  } catch {
    return undefined;
  }
}

/** Remembers and recalls vault keys behind passkeys. */
export class PasskeyVault {
  constructor(private readonly webauthn: WebAuthn, private readonly storage: KeyStorage,
    private readonly appName = "Sempere viewer") {}

  /** The remembered key of a vault, if any (a damaged record throws `corrupt`). */
  async stored(vaultId: string): Promise<StoredKey | undefined> {
    let v: unknown;
    try {
      v = await this.storage.get(vaultId);
    } catch (e) {
      throw new PasskeyError("storage", `cannot read this browser's storage: ${String(e)}`);
    }
    return v === undefined ? undefined : validRecord(v, vaultId);
  }

  /**
   * Creates a passkey with PRF (user verification required) and stores the
   * identity encrypted under it, bound to the vault id and `location`
   * (`vaultLocation`), replacing any key remembered for the vault (whose
   * passkey is then signalled unknown). Nothing is stored unless PRF works.
   * `vaultName` labels the passkey.
   */
  async remember(identity: string, vaultId: string, location: string, vaultName: string): Promise<StoredKey> {
    if (location.length === 0 || location.length > maxLocationLength) {
      throw new PasskeyError("unsupported", "this vault's address is too long to remember a key for");
    }
    const previous = await this.stored(vaultId).catch(() => undefined);
    const salt = crypto.getRandomValues(new Uint8Array(32));
    let cred: Credential | null;
    try {
      cred = await this.webauthn.create({
        publicKey: {
          rp: { name: this.appName },
          user: { id: crypto.getRandomValues(new Uint8Array(16)), name: `Sempere vault ${vaultId.slice(0, 8)}`, displayName: `Sempere: ${vaultName}` },
          challenge: crypto.getRandomValues(new Uint8Array(32)),
          pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
          authenticatorSelection: { userVerification: "required", residentKey: "preferred" },
          attestation: "none",
          timeout: 120_000,
          extensions: { prf: { eval: { first: salt } } },
        },
      });
    } catch (e) {
      throw cancelled(e);
    }
    if (!isPublicKeyCredential(cred)) throw new PasskeyError("cancelled", "no passkey was created");
    const credentialId = new Uint8Array(cred.rawId);
    const created = prfOutput(cred);
    let prf: Uint8Array;
    try {
      if (created.enabled === false) throw new PasskeyError("unsupported", noPRF);
      // Some authenticators only evaluate PRF on an assertion: ask once more.
      prf = created.first ?? await this.assert(credentialId, salt);
    } catch (e) {
      // The new passkey opens nothing: let the passkey provider drop it.
      if (e instanceof PasskeyError && e.code === "unsupported") signalUnknown(credentialId);
      throw e;
    }
    const record = await seal(identity, prf, { vaultId, location }, credentialId, salt);
    try {
      await this.storage.put(record);
    } catch (e) {
      throw new PasskeyError("storage", `cannot write this browser's storage: ${String(e)}`);
    }
    // The replaced record's passkey opens nothing now: let its provider drop it.
    if (previous && !sameBytes(previous.credentialId, credentialId)) signalUnknown(previous.credentialId);
    return record;
  }

  /**
   * One passkey prompt: the identity text remembered for the vault, if it
   * was remembered at `location`, handed to `use` (which unlocks the vault
   * and throws if the key does not open it). A record of another location
   * is refused before any prompt (`otherLocation`). A version 1 record (no
   * location) is rewritten bound to `location` once `use` succeeded, under
   * the same passkey and PRF output (no second prompt); if that write fails
   * it is tried again at the next unlock.
   */
  async unlock(vaultId: string, location: string, use: (identity: string) => Promise<void> = () => Promise.resolve()): Promise<string> {
    const record = await this.stored(vaultId);
    if (!record) throw new PasskeyError("corrupt", "no key is remembered for this vault on this device");
    const place = recordPlace(record, location);
    if (place === "other") {
      throw new PasskeyError("otherLocation",
        `the key remembered for this vault belongs to ${describeLocation(record.location ?? "")}, not to this address: paste the key here`);
    }
    const prf = await this.assert(record.credentialId, record.salt);
    const identity = await open(record, prf);
    await use(identity);
    if (place === "legacy" && location.length > 0 && location.length <= maxLocationLength) {
      const bound = await seal(identity, prf, { vaultId, location }, record.credentialId, record.salt, record.created);
      await this.storage.put(bound).catch(() => undefined);
    }
    return identity;
  }

  /** Forgets the vault's key here; the passkey left in the authenticator opens nothing. */
  async forget(vaultId: string): Promise<StoredKey | undefined> {
    const record = await this.stored(vaultId).catch(() => undefined);
    try {
      await this.storage.delete(vaultId);
    } catch (e) {
      throw new PasskeyError("storage", `cannot write this browser's storage: ${String(e)}`);
    }
    if (record) signalUnknown(record.credentialId);
    return record;
  }

  private async assert(credentialId: Uint8Array, salt: Uint8Array): Promise<Uint8Array> {
    let cred: Credential | null;
    try {
      cred = await this.webauthn.get({
        publicKey: {
          challenge: crypto.getRandomValues(new Uint8Array(32)),
          allowCredentials: [{ type: "public-key", id: buf(credentialId) }],
          userVerification: "required",
          timeout: 120_000,
          extensions: { prf: { eval: { first: salt } } } as AuthenticationExtensionsClientInputs,
        },
      });
    } catch (e) {
      throw cancelled(e);
    }
    if (!isPublicKeyCredential(cred)) throw new PasskeyError("cancelled", "no passkey was used");
    const response = cred.response as AuthenticatorAssertionResponse;
    if (!userVerified(response.authenticatorData)) {
      throw new PasskeyError("notVerified", "the passkey did not verify you (no PIN, biometric or device unlock)");
    }
    const first = prfOutput(cred).first;
    if (!first) throw new PasskeyError("unsupported", noPRF);
    return first;
  }
}

/**
 * Where a vault was opened, as a record binds it: the vault's base URL for
 * one opened over HTTP(S) (`HTTPSource.label`: no query, fragment or
 * credentials, a trailing slash), `local:` for a folder opened from this
 * computer (the user picked it; its name is not an identity). Call it with
 * the source as opened, before any cache wraps it.
 */
export function vaultLocation(src: VaultSource): string {
  return src instanceof HTTPSource ? src.label : localLocation;
}

const localLocation = "local:";

/** A location for people: the URL, or "a folder on this computer". */
export function describeLocation(location: string): string {
  return location === localLocation ? t("a folder opened from this computer") : location;
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

function isPublicKeyCredential(c: Credential | null): c is PublicKeyCredential {
  return c !== null && c.type === "public-key" && "rawId" in c && "getClientExtensionResults" in c;
}

function base64url(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Tells the passkey provider that a credential is no longer used here, where
 * the browser supports it (WebAuthn Signal API), so it can remove it. Best
 * effort: the passkey opens nothing without the record anyway.
 */
function signalUnknown(credentialId: Uint8Array): void {
  const pkc = (globalThis as { PublicKeyCredential?: { signalUnknownCredential?: (o: { rpId: string; credentialId: string }) => Promise<void> } }).PublicKeyCredential;
  if (!pkc?.signalUnknownCredential || typeof location === "undefined") return;
  pkc.signalUnknownCredential({ rpId: location.hostname, credentialId: base64url(credentialId) }).catch(() => undefined);
}

// MARK: - IndexedDB

const dbName = "sempere-viewer";
const storeName = "passkey-keys";

function request<T>(r: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error ?? new Error("IndexedDB request failed"));
  });
}

/**
 * Records in this origin's IndexedDB (`sempere-viewer` / `passkey-keys`, keyed
 * by vault id; one per vault). The database is created by the first record
 * only: looking for a record (every unlock screen) or forgetting one where none
 * exists leaves no database behind, so nothing is stored before the user opts in.
 */
export class IndexedDBKeyStorage implements KeyStorage {
  private db?: IDBDatabase;

  constructor(private readonly factory: IDBFactory = indexedDB) {}

  /** The database; undefined when it does not exist and `create` is false (its creation is aborted). */
  private async database(create: boolean): Promise<IDBDatabase | undefined> {
    if (this.db) return this.db;
    const db = await new Promise<IDBDatabase | undefined>((resolve, reject) => {
      let absent = false;
      const r = this.factory.open(dbName, 1);
      r.onupgradeneeded = (e) => {
        if (!create && e.oldVersion === 0) {
          absent = true;
          r.transaction?.abort();
          return;
        }
        r.result.createObjectStore(storeName, { keyPath: "vaultId" });
      };
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => absent ? resolve(undefined) : reject(r.error ?? new Error("cannot open IndexedDB"));
      r.onblocked = () => reject(new Error("IndexedDB is blocked by another tab"));
    });
    if (db) this.db = db;
    return db;
  }

  private async store(mode: IDBTransactionMode, create: boolean): Promise<IDBObjectStore | undefined> {
    return (await this.database(create))?.transaction(storeName, mode).objectStore(storeName);
  }

  async get(vaultId: string): Promise<StoredKey | undefined> {
    const store = await this.store("readonly", false);
    return store ? await request(store.get(vaultId)) as StoredKey | undefined : undefined;
  }

  async put(record: StoredKey): Promise<void> {
    const store = await this.store("readwrite", true);
    if (!store) throw new Error("cannot create the IndexedDB database");
    await request(store.put(record));
  }

  async delete(vaultId: string): Promise<void> {
    const store = await this.store("readwrite", false);
    if (store) await request(store.delete(vaultId));
  }
}

/** Records in memory (tests). */
export class MemoryKeyStorage implements KeyStorage {
  readonly records = new Map<string, StoredKey>();
  get(vaultId: string): Promise<StoredKey | undefined> {
    return Promise.resolve(this.records.get(vaultId));
  }
  put(record: StoredKey): Promise<void> {
    this.records.set(record.vaultId, record);
    return Promise.resolve();
  }
  delete(vaultId: string): Promise<void> {
    this.records.delete(vaultId);
    return Promise.resolve();
  }
}
