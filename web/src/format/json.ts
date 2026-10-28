// Strict JSON field readers that mirror Swift's `JSONDecoder` rules for the
// format's Codable types (Sources/Sempere/Model.swift): a required key must be
// present and of the right type, `decodeIfPresent` treats `null` like an
// absent key, numbers must be finite, integers integral.

/** A revision (or other file) whose JSON does not decode. */
export class DecodeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DecodeError";
  }
}

export type JSONObject = Record<string, unknown>;

export function fail(path: string, what: string): never {
  throw new DecodeError(`${path}: ${what}`);
}

export function isObject(v: unknown): v is JSONObject {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

export function obj(v: unknown, path: string): JSONObject {
  if (!isObject(v)) fail(path, "expected an object");
  return v;
}

export function arr(v: unknown, path: string): unknown[] {
  if (!Array.isArray(v)) fail(path, "expected an array");
  return v;
}

export function str(v: unknown, path: string): string {
  if (typeof v !== "string") fail(path, "expected a string");
  return v;
}

export function bool(v: unknown, path: string): boolean {
  if (typeof v !== "boolean") fail(path, "expected a boolean");
  return v;
}

/** A finite number (Swift rejects numbers it cannot represent). */
export function num(v: unknown, path: string): number {
  if (typeof v !== "number" || !Number.isFinite(v)) fail(path, "expected a number");
  return v;
}

/**
 * An integer. Swift decodes `Int` from any integral JSON number that fits 64
 * bits; this reader stops at ±2^53, beyond which JavaScript numbers are not
 * exact. Every integer the format defines (seq, layer, sizes) is below that.
 */
export function int(v: unknown, path: string): number {
  if (typeof v !== "number" || !Number.isSafeInteger(v)) fail(path, "expected an integer");
  return v;
}

/** The value of a required key. */
export function req(o: JSONObject, key: string, path: string): unknown {
  if (!Object.hasOwn(o, key)) fail(`${path}.${key}`, "missing");
  return o[key];
}

/** The value of an optional key; `null` reads as absent (`decodeIfPresent`). */
export function opt(o: JSONObject, key: string): unknown {
  if (!Object.hasOwn(o, key)) return undefined;
  const v = o[key];
  return v === null ? undefined : v;
}

/** Decodes an optional key with `f`, or returns undefined. */
export function optWith<T>(o: JSONObject, key: string, path: string, f: (v: unknown, path: string) => T): T | undefined {
  const v = opt(o, key);
  return v === undefined ? undefined : f(v, `${path}.${key}`);
}

/** Decodes a required key with `f`. */
export function reqWith<T>(o: JSONObject, key: string, path: string, f: (v: unknown, path: string) => T): T {
  return f(req(o, key, path), `${path}.${key}`);
}

/** Decodes every element of an array with `f`. */
export function arrayOf<T>(v: unknown, path: string, f: (v: unknown, path: string) => T): T[] {
  return arr(v, path).map((e, i) => f(e, `${path}[${i}]`));
}

const uuidPattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/** A UUID string in any case (Foundation's `UUID(uuidString:)`), returned lowercase. */
export function uuid(v: unknown, path: string): string {
  const s = str(v, path);
  if (!uuidPattern.test(s)) fail(path, "bad uuid");
  return s.toLowerCase();
}

/** True for a lowercase hyphenated UUID (a note directory name). */
export function isLowercaseUUID(s: string): boolean {
  return uuidPattern.test(s) && s === s.toLowerCase();
}

/**
 * Writers round to 3 decimals (format.md §5.6) as Swift's `InkJSON.round3`:
 * half away from zero; a value too large to scale is kept.
 */
export function round3(v: number): number {
  const scaled = v * 1000;
  if (!Number.isFinite(scaled)) return v;
  const r = Math.sign(scaled) * Math.round(Math.abs(scaled));
  return r / 1000 === 0 ? 0 : r / 1000;
}
