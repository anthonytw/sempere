// Passphrase-wrapped keys (format.md §3.2): an age file with one scrypt
// recipient whose plaintext is the identity, either the vault's stored key
// file (`keys/<name>.key.age`) or the armored copy a paper kit prints
// (`sempere keys paper --passphrase`). Decrypted with typage's scrypt
// identity; the passphrase is used once and never stored (docs/web-viewer.md).

import { Decrypter, armor } from "age-encryption";
import { parseIdentity } from "./vault.ts";

/** Largest key file read (a stored PQ key file is under 3 KiB). */
export const maxKeyFileBytes = 64 * 1024;
/** Largest scrypt work factor accepted (format.md §3.2: readers must accept 20; 2^20 needs 1 GiB). */
export const maxWorkFactor = 20;
/** Largest plaintext accepted: an identity file with comments. */
const maxPlaintextBytes = 16 * 1024;

export type KeyFileErrorCode = "notWrapped" | "notPassphrase" | "workFactor" | "wrongPassphrase" | "noKey";

/** Why a passphrase-wrapped key cannot be opened. */
export class KeyFileError extends Error {
  constructor(public readonly code: KeyFileErrorCode, message: string) {
    super(message);
    this.name = "KeyFileError";
  }
}

const armorBegin = "-----BEGIN AGE ENCRYPTED FILE-----";
const binaryMagic = "age-encryption.org/v1\n";
const encoder = new TextEncoder();

/** True when `text` holds an armored age file (a paper kit's passphrase copy). */
export function looksArmored(text: string): boolean {
  return text.includes(armorBegin);
}

/** True when `bytes` start like an age file, binary or armored. */
export function looksWrapped(bytes: Uint8Array): boolean {
  const head = new TextDecoder("utf-8", { fatal: false }).decode(bytes.subarray(0, 64)).trimStart();
  return head.startsWith(binaryMagic) || head.startsWith(armorBegin);
}

/**
 * The binary age file in `input`: armored text (lines trimmed, blank lines
 * dropped, so a copy from a PDF or with indentation still reads), or the
 * bytes as they are.
 */
export function wrappedBytes(input: Uint8Array | string): Uint8Array {
  const text = typeof input === "string" ? input : undefined;
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  if (bytes.length > maxKeyFileBytes) throw new KeyFileError("notWrapped", "the key file is larger than 64 KiB");
  const asText = text ?? new TextDecoder("utf-8", { fatal: false }).decode(bytes);
  if (looksArmored(asText)) {
    const start = asText.indexOf(armorBegin);
    const lines = asText.slice(start).split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
    const end = lines.findIndex((l) => l === "-----END AGE ENCRYPTED FILE-----");
    try {
      return armor.decode(lines.slice(0, end + 1).join("\n") + "\n");
    } catch (e) {
      throw new KeyFileError("notWrapped", `the armored key is damaged (${e instanceof Error ? e.message : String(e)}); check each line against the paper kit's checksums`);
    }
  }
  if (!looksWrapped(bytes)) throw new KeyFileError("notWrapped", "not an age-encrypted key file");
  return bytes;
}

/**
 * The scrypt work factor of a wrapped key, checked before any work: one
 * scrypt stanza only (age's rule for passphrase files), a work factor the
 * viewer accepts.
 */
export function workFactor(file: Uint8Array): number {
  const head = new TextDecoder("utf-8", { fatal: false }).decode(file.subarray(0, 2048));
  const lines = head.split("\n");
  if (lines[0] !== "age-encryption.org/v1") throw new KeyFileError("notWrapped", "not an age-encrypted key file");
  const end = lines.findIndex((l) => l.startsWith("--- "));
  if (end < 0) throw new KeyFileError("notWrapped", "the key file's header is malformed");
  const stanzas = lines.slice(1, end).filter((l) => l.startsWith("-> "));
  const scrypt = stanzas.filter((l) => l.startsWith("-> scrypt "));
  if (scrypt.length === 0) {
    throw new KeyFileError("notPassphrase", "this file is encrypted to a key, not with a passphrase");
  }
  const [line] = scrypt;
  if (stanzas.length !== 1 || !line) throw new KeyFileError("notPassphrase", "a passphrase file must have exactly one recipient");
  const m = /^-> scrypt [A-Za-z0-9+/]{22} ([1-9][0-9]?)$/.exec(line);
  const logN = m?.[1] ? Number(m[1]) : NaN;
  if (!Number.isInteger(logN)) throw new KeyFileError("notWrapped", "the key file's scrypt stanza is malformed");
  if (logN > maxWorkFactor) {
    throw new KeyFileError("workFactor", `the key file's scrypt work factor is ${logN}; this viewer accepts up to ${maxWorkFactor} (2^${logN} KiB of memory). Unlock it with the CLI: sempere keys export`);
  }
  return logN;
}

/**
 * Decrypts a wrapped key with `passphrase` and returns the identity line
 * (`AGE-SECRET-KEY-PQ-1…`). Slow on purpose (scrypt, about a second at work
 * factor 18): the viewer runs it in a worker (src/ui/keyunwrap.ts).
 */
export async function unwrapKey(file: Uint8Array, passphrase: string): Promise<string> {
  workFactor(file);
  if (passphrase.length === 0) throw new KeyFileError("wrongPassphrase", "enter the passphrase");
  const d = new Decrypter();
  d.addPassphrase(passphrase);
  let plain: Uint8Array;
  try {
    plain = await d.decrypt(file);
  } catch {
    throw new KeyFileError("wrongPassphrase", "wrong passphrase, or the key file is damaged");
  }
  if (plain.length > maxPlaintextBytes) throw new KeyFileError("noKey", "the decrypted file is not a key file");
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(plain);
  } catch {
    throw new KeyFileError("noKey", "the decrypted file is not a key file");
  }
  try {
    return parseIdentity(text);
  } catch (e) {
    throw new KeyFileError("noKey", `the decrypted file holds no usable key: ${e instanceof Error ? e.message : String(e)}`);
  }
}

/** `keys/` file name of a recipient (format.md §3.2, Swift `IdentityFile.fileName`). */
export async function keyFileName(recipient: string): Promise<string> {
  if (!recipient.startsWith("age1pq1")) return `${recipient}.key.age`;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(recipient)));
  return `age1pq-${[...digest].map((b) => b.toString(16).padStart(2, "0")).join("")}.key.age`;
}
