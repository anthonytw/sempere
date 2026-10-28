// Bounded gunzip with the platform's DecompressionStream (no third-party
// inflate). format.md §9: a revision is at most 256 MiB after gunzip.

export const defaultMaxOutput = 256 * 1024 * 1024;

export class GzipError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GzipError";
  }
}

/**
 * Decompresses one gzip member. Fails on corrupt or truncated input, and
 * stops reading (instead of allocating) once the output passes `maxOutput`.
 * Browsers reject bytes after the member (Compression Streams spec).
 */
export async function gunzip(data: Uint8Array, maxOutput = defaultMaxOutput): Promise<Uint8Array> {
  if (data.length === 0) throw new GzipError("empty gzip data");
  const stream = new Blob([data as Uint8Array<ArrayBuffer>]).stream().pipeThrough(new DecompressionStream("gzip"));
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > maxOutput) {
        await reader.cancel();
        throw new GzipError(`decompressed data larger than ${maxOutput} bytes`);
      }
      chunks.push(value);
    }
  } catch (e) {
    if (e instanceof GzipError) throw e;
    throw new GzipError(`corrupt gzip data: ${e instanceof Error ? e.message : String(e)}`);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}
