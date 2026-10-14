// The unlock screen's passkey parts (docs/web-viewer.md "Remembering the key
// with a passkey"): unlock or forget a remembered key, the opt-in checkbox,
// and the screen that creates the passkey after a pasted key unlocked.

import {
  IndexedDBKeyStorage, PasskeyError, PasskeyVault, browserReportsPRF, browserWebAuthn, describeLocation, recordPlace,
} from "../vault/passkey.ts";
import { t } from "../i18n/index.ts";
import { formatDate, h } from "./dom.ts";
import { explain } from "./errors.ts";

let shared: PasskeyVault | null | undefined;

/** The browser's passkey vault, or undefined without WebAuthn (or IndexedDB). */
export function passkeyVault(): PasskeyVault | undefined {
  if (shared === undefined) {
    const webauthn = browserWebAuthn();
    shared = webauthn && typeof indexedDB !== "undefined" ? new PasskeyVault(webauthn, new IndexedDBKeyStorage()) : null;
  }
  return shared ?? undefined;
}

export function passkeyMessage(e: unknown): string {
  return e instanceof PasskeyError ? explain(e) : t("Passkey error: {detail}", { detail: String(e) });
}

/**
 * The card for a key remembered for `vaultId`, filled in once storage
 * answers (empty when there is none). It offers the passkey only where the
 * key was remembered (`location`, `vaultLocation`): `vault.json` is not
 * authenticated before the unlock, so any server can claim this vault's id.
 * `unlock` gets the identity text and unlocks the vault (throwing if it
 * cannot).
 */
export function rememberedCard(pv: PasskeyVault, vaultId: string, location: string,
  unlock: (identity: string) => Promise<void>, failed: (message: string) => void, forgotten: () => void): HTMLElement {
  const card = h("div", { class: "card", attrs: { hidden: "" } });
  pv.stored(vaultId).then((record) => {
    if (!record) return;
    const place = recordPlace(record, location);
    const forget = h("button", {
      text: t("Forget this key"), class: "secondary", attrs: { type: "button" },
      title: t("Delete the encrypted key from this browser"),
      on: { click: () => void pv.forget(vaultId).then(forgotten, (e: unknown) => failed(passkeyMessage(e))) },
    });
    if (place === "other") {
      // Never offered here: this address may only claim the vault's id.
      card.append(
        h("h2", { text: t("Remembered for another address") }),
        h("p", { class: "hint", text: t("A key for a vault with this id is remembered on this device for {remembered}, not for {here}. Any server can claim a vault's id, so the passkey is not offered here. If you trust this address, paste the key; remembering it here replaces the other.", { remembered: describeLocation(record.location), here: describeLocation(location) }) }),
        h("div", { class: "row" }, forget));
      card.removeAttribute("hidden");
      return;
    }
    const button = h("button", { text: t("Unlock with passkey"), attrs: { type: "button" } });
    button.addEventListener("click", () => {
      button.disabled = true;
      button.textContent = t("Waiting for the passkey…");
      // `unlock` reports its own failures (the vault refused the key); the rest are the passkey's.
      let reported = false;
      const use = (identity: string) => unlock(identity).catch((e: unknown) => {
        reported = true;
        throw e;
      });
      pv.unlock(vaultId, location, use).catch((e: unknown) => {
        if (!reported) failed(passkeyMessage(e));
      });
    });
    const where = t("For {place}.", { place: describeLocation(location) });
    card.append(
      h("h2", { text: t("Remembered on this device") }),
      h("div", { class: "row" }, button, forget),
      h("p", { class: "hint", text: t("{where} Since {date}. The key is stored encrypted; only your passkey (with your PIN, fingerprint or face) can open it. Forget this key removes it from this browser; delete the passkey in your passkey manager too.", { where, date: formatDate(record.created) }) }));
    card.removeAttribute("hidden");
    button.focus();
  }, (e: unknown) => {
    card.append(h("p", { class: "error", text: passkeyMessage(e) }), h("button", {
      text: t("Forget this key"), class: "secondary", attrs: { type: "button" },
      on: { click: () => void pv.forget(vaultId).then(forgotten, (err: unknown) => failed(passkeyMessage(err))) },
    }));
    card.removeAttribute("hidden");
  });
  return card;
}

/** The opt-in checkbox of the paste form; off by default. */
export function rememberOption(): { element: HTMLElement; checked: () => boolean } {
  const box = h("input", { attrs: { type: "checkbox" } });
  const note = h("span", { class: "hint" });
  const element = h("label", { class: "check" }, box, ` ${t("Remember this key on this device with a passkey")}`, note);
  if (!passkeyVault()) {
    box.disabled = true;
    note.textContent = ` ${t("(this browser has no passkeys here: it needs WebAuthn over HTTPS)")}`;
  } else {
    void browserReportsPRF().then((prf) => {
      if (prf === false) {
        box.disabled = true;
        box.checked = false;
        note.textContent = ` ${t("(this browser cannot: its passkeys lack the PRF extension)")}`;
      }
    });
  }
  return { element, checked: () => box.checked && !box.disabled };
}

/**
 * After a pasted key unlocked the vault with the box ticked: one button
 * creates the passkey (a fresh click, which browsers require). `done` runs
 * once whatever happens, so the vault opens either way: "Not now" while the
 * browser's passkey prompt is still open finishes the screen, and the
 * prompt's answer then changes nothing.
 */
export function rememberScreen(pv: PasskeyVault, identity: string, vaultId: string, location: string, vaultName: string,
  done: () => void): HTMLElement {
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    done();
  };
  const status = h("p", { attrs: { role: "status" } });
  const create = h("button", { text: t("Create passkey"), attrs: { type: "button" } });
  const skip = h("button", { text: t("Not now"), class: "secondary", attrs: { type: "button" }, on: { click: finish } });
  create.addEventListener("click", () => {
    create.disabled = true;
    status.className = "";
    status.textContent = t("Waiting for the passkey…");
    pv.remember(identity, vaultId, location, vaultName).then(finish, (e: unknown) => {
      if (finished) return;
      create.disabled = false;
      status.className = "error";
      status.textContent = passkeyMessage(e);
      skip.textContent = t("Continue without");
    });
  });
  const screen = h("div", { class: "welcome" },
    h("h1", { text: t("Remember this key") }),
    h("div", { class: "card" },
      h("p", { text: t("Your browser or password manager creates a passkey for this viewer. The key is encrypted with a secret only that passkey can produce, after it verifies you, and only the encrypted copy is kept in this browser, for {place} only.", { place: describeLocation(location) }) }),
      h("p", { class: "hint", text: t("If your passkeys sync (iCloud Keychain, Google Password Manager, a password manager), the passkey syncs, but the encrypted key stays in this browser: other devices still need the key pasted once. Anyone who can run code in this page while you unlock could read the key, as with a pasted key.") }),
      status,
      h("div", { class: "row" }, create, skip)));
  queueMicrotask(() => create.focus());
  return screen;
}
