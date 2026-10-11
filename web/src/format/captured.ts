// Capture attribution of a recording (format.md §8.3.1 `captured`, §11): who
// captured a voice note adopted from the inbox. Read leniently as Swift's
// `CaptureAttribution` is: an object with an 8-hex `device` and an optional
// 64-hex `recipient` (the SHA-256 fingerprint of the vault recipient whose
// device capture key sealed it); any other shape is absent, never an error.
// Readers show the recipient's label while it is listed, that the device is
// no longer in the vault otherwise, and that an unattributed capture (no
// `recipient`: sealed with the vault capture key) comes from an unverified
// device (security review 2026-10 C2; stage 4, S10).

import type { JSONObject } from "./json.ts";

export interface CaptureAttribution {
  device: string;
  recipient?: string;
}

/** `captured` of a recording, or undefined when absent or malformed. */
export function decodeCaptured(value: unknown): CaptureAttribution | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  const o = value as JSONObject;
  if (typeof o.device !== "string" || !/^[0-9a-f]{8}$/.test(o.device)) return undefined;
  if (o.recipient === undefined || o.recipient === null) return { device: o.device };
  if (typeof o.recipient !== "string" || !/^[0-9a-f]{64}$/.test(o.recipient)) return undefined;
  return { device: o.device, recipient: o.recipient };
}

/** A recipient's fingerprint (format.md §11.1): lowercase hex SHA-256 of its key as written in vault.json. */
export async function recipientFingerprint(key: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Who captured a recording, as the app's recording menu says it. */
export type CapturedBy =
  | { kind: "device"; label: string }
  | { kind: "removed" }
  | { kind: "unverified" };

/**
 * Who captured `recording`, against `recipients` (the vault's list as read):
 * undefined for a recording that is not a capture (or whose `captured` is malformed).
 */
export async function capturedBy(recording: JSONObject, recipients: readonly { key: string; label: string }[]):
  Promise<CapturedBy | undefined> {
  const c = decodeCaptured(recording.captured);
  if (!c) return undefined;
  if (c.recipient === undefined) return { kind: "unverified" };
  for (const r of recipients) {
    if (await recipientFingerprint(r.key) === c.recipient) return { kind: "device", label: r.label };
  }
  return { kind: "removed" };
}
