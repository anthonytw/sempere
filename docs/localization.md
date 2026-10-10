# Localization

The app's interface is localized with String Catalogs (`.xcstrings`). English (`en`) is the
development language; **Spanish (`es`) is complete**; other languages are welcome
(see [Adding a language](#adding-a-language)). Task L in `docs/attachments.md` §14.

Scope: interface text only.

- **Note content is never translated or touched**, and neither is anything the app *writes into a
  vault* (note titles, notebook and tag names, transcript text). The default voice-note notebook is stored
  data, so it stays English on every device: a notebook whose name changed with the device language
  would split in two when a vault is shared between devices. A new note's default title is the date
  (and time) in the device's own date format: it is a title, never a key, so nothing splits.
  Only how the app *displays* an empty title (a placeholder) is localized.
- **The CLI's messages stay English** (`Sources/` is Foundation + swift-crypto only and is shared with
  Linux). The app shows its own localized sentence and, where it adds detail from a library error,
  appends that error's English text after it (for example “Could not open the vault: …”).
- Strings that must not be translated (the product name “Sempere”, file extensions, key prefixes such
  as `age1pq1…`, keyboard-shortcut glyphs) are written with `Text(verbatim:)` or are not strings in a
  localizing position.

## Files

| File | Holds |
| --- | --- |
| `Apps/Sempere/Localization/Localizable.xcstrings` | every interface string of the app, the quick-capture intents and the widget extension |
| `Apps/Sempere/Localization/InfoPlist.xcstrings` | permission prompts (microphone, camera, Face ID, speech) and the exported document type names |
| `web/src/i18n/catalog.ts` | every interface string of the web viewer (`docs/web-viewer.md` "Languages"; see [Web viewer](#web-viewer)) |

`Localization/` is a folder-synchronized group of **both** the app and the `SempereWidgets` targets
(the intents in `SempereShared` are compiled into both), so one catalog serves both bundles.
`SempereInfo.plist` and `project.pbxproj` list `es` in `knownRegions`.

## How strings get in

| Where | What to write |
| --- | --- |
| SwiftUI views: `Text`, `Button`, `Label`, `Toggle`, `Section`, `Picker`, `TextField` prompt, `.navigationTitle`, `.alert`, `.confirmationDialog`, `.help`, `.accessibilityLabel`… | the English **literal**: it is a `LocalizedStringKey` and is looked up automatically |
| A `String` that is built in code and shown later (`var title: String`, `errorMessage`, a menu title, an `NSItemProvider` name, a `UIAlertController`, a share-sheet subject…) | `String(localized: "…")` at the point where the text is *defined*. `Text(someString)` never localizes: the string must already be localized |
| A parameter typed for display | prefer `LocalizedStringResource` (App Intents require it); convert with `String(localized: resource)` |
| Stored or technical text (raw values, `UserDefaults` keys, file names, log lines, debug output, `systemImage:` names, vault data) | leave as is |

Rules:

1. **The key is the English text**, interpolations included (`"\(count) notes"` has the key
   `%lld notes`). Use the same words in every place that means the same thing, so one catalog entry
   serves all of them.
2. **Never build a sentence from translated fragments** (`a + " " + b`): word order differs. Write the
   whole sentence with interpolations, and interpolate *values* (a name, a number), not phrases.
3. **Every count is a plural.** Any text whose wording depends on a number has `one` / `other`
   variations in English and `one` / `many` / `other` in Spanish (CLDR: `many` is for millions, “1 000 000
   **de** notas”). Interpolated integers are `%lld`. A sentence with two counts is reworded or split so
   that each count is its own localized string.
4. **Device variations** (`variations.device`: `iphone`, `ipad`, `mac`, `other`) where the wording
   differs: “Tap” on an iPad, “Click” on a Mac; “Pencil” gestures; “Files app” vs “Finder”. Gate by
   catalog, not by `Platform.isMac` in code.
5. Add a **comment** for short or ambiguous strings (“Open”, “Paper”, “Pen”) saying where they
   appear and which part of speech they are (`Text("Open", comment: "Button: open a vault")`,
   `String(localized: "Open", comment: "…")`).
6. Enum `rawValue`s that are stored never change; add a separate localized `title`.
7. Multiple interpolations that Spanish reorders use positional specifiers in the translation
   (`%2$@ … %1$lld`).
8. Dates, numbers and sizes use `Date.FormatStyle`, `Measurement`, `ByteCountFormatter` and
   `FormatStyle`s so the locale formats them; never a fixed `dateFormat`.

`LocalizationCatalogTests` (runs in `swift test`, on Linux too) lists every literal in `Apps/` that the
catalog does not know and every entry without a Spanish value or plural variations, and fails the build.
It sees literals in localizing positions (`Text(…)`, `String(localized:)`, …) and the known bypasses
(`errorMessage = "…"`, `message:`, `Text(verbatim:)`); a `String` built elsewhere and shown later still
needs `String(localized:)` by hand. A plural is only needed where the *translation* changes with the
number: a sentence whose verb or noun agrees with a count is reworded around it (“sin listar: 3”) or
made plural; a `%lld` that only shows a position (“Página 3 de 10”) is not.

## Spanish glossary

Variant: neutral Spanish following Apple's own Spanish (Spain) interface terms, addressing the reader
as *tú* (infinitive or imperative for buttons: “Cancelar”, “Añadir una página”). A regional file
(`es-419`) can later override only the words that differ (Ajustes / Configuración, Rotulador /
Marcador).

| English | Spanish | Notes |
| --- | --- | --- |
| note | nota | |
| notebook | cuaderno | a `/` path of notes; not “libreta” |
| tag | etiqueta | |
| page | página | |
| vault | bóveda | the encrypted folder of notes |
| key (age identity) | clave | “clave de la bóveda”; never “llave” |
| recovery kit | kit de recuperación | |
| passphrase | frase de contraseña | |
| password | contraseña | |
| recipient | destinatario | a public key that can read the vault |
| device | dispositivo | |
| Keychain | Llavero | Apple's term; Face ID, Touch ID, iCloud Drive, Finder, Apple Pencil stay as they are; Files is Apple’s Spanish name “Archivos” |
| unlock / lock | desbloquear / bloquear | |
| library | biblioteca | the list of vaults |
| sidebar | barra lateral | |
| Settings | Ajustes | |
| Done / Cancel / OK | Listo / Cancelar / Aceptar | |
| Delete / Remove | Eliminar / Quitar | Delete destroys data; Remove detaches |
| Move to Recently Deleted | Mover a Eliminadas recientemente | |
| Rename | Renombrar | |
| Add / New | Añadir / Nueva (nota) / Nuevo (cuaderno) | agree in gender |
| Open / Close | Abrir / Cerrar | |
| Save / Restore | Guardar / Restaurar | |
| Share / Export / Import | Compartir / Exportar / Importar | |
| Search | Buscar | |
| stroke / ink | trazo / tinta | |
| pen / pencil / marker / highlighter | bolígrafo / lápiz / rotulador / resaltador | |
| eraser (object, pixel) | borrador (de objetos, de píxeles) | |
| lasso / ruler | lazo / regla | |
| paper | papel | kinds: en blanco, rayado, cuadriculado, punteado… |
| handwriting | escritura a mano | |
| recognize / recognition | reconocer / reconocimiento | |
| history | historial | |
| version | versión | “Guardar versión” |
| checkpoint | punto de control | |
| session (editing) | sesión | |
| recording | grabación | |
| transcript / transcribe | transcripción / transcribir | |
| voice note | nota de voz | |
| attachment | adjunto | |
| image / photo / PDF | imagen / foto / PDF | |
| text box | cuadro de texto | |
| inbox | bandeja de entrada | the vault's quick-capture folder |
| sync | sincronización | “sincronizar” |
| thin / thinning (history) | reducir / reducción (del historial) | |
| zoom / fit width / actual size | zoom / ajustar al ancho / tamaño real | |
| passkey | llave de acceso | Apple's Spanish term; a vault's *key* stays “clave”, never “llave” |
| device list | lista de dispositivos | the vault's recipients |
| viewer (web) | visor | “Visor de Sempere” |
| video / clip | vídeo | with the accent, as in the app; not “clip” |
| layout (paged / infinite) | disposición (paginada / infinita) | |

Tone: short, plain, no exclamation marks except where English has them. Keep ellipses (`…`) and
curly quotes (`“ ”` become `« »` only inside running Spanish text where English quotes a *name*; use
`“ ”` again for values the user typed, as Apple does). Spanish needs roughly 1.3× the room of English:
the pseudo-language check below uses 2×.

## Web viewer

The web viewer (`web/`, `docs/web-viewer.md` "Languages") follows the same scope, glossary and tone;
its catalog is `web/src/i18n/catalog.ts`, in TypeScript, because the page has no String Catalog
tooling. The differences from the app:

- The language is the first supported one of `navigator.languages`, with a **Language** selector
  (“Automatic”, “English”, “Español”) that overrides it and is remembered in the browser.
- Keys are the English text, as in the app; `{name}` replaces `%@` and `{count}` replaces `%lld`.
  Counts are entries with `en` (one/other) and `es` (one/many/other) forms and are read with `tn`.
  `t` and `tn` take typed keys, so an unknown key does not compile.
- Notebook, tag and note names, recording titles and transcripts are vault data and stay as written;
  messages from deep library errors stay English, and the errors a person meets have their own
  sentence (`web/src/ui/errors.ts`).
- `web/test/i18n.test.ts` replaces `LocalizationCatalogTests` for the web: every key has Spanish and
  its plural forms, placeholders agree, the glossary holds, every `t` key exists and is used, and no
  `src/ui` code shows an English literal. `web/scripts/smoke-language.mjs` runs it in a browser.
- Adding a language: see the end of `docs/web-viewer.md` "Languages".

## Checking layouts

- CI runs `scripts/app.sh pseudo` on an iPad simulator in the `app` job (`SEMPERE_PSEUDO_DEVICE=iPhone`
  runs it at phone width, by hand).
- `scripts/app.sh pseudo` runs the UI test `PseudoLanguageUITests` on the simulator three times: with
  the **double-length** pseudo-language (`-NSDoubleLocalizedStrings YES`), with the **right-to-left**
  pseudo-language (`-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`) and in Spanish
  (`-AppleLanguages (es)`), walking the main screens of the demo vault (library, locked, note, tags, paper picker and, through `SEMPERE_DEMO_SETTINGS`, Settings). It fails when a control or label
  leaves the window or a single-line label is cut off, and attaches a screenshot of every screen.
- `LocalizationCatalogTests` also fails if a Spanish string is more than twice as long as its English
  source for short strings (under 40 characters) — the budget the double-length check proves the
  layouts can take.
- When a view clips in Spanish, fix the layout (`.fixedSize(horizontal: false, vertical: true)`,
  `lineLimit(nil)`, `ViewThatFits`, a flexible `Spacer`), not the translation.

## Adding a language

See [CONTRIBUTING.md](../CONTRIBUTING.md#adding-a-language) for the short version.

1. Open `Apps/Sempere/Localization/Localizable.xcstrings` and `InfoPlist.xcstrings` in Xcode 26
   (**Project ▸ Sempere ▸ Info ▸ Localizations ▸ +**), or add the language code by hand as below.
2. Translate every entry. Plurals need the variations of your language's CLDR categories
   (<https://www.unicode.org/cldr/charts/latest/supplemental/language_plural_rules.html>); keep
   `%lld`, `%@` and `%1$@` specifiers, and do not translate “Sempere”.
3. Add the language code to `knownRegions` in `Apps/Sempere/Sempere.xcodeproj/project.pbxproj`.
4. Add a glossary section for the language to this file (fix the term for *vault*, *notebook*, *tag*
   before translating, then use it everywhere).
5. `swift test --filter LocalizationCatalogTests` must pass with the language added to the test's
   `languages` (and, if needed, `pluralCategories`), and
   `scripts/app.sh pseudo` should show no clipping in a language of similar length.
6. Open a pull request; the maintainer (or a native-speaking reviewer) checks the glossary.

## Tooling

`scripts/l10n.py` (Python 3, standard library only, development tool — not part of the build):

| Command | What it does |
| --- | --- |
| `merge [--table T] FRAGMENT.json…` | merge hand-written fragments (key → `en`/`es` values, plural and device forms) into the catalog (`Localizable`, or `InfoPlist` / `AppShortcuts`) |
| `format` | rewrite the catalogs the way Xcode writes them |

Checking is `LocalizationCatalogTests` (above), not the script.
