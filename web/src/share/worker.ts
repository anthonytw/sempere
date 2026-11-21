// scrypt off the page's thread. A share file is one self-contained page, so the worker is the page's own script
// run again from a `blob:` URL (the entry point tells the two apart by the absence of `document`), created
// through the one Trusted Types policy the CSP allows, `sempere-share-worker`, which admits only `blob:` URLs.
// Where a browser refuses the worker (some `file:` pages), the work runs on the page's thread behind the
// "Decrypting…" screen.

import { ShareOpenError, type ShareOpenErrorCode, decryptShare } from "./open.ts";

export interface WorkerRequest {
  armored: string;
  passphrase: string;
}

export type WorkerReply = { plain: Uint8Array } | { error: ShareOpenErrorCode | "failed" };

/** Runs in the worker: one request in, one reply out. */
export function serve(scope: {
  onmessage: ((e: MessageEvent<WorkerRequest>) => void) | null;
  postMessage(message: WorkerReply, transfer?: Transferable[]): void;
}): void {
  scope.onmessage = (e) => {
    decryptShare(e.data.armored, e.data.passphrase).then(
      (plain) => scope.postMessage({ plain }, [plain.buffer]),
      (err: unknown) => scope.postMessage({ error: err instanceof ShareOpenError ? err.code : "failed" }));
  };
}

interface TrustedTypesLike {
  createPolicy(name: string, rules: { createScriptURL(url: string): string }): { createScriptURL(url: string): unknown };
}

let policy: { createScriptURL(url: string): unknown } | undefined;

function startWorker(source: string): Worker {
  const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
  const tt = (globalThis as { trustedTypes?: TrustedTypesLike }).trustedTypes;
  policy ??= tt?.createPolicy("sempere-share-worker", {
    createScriptURL: (u: string) => {
      if (!u.startsWith("blob:")) throw new TypeError("unexpected worker URL");
      return u;
    },
  });
  try {
    return new Worker((policy ? policy.createScriptURL(url) : url) as string, { name: "sempere share" });
  } finally {
    // The worker has fetched its script by the time the constructor returns the object's first message.
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
}

/**
 * The payload bytes of `armored` under `passphrase`. `source` is this page's script, for the worker; without it
 * (or when the worker cannot start) the work runs here.
 */
export function openShare(armored: string, passphrase: string, source: string | undefined): Promise<Uint8Array> {
  if (!source || typeof Worker === "undefined") return decryptShare(armored, passphrase);
  let worker: Worker;
  try {
    worker = startWorker(source);
  } catch {
    return decryptShare(armored, passphrase);
  }
  return new Promise((resolve, reject) => {
    let answered = false;
    worker.onmessage = (e: MessageEvent<WorkerReply>) => {
      answered = true;
      worker.terminate();
      const r = e.data;
      if ("plain" in r) resolve(r.plain);
      else if (r.error === "failed") reject(new Error("failed"));
      else reject(new ShareOpenError(r.error, r.error));
    };
    worker.onerror = (e) => {
      e.preventDefault();
      worker.terminate();
      if (answered) return;
      // The worker never started (a `file:` page, a policy): do it here. A worker that died while working is
      // indistinguishable; an out-of-memory tab fails here too, and the page says so.
      decryptShare(armored, passphrase).then(resolve, reject);
    };
    worker.postMessage({ armored, passphrase } satisfies WorkerRequest);
  });
}
