// Opening a share file's age ciphertext (docs/design/1.3-share.md §3.4): one scrypt recipient, a work factor
// the viewer allows (at most 20, as for vault keys), then typage's decrypter. The passphrase is used once.

import { Decrypter, armor } from "age-encryption";

/** Largest scrypt work factor accepted (2^20 needs 1 GiB; senders write 18). */
export const maxWorkFactor = 20;

export type ShareOpenErrorCode = "notShare" | "workFactor" | "wrongPassphrase";

export class ShareOpenError extends Error {
  constructor(public readonly code: ShareOpenErrorCode, message: string) {
    super(message);
    this.name = "ShareOpenError";
  }
}

const armorBegin = "-----BEGIN AGE ENCRYPTED FILE-----";
const armorEnd = "-----END AGE ENCRYPTED FILE-----";
/** Largest armored text read (a 200 MiB file, base64 and line breaks). */
export const maxArmorChars = 280 * 1024 * 1024;

/** The binary age file in the page's data block. */
export function ageBytes(text: string): Uint8Array {
  if (text.length > maxArmorChars) throw new ShareOpenError("notShare", "too large");
  const start = text.indexOf(armorBegin);
  const end = text.indexOf(armorEnd, start + 1);
  if (start < 0 || end < 0) throw new ShareOpenError("notShare", "not an age file");
  const lines = text.slice(start, end + armorEnd.length).split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
  try {
    return armor.decode(lines.join("\n") + "\n");
  } catch {
    throw new ShareOpenError("notShare", "the armor is damaged");
  }
}

/**
 * The scrypt work factor in the age header, checked before any work: exactly one recipient, an scrypt stanza,
 * a factor the viewer accepts.
 */
export function shareWorkFactor(file: Uint8Array): number {
  const head = new TextDecoder("utf-8", { fatal: false }).decode(file.subarray(0, 2048));
  const lines = head.split("\n");
  if (lines[0] !== "age-encryption.org/v1") throw new ShareOpenError("notShare", "not an age file");
  const end = lines.findIndex((l) => l.startsWith("--- "));
  if (end < 0) throw new ShareOpenError("notShare", "the header is malformed");
  const stanzas = lines.slice(1, end).filter((l) => l.startsWith("-> "));
  const m = stanzas.length === 1 ? /^-> scrypt [A-Za-z0-9+/]{22} ([1-9][0-9]?)$/.exec(stanzas[0] ?? "") : null;
  const logN = m?.[1] ? Number(m[1]) : NaN;
  if (!Number.isInteger(logN)) throw new ShareOpenError("notShare", "not a passphrase file");
  if (logN > maxWorkFactor) throw new ShareOpenError("workFactor", `work factor ${logN}`);
  return logN;
}

/** The payload bytes inside `armored` (the data block's text), opened with `passphrase`. */
export async function decryptShare(armored: string, passphrase: string): Promise<Uint8Array> {
  const file = ageBytes(armored);
  shareWorkFactor(file);
  const d = new Decrypter();
  d.addPassphrase(passphrase);
  try {
    return await d.decrypt(file);
  } catch {
    throw new ShareOpenError("wrongPassphrase", "wrong passphrase, or the file is damaged");
  }
}
