// Errors as the user reads them (docs/web-viewer.md "Languages"). The library layers throw
// English messages with a `code`; the interface says the same thing in its own language. Where a
// message carries technical detail that is not in the code (a parser's complaint, an HTTP status)
// the localized sentence is followed by that detail as the library wrote it, as the app does with
// the CLI's errors. Errors without a known code are shown as they are.

import { BlobError } from "../vault/blobs.ts";
import { KeyFileError } from "../vault/keyfile.ts";
import { PasskeyError } from "../vault/passkey.ts";
import { VaultError } from "../vault/vault.ts";
import { t } from "../i18n/index.ts";

function withDetail(sentence: string, e: Error): string {
  return `${sentence} (${e.message})`;
}

function vaultError(e: VaultError): string {
  switch (e.code) {
    case "manifestCorrupt": return withDetail(t("This vault's vault.json cannot be read."), e);
    case "unsupportedFormat": return withDetail(t("This viewer cannot read this vault's format."), e);
    case "legacyVault": return t("This vault still lists a classic (X25519) key. Migrate it with the app or the CLI first.");
    case "badIdentity": return t("No valid key was found. Paste the AGE-SECRET-KEY-PQ-1… line or the whole key file.");
    case "classicIdentity": return t("This is a classic (X25519) key; Sempere vaults use post-quantum keys (AGE-SECRET-KEY-PQ-1…).");
    case "wrongKey": return t("This key does not open the vault.");
    case "invalidVaultSecret": return withDetail(t("The vault's secret is not valid."), e);
  }
}

function keyFileError(e: KeyFileError): string {
  switch (e.code) {
    case "wrongPassphrase": return t("Wrong passphrase, or the key file is damaged.");
    case "notPassphrase": return t("This key file is not locked with a passphrase.");
    case "workFactor": return t("This browser cannot derive the key from this passphrase (the key file asks for too much work or memory). Use a desktop browser, or unlock it with the CLI: sempere keys export.");
    case "noKey": return t("The decrypted file does not hold a usable key.");
    case "notWrapped": return withDetail(t("This is not a key file locked with a passphrase."), e);
  }
}

function passkeyError(e: PasskeyError): string {
  switch (e.code) {
    case "cancelled": return t("The passkey prompt was cancelled or timed out.");
    case "notVerified": return t("The passkey did not verify you (no PIN, biometric or device unlock).");
    case "wrongPasskey": return t("This passkey does not open the remembered key: forget it and paste the key.");
    case "corrupt": return t("The remembered key is missing or damaged: forget it and paste the key.");
    case "otherLocation": return t("The remembered key belongs to another address: paste the key here.");
    case "unsupported": return withDetail(t("The key cannot be remembered with a passkey here."), e);
    case "storage": return withDetail(t("This browser's storage cannot be used."), e);
  }
}

/** What an attachment is, for `blobProblem`. */
export type BlobKind = "audio" | "video" | "image" | "pdf";

/**
 * A missing or over-limit attachment (BlobError `missing`, `tooLarge`) in the interface language,
 * the same for every kind; `limit` is this viewer's cap for the kind in bytes. Undefined for other
 * errors. Image and PDF texts are lower-case: they follow "Page N: kind id:" in a note's problem list.
 */
export function blobProblem(e: unknown, kind: BlobKind, limit: number): string | undefined {
  if (!(e instanceof BlobError)) return undefined;
  const size = Math.floor(limit / 2 ** 20);
  if (e.code === "missing") {
    switch (kind) {
      case "audio": return t("The audio file is missing from the vault (or not synced yet).");
      case "video": return t("The video file is missing from the vault (or not synced yet).");
      case "image": return t("the image file is missing from the vault (or not synced yet)");
      case "pdf": return t("the PDF file is missing from the vault (or not synced yet)");
    }
  }
  if (e.code === "tooLarge") {
    switch (kind) {
      case "audio": return t("The recording is larger than this viewer plays ({size} MiB); export it with the CLI.", { size });
      case "video": return t("The clip is larger than this viewer plays ({size} MiB); export it with the CLI.", { size });
      case "image": return t("the image is larger than this viewer shows ({size} MiB); export it with the CLI", { size });
      case "pdf": return t("the PDF is larger than this viewer shows ({size} MiB); export it with the CLI", { size });
    }
  }
  return undefined;
}

/** The text for an error: a sentence in the interface language for the errors with codes, else its own message. */
export function explain(e: unknown): string {
  if (e instanceof VaultError) return vaultError(e);
  if (e instanceof KeyFileError) return keyFileError(e);
  if (e instanceof PasskeyError) return passkeyError(e);
  return e instanceof Error ? e.message : String(e);
}
