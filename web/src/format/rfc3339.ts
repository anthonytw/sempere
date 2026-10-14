// RFC 3339 dates (format.md §6), as Sources/Sempere/RFC3339.swift: years
// 0001…9999, an optional 1–9 digit fraction truncated to milliseconds, `Z` or
// `±HH:MM`. Dates are integer milliseconds since 1970 in this code base.

/** `0001-01-01T00:00:00Z` in Unix milliseconds. */
export const earliestMillis = -62_135_596_800_000;
/** Just past `9999-12-31T23:59:59.999Z`. */
export const endMillis = 253_402_300_800_000;

function isLeap(y: number): boolean {
  return y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
}

function daysIn(month: number, year: number): number {
  if (month === 2) return isLeap(year) ? 29 : 28;
  return month === 4 || month === 6 || month === 9 || month === 11 ? 30 : 31;
}

function div(a: number, b: number): number {
  return Math.trunc(a / b);
}

/** Days since 1970-01-01 of a proleptic Gregorian date (Hinnant). */
export function daysFromCivil(year: number, month: number, day: number): number {
  const y = month <= 2 ? year - 1 : year;
  const era = div(y >= 0 ? y : y - 399, 400);
  const yoe = y - era * 400;
  const doy = div(153 * (month + (month > 2 ? -3 : 9)) + 2, 5) + day - 1;
  const doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy;
  return era * 146_097 + doe - 719_468;
}

function civil(days: number): [number, number, number] {
  const z = days + 719_468;
  const era = div(z >= 0 ? z : z - 146_096, 146_097);
  const doe = z - era * 146_097;
  const yoe = div(doe - div(doe, 1460) + div(doe, 36_524) - div(doe, 146_096), 365);
  const doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100));
  const mp = div(5 * doy + 2, 153);
  const d = doy - div(153 * mp + 2, 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  return [yoe + era * 400 + (m <= 2 ? 1 : 0), m, d];
}

/** Parses an RFC 3339 date to Unix milliseconds, or undefined. */
export function parseRFC3339(s: string): number | undefined {
  // Code units, not code points: any non-ASCII character fails a digit or
  // separator check below, as it does on the UTF-8 bytes in Swift.
  const n = new TextEncoder().encode(s);
  if (n.length < 20 || n.length > 35) return undefined;
  const number = (at: number, width: number): number | undefined => {
    if (at + width > n.length) return undefined;
    let v = 0;
    for (let i = at; i < at + width; i++) {
      const c = n[i] ?? 0;
      if (c < 0x30 || c > 0x39) return undefined;
      v = v * 10 + (c - 0x30);
    }
    return v;
  };
  const year = number(0, 4), month = number(5, 2), day = number(8, 2);
  const hour = number(11, 2), minute = number(14, 2), second = number(17, 2);
  if (year === undefined || month === undefined || day === undefined || hour === undefined
    || minute === undefined || second === undefined) return undefined;
  if (n[4] !== 0x2d || n[7] !== 0x2d || n[10] !== 0x54 || n[13] !== 0x3a || n[16] !== 0x3a) return undefined;
  if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1 || day > daysIn(month, year)
    || hour > 23 || minute > 59 || second > 59) return undefined;
  let i = 19;
  let millis = 0;
  if (n[i] === 0x2e) {
    i += 1;
    let digits = 0;
    while (i < n.length && (n[i] ?? 0) >= 0x30 && (n[i] ?? 0) <= 0x39) {
      if (digits < 3) millis = millis * 10 + ((n[i] ?? 0) - 0x30);
      digits += 1;
      i += 1;
    }
    if (digits < 1 || digits > 9) return undefined;
    for (let k = Math.min(digits, 3); k < 3; k++) millis *= 10;
  }
  let offset = 0;
  if (i >= n.length) return undefined;
  const c = n[i];
  if (c === 0x5a) {
    i += 1;
  } else if (c === 0x2b || c === 0x2d) {
    const oh = number(i + 1, 2), om = number(i + 4, 2);
    if (n.length !== i + 6 || n[i + 3] !== 0x3a || oh === undefined || om === undefined || oh > 23 || om > 59) {
      return undefined;
    }
    offset = (c === 0x2b ? 1 : -1) * (oh * 3600 + om * 60);
    i += 6;
  } else {
    return undefined;
  }
  if (i !== n.length) return undefined;
  const seconds = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset;
  const ms = seconds * 1000 + millis;
  if (ms < earliestMillis || ms >= endMillis) return undefined;
  return ms;
}

function pad(v: number, width: number): string {
  return String(v).padStart(width, "0");
}

/** `YYYY-MM-DDTHH:MM:SS.mmmZ`, as writers emit it. */
export function formatRFC3339(ms: number): string {
  const millis = ((ms % 1000) + 1000) % 1000;
  const seconds = (ms - millis) / 1000;
  const days = Math.floor(seconds / 86_400);
  const rest = seconds - days * 86_400;
  const [y, m, d] = civil(days);
  return `${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}T${pad(Math.floor(rest / 3600), 2)}:`
    + `${pad(Math.floor(rest / 60) % 60, 2)}:${pad(rest % 60, 2)}.${pad(millis, 3)}Z`;
}
