# Web viewer

A read-only viewer for Sempere vaults that runs entirely in the browser
(`web/`, TypeScript + Vite, no backend). It opens a vault folder of encrypted
files, decrypts them in the page with the key the user pastes, merges the
revisions into notes, and draws them. It never writes to the vault or to any
server. It keeps three things in the browser: a cache of the vault's
encrypted files, exactly as downloaded ("Opening fast" below); only
when asked, a key encrypted under a passkey ("Remembering the key with a
passkey"); and the interface language if one was chosen ("Languages");
nothing decrypted and never the key in the clear.

What it does:

- **Open** the vault the server configures (`config.json`, "Hosting"), or,
  without a configuration, a vault from an `http(s)` URL (a static file server with
  `sempere-index.json`, or a WebDAV share), from a folder picked with the File
  System Access API (Chrome, Edge), from `<input webkitdirectory>` (every
  browser), or from a folder dropped on the page.
- **Open fast**: the note list comes from the vault's published summaries
  (`sempere-summaries.sealed`, `format.md` §12) and the encrypted files are
  cached in the browser, so a later visit downloads and decrypts only what
  changed ("Opening fast").
- **Unlock** with the `AGE-SECRET-KEY-PQ-1…` identity, pasted as the bare line
  or the whole `age-keygen -pq` key file. Legacy (X25519) vaults are refused
  (`format.md` §3.3.2), as are classic `AGE-SECRET-KEY-1…` keys. Or with a
  passphrase: the vault's own passphrase-wrapped key file, or a recovery
  kit's passphrase-locked copy ("Unlocking with a passphrase"). Or, on a
  device where you chose to, with one passkey prompt (below).
- **Browse** notebooks (the `/` hierarchy of §5.4), tags (one spelling per tag
  key, §5.4.1), favorites and deleted notes; **search** titles, tags,
  notebooks and recognised handwriting (the same rules as the app's
  `NoteSearch`: case, accents and width ignored, every word must match,
  `#word` matches tags only), with a snippet and a jump to the matching page
  (the snippet quotes one part of the page, never an equation's LaTeX: a match
  only inside an equation shows "[equation]");
  and, when asked, the recordings' transcripts (the CLI's `search
  --transcripts` rules), with a jump to the recording and time ("Searching
  transcripts").
- **Read** a note: pages stacked vertically, or one tall infinite page, with
  pan and zoom (wheel or trackpad, Ctrl/⌘-wheel or pinch to zoom, drag,
  arrow keys, `+` `-` `0` `1`). Panning sideways is possible only while the page at the
  current zoom is wider than the viewport; a note that fits stays centred, so
  scrolling it with a trackpad or a finger (also in an iframe) only moves it
  vertically (`web/scripts/smoke-pan.mjs`). Pages are drawn as they come near the viewport and
  go back to a placeholder once a few screens away, so a long note keeps only the pages around
  the viewport in memory (`web/scripts/smoke-release.mjs`). Paper (every kind of §5.4.2, page-level paper,
  unknown kinds drawn blank) and ink are drawn by a port of `SempereRender`, so
  a page in the viewer is the SVG that `sempere export --format svg` writes.
- **Speak your language**: the interface is in English or Spanish, chosen from the browser's
  language list with an override in the page ("Languages" below).
- **Attachments** (§8, "Attachments" below): images, text boxes and PDF pages
  in their layers under the ink, placeholders for what cannot be drawn, and
  the note's recordings with a player and their transcripts.

## Remembering the key with a passkey

Opt-in, per vault and per browser. Under the key field, "Remember this key on
this device with a passkey" (off by default). When it is ticked and the pasted
key unlocks the vault, the viewer asks for a passkey ("Create passkey", a
fresh click because browsers allow WebAuthn only from one) and then opens the
vault; "Not now" or any failure opens it without remembering.

How (`web/src/vault/passkey.ts`):

1. `navigator.credentials.create` makes a passkey for the viewer's origin
   (RP ID: its host name), `userVerification: "required"`, `attestation:
   "none"`, with the WebAuthn **PRF** extension evaluated on a random 32-byte
   salt. Authenticators that evaluate PRF only on an assertion get one more
   prompt (`get`) right after.
2. The 32-byte PRF output goes through HKDF-SHA-256 (empty salt, info
   `sempere-viewer/2 passkey key-wrap` ‖ 0 ‖ L(vault id) ‖ L(location) ‖
   L(credential id), where L(x) is x's length as 32-bit big-endian then x) to
   an AES-256-GCM key, which encrypts the identity text with a random 96-bit
   nonce and additional data `sempere-viewer/2` ‖ 0 ‖ L(vault id) ‖
   L(location) ‖ L(credential id). The AES key is a non-extractable
   `CryptoKey`; neither it nor the PRF output is kept.
3. IndexedDB (database `sempere-viewer`, store `passkey-keys`, keyed by vault
   id, one record per vault) holds `{version: 2, vaultId, location,
   credentialId, salt, iv, ciphertext, created}`: nothing the key can be
   recovered from without the passkey. The vault id, the location and the
   date are readable by whoever reads that storage. The database is created
   by the first remembered key: looking for one on the unlock screen leaves
   none behind.

**The location.** `vault.json` is not authenticated until a key has opened
it, so any server can serve one with the id of a vault you remembered (and a
secret of its own, encrypted to your public key). A record is therefore bound
to where the vault was opened, not only to its id: the vault's normalised URL
(`HTTPSource.label`: no query, fragment or credentials, a trailing slash; a
different host, port or path is a different location), or `local:` for any
folder opened from this computer (picked by the user; its name is no
identity). The location is bound into the HKDF info and the AAD, so a record
edited to name another location does not decrypt. The passkey is offered only
at the record's own location: elsewhere the unlock screen says "Remembered for
another address", names it, and offers no passkey (paste the key; remembering
it there replaces the record). The same vault served at two addresses keeps
one record, for the address where it was last remembered.

Records written before the location existed (`version: 1`: info
`sempere-viewer/1 passkey key-wrap` ‖ 0 ‖ vault id ‖ 0 ‖ credential id, AAD
`sempere-viewer/1` ‖ 0 ‖ vault id ‖ 0 ‖ credential id) still open. The card
names the current address and says the key will be tied to it; once the
remembered key has unlocked the vault there, the record is sealed again as
version 2 for that location (same passkey, salt and date, a fresh nonce, no
second prompt). A version 1 record whose key does not open the vault at that
address stays as it was.

Next time, the unlock screen shows "Unlock with passkey": one prompt with the
stored credential id and salt (user verification required; the viewer also
checks the UV flag of the authenticator data), PRF, HKDF, AES-GCM decrypt, and
the identity goes to typage's `Decrypter` in memory as if it had been pasted.
A record that does not decrypt (another passkey, an altered or moved record)
or a key the vault no longer lists is an error that says to forget it and
paste the key. "Forget this key" deletes the record, and remembering the
vault's key again replaces it; either way, where the browser has the
WebAuthn Signal API the viewer tells the passkey provider the old credential is
gone (`signalUnknownCredential`), otherwise delete the passkey ("Sempere: <vault>")
in your passkey manager. Lock still reloads the page and keeps the record.

**No PRF, no remembering.** If the browser reports no PRF
(`getClientCapabilities`), the option is disabled with the reason; if the
passkey turns out to have none (`prf.enabled` false, or no PRF output), the
viewer says so, stores nothing and opens the vault. There is no fallback:
the key is never stored in plain, under a PIN or password the page could
guess offline, or under a key that IndexedDB itself holds. PRF needs a
current browser and a passkey provider that implements it (for example
current Chrome and Edge with Google Password Manager or a FIDO2 security key
with `hmac-secret`, Safari 18 or later with iCloud Keychain); support varies by
platform, which is why the viewer checks at run time. WebAuthn needs a secure
context: HTTPS, or `http://localhost`.

## Unlocking with a passphrase

A vault may keep its key locked with a passphrase (`format.md` §3.2:
`keys/<name>.key.age`, an age file with one scrypt recipient whose plaintext is
the identity file), and `sempere keys paper --passphrase` prints a recovery
kit whose QR code and text are the same kind of file, armored. The viewer opens
both (`web/src/vault/keyfile.ts`, `web/src/ui/passphrase.ts`):

- **The vault's stored key.** After `vault.json` is read, the viewer looks for
  `keys/<name>.key.age` of each current recipient (the name computed as the
  CLI does: `age1pq-` and the SHA-256 of the recipient string), as the CLI and
  the app offer only current recipients' key files. When one is there, the
  unlock screen shows "Unlock with your passphrase" (a choice of key when there
  are several). A file that is not a passphrase file is not offered.
- **A recovery kit's locked copy, or a key file.** The paste field takes the
  armored text (`-----BEGIN AGE ENCRYPTED FILE-----`, from the kit's QR code or
  typed from its lines; surrounding spaces, blank lines and CRLF are tolerated,
  and a damaged line says to check the kit's per-line checksums), and "Choose a
  key file…" takes a `.key.age` file (binary or armored) or a plain key file.
  A locked key shows a passphrase field.

The header is checked before any work: exactly one recipient, scrypt, work
factor at most 20 (`format.md` §3.2 lets readers stop there; 2^20 needs
1 GiB). Anything else is refused with its reason (a larger work factor points
to `sempere keys export`). Then typage's scrypt identity decrypts the file in a
**worker** (`web/src/ui/keyworker.ts`), so the page stays responsive for the
second or so it takes at the writers' work factors (15 to 18), and the
worker is terminated afterwards, which frees scrypt's memory; a worker that
dies (out of memory on a small device) is reported. The plaintext (at most
16 KiB, strict UTF-8) must hold one post-quantum identity, parsed like a pasted
key, and the identity must then unlock the vault as usual.

The passphrase is read from its field once, the field is cleared, and the
string goes to the worker in a message: it is never stored, logged, put in a
URL or sent, and neither is the decrypted key (held in memory like a pasted
one). With "Remember this key on this device with a passkey" ticked, what is
remembered is the **identity**, encrypted under the passkey as above, never the
passphrase; the next visit unlocks with the passkey alone.

The worker is a file of the viewer, created through a second Trusted Types
policy, `sempere-key-worker`, which admits exactly its URL (as
`sempere-pdf-worker` does for pdf.js), so the CSP keeps `worker-src 'self'`
and `require-trusted-types-for 'script'`.

## Languages

The viewer's interface is localized like the app's (`docs/localization.md`): English (`en`) is the
development language and **Spanish (`es`) is complete**. Only the interface is translated:

- **Vault data is shown as written**: note titles, notebook and tag names (the `/` hierarchy of
  §5.4), recording titles, transcripts and page text are never translated or altered. Only how the
  viewer *displays* an empty title ("Untitled") is localized.
- **The language** is the first supported one of `navigator.languages`, in the user's order (`es-MX`
  is `es`; a browser that lists none gets English), or the choice made with the **Language** selector
  ("Automatic", "English", "Español", each language in its own name). It is on the open and unlock
  screens and in the top bar. The choice is kept in this browser (`localStorage`, key
  `sempere-viewer-language`; nothing secret, and nothing depends on it: where storage is blocked it
  lasts until the page closes). It sets `<html lang>` and the page title, and dates, numbers and sizes
  follow it (`Intl`).
- **Changing the language redraws the screen** in the new one. The open note stays open and the search
  box keeps its text (the list is read again from the browser's cache); a URL typed on the open screen is kept; a key pasted on the
  unlock screen is not (it is never stored), so choose the language first.
- **Messages from deep inside the libraries** (a network failure, a parser's complaint about a
  damaged file) stay English, as the CLI's do. The errors a person is likely to meet (wrong key,
  wrong passphrase, a classic X25519 key, passkey refusals, a vault from a newer format) have their
  own sentence in each language (`src/ui/errors.ts`); where the English message carries detail the
  code does not, it follows the sentence in parentheses.
- **Words that must stay**: "Sempere", "WebDAV", file names, `AGE-SECRET-KEY-PQ-1…`, command names
  (`sempere vault index`) and the `1:1` button.

How (`web/src/i18n/`): `catalog.ts` holds every string, keyed by its English text (the app's way:
`{name}` marks a value); a count is an entry with `en` and `es` plural forms (English one/other,
Spanish one/many/other, `many` being for millions: "1 000 000 de notas") and is read with `tn(key,
count)`. `t(key, values)` and `tn` take **typed keys**, so a missing entry is a compile error. Never
build a sentence from translated pieces (word order differs), and give each count its own entry.
`test/i18n.test.ts` fails when a key lacks Spanish or a plural form, when a placeholder differs
between languages, when a Spanish text breaks the glossary ("bóveda", "cuaderno", "etiqueta", "frase
de contraseña", "llave de acceso" for a passkey, never "llave" for a vault key), when a `t` key is
unknown or unused, and when `src/ui` shows a literal English string without `t`.
`scripts/smoke-language.mjs` (Chromium) checks the choice, the override, a Spanish vault session and
the switch with a vault open.

To add a language, add its code to `locales` and `languageNames`, a column to every entry of
`catalog.ts` (and its plural categories to `Plural`), a glossary section to `docs/localization.md`,
and extend `i18n.test.ts`.

## Searching transcripts

The search box finds notes by titles, tags, notebooks and page text, as the
app does. Under it, "Also search recording transcripts" (off by default) adds
the recordings' transcripts (`format.md` §8.3.2), which live in encrypted
blobs: like `sempere search --transcripts`, ticking it reads every note that
is not deleted and decrypts every transcript blob, verified as any blob
(`web/src/ui/transcriptsearch.ts`), four notes at a time, with the progress
under the box ("Reading transcripts: 12 of 200 notes…", then "N transcripts
searched"). Encrypted files come from the browser's cache when they are there;
the decrypted transcripts are kept in the tab's memory until Lock, never
stored. A transcript that cannot be read (missing, failing verification, or
naming another recording) is listed by note and recording, as the CLI warns
about it; a note that cannot be read is counted.

Matches are the CLI's (`web/src/format/occurrences.ts`,
`web/src/format/phrasesearch.ts`, ports of `RecognitionSearch` in
`Sources/SempereCLI/Search.swift`): the trimmed query is one phrase, found in
each segment's text ignoring case and accents the way Foundation's
`range(of:options: [.caseInsensitive, .diacriticInsensitive])` does on Linux
(CFString's search): grapheme extenders ignored, a precomposed letter whose
decomposition starts below U+0510 matching its base (é matches e, が does not
match か), full case folding (ß matches ss, ﬁ matches fi, but a match never
splits one character's folding, so ß does not match s), no width folding
(Ａ does not match A); non-overlapping occurrences; the CLI's snippet (30
characters on each side, lines joined, `…` where cut). This differs from the
note search on purpose: the note search takes words, the transcript search
takes a phrase, as the CLI's `notes search` and `search` do.

Notes found by the note search come first, in its order; notes found only in
a transcript follow (by title, as the CLI sorts). Under each note, up to five
matching segments are listed with the recording's title, the time and the
snippet with the match marked; a click opens the note, opens its recording,
shows the transcript with that segment marked and scrolled into view, and cues
the audio at the segment's start (playing waits for Play). The other filters
(notebook, tag, favorites) apply to transcript matches as to the rest.

Each segment's folded text is made once, at the first search, so later
queries run the full matching only on segments that can contain the phrase.

## How it reads a vault

The code mirrors the Swift reader and is tested against it (see "Tests").

| Step | Where | Swift counterpart |
| --- | --- | --- |
| `vault.json`: format, recipients, legacy check | `web/src/vault/vault.ts` | `Vault.readManifest` |
| age decryption (MLKEM768-X25519 stanzas) | [typage](https://github.com/FiloSottile/typage) `age-encryption` 0.3.1 | `Age` |
| `SMPR` framing, HMAC-SHA256 tag under the vault secret (WebCrypto), previous secret during a rewrap | `vault.ts` | `BodyFraming`, `NoteStore.unframe` |
| bounded gunzip (`DecompressionStream`), strict UTF-8, JSON | `web/src/vault/gzip.ts` | `Gzip.decompress` |
| revision decoding with Swift's `Codable` rules; name and content must agree (§5) | `web/src/format/model.ts`, `ids.ts`, `rfc3339.ts`, `attachments.ts` | `Model.swift`, `Revision.swift`, `Attachments.swift` |
| merge: snapshots, uncovered deltas, LWW registers, tombstones, orphans, tag OR-set with legacy baseline, items and recordings | `web/src/format/reducer.ts`, `tags.ts`, `registers.ts` | `NoteReducer`, `AttachmentRegisters` |
| concurrent replacements of a stroke (`format.md` §5.6.1), checked against Swift by `Tests/SempereTests/Fixtures/concurrent-replacement-vectors.json` | `web/src/format/lineage.ts` | `StrokeLineage` |
| B-spline sampling, ribbons, monoline, paper ruling, page extent | `web/src/render/` | `SempereRender` |
| blobs: keyed name, streaming age decryption, `INKB` framing, padding, SHA-256 (§8.1) | `web/src/vault/blobs.ts` | `BlobStore`, `Blob.swift` |
| item order, frames, rotation, crops, orientation, placeholders (§8.2.3, §8.5.1–§8.5.2) | `web/src/render/items.ts`, `itemsvg.ts` | `Items.swift`, `PageComposer` |
| JPEG and PNG headers, metadata stripping (§8.2.5) | `web/src/render/images.ts` | `JPEG.swift`, `PNGDecoder.swift` |
| text lines: stored `breaks`, line metrics, alignment, direction (§8.5.3) | `web/src/render/text.ts` | `TextLayout.swift` |
| PDF pages (§8.2.6) | pdf.js 6.4.299 (`web/src/ui/pdf.ts`) | `SemperePDF`, Poppler / PDFKit |
| transcripts (§8.3.2) | `web/src/format/transcript.ts` | `Transcript` |
| newer format versions: `sempere/<major>`, revision markers, lenient decoding of newer revisions, bounded report (§7) | `web/src/format/newer.ts`, `model.ts`, `vault.ts` | `NewerContent.swift`, `Revision.swift` |

Typage 0.3.1 implements the age v1.3 hybrid recipient (`mlkem768x25519`,
HPKE with X-Wing) with `@noble/post-quantum`; the viewer has no cryptography
of its own beyond calling typage, WebCrypto (HMAC-SHA256, HKDF) and, for
signed secret links (`format.md` §2.1), `@noble/curves` 2.4.0 (Ed25519) and
`@noble/post-quantum` 0.7.1 (ML-DSA-65, `web/src/vault/link.ts`), both pinned
and pure JavaScript, so the CSP needs no WebAssembly or `eval`.

Unreadable revisions (wrong tag, undecryptable, undecodable) are reported in
the note view and the list ("N unreadable revisions", a "Problems" filter);
the note is shown merged from the rest, marked as such (§4: report, never
silently drop).

## Opening fast

A vault of a few hundred notes has a few thousand revision files, each a
post-quantum age file: fetching and decrypting all of them on every visit took
seconds. Three things make a visit fast:

1. **Published summaries** (`format.md` §12). `sempere-summaries.sealed` at
   the vault root holds each note's title, tags, notebook, flags, dates, page
   count and searchable text, with the names of the revision files it was made
   from, sealed (AES-256-GCM) under a key derived from the vault secret. The
   viewer reads it right after unlocking and shows the whole list at once,
   then checks the vault's listing: a note whose revision names equal its
   entry's is current (revision files are write-once, so the same names are
   the same content); any other note (new, edited, compacted, or without an
   entry) is decrypted as before, and an entry whose note is gone is dropped.
   The file is a hint: missing, stale, damaged or another vault's means only
   that more notes are decrypted, never an error. It is written by
   `sempere vault summaries` and kept current by `sempere sync webdav`
   (`--web-viewer` creates it on the server, with `sempere-index.json`;
   `docs/cli.md`). When a note is opened, the summary computed from its
   revisions replaces its entry.
2. **A cache of ciphertext.** Revisions and blobs fetched over HTTP are kept
   in IndexedDB (`web/src/vault/cache.ts`), keyed by the vault's URL and id,
   its **key state** (a hash of `vaultSecret` as sealed in `vault.json` and of
   `rewrap-journal.json` when there is one) and the file's path, exactly as
   the server sent them. A recipient change re-seals the secret and a rewrap
   rewrites files in place under their names, so the key state changes with
   either (and again when the rewrap finishes), and opening the vault deletes
   every copy cached under an earlier one: a key removed from the vault never
   opens a copy the browser kept from before (security review 2026-10, P4).
   Within one key state they are write-once,
   so a cached file is never fetched again: a later visit requests only names
   it has not seen (plus `config.json`, `vault.json`, the summaries file and
   the listing, which change). After each listing, cached revisions the
   listing no longer has and every file of a note that is gone are deleted;
   the rest is bounded at 512 MiB (least recently used first; no file over
   64 MiB is cached). Everything read from the cache is decrypted and
   verified like a download (age, the body tag of §4, a blob's hash and keyed
   name), and a cached file that fails (a recipient change rewrote it,
   storage damage) is deleted and downloaded once more. "Clear cached data"
   (on the open, unlock and main screens) deletes the cache of every vault.
   Where IndexedDB is unavailable (some private windows) the cache lives in
   memory for the tab. Local folders are not cached.
3. **One-request listing.** With `sempere-index.json` on the server
   (`"listing": "index"` in `config.json`), the listing is one request;
   over WebDAV it is one `PROPFIND` per note, done 8 at a time while the
   changed notes are decrypted 4 at a time.

The status line shows the progress ("Checking 120 of 640 notes…",
"Decrypting 3 of 5 changed notes…") and then the count; note bodies are
decrypted when a note is opened.

Measured with `scripts/smoke-cache.mjs` (Chromium, the server on the same
machine, every request delayed by 40 ms) on a synthetic vault of 200 notes
and 600 revisions: unlock to the verified list took 7.3 s on a first visit
without summaries (809 requests, 600 revision downloads) and 5.4 s on a
second visit (209 requests, no revision downloaded: decryption dominates);
with the summaries file 1.8 s over WebDAV (208 requests) and 0.3 s with the
index (8 requests), the first rows after 0.25 s, first visit or not.

A vault of a later format version (`sempere/2`, unknown `features`) opens
like any other, and the status line says it was written partly by a newer
Sempere (the reasons in its tooltip). In a revision marked newer (§7.4)
unknown ops and fields and undecodable snapshot elements are skipped; the note
view says what was skipped, the list marks the note "newer version", and a
revision with a later body version is reported as written by a newer
version. The viewer never writes, so it needs nothing else to be read-only
(§7.3). `test/newer.test.ts` checks this against the committed
`newer.sempere` fixture and its CLI export (`test/golden/newer`).

## Attachments

A page is drawn bottom to top as §8.2.3 says: paper, items by `(layer, z,
id)` (a background-layer item first fills its rotated frame with the paper
colour), then the ink. Each item is one of:

- **Text box**: laid out by `text.ts` with the stored `breaks` when they are
  valid (strictly increasing, inside a paragraph, on a grapheme cluster
  boundary), so the lines are the app's and the CLI's; the vertical metrics
  are the format's (line size `S` = largest run size, height `1.2 S`, baseline
  `0.95 S` below the line's top), so every line sits at the same height as in
  the exports. The glyphs are the browser's: generic families map to system
  font stacks (`sans`: system-ui, Segoe UI, Roboto, Noto Sans, Helvetica,
  Arial; `serif`: Iowan Old Style, Noto Serif, Georgia, Times; `mono`:
  ui-monospace, SF Mono, Menlo, Consolas, Noto Sans Mono), runs become
  `<tspan>`s (bold, italic, underline, strikethrough, colour, size, `lang`),
  and the browser shapes and reorders each line within its paragraph's
  direction (`dir`, or for `auto` the first letter's script). Without valid
  `breaks` the viewer breaks greedily with widths measured by the browser
  (after white space, after `-`, between wide CJK characters, and inside a
  word wider than the frame), which can differ from another renderer's lines.
- **Markdown text box** (§8.2.4 "Markdown text", §8.5.4): parsed and laid
  out by a port of the Swift code (`src/format/markdown.ts`: the dialect's
  parser, plain text, rendered paragraphs; `src/render/markdown.ts`: lines,
  metrics, markers, quote bars, rules, code fills), then drawn as the items it
  stands for: text items with fixed lines (run `font` `mono` for code), its
  formulas as math items (their stored render through pdf.js, else their
  source) and its shapes under them. With the box's stored `layout` (when its
  hash matches the text) the lines and baselines are the CLI's and the app's
  whatever the fonts (`test/markdown.test.ts` reads the shared fixtures
  `Tests/SempereTests/Fixtures/text/markdown.json`; the cross-check compares
  the fixture vault's Markdown note with the CLI's SVG, shapes included).
  **Math is drawn from the stored renders, not KaTeX:** a KaTeX typesetting
  would size formulas differently from SwiftMath and so move the lines away
  from the app's and the CLI's, needs its own fonts and stylesheet (the CSP
  allows neither), and parses LaTeX in the page; the renders are the same PDF
  path as equation items, already verified and sandboxed in pdf.js. A formula
  the app has not typeset yet (a box written by the CLI) shows its LaTeX
  source in a monospace font, as in the CLI's exports, and is reported. Search
  sees the plain text (no markup).
- **Image** (JPEG or PNG, by signature): the header is checked first (8-bit
  baseline or progressive JPEG with 1 or 3 components, any valid PNG, at most
  100 MP and plausible for the file's size), metadata is stripped as the
  exports strip it (so an EXIF orientation in the file can never apply; the
  item's `orientation` does), and the browser decodes it from a `blob:` URL; a
  decode that fails or yields another size is a placeholder. Orientation, crop
  and rotation are one matrix, as in the CLI's SVG.
- **PDF page**: drawn by pdf.js (below) at the zoom's resolution (2 to 8
  pixels per point, at most 16 MP per item, sharpened again after zooming in),
  only the cropped part of the effective page (where a crop reaches beyond
  the page, the paper shows, as in the exports). pdf.js's effective page is
  CropBox ∩ MediaBox turned by `/Rotate`, tested against the tables of
  §8.5.1 (`test/pdf.test.ts`). Annotations are not drawn (§8.2.6).
- **Video** (§8.2.7): its poster, placed like an image (the whole image,
  upright, onto the frame), under the format's play mark (a dark disc with a
  white triangle, turned with the item); without a poster, a placeholder
  under the mark (not reported: nothing is missing). Tapping the clip on the
  page, or Play in the "N videos" list above the pages, decrypts and verifies
  the clip and plays it in a `<video>` under the list (H.264 plays in every
  current browser except Chromium builds without proprietary codecs, HEVC in
  Safari and in Chrome or Edge with hardware decoding; an unplayable clip says
  so). One clip is held at a time: playing another, Close, or leaving the note
  revokes its object URL so the browser frees it.
- **Placeholder** (§8.5.2), for an unknown kind (an equation only when it has neither a rendering nor a source),
  a missing, unreadable or invalid blob, HEIC (no decoder in the viewer; the
  app converts photos to JPEG by default), an image or PDF it cannot draw, or
  a page index the PDF lacks. The note view lists every placeholder with its
  reason ("N items shown as placeholders").

**Blobs** (§8.1) are read only when their item comes within half a screen of
the viewport (a video's poster with it), audio and video clips only when
played, transcripts when opened.
Each is looked up at `notes/<id>/att/<name>.<kind>.age`, with `name` keyed from
the reference's hash under the vault secret (and under the previous secret
while a rewrap is unfinished, §8.1.5), decrypted as a stream (typage checks
each 64 KiB chunk), and checked as a whole before anything is used: magic and
version, the header's hash and length equal to the reference's (which binds
the file to its keyed name), zero padding, and the SHA-256 of the content.
Content is never handed out before that. Limits: images 64 MiB, PDFs 256 MiB,
transcripts 64 MiB, audio 256 MiB (the format allows 1 GiB, §8.4, but a
browser holds the whole verified file in memory; 256 MiB is over 8 hours at
the app's default 64 kbit/s; a longer recording says to export it with the
CLI), video clips 512 MiB (a longer clip shows its
poster and says to extract it with the CLI), and at most 1 MiB of padding beyond
what a writer adds. Each blob is read once per open note however many items
use it.

**Recordings on the page** (§8.2.9) are drawn as their card (the CLI's
elements, cross-checked with its SVG): the microphone icon, the title and
length, and the transcript once it is read (lazily, verified). A tap on a
card plays its recording in the list below.

**Recordings** (§8.3) are listed above the pages (title, start, length). Play
decrypts the audio into an `<audio>` element (AAC in MPEG-4 plays in every
current browser except Chromium builds without proprietary codecs; ALAC only
in Safari; an unplayable format says so). A transcript is checked against
§8.3.2 (format, the recording it names, segment and word order and ranges,
confidences) and listed by segment; a segment's time plays from there, and
words under 0.5 confidence are dotted-underlined.

## Threat model

What the viewer protects, and against whom.

**Assets:** the age identity, the vault secret, and decrypted note content.

**Trusted:** the browser, the user's device, and the viewer's own files as
served (`index.html` and its hashed `assets/`). Whoever can change those files
on the server (or in transit without TLS) can change the code that receives
the key: the viewer is exactly as trustworthy as the host that serves it.
Serve it over HTTPS from a host you control, and prefer a build you made
yourself (`npm ci && npm run build`).

**Untrusted:** everything in the vault and everything the storage server
returns: file contents, listings (`sempere-index.json`, PROPFIND bodies),
the summaries file, sizes and names; and the browser cache, which holds what
the server sent. A hostile server can withhold, replay or reorder files, but
cannot forge or alter a revision without the vault secret (the HMAC tag binds
note id, file name and body, §4), and cannot make the viewer run code:

- **No markup from data.** The UI builds DOM nodes and sets text; nothing
  parses HTML. SVG is created element by element from the renderer's
  commands, with an allow-list of element and attribute names. ESLint forbids
  `innerHTML`, `outerHTML` and `insertAdjacentHTML`.
- **Content-Security-Policy** (in the built `index.html`, and to be sent as a
  header too, below): `default-src 'none'; script-src 'self'; style-src 'self';
  img-src 'self' data: blob:; media-src blob:; connect-src 'self' [vault
  origins]; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src
  'none'; worker-src 'self'; manifest-src 'none'; require-trusted-types-for
  'script'; trusted-types sempere-pdf-worker sempere-key-worker`. No inline script or style, no
  `eval`, no WebAssembly, no third-party origin. `blob:` URLs are created by
  the page only, from verified blobs with a type the viewer sets (`image/jpeg`,
  `image/png`, PNGs it rendered itself, `audio/*`); the DOM builder refuses
  any other image reference. Each of the two Trusted Types policies admits
  exactly one URL: the bundled pdf.js worker, and the key worker that runs
  scrypt for a passphrase-wrapped key.
- **Attachments are untrusted too.** A blob is used only after it verified
  (above); a hostile writer who holds a vault key can still store a crafted
  image, PDF or audio file under a valid name. Those reach the browser's own
  decoders (images, audio) and pdf.js, never markup: images are checked and
  stripped first and shown through `<image>` (no script runs in an image),
  audio goes to `<audio>`, and a PDF is parsed by pdf.js in its worker with
  scripting, XFA, annotations, font loading (glyphs are drawn as paths) and
  WebAssembly off; it can only produce pixels. Reading a PDF, reading a
  page and drawing a page each stop after 30 s; a PDF that hangs while being
  read gets the worker replaced, so later notes are not blocked by it. Transcripts are JSON shown as text.
- **Bounded work** (§9): blobs within the limits of "Attachments" above,
  images within 100 MP before decoding, at most 10 000 items per page,
  revision files up to 256 MiB and 256 MiB after gunzip, `vault.json` 16 MiB, listings 16 MiB (PROPFIND) and 64 MiB (index),
  the unknown-field budget of §9 (24 levels, 16 384 values per file), and the
  renderer limits of `SempereRender` (extent 200 000 pt, samples per control
  point, outline points per page, ruling commands per band and page). Every
  failure is a typed error shown to the user; a seeded fuzz test checks that.
- **Summaries** (`format.md` §12) are authenticated under the vault secret:
  the server can withhold one or serve an older one (its entries then still
  match unchanged notes, or are decrypted again), not forge one. A malicious
  recipient can write entries that disagree with its revisions; a note opened
  shows its revisions. The file is bounded (64 MiB, 256 MiB after gunzip),
  each entry is checked (canonical sorted revision names, dates, counts, page
  numbers) and a bad entry is dropped alone; a fuzz test covers it.
- **Device list and secret link** (`format.md` §2.1): the viewer keeps no
  trust record and writes nothing, so it reports only what the recipients
  tag says under the secret. It checks `secretLink` for one purpose: a
  rewrap journal's previous secret (blob names and derived keys during an
  unfinished rewrap) counts only when the link connects it to the current
  secret, with both signatures (Ed25519 and ML-DSA-65) verifying under the
  previous secret's derived public keys, or, for a journal an older writer
  left, the legacy HMAC (which needs the current secret to forge). A link
  with one valid signature is refused. The link stays in `vault.json` after
  the rewrap, and a removed device holds the outgoing secret, so the journal
  must also still be bound by `vault.json` (`rewrapPending`, `format.md`
  §3.3.1); with no trust record, the viewer
  cannot tell a `vault.json` put back from the rotation, which then still
  binds the genuine journal (`journal.test.ts`). Shared test vectors with the Swift
  code: `Tests/SempereTests/Fixtures/secret-link-vectors.json`.
- **`config.json`** (deploy time, "Hosting") holds no secret and is only
  read: it names the vault's URL and listing and whether other vaults may be
  opened. One that exists but cannot be read or parsed stops the viewer
  (fail closed) rather than falling back to ad-hoc loading.
- **Stored key files** (`keys/`, "Unlocking with a passphrase") come from the
  server too. One the server swapped can only fail: without the passphrase it
  cannot make a file that your passphrase decrypts, and a key it chose would
  still have to be one of the vault's recipients to unlock anything. Its
  header is checked first (one scrypt recipient, work factor at most 20, so at
  most 1 GiB in a worker that is then terminated), and its plaintext is
  bounded. Whoever holds the file (the server, a backup) can guess the
  passphrase offline, as with any copy of the vault: the viewer adds nothing
  there; choose a long passphrase.
- **Names are validated** before use: note directories must be lowercase
  UUIDs and revision files canonical `<hlc>-<device>-<seq>.<kind>.age` names;
  anything else is ignored (§1), so a listing cannot point the viewer at
  another path.

**The key:** pasted into a text area, read once, and held only in the
`Decrypter` object in memory (a key unlocked with a passphrase likewise; the
passphrase itself is read once, handed to the key worker and dropped, never
stored or sent). Unless the user asks for a passkey (below), it
is not stored (no cookies, `localStorage`, IndexedDB or service worker); it is
never put in the URL, never logged, and never sent:
the only requests the viewer makes are `GET` and `PROPFIND` for vault files,
which carry no key material, and (when a note has a PDF page) `GET`s of the
viewer's own pdf.js files: the worker, standard fonts, CMaps and the
JavaScript JPEG 2000 / JBIG2 decoders under `pdfjs/`, which say only that some
PDF needed them. **Lock** reloads the page, which drops the key and
every decrypted note. JavaScript cannot guarantee that memory is wiped, and a
browser extension with access to the page can read anything the page can; use
a browser profile without such extensions for sensitive vaults.

**What the browser keeps:** the ciphertext cache of "Opening fast", in
IndexedDB under the viewer's origin: vault files exactly as downloaded, keyed
by the vault's URL and id, its key state and the file's path, with a size and a last-use
time; copies of an earlier key state are deleted when the vault is opened. **Nothing decrypted is persisted**: no note content, title, summary,
vault secret or key, and no derived key (the summaries are decrypted into
memory on each visit). Someone with access to the browser profile learns
what the server shows anyone who can list it (note ids, revision and blob
names, sizes) and which vaults were opened there, and holds encrypted files
that need the key, as a copy of the vault would. "Clear cached data"
deletes it (not a remembered key, which "Forget this key" deletes); clearing
the site's data in the browser deletes both.

**A key remembered with a passkey** (opt-in, above). What each attacker can do:

- *A malicious or compromised viewer origin, or XSS in the viewer:* exactly
  what it can do to a pasted key, plus one thing. Code running in the page can
  read the IndexedDB record and ask for the passkey; the user sees a passkey
  prompt and, by approving it, hands that code the PRF output and so the key.
  It can do so at any visit, not only when the user would have pasted the key.
  The defence stays the same as for pasting: the strict CSP, no markup from
  data, Trusted Types, and serving the viewer from a host you control. Approve
  a passkey prompt only when you pressed "Unlock with passkey".
- *Another origin* (a phishing copy of the viewer): cannot read this origin's
  IndexedDB, and the browser refuses it the passkey (bound to the RP ID). A
  page on another port of the same host shares the RP ID, so it could prompt
  for the passkey, but without the record the PRF output opens nothing. Host
  the viewer on a host name of its own.
- *A stolen disk or a copied browser profile:* gets the record, which is
  AES-256-GCM ciphertext under a key derived from a secret that lives in the
  authenticator (Secure Enclave, TPM, security key, or the passkey manager's
  vault) and is released only after user verification. Without the
  authenticator and the user's PIN, fingerprint or face, nothing.
- *A stolen, unlocked device:* the passkey still asks for user verification
  (the viewer requires it and checks the UV flag).
- *A synced passkey* (iCloud Keychain, Google Password Manager, a password
  manager): its PRF secret syncs with it, end-to-end encrypted by that
  service. The record does not sync: another device with the passkey but not
  this browser's IndexedDB gets nothing, and someone who breaks into the sync
  account still needs the record. Someone with both (the sync account and a
  copy of this browser's storage) has the key; a device-bound passkey
  (security key, or a provider that does not sync) avoids that.
- *Content of the vault or the server* cannot read any of this: the passkey
  code never runs on vault data. A server chooses which record the unlock
  screen looks up, though (the vault id in `vault.json`, read before any
  unlock), so records are bound to the vault's location (above): a hostile
  address that claims the id of a vault you remembered elsewhere (a link to
  `?vault=https://elsewhere/`, say) is not offered the passkey. At the same
  address the server is trusted as for a pasted key: a key it opens is still
  only in this tab's memory, and the vault it serves is what you see.

Forgetting deletes the record; JavaScript cannot guarantee that the browser
wipes deleted storage from disk at once.

**Metadata visible to the server** (as for any storage, `docs/io.md`): note
ids, revision file names (time, device id, sequence), blob names, kinds and
sizes, file sizes, and when the viewer reads which file (a blob is read when
its item comes on screen, audio when it is played, so the server can tell
roughly where a reader is in a note). `sempere-index.json` lists the same names; it
holds no content.

**Out of scope:** a compromised host serving modified viewer code, a
compromised browser or OS, shoulder surfing, and traffic analysis.

## Hosting

The viewer is static files: `web/dist/` after `npm run build` (relative
paths, so any sub-path works). The vault is any folder of its files. Put both
on **one origin** (for example `https://notes.example.org/` for the viewer and
`https://notes.example.org/vault/` for the vault): then `connect-src 'self'`
covers it and no CORS is needed. To read a vault on another origin, build with
it allowed, `SEMPERE_CONNECT_SRC="https://dav.example.org" npm run build`
(space-separated origins), and have that server send CORS headers for the
viewer's origin (`Access-Control-Allow-Origin`, and for WebDAV
`Access-Control-Allow-Methods: GET, PROPFIND`, `Access-Control-Allow-Headers:
Depth, Content-Type`, plus `Access-Control-Allow-Credentials: true` if it
needs a login).

`index.html?vault=https://notes.example.org/vault/` pre-fills the URL (never
put a key in a URL) when the viewer has no configuration.

### `config.json`: the server decides the vault

A deployment can fix which vault the viewer shows with a `config.json` next to
`index.html` (it holds no secret; `connect-src 'self'` still covers a
same-origin vault):

```json
{ "vault": "./vault/", "listing": "webdav", "allowOtherVaults": false }
```

- `vault`: the vault's URL, relative to `config.json` (so `./vault/` is the
  same origin); `http(s)` only, without credentials, query or fragment.
- `listing`: `webdav` (`PROPFIND`), `index` (`sempere-index.json`) or `auto`
  (the index if there is one, else WebDAV; the default).
- `allowOtherVaults`: `false` (the default) opens that vault directly, at the
  key prompt: the URL field, "Open a vault folder…", the drop zone and the
  unlock screen's "Back" are not shown at all, and `?vault=` is ignored.
  `true` keeps the ad-hoc screen with `vault` pre-filled.

Without a `config.json` (a 404) the viewer behaves as before: any vault by URL
or folder. A `config.json` that exists but is not valid stops the viewer with
its error. The maintainer's lab writes it in its deploy recipe, next to the
built `dist/`:

```bash
printf '{"vault": "./vault/", "listing": "index", "allowOtherVaults": false}\n' > /srv/sempere/viewer/config.json
```

### A WebDAV mirror made by `sempere sync webdav`

The setup the roadmap plans: the vault lives in iCloud Drive; a Mac runs
`sempere sync webdav` every few minutes (`launchd`), mirroring it to a WebDAV
share on a home server; the server also serves the viewer. The viewer lists
the share with `PROPFIND` (`Depth: 1`) and reads files with `GET`, so the
share needs no index. Authentication is the web server's (HTTP Basic or a
login cookie, prompted by the browser); the viewer sends credentials only to
its own origin.

