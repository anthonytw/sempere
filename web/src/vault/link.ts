// The signed secret link (format.md §2.1 "Secret link"; security review
// 2026-10, R2): Ed25519 and ML-DSA-65 key pairs derived from a vault secret
// with HKDF, and a `secretLink` that is valid only when both signatures by the
// outgoing secret's keys verify. The viewer keeps no trust record: it checks a
// link only for a rewrap journal's previous secret, which it holds (§3.3.1).
// Pure JavaScript (@noble), so it runs under the strict CSP (no WebAssembly).

import { ed25519 } from "@noble/curves/ed25519.js";
import { ml_dsa65 } from "@noble/post-quantum/ml-dsa.js";
import { concat } from "./bytes.ts";

export const sizes = { ed25519PublicKey: 32, ed25519Signature: 64, mldsa65PublicKey: 1952, mldsa65Signature: 3309 };

/**
 * `secretLink` as read from `vault.json`: both signatures (`signed`), the HMAC
 * of older writers (`legacy`, 64 hex digits as written), or anything else
 * (`malformed`, never verifies).
 */
export type SecretLink =
  | { kind: "signed"; ed25519: Uint8Array; mldsa65: Uint8Array }
  | { kind: "legacy"; hex: string }
  | { kind: "malformed" };

/** The link verification keys of a secret: what a device's trust record holds. */
export interface LinkPublicKeys {
  ed25519: Uint8Array;
  mldsa65: Uint8Array;
}

const encoder = new TextEncoder();

/** `count` bytes from exactly `2 × count` lowercase hex digits, else undefined. */
export function unhex(s: unknown, count: number): Uint8Array | undefined {
  if (typeof s !== "string" || s.length !== 2 * count || !/^[0-9a-f]*$/.test(s)) return undefined;
  const out = new Uint8Array(count);
  for (let i = 0; i < count; i++) out[i] = parseInt(s.slice(2 * i, 2 * i + 2), 16);
  return out;
}

/** Reads `secretLink`'s JSON value (undefined or null: no link). Never throws. */
export function parseSecretLink(v: unknown): SecretLink | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "string") return { kind: "legacy", hex: v };
  if (typeof v === "object" && !Array.isArray(v)) {
    const o = v as Record<string, unknown>;
    const ed = unhex(o.ed25519, sizes.ed25519Signature);
    const ml = unhex(o.mldsa65, sizes.mldsa65Signature);
    if (ed && ml) return { kind: "signed", ed25519: ed, mldsa65: ml };
  }
  return { kind: "malformed" };
}

async function hkdf(secret: Uint8Array, info: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", secret as Uint8Array<ArrayBuffer>, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(info) }, key, 256);
  return new Uint8Array(bits);
}

/** The two 32-byte seeds (never stored). */
export async function linkSeeds(secret: Uint8Array): Promise<{ ed25519: Uint8Array; mldsa65: Uint8Array }> {
  return {
    ed25519: await hkdf(secret, "sempere/1 secret link ed25519 seed"),
    mldsa65: await hkdf(secret, "sempere/1 secret link ml-dsa-65 seed"),
  };
}

/** The public keys of `secret`'s link signing keys (Ed25519 RFC 8032, ML-DSA-65 FIPS 204 KeyGen_internal). */
export async function linkPublicKeys(secret: Uint8Array): Promise<LinkPublicKeys> {
  const seeds = await linkSeeds(secret);
  return { ed25519: ed25519.getPublicKey(seeds.ed25519), mldsa65: ml_dsa65.keygen(seeds.mldsa65).publicKey };
}

/** `"sempere/1" ‖ 0 ‖ "secret link" ‖ 0 ‖ vaultId ‖ 0 ‖ secretId(new)`. */
export async function linkMessage(next: Uint8Array, vaultId: string): Promise<Uint8Array> {
  const parts = [encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("secret link"), Uint8Array.of(0),
    encoder.encode(vaultId.toLowerCase()), Uint8Array.of(0), await hkdf(next, "sempere/1 secret id")];
  return concat(parts);
}

/** True when `link` is signed and BOTH signatures verify under `keys` over the link to `next`. */
export async function verifySignedLink(link: SecretLink | undefined, keys: LinkPublicKeys, next: Uint8Array,
  vaultId: string): Promise<boolean> {
  if (link?.kind !== "signed") return false;
  if (keys.ed25519.length !== sizes.ed25519PublicKey || keys.mldsa65.length !== sizes.mldsa65PublicKey) return false;
  const message = await linkMessage(next, vaultId);
  // Both are checked whatever the first says; a throw (malformed input) is a failure.
  const check = (f: () => boolean): boolean => {
    try {
      return f();
    } catch {
      return false;
    }
  };
  const edValid = check(() => ed25519.verify(link.ed25519, message, keys.ed25519));
  const mlValid = check(() => ml_dsa65.verify(link.mldsa65, message, keys.mldsa65));
  return edValid && mlValid;
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

/**
 * True when `link` links the secret `previous` to `next`, for a reader holding
 * both (a rewrap journal's previous secret): a signed link under `previous`'s
 * keys, or the legacy HMAC under its old `linkKey` (forging that needs
 * `secretId(next)`, which only holders of `next` know).
 */
export async function linkConnects(link: SecretLink | undefined, previous: Uint8Array, next: Uint8Array,
  vaultId: string): Promise<boolean> {
  if (link?.kind === "signed") return verifySignedLink(link, await linkPublicKeys(previous), next, vaultId);
  if (link?.kind !== "legacy") return false;
  const given = unhex(link.hex, 32);
  if (!given) return false;
  const key = await crypto.subtle.importKey("raw", (await hkdf(previous, "sempere/1 secret link key")) as Uint8Array<ArrayBuffer>,
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = new Uint8Array(await crypto.subtle.sign("HMAC", key,
    (await linkMessage(next, vaultId)) as Uint8Array<ArrayBuffer>));
  return equalBytes(expected, given);
}
