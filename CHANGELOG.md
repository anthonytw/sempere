# Changelog

All notable changes to Sempere are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the CLI's version
(`Sources/SempereCLI/Version.swift`) follows [Semantic Versioning](https://semver.org/).
The section for a version is the body of its GitHub Release (`docs/releasing.md`).

## [Unreleased]

### Added

- Mac menu bar: Note, Tools and View entries for what was toolbar-only (Version History, Add Page After
  This One / at End, Duplicate, Delete and Undo Delete Page, the Pages/Pageless switch, Show Pages, the
  Text and Select tools, Smaller/Larger Object Eraser, the compact palette), and a Sempere icon in the
  system menu bar (Settings → General → Show in Menu Bar) with Quick Voice Note, New Note and Open
  Sempere. A voice note from it is sealed into the vault's inbox without unlocking, as on the iPad;
  File > Start/Stop Voice Note (⇧⌘M) does the same from the menu.
- iPhone: the overflow menu's Pages submenu has the page layout switch, Add Page After This One / at
  End, Insert PDF at this page, Duplicate, Delete, Undo Delete and the page thumbnails; swiping left or
  right turns pages while reading; the paper picker has a compact layout.
- Setting expectations. `sempere --version` prints the GPL notice ("This program comes with ABSOLUTELY
  NO WARRANTY…") with links to the licence and the security policy; `sempere about` (`--json`) adds the
  source, where to report a vulnerability, the security limits and the third-party software. The app
  shows "About Your Key" the first time a vault is unlocked with a key on a device (a new vault
  included): only the key opens the notes, nobody can recover them if every copy is lost, with
  buttons to save the key and recovery kit and to the backup settings; "I Understand" closes it. A
  six-page quick tour follows once per device. Settings ▸ About shows the version, the licence
  (bundled), acknowledgments and the links, and reopens both; on the Mac, Sempere ▸ About Sempere and
  Help ▸ Quick Tour / About Your Key. New `docs/security.md` says what the encryption protects and
  what it does not; `SECURITY.md` describes the advisory process.
- Device list repair and key replacement in the app (GA-17): the "device list was changed without
  its key" alert offers Choose Devices to Keep… (the CLI's `vault recipients repair --keep`), which
  always keeps this device's key and asks for Face ID or Touch ID before keeping a key this device
  never confirmed; the Vault Keys window has Replace… (`vault recipients replace`) for another
  device's key, pasted or generated.
- `sempere backup status DIR --max-age DAYS` exits 3 when no backup run completed in DAYS days, the
  app's Remind Me for scripts (GA-18). `backup.json` records the last run without file errors
  (`completed`), which the check counts from; the app and the CLI share the rule.
- Markdown text boxes with LaTeX math (`format.md` §8.2.4 "Markdown text", §8.5.4): headings, bold,
  italic, strikethrough, code, bullet, numbered and task lists, links, block quotes, code blocks, rules,
  inline `$…$` and display `$$…$$` math. The source is the box's text, so older versions show it as plain
  text; the rendered lines are stored with it and the same in the app, its exports, `sempere export` and the
  web viewer. App: new text boxes are Markdown, edited as source with a Markdown bar of helpers and drawn
  rendered; formulas are typeset with SwiftMath when the edit closes. CLI: `attach text --markdown`,
  `items text` (with `--markdown`/`--no-markdown`); search sees the text without markup; Markdown exports
  keep the source, HTML exports render it. Styled text boxes keep working unchanged.
- WebDAV vaults in the app: Open from WebDAV… (server folder URL, user, password, Test Connection, the
  vaults found there). The vault is downloaded into a copy on the device, which works offline, and
  every change is pushed to the server shortly after it is made, when the app comes back and every five
  minutes; the server is never trusted to change the vault (push-only). The password stays in the
  Keychain only; https only, and a self-signed server needs an explicit "Trust This Certificate" with
  its fingerprint, after which only that certificate is accepted. The note list shows the sync state
  (Offline, changes not uploaded, a problem and what to do) with Sync Now, Download Again… (to get other
  devices' notes) and Server Settings…. CLI: `sempere webdav check` and `sync webdav --push-only
  --keep-server-changes`. The Mac build may now make outgoing connections (`network.client`), only to
  the server you configure.
- Vaults in another app's Files provider storage (Proton Drive) are read and written through file
  coordination even when the provider does not report its files as cloud items, so they are fetched and
  uploaded; what still needs a device test is listed in `docs/io.md` ("Other Files providers").
- Settings sync through the vault (`docs/settings-sync.md`, `format.md` §13): the vault can hold
  `settings.age`, a VS Code-style settings.json encrypted and tagged like a revision, that devices
  which opt in (Settings ▸ Sync Settings with This Vault) follow. Every setting syncs; keys only some
  kinds of device use are ignored by the others, and `[mac]` / `[ipad]` / `[iphone]` blocks hold
  per-type values. Merged per key (last writer wins), so concurrent edits on two devices both survive.
  "Only on This Device" keeps a setting local until "Use Synced Value". `$schemaVersion` and
  `$minReaderVersion` keep older and newer apps compatible (older apps pause rather than write).
  CLI: `sempere settings list|get|set|reset|edit|validate|schema` (`--type` for a type block); the
  schema is `docs/settings.schema.json`. Backups copy the file and `sempere sync webdav` merges it.
- Web viewer in Spanish: the interface is in English or Spanish, taken from the browser's language list
  with a Language selector (Automatic, English, Español) that overrides it and is remembered in the
  browser. Notes, notebook and tag names, recording titles and transcripts are shown as written; dates,
  numbers and sizes follow the language; the usual errors (wrong key or passphrase, passkey refusals) are
  worded in it. A test fails when a string lacks Spanish. `docs/web-viewer.md` "Languages".
- Recordings in exports, finished (C4): "PDF + attachments" ends with an attachment list (kind, title,
  pages, duration, size of every recording, transcript and video clip), each row linked to its
  embedded file and to the page it is on; `sempere export --recordings list` adds the page alone.
  `sempere export --format media` and the app's "Media" export (single note and "Export Notes…") write
  a note's recordings, transcripts (as text), video clips, images and PDFs as files, decrypted and
  verified, with readable names and a `media.json` manifest; bulk runs skip notes without media and
  resume like the other formats.
- Handwriting → LaTeX on device (G1 part 2), behind a setting and without a model yet: research with
  licences, sizes, accuracy and measured decoder costs in `docs/research/handwriting-to-latex.md`. CLI:
  `sempere recognize-math` picks ink (`--strokes`, `--rect`, `--lasso`, `--all-ink`), reads it with a
  converted Core ML model on macOS (`--model DIR`, every file checked against its manifest's SHA-256) or
  takes `--latex`, and with `--place replace|beside` turns it into an equation in one delta. App:
  Settings → Handwritten Math (off by default; a model is downloaded only on request, its size shown
  first) and Insert → Equation from Handwriting…: circle the ink, check the LaTeX the model read (with the
  SwiftMath preview), then replace the ink or place the equation beside it, with undo.
  `tools/math-model/convert.py` converts a Hugging Face image-to-LaTeX model into the model folder format.
- Web viewer: transcript search and passphrase-wrapped keys (`docs/web-viewer.md`). "Also search
  recording transcripts" (off by default, like `sempere search --transcripts`) reads and decrypts every
  transcript in the tab and lists the matching segments under their notes; a match opens the recording
  with its segment marked and the audio cued there. Matching follows `sempere search` (case and accents
  ignored, full case folding, no width folding), checked against the CLI by shared goldens in CI. The
  unlock screen opens the vault's passphrase-wrapped key file (`keys/`, `format.md` §3.2) and a recovery
  kit's passphrase-locked copy (pasted or chosen as a file); scrypt runs in a worker, work factors up to
  20, the passphrase is never stored, and the key can then be remembered with a passkey.
- Signed secret links (security review 2026-10, R2): a secret rotation's `secretLink` is now an Ed25519
  and an ML-DSA-65 (FIPS 204) signature by keys derived from the outgoing secret, valid only when both
  verify, and each device's trust record keeps only the two public keys, so reading a record (or a backup
  of it) no longer lets anyone forge a link (`format.md` §2.1). Existing vaults and records are upgraded
  in place once: `sempere vault link` shows the state and `sempere vault link upgrade` does it; the app
  does it after unlocking; any CLI write upgrades the machine's record. An old HMAC record confirms only
  the secret it was made for (a machine that missed a key change confirms the list). Upgraded vaults are
  marked `signed-secret-link`, so earlier builds stop writing to them (pre-1.0). The web viewer checks
  signed links with `@noble/post-quantum` and `@noble/curves`.
- App: Settings → Backups. Back Up Now copies the vault's encrypted files to a folder you choose (another
  drive, another cloud provider), only what is new each time, on the same code as `sempere backup`; Verify
  Backup checks it (decrypting every note while the vault is unlocked) and lists what is wrong, which the next
  backup repairs; the last backup's date and size; an optional reminder after a number of days without a
  backup. Restore from Backup (in Settings and on the welcome screen) shows what a backup holds, then restores
  it into a new vault, never over the open one.
- CLI: `sempere backup status DIR` (last run, notes, files and bytes from `backup.json`) and
  `sempere restore DIR --to NEW --dry-run` (what a restore would bring back, and whether `NEW` can take it).
  `restore` refuses a target that is, holds or lies inside the vault named by `--vault` / `$SEMPERE_VAULT`.

- "Recently Recognized" is shared by every device, like the trash: a recognition run ("Recognize All
  Notes", `sempere recognize`) marks each note it writes recognition for with the time of the run
  (`meta.recognized`, `format.md` §5.4), which syncs with the note. The sidebar lists it under All Notes
  with the smart lists. CLI: `sempere recognize --recent [--days N] [--json]`; `notes show --json` gives
  `recognized`. Builds before this one reject a revision carrying the new register (pre-1.0).
- New-note titles: presets (Date and Time, Date, Year-Month-Day Time, Weekday and Date) and a custom
  pattern, a Unicode date pattern or a strftime format, checked as it is typed with a live preview, the
  reason it is refused and an Insert menu of fields. CLI: `notes new --title-format` takes strftime too
  and refuses a format it cannot use (exit 2) with the same reason; `SEMPERE_TITLE_FORMAT` sets the default.
- iPhone and iPad: an iCloud sync in flight when the device locks or the app leaves the screen finishes
  in the background time iOS gives, and scheduled background tasks continue it when iOS allows
  (`docs/io.md` "Background sync" lists the limits).
- Unused attachments (E7): the app keeps a per-note index of each note's attachment files on the device,
  updated only for the note that changed (an edit, or a revision arriving by sync or iCloud). Settings →
  Storage shows "Unused Attachments: N items, X MB" and "Held by History" (files only older versions
  show); the list groups them by note with a preview, what each was (a recording's duration and title),
  since when it is unused, a link to the note's history at the version that last used it, and Delete,
  which stays disabled until 30 days after the file was first found unused ("Delete All Eligible" does
  every one that is). Deleting reads the note again and never removes a file any version uses; in iCloud
  Drive nothing is decided while a version of the note is not downloaded. CLI: `sempere blobs unused`
  reports the same numbers (`--json`: totals, items with `firstSeen`, `deletableFrom`, `eligible`,
  `held`), and `sempere blobs gc --file NAME` deletes one eligible blob.
- Recordings on the page (`format.md` §8.2.9, an `audio` item kind). Stopping a recording in the app
  places it on the page you were looking at as a card with a microphone icon, a play/pause button,
  its length and its transcript; move, resize or delete it like any item. Every recording of a note
  is listed by Recordings… (the note's menu, the Recordings menu, Note > Recordings… ⌃⌘R on the Mac).
  CLI: `recordings list|place|rename|delete`, `attach recording --place`; exports and the web viewer
  draw the card.

- Web viewer opens fast on every visit (`docs/web-viewer.md` "Opening fast"). A `config.json` next to
  the viewer lets the server fix the vault (straight to the key prompt; no URL field, folder picker or
  `?vault=`). The note list comes at once from the vault's published summaries, `sempere-summaries.sealed`
  (`format.md` §12: sealed under a key derived from the vault secret, entries keyed by revision file
  names, a hint never trusted over the revisions); only notes that changed are decrypted. Encrypted
  vault files are cached in IndexedDB (write-once, so never fetched twice; evicted when gone from the
  listing; 512 MiB LRU; "Clear cached data"); nothing decrypted is stored. CLI: `sempere vault
  summaries`; unlocked commands keep an existing file current; `sync webdav` keeps the server's copy
  current and `--web-viewer` creates it and `sempere-index.json` there. On 200 synthetic notes over a
  40 ms link: 7.3 s to a listed vault before, 0.3 s with summaries and the index.
- App Store submission preparation (`docs/release/`): export compliance answers with sources,
  privacy manifests for the app and the widget extension, App Privacy and age rating answers, App
  Review notes, listing drafts, the Mac App Store (universal purchase) steps, and a privacy policy page
  for GitHub Pages (`docs/privacy/`). `scripts/release-check.sh` (run by CI) fails on mismatched
  version or build numbers, a committed signing team, a missing or incomplete privacy manifest, or an
  entitlement outside the allow-list.
- Keys (2026-10-07 request). Web viewer: an opt-in "Remember this key on this device with a passkey".
  A WebAuthn passkey with the PRF extension (user verification required) yields a secret that HKDF turns
  into an AES-256-GCM key; only the encrypted key, its nonce, the PRF salt and the credential id go to
  IndexedDB. "Unlock with passkey" is one prompt; "Forget this key" deletes the record. Without PRF the
  viewer explains why and stores nothing. App: Settings → Device Keys → "Save Key…" exports this device's
  key after Face ID to Files or the share sheet (for a password manager), with its paper recovery kit;
  "New Key…" makes a key for another device, encrypts the vault to it and offers the same. Key files are
  the CLI's format (`keys generate`), written only where the user chooses; the share sheet's copy is
  deleted when it closes.
- Read-only access to vaults of a newer format version (`format.md` §7). A vault whose `vault.json`
  names a later `format` (`sempere/2`) or an unknown extension, and revisions marked as written by a
  newer version, no longer stop this version: it shows everything it understands (unknown ops, fields
  and snapshot elements are skipped, a later body version is left out, each reported) and never writes.
  CLI: reading commands report `readOnly`, `readOnlyReasons` and per-note `newer` in `--json`; every
  write exits 7. App: a read-only banner, notes open read-only, no autosave, thinning, inbox adoption or
  transcripts. The web viewer opens such vaults too.

- CLI: `sempere sync webdav --push-only [--delete-extraneous]`, a one-way mirror for a server that is not
  trusted to write back. It uploads, overwrites the server's `vault.json` / `rewrap-journal.json` from the local
  copy, and follows local compaction and blob collection with deletions on the server; it never downloads and
  never changes the vault (a compromised server cannot feed an attacker's recipient back). Files only the server
  has and nothing explains are reported as `extraneous` (new in `--json`, with `overwritten`) and removed with
  `--delete-extraneous`.
- The app's interface in Spanish (task L). Every interface string lives in String Catalogs
  (`Apps/Sempere/Localization/`), with plural forms, iPhone/iPad/Mac wording, the permission prompts, the
  Siri phrases and the Lock Screen widget, Control Center control and Live Activity text. Notes, notebook
  and tag names and the CLI's messages are not translated. Rules, the Spanish glossary and a guide to adding
  a language: `docs/localization.md`, `CONTRIBUTING.md`. `scripts/app.sh pseudo` checks the layouts in the
  double-length, right-to-left and Spanish languages; `LocalizationCatalogTests` keeps the catalogs
  complete.
- A note open in the app picks up what another device writes to it (iCloud Drive, any sync, the CLI)
  without being reopened: the new revisions are downloaded and merged into the open canvas, pages,
  items, text boxes and recordings. Ink not saved yet is saved first and kept; only pages whose ink
  changed are redrawn, at the same scroll and zoom; nothing is written back for the merge. A small
  "Updated from another device" notice shows for a few seconds.
- Equations (task G1, `format.md` §8.2.8): `math` items hold LaTeX source, display or inline style,
  size, colour and a typeset PDF rendering. App: Insert → Equation… and "Edit Equation…" open a sheet
  with a live SwiftMath preview; the rendering is stored, so exports, the CLI and the web viewer draw
  the equation without a typesetter. CLI: `sempere attach math --latex '…'` (`--inline`, `--size`,
  `--color`, `--render FILE.pdf`), `sempere items math`, equations in `items list`, `notes show` and
  `search`; exports embed the rendering (PDF form; SVG/PNG via Poppler), else draw the source with a
  warning, and Markdown/HTML keep the source as `$$…$$`. LaTeX sources are bounded (8 KiB, 4 096
  symbols, 64 levels) before anything parses them.
- App polish round 1 (TestFlight build 4 feedback). The notebook field of a new note and of Move to
  Notebook is a combo box: type a new `/`-separated path or pick an existing notebook from a list that
  narrows as you type. "Recognize All Notes" ends with "Recognized N notes" and keeps the notes it changed
  (title, pages read) under "Recently Recognized" in the sidebar until the next run. A note opened from a
  search result highlights the matching words on the page (from the recognition boxes) with previous and
  next buttons across all pages and a "3 of 12 matches" count. Drag notes (several, in Select mode) onto
  a notebook or All Notes in the sidebar to move them, drag a notebook onto another to nest it or onto
  All Notes to un-nest it, or use "Move Notebook To…"; a notebook cannot go into itself or a notebook
  inside it, the drop target highlights, and each drop is one commit with one undo step. CLI:
  `sempere search --show-boxes` (match locations, numbered across the note), `sempere notebooks move NOTEBOOK PARENT`.
  Word boxes that cannot be drawn (not finite, beyond 10⁹ points, negative size) are never
  highlighted or listed (`format.md` §5.5).
- CLI: `sempere items list|move|rotate|front|delete|duplicate|copy`, the app's item gestures (one
  delta each, through the same `NoteOps` builders; `copy` copies attachments to the other note first).
- Attachment plumbing in the app (task E0, `docs/attachments.md` §13–14): a note's images, text
  boxes and PDF pages are drawn between the paper and the ink (a placeholder while a blob
  downloads or when it is missing), and Select Items mode selects, moves, resizes, duplicates,
  copies and pastes (between notes too), brings to front and deletes them, each gesture one
  delta with undo. In iCloud Drive a note's attachments download on demand: images and PDF
  pages when a page shows them, never with the note. The shared `NoteOps` item builders and
  `ItemRaster` (one item drawn as the exports draw it) are in the library for the CLI too.
- `sempere recognize [ID…|--all] [--missing-only|--force] [--dry-run]` reads handwriting with
  Vision on macOS and stores it as page recognition, one delta per note, with the app's code (page
  selection `RecognitionPolicy.pagesToRead`, image plan `RecognitionImage`, Vision mapping
  `VisionText`, now shared by both). `import notability --recognize missing` does it right after
  an import for pages Notability never indexed. Notability's recognition is replaced only with
  `--force`. The Linux build refuses with a clear message (`--dry-run` works).
- `sempere notes search QUERY`: the app's search (titles, tags, notebooks, recognised text; all
  words; ranked) with `--notebook`, `--tag`, `--deleted` and `--json`.
- Version history round 2 (`docs/format.md` §5.8): **checkpoints** (named versions:
  `sempere notes checkpoint NOTE [--name TEXT]`, the app's Save Version in the note toolbar and
  the Mac Note menu), **editing sessions** (the app records one id per opening of a note;
  `sempere notes history --sessions` and the app's history list group autosaves into sessions
  under the checkpoints, collapsed), and **thinning** (`sempere compact --thin-older-than 30d
  [--dry-run]`; in the app a setting, default 30 days or never, a daily automatic run and Thin
  Now with a preview): old autosaves go, every checkpoint and the newest autosave of each
  session stay restorable, the note's state never changes. `compact` never deletes a checkpoint
  and keeps it restorable, and keeps a note's first revision while device clocks disagree (an
  older revision with a later `wall`), so the note's creation date cannot move.
- Web viewer: attachments (`docs/web-viewer.md`, `format.md` §8). Images (orientation, crop,
  rotation, metadata stripped), text boxes laid out with their stored line breaks and the
  format's line metrics, PDF pages drawn by a pinned pdf.js (worker and font data served by the
  viewer itself; no font loading, scripts or annotations), placeholders for unknown kinds and for
  missing, invalid or undrawable blobs (listed with the reason), and a note's recordings with
  playback and transcripts. Blobs are read only when their item comes on screen (audio when
  played), decrypted as a stream and checked before use: framing, zero padding, content hash and
  the keyed name. The Content-Security-Policy gains `blob:` images and media, a same-origin
  worker and one Trusted Types policy for it. Cross-checked against the CLI's SVG export of new
  synthetic fixture notes.
- Notability import of attachments (tasks D1, D2, `docs/import-notability.md` "Attachments"):
  the PDF pages of a note made from a PDF become page backgrounds (`pdfPage` items backed by the
  original PDF, laid out from the PDF's own page boxes), and images become image items with
  their frame, rotation and crop, metadata stripped. `sempere import notability` gains
  `--no-attachments` and `--keep-image-metadata`, and reports what it placed (`attachments`)
  and why anything was left out (`warnings`).
- Notability import of typed text and recordings (tasks D3, D4): typed text becomes text items
  with bold, italic, underline, strikethrough, colours and sizes as runs (and `lang` for CJK,
  Arabic and Hebrew runs); `Recordings/` becomes the note's recordings with their audio, and
  strokes link to the recording (`rec`) where `eventTokens` read as times in it.
- Attachments from the command line (task F, `docs/cli.md` "Adding attachments"): `sempere attach
  image|pdf|text|recording|transcript` add an image, PDF pages (as new background pages or as a
  figure), a text box, an MPEG-4 recording or a transcript to a note, each as one delta with
  `--json` output; `sempere import pdf` makes a note from a PDF, one page per PDF page with the
  page as its background; `sempere search` also searches the text of text boxes and, with
  `--transcripts`, transcripts; Markdown and HTML exports include typed text. The logic is shared
  with the app: `NoteOps` placement builders, `AudioProbe` (MPEG-4 header reader), `ImageIngest`
  and `PDFIngest`.
- Attachment merge (task A1, `docs/format.md` §5.3, §8.2.2, §8.3.1): placed items and recordings
  merge as sets with permanent tombstones, orphans and covered-add removal, and their fields as
  last-writer-wins registers (unknown fields included), in the library and the web viewer.
  Snapshots, `compact`, history and `notes restore` now keep them (restore re-creates removed
  items and recordings with `parent`; a moved item goes back to its page). Summaries count items
  and recordings, list the blobs a note references, and make text boxes searchable.
  `sempere notes show` lists items and recordings (`items`, `recordings` in `--json`; `notes list
  --json` counts them).
- iPhone app, as a reader (`docs/iphone.md`): the app target now also runs on iPhone. The vault,
  its notebooks and tags, the note list and the note are a stack; a note opens for reading (pan,
  zoom, page bar) and the pencil button switches on light finger annotation. Search, export,
  version history and Face ID unlock work as on the iPad. The iPad and the Mac are unchanged.
  iPhone 6.9" App Store screenshots: `scripts/screenshots.sh iphone`.
- **Paged and pageless notes** (`docs/format.md` §5.4.3, #52): a note has fixed-size pages
  or one infinite page, and switches between them without deleting or moving ink
  (`sempere notes layout ID paged|pageless`; in the app, the Page Layout menu). In the app,
  paged notes add a page after the current one or at the end, delete (with undo),
  duplicate, and reorder pages by dragging in a thumbnail strip; each gesture is one delta.
  The CLI has the same gestures: `sempere pages add --after`, `move`, `delete`, `duplicate`.
  Recognised text that moves with its ink keeps its `basis`, so it is not read again (or is,
  when it was stale).
- CLI parity with the app's note browser and canvas: `sempere notes new`, `rename`, `tag`
  (`--add`/`--remove`), `move`, `paper` (whole note or `--page N`, every parametric kind and
  parameter), `delete`, `undelete`; `sempere notebooks list` / `rename` (the whole subtree);
  `sempere tags list`; `sempere pages list` / `add`. Each edit is one delta through the same core
  code as the app (`NoteOps`, `Vault.apply`), with `--json`. Policy: the CLI gets every feature
  first (`CLAUDE.md` "CLI first").
- Web viewer (`web/`, `docs/web-viewer.md`): a static, read-only page that opens a vault from a
  web server (static files or WebDAV) or a local folder, decrypts it in the browser with the
  pasted post-quantum key (typage), and shows notebooks, tags, search over titles and
  handwriting, and the notes' pages with pan and zoom, drawn exactly like the CLI's SVG export.
  The key stays in the tab's memory; strict Content-Security-Policy; no third-party requests.
- CLI: `sempere vault index` writes `sempere-index.json`, the listing the web viewer reads on a
  static server. Once written it is kept current: every command that opens the vault rewrites it
  when the listing changed, and `sync webdav` rewrites the server's copy.
- Mac app, phase 2 (`docs/mac.md`): menu bar and shortcuts from one command list, a window per
  note with state restoration, drag a note to the Finder as PDF, a key window (recipients, add
  or remove a device key, recovery kit), mouse and trackpad input (the object eraser now works
  with a pointer), an access check for saved vault folders, and sandbox entitlements for Mac builds.
- iPad app: handwriting search. Pages are read on the device with Vision after the strokes
  change (and when a note opens), the text is saved as page recognition (`format.md` §5.5, new
  optional `basis` field), and the note list searches recognised text, titles, notebooks and
  tags and opens the matching page. Recognition from a Notability import is kept until the
  page's strokes change.
- Age library: streaming encryption and decryption in constant memory (`AgeEncryptor`,
  `AgeDecryptor`, file-to-file `AgeFile.encrypt` / `decrypt`), header-only rewrap that keeps the
  file key and payload (`AgeFile.rewrapHeader`) and streaming full re-encryption
  (`AgeFile.reencrypt`), for attachments.
- Attachment blob store (`docs/format.md` §8.1; task B2): each note's `att/` holds its
  attachments' bytes as streamed, Padmé-padded age files named by a keyed hash, verified on
  every read (framing, padding, content hash, name). Recipient changes rewrap them: header only
  when a device key is added, full re-encryption and renaming when one is removed or the key
  type changes (`vault recipients … --rewrap header|reencrypt` to choose), resumable from the
  journal. New `sempere blobs list | verify | extract | add | copy | unused | gc | repair`;
  collection is per note and per device after a 30-day window; `recover` reads a single blob.
  `vault.json` gains `features: ["attachments"]` with the first blob, and a build that finds an
  unknown feature refuses to write.
- Attachment model types (`docs/format.md` §8; task A0): placed items (text, image, PDF page, and
  unknown kinds kept verbatim), recordings, transcripts, blob references and their six ops. Revisions
  holding them now decode instead of being reported unreadable (merged since A1, above).
- PDF page backgrounds in exports (attachments task C3). A new `SemperePDF` library reads PDFs
  from untrusted attachments (cross-reference tables and streams, object streams, incremental
  updates, rebuilding a broken file by scanning; bounded and fuzzed). PDF exports copy the original
  page in as a Form XObject (exact, PDF 1.7); SVG and PNG exports draw it with Poppler's
  `pdftoppm` when installed, run as a separate, time- and resource-limited process
  (`--pdf-renderer auto|poppler|none`, `--pdf-timeout`). Anything that cannot be drawn becomes a
  placeholder with a warning, never a failed export. Applies to notes once item ops are merged (A1).
- Images in exports (task C1): PDF embeds JPEGs as stored (no re-encoding) and other images
  losslessly; SVG uses data URIs or, with `export --assets DIR`, linked files; PNG export decodes
  and resamples them (pure-Swift baseline/progressive JPEG and PNG decoders). Location and camera
  metadata is removed from every exported image unless `--keep-image-metadata`. Images that
  cannot be drawn (missing attachment, HEIC in the CLI, over 100 MP) become placeholders with a
  warning. Images and PDF page backgrounds share one export report and placeholder path, and
  Markdown and HTML exports draw both.
- Text in exports (task C2): text boxes in any script, laid out per `format.md` §8.5.3 (stored line
  breaks, else UAX #14; right-to-left per UAX #9; grapheme clusters per UAX #29), shaped (Arabic
  joining and ligatures, mark attachment), drawn with the bundled Noto fonts (OFL 1.1, shipped in
  `fonts/` next to the CLI) or font packs (`$SEMPERE_FONT_DIR`, `~/.local/share/sempere/fonts`,
  system fonts). PDF and SVG embed font subsets only, with searchable text; characters no font
  covers are reported with the script and what to install.

### Security

- `sempere vault summaries --plaintext --out FILE` writes the decrypted summaries owner-only (0600 from the
  moment the file exists, replacing any older file) instead of with the umask's mode (security review P5).
- Web viewer: a key remembered with a passkey is bound to where the vault was opened (its URL, or a folder on
  this computer) as well as its id, in the HKDF info and the AAD, and offered only there: an address that
  claims the id of a vault remembered elsewhere no longer gets "Unlock with passkey" (security review P3).
  Keys remembered before still open, and are tied to the address where they first unlock the vault.
  Remembering again tells the passkey provider the old passkey is unused, and the viewer's IndexedDB database
  is created only when a key is first remembered.
- Release checks: `scripts/release-check.sh` fails on networking in the app (`URLSession`, Network.framework,
  sockets, web views, …) outside the dormant handwriting-model downloader, and on a non-empty model catalogue;
  it checks SwiftMath's exact pin and, in CI's app job, scans its sources. The privacy policy (both copies),
  the App Store answers and `DESIGN.md` now say exactly what network code the app contains and that it never
  runs in this version. The CLI release refuses a CHANGELOG section that still holds `TODO(user)` or has no
  date.
- Security review 2026-10, the open findings (#125). **C2:** each capture profile now holds its own
  device's capture key (`format.md` §11.1), so a voice note is attributed to the device that recorded it
  (`captured` on the recording, "Voice note from iPad" in the app, `from …` in `sempere inbox list` and
  `import`) and no other profile can pass as it or add a transcript to its voice notes; profiles made
  before are replaced at unlock, and their captures adopted as unattributed. **C3:** a device removed from
  the vault can no longer add voice notes, also while the rewrap of its removal is unfinished; its waiting
  captures are reported and kept. **N3:** `format` and `features` in `vault.json` are authenticated
  (`markersTag`, `format.md` §2.1 "Version markers") and kept in the trust record: a downgraded, stripped
  or replayed manifest is refused for writing (exit 6) and reported; older vaults are tagged at their
  next unlock or write; `sempere vault markers [status|tag|repair]`. Older Sempere versions read such a
  vault and stop writing to it (the new `markers-tag` feature). **P4:** the web viewer's ciphertext cache
  is keyed by the vault's key state, so a recipient change or a finished rewrap drops copies a removed key
  could open. **C8:** the comment in `QuickCapture.swift` now names the protection class it uses.
- Security review of October 2026 (`docs/security-review-2026-10.md`):
  - A `rewrap-journal.json` planted in the vault folder, or sent by a sync server, made revisions and
    blobs tagged under a secret of the attacker's verify, and a resumed rewrap re-tagged them under the real
    secret. Its secret now counts only when `secretLink` links it to the vault's (Swift and the web viewer).
  - An unconfirmed secret is now detected before the tag is looked at. A stripped or bogus tag under a
    replaced secret can no longer be confirmed or repaired. A repair can no longer keep an attacker's key
    found by the shorter-list search.
  - A locked `sync webdav` no longer takes a `vault.json` whose sealed secret or tag changed.
  - Quick capture transcripts are bound to their audio (`format.md` §11.2), so another holder of the capture
    key cannot add one to an existing voice note. `sempere inbox transcript` takes `--audio`.
  - Trust records are created mode 0600 in a 0700 folder, and the app keeps them out of backups.
  - Other fixes:
    - PROPFIND bodies with NUL bytes (UTF-16) are refused.
    - `blobs repair` stops on a note with newer revisions.
    - `inbox capture` and `inbox transcript` refuse vaults of a newer format.
    - A huge video duration no longer traps Markdown and HTML exports or the player.
    - Video metadata stripping refuses a second `moov` or a truncated box other than `mdat`, and blanks a
      top-level `udta`.

### Changed

- Exports cut pageless pages at gaps in the ink near each sheet height instead of through
  lines of handwriting (`export --breaks gaps`, the default; `--breaks fixed` keeps the old
  cuts). Ink that a concurrent edit left below a fixed-size page is exported on an extra page
  instead of being dropped.
- `sempere notes list --notebook PATH` now lists the notes in that notebook and below it, comparing
  canonical paths by segment as the app's sidebar does (it compared raw names before).

- **Faster vault opening** (#54). Note summaries skip stroke geometry, are read in parallel,
  and are kept in an encrypted per-device cache (`docs/format.md` §10), so a 600-note vault
  lists in about 1.8 s instead of 21 s, and in 0.08 s when nothing changed. `notes list` gains
  `--no-cache`; `search` uses the same fast path. The app closes the unlock sheet as soon as the
  key is accepted, shows "Opening vault: n of m" while the list fills in, shows cached summaries
  at once on a reopen, and always says why the list is empty.

- **Instant reopen and fast note opening in the app** (#56). The note list opens from the
  encrypted local index and only notes whose revision files changed are downloaded and read
  (an iCloud vault no longer re-checks every file on every launch); a file presenter wakes the
  sync for the notes it names, a full validation runs at low priority, and list updates are
  throttled differences. Notes opened before open from an encrypted drawing cache (200 MB,
  least recently used first, deleted with the vault on this device); others are converted off
  the main thread, the strokes on screen first. Revisions decode their stroke points about twice
  as fast (same JSON). Every phase has an os_signpost interval; debug builds log timings to
  `Library/Logs/SemperePerf.log`.
- The app's Markdown export is now "Text (Markdown)": it leads with the recognised text, the
  PDF is optional (off), and it is disabled for notes without recognised text. HTML export is
  CLI-only.

- Licence: GPL-3.0-or-later with an App Store exception (`LICENSE-EXCEPTION`, a GPLv3 section 7
  additional permission). Contributions are licensed under the same terms and certified with a
  DCO sign-off; there is no contributor licence agreement.

### Fixed

- Two devices slicing (pixel eraser), moving or recolouring the same stroke without seeing each other's
  edit no longer leave both sets of pieces drawn over each other, each bringing back ink the other
  erased: the later edit wins, everywhere and in any order (`format.md` §5.6.1), including what the
  other device did to its pieces afterwards. Snapshots keep what the rule needs (`replaces`,
  `tombstones.lineage`, `tombstones.superseded`), so compaction never changes the result; the web viewer
  merges the same way. New `sempere notes dedupe (ID… | --all) [--dry-run]` lists and removes strokes
  left over in existing vaults (hidden ones older builds still draw, and duplicates the merge cannot
  resolve, such as an undo racing a slice). The app now links a stroke it moves or recolours to the
  original (`parent`), so those edits take part.

- Dragging notes onto a notebook in the sidebar, and a notebook onto another, works on the iPad and the
  Mac. The sidebar asked the drag for a "move" operation, which drags started from a list do not allow,
  so the system cancelled every drop when it was released (the row still lit up while hovering). A
  notebook dragged within the sidebar never reached the other rows at all (a list keeps its own drags):
  notebook rows now start their drag, and show their context menu, from a view of their own.
- Exporting a note with a recording no longer crashes on the Mac: Share… and Save… are presented
  by UIKit from the export sheet, and their callbacks are safe on any thread. Long recordings are
  streamed into "PDF + attachments" instead of being read into memory.

- App crash audit (no new features): a hostile or corrupt revision can no longer crash the app when a note
  is shown. Items whose frame overflows to NaN, or lies past 200 000 pt, are not drawn or selectable (Core
  Animation raised on a NaN layer position); huge video durations no longer trap in the player title and the
  Markdown/HTML exports; recorded strokes too wide to draw get no playback highlight; huge rotations are
  reduced to one turn; PDF page previews and page-strip thumbnails have pixel budgets; a NaN audio duration
  gives a valid scrubber. Opening a note in iCloud asks file states off the main thread, and a Mac drag-out
  whose preparation never ends fails after 20 s instead of freezing.

## [0.5.0] - TODO(user): date of the first release

First public release of the `sempere` CLI. Everything below was merged before
the first tag; the pull request numbers refer to
[anthonytw/sempere](https://github.com/anthonytw/sempere/pulls).

### Added

- **age v1 encryption**, spec-exact, validated against the C2SP test vectors and
  the reference `age` CLI: X25519 and scrypt recipients, armor, Bech32 keys (#2).
- **Vault format** (`docs/format.md`): append-only note log with hybrid logical
  clock, merge, snapshots and compaction (#3); on-disk layout, body framing with
  per-vault HMAC tag, keys, note store, fixture vault (#6).
- **Rendering** to vector PDF and SVG from PencilKit-style B-splines (#1), and
  pure-Swift PNG export (`export --format png [--dpi N]`) (#13).
- **CLI** `sempere`: `keys`, `vault init/info/recipients/verify`, `notes`, `export`,
  `recover`, `compact`, `snapshot` (#7); `import notability` and `search` (#12);
  `sync webdav` with the built-in WebDAV client (#16). See `docs/cli.md`.
- **Notability importer** for `.note` packages and backup zips, including
  recognised handwriting as page recognition (#8); PDF page stride and page
  counts in the import report (#18); fidelity evaluation of every imported note (#19).
- **History and restore**: restore points per revision, `notes history`,
  `notes restore`, `export --at` (#14).
- **iPad app (in development, not released)**: Xcode project, vault shell and CI (#10);
  vault browser (#15); PencilKit canvas with stable stroke ids and autosave (#17);
  usability pass: a vault as one item in Files, progressive iCloud loading,
  tool palette, rename, tags (#21).
- **Release engineering**: tagged builds publish static Linux (x86_64, aarch64) and
  universal macOS CLI tarballs with `SHA256SUMS` and build provenance
  attestations; Homebrew formula template; CONTRIBUTING, SECURITY and App Store
  preparation docs.
- CI: Linux (`swift:6.4-noble`) and macOS test jobs, static Linux CLI build (#4),
  cloud setup script (#11).

### Fixed

- Render input validation and infinite-page output (#5).
- Two PNG and marker rendering bugs found by the import fidelity evaluation (#19).
- App: debug launch expands `~/` to the app's data container (#20).

[Unreleased]: https://github.com/anthonytw/sempere/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/anthonytw/sempere/releases/tag/v0.5.0
