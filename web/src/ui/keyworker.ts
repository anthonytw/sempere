// The key worker: scrypt for a passphrase-wrapped key (src/vault/keyfile.ts)
// off the page's thread, so the page stays responsive for the second or more
// it takes (up to 1 GiB of memory at work factor 20). One message in, one
// out; the page terminates the worker after it, which frees that memory.

import { KeyFileError, unwrapKey } from "../vault/keyfile.ts";

export interface KeyWorkerRequest {
  file: Uint8Array;
  passphrase: string;
}

export type KeyWorkerReply = { identity: string } | { error: { code: string; message: string } };

const scope = globalThis as unknown as {
  onmessage: ((e: MessageEvent<KeyWorkerRequest>) => void) | null;
  postMessage(message: KeyWorkerReply): void;
};

scope.onmessage = (e) => {
  const { file, passphrase } = e.data;
  unwrapKey(file, passphrase).then((identity) => scope.postMessage({ identity }), (err: unknown) => {
    scope.postMessage({ error: err instanceof KeyFileError ? { code: err.code, message: err.message }
      : { code: "failed", message: err instanceof Error ? err.message : String(err) } });
  });
};
