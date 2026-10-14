// Browser smoke test of the viewer's languages (docs/web-viewer.md "Languages"), not part of
// `npm test`: serves dist/ and a vault on one origin and drives the viewer in Chromium with
// Playwright. Checks:
//   - the language follows the browser's language list (es → Spanish, fr → English fallback,
//     the first supported language of the list wins) and sets <html lang>;
//   - the language selector overrides it, the choice survives a reload, and "Automatic" goes back;
//   - after unlocking, the interface is Spanish while the vault's own text (note titles, notebook
//     and tag names) is shown exactly as written, and the CSP still allows the page to run;
//   - switching the language with a vault open redraws the screen and keeps the open note.
// Usage: node scripts/smoke-language.mjs VAULT_DIR KEY_FILE (CI: test/fixtures/render.sempere, which has notebooks and tags)
import { readFileSync } from "node:fs";
import { launchChromium, serveVault, unlocked } from "./smoke-lib.mjs";

const [vaultDir, keyFile] = process.argv.slice(2);
const { base, close } = await serveVault({ mounts: [{ prefix: "/static/", vaultDir }] });
const key = readFileSync(keyFile, "utf8");

let failures = 0;
const check = (ok, what) => { console.log(ok ? "ok  " : "FAIL", what); if (!ok) failures++; };

const browser = await launchChromium();
const newPage = async (locale, languages) => {
  const ctx = await browser.newContext({ locale, viewport: { width: 1300, height: 800 } });
  if (languages) await ctx.addInitScript((l) => Object.defineProperty(navigator, "languages", { get: () => l }), languages);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("404")) errors.push(m.text()); });
  return { ctx, page, errors };
};
const heading = (page) => page.locator("h1").first().textContent();
const lang = (page) => page.evaluate(() => document.documentElement.lang);

// 1. The browser's languages.
for (const [locale, languages, want, wantLang] of [
  ["es-ES", undefined, "Visor de Sempere", "es"],
  ["en-US", undefined, "Sempere viewer", "en"],
  ["fr-FR", ["fr-FR", "fr"], "Sempere viewer", "en"],
  ["fr-FR", ["fr-FR", "es-MX", "en"], "Visor de Sempere", "es"],
]) {
  const { ctx, page, errors } = await newPage(locale, languages);
  await page.goto(`${base}/`);
  await page.locator("h1").first().waitFor();
  check((await heading(page)) === want && (await lang(page)) === wantLang, `${JSON.stringify(languages ?? locale)}: ${want}, <html lang=${wantLang}>`);
  check((await page.title()) === want, `${JSON.stringify(languages ?? locale)}: page title`);
  check(errors.length === 0, `${JSON.stringify(languages ?? locale)}: no page errors ${JSON.stringify(errors)}`);
  await ctx.close();
}

// 2. The selector overrides the browser, survives a reload, and Automatic goes back.
{
  const { ctx, page } = await newPage("es-ES");
  await page.goto(`${base}/`);
  await page.locator("input[type=url]").fill(`${base}/static/`);
  await page.locator("select.language, .language select").selectOption("en");
  check((await heading(page)) === "Sempere viewer" && (await lang(page)) === "en", "selector: English over a Spanish browser");
  check((await page.locator("input[type=url]").inputValue()) === `${base}/static/`, "selector: the typed URL is kept");
  await page.reload();
  check((await heading(page)) === "Sempere viewer", "selector: the choice survives a reload");
  await page.locator(".language select").selectOption("auto");
  check((await heading(page)) === "Visor de Sempere", "selector: Automatic follows the browser again");
  await page.locator(".language select").selectOption("es");
  await page.reload();
  check((await heading(page)) === "Visor de Sempere", "selector: Spanish chosen explicitly");
  await ctx.close();
}

