// Interface language of the viewer (docs/web-viewer.md "Languages"), the web
// counterpart of the app's String Catalog (docs/localization.md): English is
// the development language and every key is its English text; Spanish is
// complete. Only the viewer's own interface is translated. Anything that comes
// from a vault (note titles, notebook and tag names, recording titles,
// transcripts) is shown as written, and technical messages from deep library
// errors stay English, as the CLI's do.

import { catalog } from "./catalog.ts";

export const locales = ["en", "es"] as const;
export type Locale = (typeof locales)[number];

/** Each language in its own language (never translated, so it can always be found). */
export const languageNames: Record<Locale, string> = { en: "English", es: "Español" };

/** A language choice: `auto` follows the browser's language list. */
export type Preference = Locale | "auto";

type Catalog = typeof catalog;
/** CLDR plural categories used by the supported languages (`many` is Spanish for millions). */
export interface Plural {
  one: string;
  other: string;
  many?: string;
}
/** Keys of entries with plural forms: the key is the `other` form, with `{count}`. */
export type PluralKey = { [K in keyof Catalog]: Catalog[K] extends { en: Plural } ? K : never }[keyof Catalog];
export type TextKey = Exclude<keyof Catalog, PluralKey>;
export type Args = Record<string, string | number>;

const storageKey = "sempere-viewer-language";

let current: Locale = "en";
let rules = new Intl.PluralRules("en");

export function locale(): Locale {
  return current;
}

/** A supported language for a BCP 47 tag (`es-MX` is `es`), if any. */
export function matchLocale(tag: string): Locale | undefined {
  const primary = tag.toLowerCase().split(/[-_]/)[0];
  return locales.find((l) => l === primary);
}

/** The first supported language of the browser's list, in the user's order; English when none. */
export function detectLocale(languages: readonly string[]): Locale {
  for (const tag of languages) {
    const l = matchLocale(tag);
    if (l) return l;
  }
  return "en";
}

export function isPreference(v: unknown): v is Preference {
  return v === "auto" || (typeof v === "string" && (locales as readonly string[]).includes(v));
}

/** The remembered choice (`auto` when none, or when storage is unavailable or holds something else). */
export function storedPreference(): Preference {
  try {
    const v = localStorage.getItem(storageKey);
    return isPreference(v) ? v : "auto";
  } catch {
    return "auto";
  }
}

/** Remembers the choice in this browser (a per-viewer convenience: nothing depends on it). */
export function storePreference(p: Preference): void {
  try {
    if (p === "auto") localStorage.removeItem(storageKey);
    else localStorage.setItem(storageKey, p);
  } catch {
    // Private windows and blocked storage: the choice lasts until the page is closed.
  }
}

/** The language for a choice: the choice itself, or the browser's for `auto`. */
export function resolve(p: Preference, languages: readonly string[]): Locale {
  return p === "auto" ? detectLocale(languages) : p;
}

function browserLanguages(): readonly string[] {
  if (typeof navigator === "undefined") return [];
  return navigator.languages?.length ? navigator.languages : navigator.language ? [navigator.language] : [];
}

/** Switches the interface language (and the page's `lang` and title). */
export function setLocale(l: Locale): void {
  current = l;
  rules = new Intl.PluralRules(l);
  if (typeof document !== "undefined") {
    document.documentElement.lang = l;
    document.title = t("Sempere viewer");
  }
}

/** Applies the stored choice, or the browser's languages: call once before the first screen. */
export function initLocale(): void {
  setLocale(resolve(storedPreference(), browserLanguages()));
}

/** Applies and remembers a choice. */
export function choosePreference(p: Preference): void {
  storePreference(p);
  setLocale(resolve(p, browserLanguages()));
}

function fill(text: string, args: Args | undefined): string {
  if (!args) return text;
  return text.replace(/\{(\w+)\}/g, (whole, name: string) => {
    const v = args[name];
    return v === undefined ? whole : String(v);
  });
}

/** The text for `key` in the current language, with `{name}` placeholders filled from `args`. */
export function t(key: TextKey, args?: Args): string {
  if (current === "en") return fill(key, args);
  const entry: { es: string } = catalog[key];
  return fill(entry.es, args);
}

/** A count's text: the plural form for `count` (available as `{count}`, with the other `args`). */
export function tn(key: PluralKey, count: number, args?: Args): string {
  const entry: { en: Plural; es: Plural } = catalog[key];
  const forms = current === "en" ? entry.en : entry.es;
  const category = rules.select(count) as keyof Plural;
  return fill(forms[category] ?? forms.other, { ...args, count: count.toLocaleString(current) });
}

/** Every key with its English text, for the catalog test and tooling. */
export function entries(): [string, { en?: Plural; es: string | Plural }][] {
  return Object.entries(catalog);
}
