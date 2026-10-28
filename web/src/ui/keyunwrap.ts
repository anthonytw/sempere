// Runs the scrypt of a passphrase-wrapped key in a worker (src/ui/keyworker.ts),
// created through a Trusted Types policy that admits exactly that worker's URL
// (CSP `trusted-types sempere-key-worker`). Where workers are unavailable (unit
// tests) it runs in place.

import { KeyFileError, type KeyFileErrorCode, unwrapKey } from "../vault/keyfile.ts";
import type { KeyWorkerReply, KeyWorkerRequest } from "./keyworker.ts";
import workerURL from "./keyworker.ts?worker&url";

interface TrustedTypesLike {
  createPolicy(name: string, rules: { createScriptURL(url: string): string }): { createScriptURL(url: string): unknown };
}

let policy: { createScriptURL(url: string): unknown } | undefined;

function startWorker(): Worker {
  const url = new URL(workerURL, document.baseURI).href;
  const tt = (globalThis as { trustedTypes?: TrustedTypesLike }).trustedTypes;
  policy ??= tt?.createPolicy("sempere-key-worker", {
    createScriptURL: (u: string) => {
      if (u !== url) throw new TypeError("unexpected worker URL");
      return u;
    },
  });
  return new Worker((policy ? policy.createScriptURL(url) : url) as string, { name: "sempere key" });
}

const codes = new Set<string>(["notWrapped", "notPassphrase", "workFactor", "wrongPassphrase", "noKey"]);

/** The identity in a wrapped key file, unlocked with `passphrase` (never kept). */
export function unwrapKeyInWorker(file: Uint8Array, passphrase: string): Promise<string> {
  if (typeof Worker === "undefined" || typeof document === "undefined") return unwrapKey(file, passphrase);
  return new Promise((resolve, reject) => {
    const worker = startWorker();
    const done = () => worker.terminate();
    worker.onmessage = (e: MessageEvent<KeyWorkerReply>) => {
      done();
      const r = e.data;
      if ("identity" in r) resolve(r.identity);
      else reject(new KeyFileError(codes.has(r.error.code) ? r.error.code as KeyFileErrorCode : "noKey", r.error.message));
    };
    worker.onerror = (e) => {
      e.preventDefault();
      done();
      // Typically an allocation failure: scrypt at work factor 20 needs 1 GiB.
      reject(new KeyFileError("workFactor", "this browser could not derive the key from the passphrase (out of memory?). Try a desktop browser, or the CLI: sempere keys export"));
    };
    const request: KeyWorkerRequest = { file, passphrase };
    worker.postMessage(request);
  });
}