// 3. A vault in Spanish: the interface translates, the vault's own text does not.
{
  const { ctx, page, errors } = await newPage("es-ES");
  await page.goto(`${base}/`);
  await page.locator("input[type=url]").fill(`${base}/static/`);
  await page.locator("form button[type=submit]").click();
  await page.locator("textarea").waitFor();
  check((await heading(page)) === "Desbloquear bóveda", "unlock screen in Spanish");
  await page.locator("textarea").fill(key);
  await page.locator("form:has(textarea) button[type=submit]").click();
  await page.locator(".note-list button.note").first().waitFor({ timeout: 30000 });
  await page.waitForFunction(() => /\d+ notas?( ·|$)/.test(document.querySelector(".status")?.textContent ?? ""), null, { timeout: 30000 });
  const chrome = await page.evaluate(() => ({
    lock: [...document.querySelectorAll(".topbar button")].map((b) => b.textContent),
    sidebar: [...document.querySelectorAll(".sidebar h3, .sidebar > ul > li .label")].map((e) => e.textContent),
    status: document.querySelector(".status")?.textContent,
    search: document.querySelector("input[type=search]")?.getAttribute("placeholder"),
  }));
  check(chrome.lock.includes("Bloquear"), `Spanish top bar ${JSON.stringify(chrome.lock)}`);
  check(["Todas las notas", "Favoritas", "Cuadernos", "Etiquetas"].every((w) => chrome.sidebar.includes(w)), `Spanish sidebar ${JSON.stringify(chrome.sidebar)}`);
  check(/\d+ notas?/.test(chrome.status ?? ""), `Spanish status "${chrome.status}"`);
  check(chrome.search === "Buscar títulos, etiquetas y manuscritos", "Spanish search placeholder");
  // Vault data is shown as written, in both languages.
  const data = async () => page.evaluate(() => ({
    titles: [...document.querySelectorAll(".note-list .title")].map((e) => e.textContent).sort(),
    notebooks: [...document.querySelectorAll(".sidebar ul ul .label")].map((e) => e.textContent).sort(),
    tags: [...document.querySelectorAll(".sidebar li .label")].map((e) => e.textContent).filter((x) => x?.startsWith("#")).sort(),
  }));
  const es = await data();
  await page.locator(".note-list button.note").first().click();
  await page.locator(".page svg").first().waitFor({ timeout: 30000 });
  const openTitle = await page.locator(".note-header h2").textContent();
  // 4. Switching with the vault open redraws the screen and keeps the note and the search.
  const term = (openTitle ?? "").trim().split(/\s+/)[0];
  await page.locator("input[type=search]").fill(term);
  await page.waitForTimeout(400);
  const filtered = await page.locator(".note-list button.note").count();
  await page.locator(".topbar .language select").selectOption("en");
  await page.waitForFunction(() => document.querySelector(".topbar button.secondary:last-child")?.textContent === "Lock");
  await page.locator(".note-header h2").waitFor();
  await page.locator(".note-list button.note").first().waitFor();
  await unlocked(page);
  check(term.length > 0 && (await page.locator("input[type=search]").inputValue()) === term, `switching language keeps the search box's text "${term}"`);
  check((await page.locator(".note-list button.note").count()) === filtered, `the list stays filtered by it (${filtered} notes)`);
  await page.locator("input[type=search]").fill("");
  await page.waitForTimeout(400);
  const en = await data();
  check(JSON.stringify(es) === JSON.stringify(en) && es.titles.length > 0, `vault data identical in both languages (${es.titles.length} notes, ${es.notebooks.length} notebooks, ${es.tags.length} tags)`);
  // The notebook and tag names of the vault itself, as written: only the interface around them is translated.
  check(es.notebooks.length > 0 && es.tags.length > 0, "the vault has notebooks and tags to compare");
  check(es.notebooks.every((n) => !/cuaderno|nota/i.test(n ?? "")) && es.tags.every((n) => !/etiqueta/i.test(n ?? "")), `notebook and tag names untranslated ${JSON.stringify([...es.notebooks, ...es.tags])}`);
  check((await page.locator(".note-header h2").textContent()) === openTitle, "switching language keeps the open note");
  check((await page.locator(".sidebar h3").allTextContents()).includes("Notebooks"), "English sidebar after switching");
  check(errors.length === 0, `no page errors ${JSON.stringify(errors)}`);
  await ctx.close();
}
await browser.close();
close();
process.exit(failures ? 1 : 0);