```bash
# on the Mac, from the iCloud vault (docs/cli.md "Sync"); --identity lets it keep
# the server's summaries current, --web-viewer creates them (and the index) the first time
SEMPERE_WEBDAV_PASSWORD=… sempere sync webdav https://notes.example.org/vault/ \
  --vault ~/Library/Mobile\ Documents/com~apple~CloudDocs/Notes.sempere --user notes \
  --identity ~/.config/sempere/identity.key --push-only --web-viewer
```

The run keeps `sempere-summaries.sealed` and `sempere-index.json` on the server
describing what the server holds, rewriting them only when that changed;
without `--identity` the summaries are left as they are (stale entries only
mean more decryption in the viewer).

A Caddy site for viewer and share (Caddy's `webdav` module):

```caddyfile
notes.example.org {
	basic_auth {
		notes <bcrypt hash>
	}
	header {
		Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; media-src blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; worker-src 'self'; manifest-src 'none'; require-trusted-types-for 'script'; trusted-types sempere-pdf-worker sempere-key-worker"
		Referrer-Policy no-referrer
		X-Content-Type-Options nosniff
		Strict-Transport-Security "max-age=31536000"
	}
	handle_path /vault/* {
		root * /srv/sempere/Notes.sempere
		webdav
	}
	handle {
		root * /srv/sempere/viewer
		file_server
	}
}
```

Send the CSP as a header as well as the built-in meta tag: only the header can
carry `frame-ancestors` (no framing of the viewer), and only a header applies
to the pdf.js worker. Serve `.mjs` files as `text/javascript` (Caddy does): the
worker is a module.

### A plain static server

A static server (nginx, GitHub Pages, S3, `python3 -m http.server`) cannot
list folders, so the vault needs a listing next to `vault.json`:

```bash
sempere vault index --vault /srv/www/Notes.sempere     # writes Notes.sempere/sempere-index.json
```

`sempere-index.json` is `{"format": "sempere-index/1", "notes":
{"<noteId>": ["<revision file>", …]}}`: note ids and revision names only,
which the server sees anyway. It needs no key. Once it exists it stays
current with no manual step: every `sempere` command that opens the vault
(`compact`, `import`, `snapshot`, edits, `sync webdav`, even `verify`)
rewrites it when the vault's listing changed since, and `sync webdav`
rewrites the server's copy, if the server has one, to list what the server
holds after the sync. No command creates it except `vault index` (and, on a
WebDAV server, `sync webdav --web-viewer`). A copy made
by other means (`rsync` of the vault folder) carries the index with it. Writes
by the app do not update it; the next `sempere` command does. Every reader
treats the file as an unknown file and ignores it (`format.md` §1); `sync
webdav` never copies it from one side to the other. `--out -` prints it, `--out PATH`
writes it elsewhere. The viewer's listing choice "Index file or WebDAV" tries
the index first and falls back to `PROPFIND`.

### Local folders

"Open a vault folder…" uses `showDirectoryPicker` (read-only) where the
browser has it, and a folder `<input>` elsewhere; dropping the `.sempere`
folder works in every current browser. In Safari and Firefox the folder input
reads every file of the folder into a list first; very large vaults open
faster from a URL. Files in iCloud Drive that are not downloaded to the
computer (`.icloud` placeholders) are not part of the folder and their notes
are missing: download the vault first.

## Limits

- **Read-only.** No editing, no restore, no history browser, no export.
- **Attachments**: text boxes use the browser's fonts, so glyph widths differ
  from the app's and the CLI's (lines and heights do not when `breaks` are
  stored); underline and strikethrough are the browser's, not at the format's
  offsets; a renderer without a font for a script shows the browser's
  fallback, not a report. HEIC images are placeholders. PDF pages need a
  browser with module workers (every current one); the pdf.js build used is
  the "legacy" one, which polyfills recent JavaScript for older browsers.
  Blobs are held in memory while their note is open (no temporary files in a
  browser). Ink is not linked to audio (`rec`) yet.
- **Ink** is drawn like `SempereRender`: flat colour per stroke (mean opacity
  times a tool factor), no pencil grain, watercolour bleed or nib angle; the
  same approximations as the CLI's PDF and SVG exports.
- **Legacy vaults** (any X25519 recipient) are refused: migrate first.
- **Passphrase-wrapped keys** with a scrypt work factor over 20 are refused
  (`format.md` §3.2 allows readers to stop there; writers use 15 to 18): use
  `sempere keys export`. At 20 scrypt needs 1 GiB, which a phone's browser may
  not give a worker; the viewer then says so.
- **Transcript search** reads and decrypts every transcript of the vault the
  first time it is ticked in a tab (seconds for hundreds of notes; the
  encrypted files are cached, decryption is not), and keeps them in memory
  until Lock. The matching is the CLI's, as Foundation does it on Linux; in
  rare corner cases (a phrase that starts with a combining mark or a variation
  selector, full-width letters followed by variation selectors) where a match
  ends can differ by those marks. Matches are not highlighted in the audio
  item cards on the page.
- **Without a summaries file**, every note is decrypted to list titles and
  tags: a vault of a few hundred notes takes seconds (four notes and up to 24
  requests at a time), on later visits too (the files then come from the
  cache, but decryption dominates). Publish one (`sempere vault summaries`,
  or `sync webdav --web-viewer`). Decrypted notes are kept in memory only for
  the notes opened most recently.
- **Equations** (`math` items, format.md §8.2.8) are drawn from their stored
  rendering with pdf.js on a transparent page (no white box over the paper);
  an equation without a rendering, or whose rendering cannot be drawn, shows
  its LaTeX source in a monospace font. The viewer has no math typesetter.
- **Search** covers titles, tags, notebooks, recognised text, text boxes,
  equations' LaTeX source and PDF page text (`pageText`, format.md §8.2.6), as in the app; words are not
  highlighted on the page yet. A note with `markersBehindText` (§5.4) draws
  its marker strokes below its text boxes and images (§8.2.3), as the CLI's
  exports do.
- Integers in revisions are read up to ±2^53 (every value the format defines
  is below that); Swift accepts larger ones for a few informational fields and
  for origin indices.

## Development and tests

```bash
cd web
npm ci                 # exact versions from package-lock.json
npm run dev            # Vite dev server (no CSP in dev mode)
npm run lint && npm run typecheck && npm test
npm run build          # dist/, with the CSP meta tag
npm run fixture        # rewrite test/fixtures/render.sempere (TypeScript writes, Swift reads)
scripts/golden.sh      # rewrite test/golden from the Swift CLI (builds it)
# browser smoke tests, Playwright + Chromium (smoke.mjs needs sempere-index.json in the vault: `sempere vault index`):
node scripts/smoke.mjs ../Tests/SempereTests/Fixtures/sample.sempere ../Tests/SempereTests/Fixtures/sample.key
node scripts/smoke-attachments.mjs test/fixtures/render.sempere ../Tests/SempereTests/Fixtures/sample.key
# passphrase-wrapped keys (stored key file, recovery kit copy, then a passkey) and transcript search (CI's web job)
node scripts/smoke-search-keys.mjs
node scripts/make-search-fixture.ts   # rewrite test/fixtures/search.sempere (then scripts/golden.sh)
# passkey: Chromium's virtual authenticator (CTAP2, UV, PRF), and one without PRF
node scripts/smoke-passkey.mjs ../Tests/SempereTests/Fixtures/sample.sempere ../Tests/SempereTests/Fixtures/sample.key
node scripts/smoke-video.mjs test/fixtures/render.sempere ../Tests/SempereTests/Fixtures/sample.key
# pages far from the viewport go back to placeholders and are drawn again on return
node scripts/smoke-release.mjs test/fixtures/render.sempere ../Tests/SempereTests/Fixtures/sample.key
# languages: the browser's language list, the override, a Spanish vault session, the switch with a vault open (CI's web job)
node scripts/smoke-language.mjs test/fixtures/render.sempere ../Tests/SempereTests/Fixtures/sample.key
# config.json modes, the cache (second visit fetches no unchanged file) and the summaries, with timings
# (run `sempere vault summaries` and `sempere vault index` on a copy of the vault first; LATENCY_MS=40 adds latency):
node scripts/smoke-cache.mjs COPY_OF_VAULT KEY_FILE
# all of them, as CI's `web-smoke` job runs them (needs the built CLI: it gives a copy of the sample vault summaries and an index):
scripts/smoke-all.sh
```

Tests (`web/test/`, vitest, Node 22):

- **Cross-check with the Swift CLI** (`crosscheck.test.ts`): for every note of
  `Tests/SempereTests/Fixtures/sample.sempere` and of
  `web/test/fixtures/render.sempere`, the TypeScript reconstruction must equal
  `sempere export --format json` and the TypeScript SVG must equal
  `sempere export --format svg` byte for byte. The render fixture is written
  by `scripts/make-fixture.ts` (encrypted to the throwaway test key) and covers
  every paper kind, every tool, transforms, dots, infinite pages, two devices
  with a snapshot, removals, page order, recognition, legacy and per-tag
  tags, an orphan delta, attachments and unknown fields. CI's `web-golden`
  job regenerates `test/golden` with the CLI (SVG with `--pdf-renderer none`,
  so PDF pages are placeholders there and the goldens do not depend on a
  Poppler version) and fails on any difference, so the committed goldens are
  always the Swift output.
- **Attachments against the CLI** (`items-crosscheck.test.ts`): three fixture
  notes with blobs (`test/fixtures/media/`: a synthetic JPEG with EXIF and a
  comment, a PNG with a text chunk, a hand-written two-page PDF with a
  CropBox and `/Rotate`, a one-second tone, a transcript, a one-second H.264
  test-pattern clip; plus a missing, a forged and a HEIC blob, an unknown
  kind, video items with and without posters, rotated, with a poster set and
  reset by another device and with a missing clip, and two equations: one with
  a rendering, which the goldens, made without a PDF renderer, draw as its
  source text, and one without). The page outside the
  `items` group is compared byte for byte; the group itself structurally,
  since the CLI embeds its own font subsets: background fills, placeholders,
  each image's clip polygon and matrix (blobs read by the viewer's own
  reader), each text line's baseline, size, characters, direction (and x
  where it does not depend on glyph widths), each text box's rotation, and
  each video's play mark element for element.
