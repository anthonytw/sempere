// The signed epoch link (format.md §15.3 `epochLink`): the shape `vault.json` carries and the hex
// reader the vault code shares. The key pairs and the message live in epoch.ts. Pure JavaScript.

export const sizes = { ed25519PublicKey: 32, ed25519Signature: 64, mldsa65PublicKey: 1952, mldsa65Signature: 3309 };

/**
 * `epochLink` as read from `vault.json`: both signatures (`signed`), or
 * anything else (`malformed`, a string included: never verifies).
 */
export type SecretLink =
  | { kind: "signed"; ed25519: Uint8Array; mldsa65: Uint8Array }
  | { kind: "malformed" };

/** The link verification keys of an epoch. */
export interface LinkPublicKeys {
  ed25519: Uint8Array;
  mldsa65: Uint8Array;
}

/** `count` bytes from exactly `2 × count` lowercase hex digits, else undefined. */
export function unhex(s: unknown, count: number): Uint8Array | undefined {
  if (typeof s !== "string" || s.length !== 2 * count || !/^[0-9a-f]*$/.test(s)) return undefined;
  const out = new Uint8Array(count);
  for (let i = 0; i < count; i++) out[i] = parseInt(s.slice(2 * i, 2 * i + 2), 16);
  return out;
}

/** Reads `epochLink`'s JSON value (undefined or null: no link). Never throws. */
export function parseSecretLink(v: unknown): SecretLink | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "object" && !Array.isArray(v)) {
    const o = v as Record<string, unknown>;
    const ed = unhex(o.ed25519, sizes.ed25519Signature);
    const ml = unhex(o.mldsa65, sizes.mldsa65Signature);
    if (ed && ml) return { kind: "signed", ed25519: ed, mldsa65: ml };
  }
  return { kind: "malformed" };
}
