// The language choice (docs/web-viewer.md "Languages"): "Automatic" follows the browser's list of
// languages; English and Spanish can be chosen. The choice is remembered in this browser.

import { choosePreference, isPreference, languageNames, locale, locales, storedPreference, t } from "../i18n/index.ts";
import { h } from "./dom.ts";

/**
 * A language selector. Choosing applies and remembers the choice, then runs `changed` so the
 * screen that holds it draws itself again in the new language.
 */
export function languagePicker(changed: () => void): HTMLElement {
  const preference = storedPreference();
  const select = h("select", { attrs: { "aria-label": t("Language") } },
    h("option", { text: t("Automatic"), attrs: { value: "auto" } }),
    // Each language in its own language, so it can be found whatever the interface says.
    ...locales.map((l) => h("option", { text: languageNames[l], attrs: { value: l } })));
  select.value = preference;
  select.addEventListener("change", () => {
    const v = select.value;
    if (!isPreference(v)) return;
    choosePreference(v);
    changed();
  });
  return h("label", { class: "language", title: `${t("Language")}: ${languageNames[locale()]}` }, `${t("Language")} `, select);
}