- Blobs (`blobs.test.ts`: the §8.1.3 test vector, Padmé, every framing
  failure, missing, forged and cross-note blobs, the previous secret during a
  rewrap), images, placement, text layout and transcripts
  (`attachment-render.test.ts`), and pdf.js's effective page and crop mapping
  for each `/Rotate` (`pdf.test.ts`, rendered in Node with pdf.js's optional
  `@napi-rs/canvas`).
- Signed secret links (`link.test.ts`): the seeds, public keys and message
  of `Tests/SempereTests/Fixtures/secret-link-vectors.json`, the links made
  by noble and by swift-crypto verifying, links with one valid signature
  refused, strict parsing, and a journal secret accepted only through a
  link whose two signatures verify.
- Ports of the Swift merge, tag, clock, model, search and notebook tests,
  including §5.3's shuffled-order reconstruction and the multi-device tag
  convergence simulation.
- Published summaries (`summaries.test.ts`): the §12.1 vector, the Swift
  goldens (`test/golden/*.summaries.json`, from `sempere vault summaries
  --plaintext`) equal to what the viewer computes from the revisions,
  tampered, foreign-secret and wrong-vault files refused, malformed entries
  dropped alone. The listing (`listing.test.ts`): summaries shown first,
  only stale notes decrypted, gone notes dropped, a second visit with the
  cache downloading nothing, eviction. The cache (`cache.test.ts`: LRU,
  write-once paths only, a failing cached file evicted and fetched again,
  IndexedDB through `fake-indexeddb`) and `config.json` (`config.test.ts`).
- Vault and source tests: legacy refusal, wrong key, tag binding to note and
  file name, unreadable revisions reported, bounded reads and gunzip, index
  and PROPFIND parsing with hostile names.
- Transcript search against the CLI (`phrasesearch.test.ts`): for each term
  of `scripts/golden.sh` and each fixture vault (`sample`, `render`, and
  `search.sempere`, written by `scripts/make-search-fixture.ts`: handwriting
  with word boxes, text boxes, an equation, PDF page text, long and accented
  transcripts, a deleted note, a missing transcript and one naming another
  recording), the hits the viewer computes equal `sempere search TERM
  --transcripts --json` (`test/golden/search/`), and so does the exit status.
  The matching itself (`occurrences.test.ts`): `test/golden/occurrence-vectors.json`
  is what Foundation's `range(of:)` and the CLI's snippet give for the cases
  of `test/fixtures/occurrence-cases.json` (`scripts/occurrence-vectors.swift`,
  run by `golden.sh`, so CI's `web-golden` job regenerates and diffs it).
- Passphrase-wrapped keys (`keyfile.test.ts`): the sample vault's stored key
  file and a recovery kit's armored copy, both written by the Swift CLI, a
  sloppy paste, wrong and empty passphrases, a damaged armor line, files that
  are not passphrase files, a work factor over 20 refused before any scrypt,
  and decrypted files that hold no post-quantum key.
- Passkeys (`passkey.test.ts`, mocked WebAuthn): round trip, PRF at creation
  or only on assertion, no PRF stores nothing, cancelled prompts, a missing UV
  flag, records swapped between vaults or credentials or altered, malformed
  records, forget; only ciphertext, nonce, salt and credential id are stored.
- A seeded fuzz test of the decoders, the merge, the renderer, item layout,
  image headers, transcripts, blob framing, the listing parsers and key files
  (typed errors only), and of the phrase search (ranges stay in the text).

CI (`.github/workflows/ci.yml`): the `changes` job runs the `web` job (lint,
typecheck, tests, build) only when `web/` (or the workflow) changes, and the
`web-golden` job (Swift CLI goldens) also when the Swift code that writes them
changes (`Sources/` of the reducer, renderer and CLI, the fixture vault,
`Package.*`): a PR that moves the CLI's export must update `web/` with it.
`main` runs both always.

Dependencies are pinned exactly in `web/package.json` and
`web/package-lock.json`. Runtime: `age-encryption` (typage, BSD-3-Clause) with
its `@noble`/`@scure` libraries (MIT; `@noble/hashes` is also used directly,
for the streaming SHA-256 of blobs), and `pdfjs-dist` 6.4.299 (Apache-2.0;
its standard fonts are under the Foxit and Liberation (OFL) licences, copied
with them into `dist/pdfjs/`). pdf.js is loaded only when a note shows a PDF
page; its build-time copy step is the `sempere-pdfjs-assets` plugin in
`vite.config.ts`. Install
with `npm ci`, never `npm install`, in CI and for releases.
