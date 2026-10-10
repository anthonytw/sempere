# Gap audit, October 2026

What the docs promise against what `main` does. Docs-only audit, no feature code.
Audited at `ecc62ec` (#119) on 2026-10-09; `main` was merged in afterwards (#121, which
brought the ROADMAP and plan statuses up to date, so the stale-status rows of the area
audits no longer apply). Statuses in `docs/ROADMAP.md` were not trusted while auditing.

## Method and limits

- Every doc in `docs/` (format, io, cli, mac, iphone, attachments, quick-capture,
  import-notability, web-viewer, localization, post-quantum, releasing, `release/`,
  `appstore/`, `privacy/`, the security review, HANDOFF, ROADMAP, plan) and
  `DESIGN.md` was read by area. For each behaviour described as existing, the code
  under `Sources/`, `Apps/`, `web/src/` and the tests were searched.
- Only gaps are listed. A behaviour that is implemented, tested and reachable is not.
- `docs/format.md` (3,100 lines) and `docs/attachments.md` (1,960 lines) were read
  selectively and checked by grepping for the identifiers they name, so a gap in a
  section nobody named is possible. No tests were run (no Xcode here), so "untested"
  means "no test found by search", not "test fails".
- The code has no `TODO`/`FIXME`/`HACK` comments and no `it.skip`, `xit`, `#if false`
  or `@Test(.disabled)`. Skipped tests are all environment guards (section F).
- Evidence was spot-checked by the author for the rows marked ✔ in the last column of
  section A (rotation, favorites, voice notebook, transcription download, C4 modes,
  P5, network, changelog, CLI read-only and flag tests, `validateVault`); the rest is as reported by the area audits and cites
  `file:line` for the reader to confirm.
- Open PRs that already cover a gap (at the time of writing) are named in the state column, not proposed again:
  #122 (recordings list page and `--format media`), #123 (mouse stroke smoothing); both have since merged (GA-20, GA-21 are done).

Scope (maintainer, 2026-10-09): everything here is in scope for the first release and is
planned in `docs/ROADMAP.md`, where each row was folded into its component section with its
GA id and size; GA-11, GA-12, GA-22, GA-24, GA-25 and GA-26 are dropped (marked below).

Size: S = under a day, one PR, little design; M = a PR with design choices or app and
CLI work; L = a design question, a format change or an outside decision.

## A. Features: documented, partly or wholly missing

| ID | Area | Behaviour | Where documented | State on main | Evidence | Size |
| --- | --- | --- | --- | --- | --- | --- |
| GA-01 | Notes | Favorites: `meta.favorite` is read (summaries, web viewer's Favorites list) but nothing can set it | `format.md` §5.4 (meta register), §12; `cli.md` notes | done in #131: `notes favorite`, `notes list --favorites`; the app toggles it (context menu, toolbar) and lists Favorites in the sidebar | `Sources/Sempere/Model.swift:554,862` (model); no hit for "favorite" in `Sources/SempereCLI` or `Apps/Sempere/SempereApp`; `web/src/ui/app.ts:420,458` | M |
| GA-02 | Items | Rotate an item in the app (CLI `items rotate` exists) | `attachments.md` §14 E0 | done in #131: Rotate 90° Left / Right in the selection menu and a two-finger turn; one undo step | `Apps/Sempere/SempereApp/NoteEditor+Items.swift:119` (`setItemRotation`, no caller in `Apps/`); `Sources/SempereCLI/Items.swift:172` | M |
| GA-03 | Items | Edit a placed text box's text or style from the CLI | `attachments.md` §14 F ("Not done") | app-only; `NoteOps.setText` exists in core | `Sources/SempereCLI/Items.swift` (subcommands: list, move, rotate, crop, replace, front, delete, duplicate, copy, math, poster; no text) | M |
| GA-04 | Settings | "Notebook for quick voice notes" in Settings → New Notes does nothing: capture reads the notebook stored in the capture profile (Quick Voice Notes section) | `attachments.md` §15; `SettingsView` footer | done in #131: Quick Voice Notes ▸ Notebook is the one setting; the New Notes field is removed and its stored value migrated | `NewNoteSettings.voiceNotebook()` read only at `Apps/Sempere/SempereApp/SettingsView.swift:81,140`; capture uses `QuickCaptureSettings.swift:30-31,71`, `AppModel+Inbox.swift:22` | S |
| GA-05 | Settings | Transcription model download status "and a download button" | `attachments.md` §15 | done in #131: the button calls `SpeechTranscription.downloadModel` (Apple's asset service) and `transcribe --download-model` does the same | `TranscriptionSettings.downloader` declared `DeviceSettings.swift:218`, read `SettingsView.swift:303,326`, assigned nowhere; `RecordingPreferences.swift:53-62` ("Nothing is downloaded here") | M |
| GA-06 | Search | Transcript text in the app's search (CLI `search --transcripts` and the web viewer have it) | `attachments.md` §14 E5 ("Not done") | app missing | no "transcript" in `AppModel+Search.swift` or `VaultIndex.swift`; `web/src/…/transcriptsearch.ts` | M |
| GA-07 | Search | Highlight search hits on text boxes (only recognition boxes are highlighted) | `attachments.md` §14 E2 ("Not done") | app missing | `Apps/Sempere/SempereApp/NoteEditor+SearchHighlight.swift` is recognition-box based | M |
| GA-08 | Import | The app's Notability import hides the report (`dropped.*`, warnings) and has no option for `--no-attachments`, `--keep-image-metadata`, `--recognize missing`, `--pdf-text` | `import-notability.md` "Not imported" (counted with a warning); ROADMAP "same defaults" | partial in the app | `AppModel+NotabilityImport.swift:25-31` (`NotabilityImportSummary` keeps imported/skipped/failed only) | M |
| GA-09 | Import | Notability's own transcripts become transcript blobs (`engine: notability-<version>`) | `attachments.md` §11 Recordings ("if any") | missing | no "transcript" in `Sources/SempereImport/*.swift` | S |
| GA-10 | Import | GIF, TIFF and WebP images in a Notability bundle: doc says counted in `dropped.media`; code classifies them as images but `ImageIngest` refuses non-JPEG/PNG | `import-notability.md:947` | unclear; trace and fix doc or code | `NotabilityBundleAttachments.swift:23`; `AttachmentIngest.swift:13` | S |
| GA-11 | Transcription | `DictationTranscriber` step of the fallback chain | `attachments.md` §14 E5 | dropped (maintainer, 2026-10-09) | no hit in `Sources/SempereSpeech` | S |
| GA-12 | Recording | Live transcript while recording; "ink appears as it was written" playback mode | `attachments.md` §14 E4 ("Not done") | dropped (maintainer, 2026-10-09) | no `AVAudioEngine` in `Apps/` | L |
| GA-13 | Mac | Keyboard shortcuts for item actions (duplicate, front, delete) and for recording | `attachments.md` §14 E0, E4 | done in #131: ⌘D, ⌥⇧⌘F, ⌃⌘⌫ for Duplicate / Bring to Front / Delete Item and ⌃⌘M for Start / Stop Recording | `Apps/Sempere/SempereApp/MenuCommand.swift:148` | S |
| GA-14 | Mac | Menu parity: Version History, page duplicate/delete/undo-delete, Add Page After This One, layout toggle, Show Pages, Text and Select tools, eraser size, Compact Palette are toolbar-only; the menu's Add Page only appends | `mac.md` (menu table) | done in #136 (Note, Tools, View menus; no Edit entry) | `MenuCommand.swift:11-24` vs `NoteCanvasView.swift:458-560`; `AppCommands.swift:~138` | M |
| GA-15 | iPhone | Page layout switch, Duplicate/Delete/Undo Delete Page, Add Page After This One, Insert PDF at page, thumbnail strip are not on the phone toolbar | `iphone.md:44-51` | done in #136 (Pages submenu of the overflow menu) | `NoteCanvasView.swift:458,473,534-548,252,558` (`fullToolbar`); `phoneToolbar` 312-346 | M |
| GA-16 | iPhone | Swipe to turn pages; search-hit highlights on the phone; paper picker layout pass | `iphone.md:104-106` | done in #136: swipe and picker layout; the highlights already worked on the phone (shared canvas code, test added) | `PaperPickerView.swift:32,49` | M |
| GA-17 | App | Recipient repair `--keep` and replace-recipient outside migration are CLI-only (the alert tells the user to run the CLI) | `format.md` §2.1 Repair, §3.3; `cli.md:194-199` | done: #135 (Choose Devices to Keep…, Replace…) | `AppModel+Recipients.swift:72,90-93` | M |
| GA-18 | Backup | "Remind Me" (overdue reminder) has no CLI counterpart; `--prune` and `--archive` have no app counterpart | `io.md:667-673`; `cli.md:783-785` | done: #135 (`backup status --max-age`; prune and archive stay CLI-only, reasons in `cli.md`) | `BackupReminder.fireDate` (app); `Sources/SempereCLI/Backup.swift:47,57` | S |
| GA-19 | Export | HTML and SVG export, `--clean`, `--breaks` are CLI-only; the app's `ShareFormat.html` is never offered | `io.md:460-461,499` | CLI-only (documented) | `ExportCommand.swift:7-9`; `ExportSheet.swift:207,221` | S |
| GA-20 | Export | `export --recordings list` (a recordings list page) and `--format media` | `attachments.md` §14 C4, §16 #14; ROADMAP line 48 | done: #122 merged after the audit | was `Sources/SempereCLI/Export.swift:241-243` (`none, attach` only) | M (#122) |
| GA-21 | Mac | Mouse and trackpad stroke smoothing | `mac.md:408-411`; ROADMAP "mouse stroke smoothing 💡" | done: #123 merged after the audit | `Sources/Sempere/StrokeSmoothing.swift` | M (#123) |
| GA-22 | Math | "Convert to Math" ships with no model: `MathModelCatalog.entries` is empty, the pref is off by default, a model loads only from a DEBUG folder | `docs/research/handwriting-to-latex.md`; ROADMAP #118 | dropped (maintainer, 2026-10-09); the on-device import tooling of #127 stays as is, behind its off-by-default flag | `Sources/SempereRender/MathModel.swift:217-221`; `Apps/Sempere/SempereApp/MathModels.swift:9-15,66`; `MathSettings.swift:16` | L |
| GA-23 | Capture | Quick capture on a Mac only through Shortcuts and Siri; no menu-bar item | `quick-capture.md` "Surfaces" | done: File > Start/Stop Voice Note in #136; the status-bar item (AppKit bundle) in the follow-up PR | no menu-bar code under `Apps/` | M |
| GA-24 | Capture | Adopt captures from a key that no longer verifies, after a confirmation; keeping the secret in the Keychain is an open design question | `quick-capture.md` threat model | dropped (maintainer, 2026-10-09) | no code path | L |
| GA-25 | Web | Ink linked to audio (`rec`): tap to seek, playback highlight | `web-viewer.md` Limits | dropped (maintainer, 2026-10-09) | no `rec` handling in `web/src/ui` or `web/src/render` | M |
| GA-26 | Web | Search matches highlighted on the page and in audio cards | `web-viewer.md` Limits | dropped (maintainer, 2026-10-09) | doc only | M |
| GA-27 | Import | Dashed strokes imported solid; strokes and shapes of undecoded `.ntb` kinds not converted (counted and reported); highlighter-behind-PDF, pages of two heights | `import-notability.md` "Not imported" | partial (documented, counted) | `Sources/SempereImport/NotabilityImporter.swift:487`; `NotabilityBundle.swift:181,193` | M–L |
| GA-28 | Web | A cached or remembered thing the docs call safe is not: web cache ciphertext from before a rewrap stays openable by a removed key (P4); passkey record keyed by an unauthenticated vault id (P3) | `web-viewer.md` "Opening fast", "A key remembered with a passkey"; `security-review-2026-10.md` P3, P4 | P3 fixed in #130 (records bound to the vault's location, version 1 records migrated); P4 in #125 | `web/src/vault/cache.ts:141,151,224`; `web/src/vault/passkey.ts:28,43` | S each |

## B. Security review: findings still open on main

From `docs/security-review-2026-10.md`; the ones with code evidence are verified present.
Fixed items (R4/W1, W2–W5, C5, R5, N2, P1) each have code and a test.

| ID | Finding | State on main | Evidence | Size |
| --- | --- | --- | --- | --- |
| GA-30 | P5: `vault summaries --plaintext --out` writes a world-readable file ✔ | fixed in #130 (created 0600, then renamed into place) | `Sources/SempereCLI/Summaries.swift:55` (`.atomic`, no 0600) | S |
| GA-31 | C2: a forged capture's attribution (capturing device not stored, notebook from the manifest) | open (title and notebook bounds fixed) | `Sources/Sempere/CaptureInbox.swift` (`boundedName`) | M |
| GA-32 | C3: a removed device's captures are adopted while its rewrap is unfinished | open; needs an authenticated names list (format change) | review "C3: left open"; `quick-capture.md` | L |
| GA-33 | N3: `format` and `features` in `vault.json` are not covered by `recipientsTag` | open; limit documented | `format.md:274` | L |
| GA-34 | C8: stale `completeUnlessOpen` comments | open (Info) | `Apps/Sempere/SempereApp/QuickCapture.swift:118,283` vs `:190` | S |

## C. Network, privacy and release documents that disagree with the code

| ID | Item | State on main | Evidence | Size |
| --- | --- | --- | --- | --- |
| GA-40 | The privacy policy (both copies), App Store answers and `DESIGN.md` say the app makes no network connections; the app now contains a model downloader. It never runs (empty catalogue) and the Mac build lacks `network.client`, so it could not run sandboxed anyway. `release-check.sh` has no check for `URLSession` in `Apps/` | doc-stale, and an unguarded drift | `Apps/Sempere/SempereApp/MathModels.swift:185-191` (comment: "the app's only network use"); `docs/release/app-store.md` §3, §6; `docs/appstore/privacy-policy.md:11`; `docs/privacy/index.html:30`; `scripts/release-check.sh` (no match) ✔; fixed in #130: the documents describe the dormant downloader, `release-check.sh` fails on networking outside `NETWORK_ALLOWED` and on a non-empty catalogue | M |
| GA-41 | `CHANGELOG.md` `## [0.5.0] - TODO(user): date…` would ship as the release-notes heading; `release.yml` only checks the section is non-empty | guarded in #130 (`changelog-section.sh` refuses `TODO(user)` and an undated heading, so the tag fails); the date itself is the maintainer's | `CHANGELOG.md:357` ✔ | S |
| GA-42 | SwiftMath's privacy manifest TODO and version pin unverifiable from the root `Package.resolved` | fixed in #130: the pin is in the project's own `Package.resolved` (1.7.3, `fa8244ed`) and `release-check.sh` matches it to the pbxproj; CI's `app` job scans the checkout (`--checkouts`): 1.7.3 has no manifest, no required-reason API use and no networking, so it needs none | `docs/release/app-store.md` §2; `project.pbxproj:703` | S |
| GA-43 | The App Store review notes / listing draft claims highlighted words on the page; not re-checked against the iPhone, which has none | to check | `docs/release/app-store.md` §8; `iphone.md:104` | S |

## D. Tests and CI: behaviour exists, nothing checks it

| ID | Item | Evidence | Size |
| --- | --- | --- | --- |
| GA-50 | WebDAV integration tests never run in CI (`SEMPERE_WEBDAV_TEST_URL`; only `scripts/test-webdav.sh`) | `Tests/SempereWebDAVTests/IntegrationTests.swift:12,120`; `BlobIntegrationTests.swift:16`; `Tests/CLITests/CLIWebDAVTests.swift:62,85`; `ci.yml` (no match) | M |
| GA-51 | Pseudo-language layout test (double-length, RTL, Spanish) never runs in CI, and only on the iPad simulator, not at iPhone width or on Catalyst | `PseudoLanguageUITests.swift:22-25,49`; `scripts/app.sh:7,72` | S–M |
| GA-52 | Web CI runs 2 of 7 browser smoke scripts; `smoke-cache` skips the summaries and index scenarios because the fixture has neither file | `ci.yml:358-362`; `web/scripts/smoke-cache.mjs:118,127` | M |
| GA-53 | No Linux assertion for `sempere recognize` without Vision (exit 1, nothing changed) or for `attach video --from-clip` without AVFoundation ✔ | `Sources/SempereCLI/Recognize.swift:15-18,111,116`; `AttachVideo.swift:211`; `Tests/CLITests/CLIRecognizeTests.swift:134` (`#if`, no `#else`) | S |
| GA-54 | `writeEpoch` (the "save during a merge read reads again" data-loss guard), `summaryEpochs`, `DerivedLists`, `listUpdateInterval` have no direct tests | `NoteEditor.swift:94,976,1002,1088,1103`; `AppModel.swift:119`; `AppModel+ListUpdates.swift:130` | M |
| GA-55 | `validateVault` (30-minute iCloud validation) and `backgroundTimeExpired` untested | `AppModel+Reconcile.swift:240`; `BackgroundSync.swift:29-30` | S |
| GA-56 | Quick-capture intents, widget views and Live Activity dismissal (5 s / 12 s) untested | `QuickCapture.swift:512-559`; only `VoiceNoteStatusTests`, `QuickCaptureTests` | M |
| GA-57 | Menu handlers (`RootView.perform`, Open Recent, Reopen Last Vault) and `@SceneStorage` restore untested; `MacWindowUITests` presses no Note/Tools/View command | `RootView.swift:307-339,24,267,273`; `AppCommands.swift:59-61` | M |
| GA-58 | iPhone: no UI test of the overflow menu or Annotate; the "wide landscape ignores stored column" rule and the pageless one-screen rule are untested at phone size | `PhoneLayoutTests.swift:87-198`; `RootView.swift:37-38` | M |
| GA-59 | Key export: printing the recovery kit, `KeyFileActions`, `adoptRewrapped`/`keyEpoch`, PDF-drag purge (`PDFPreparation.purge`) untested | `KeyExportViews.swift:56-57,100`; `PDFPreparation.swift:87`; `AppModel+Windows.swift:255` | S |
| GA-60 | `sync webdav --retry-quarantined` and the `.sempere-restore.json` resume marker are tested at library level only, not through the commands | `Sync.swift:97`; `Sources/Sempere/Backup.swift:258` | S |
| GA-61 | Required-tool skips are not turned into failures in CI for zbar, zip, pdftotext, `BidiTest.txt` (UCD 15.1 must match) or macOS poppler; a missing install skips silently | `QRCodeTests.swift:207`; `ZipArchiveTests.swift:31`; `UnicodeConformanceTests.swift:59-60`; `ci.yml:92-95,116-117` | S |
| GA-62 | Mac Catalyst app suites run only on `main` and dispatch, not on PRs | `ci.yml:255-271` | S (decision) |
| GA-63 | Fixture vault has no note with items (README says "a follow-up of A1", merged in #66) | `Tests/SempereTests/Fixtures/README.md:32` (verify) | S |
| GA-64 | Settings tests: no test for the "removal: headers only" confirmation or the photo-privacy default | `SettingsView.swift:498` | S |
| GA-65 | Read-only vaults (exit 7): `cli.md:67-73` lists about 40 write commands that must refuse; `CLIReadOnlyTests` covers 15. Untested: `notes move/paper/undelete/language/markers/layout/restore`, `pages move/delete/duplicate`, every `items`, `attach image/pdf/math/video/recording/transcript`, `recordings place/rename/delete`, `notebooks rename/move`, `import notability/pdf`, `blobs copy`, `recipients remove/replace/repair/confirm`, `inbox import`, `recognize`, `restore` (a command that forgets `requireWritable` would write into a newer-format vault) | `Tests/CLITests/CLIReadOnlyTests.swift:80-100` | M |
| GA-66 | CLI flags documented but never exercised by a test: `search --show-boxes`, `backup --checksum`, `export --pdf-timeout`, `sync --retry-quarantined`/`--device`, paper options (`--line-width`, `--dot-radius`, `--margin-*`, `--staff-*`, `--summary-height`, `--background`), `items duplicate --dx/--dy`, `items crop --keep-frame`, `attach text --italic`, `attach recording --sample-rate/--channels`, `--store-passphrase-env`; `blobs repair` only for "nothing to do" | `cli.md:973-982,1070-1078,1299-1304,1482,1896-1957`; `Search.swift:107`; `Backup.swift:49`; `Export.swift:125` | S–M |

## E. Device verification still owed

Not code gaps, but "done" in the docs and unverified: `mac.md` "To try by hand" (13 steps,
sandboxed reopen of a bookmarked vault, window restoration, Finder drag-out and Open With,
iCloud PDF pages, recording card export) — GA-70 (L, needs a Mac); `iphone.md` "not tried on a
physical iPhone" (Face ID, folder picker, finger annotation) — GA-71 (M, needs a phone);
the "not yet tried on the iPad" rows of ROADMAP, in particular background sync
(`io.md:193-235`), remote merge, continuous page scrolling, drops, sidebar — GA-72 (M, needs
the iPad); the sandboxed Catalyst bookmark question (`io.md:413-439`) — GA-73 (M).

## F. Documents that are stale (fix the doc, not the code)

| ID | Document | What is stale | Size |
| --- | --- | --- | --- |
| GA-80 | `docs/ROADMAP.md` | Header commit and many 🚧/🔀 rows for merged PRs: fixed by #121; `vault summaries` is still listed twice | S |
| GA-81 | `docs/attachments.md` | Tasks B1–E5 say "in review (#NN)"; G1/G2 headed "not scheduled"; "F: removing a placed item not done" but `items delete` exists (`Items.swift:356`); §11 "Unknowns to investigate" are all implemented; E7 has no status block | S |
| GA-82 | `docs/import-notability.md:338-341` | Sample table lists images, template PDFs, typed text, `.ntb` PDF pages as "not imported"; they are imported | S |
| GA-83 | `docs/format.md:2815-2817` (§10.1) | The `activity` file no longer holds Recently Recognized (`meta.recognized`, `RecentActivity.swift:~33-37`) | S |
| GA-84 | `docs/localization.md:24-31` | Two catalogs listed, a third (`AppShortcuts.xcstrings`) exists; `SempereInfo.plist` has no `es` (`knownRegions` is in the pbxproj) | S |
| GA-85 | `docs/mac.md` | Settings can open in more than one window (`SempereApp.swift:74-77`); the list of features gated off on Mac (quick capture, background refresh, voice-note banner, video capture) is not stated; iPad keyboards get no shortcuts besides Export | S |
| GA-86 | `DESIGN.md` | "Built-in WebDAV client (phase 3)" (app has none; fixed with the app's WebDAV vaults, #137); "undecided" distribution and contributor-agreement text (exception exists, app in TestFlight); "X25519, ChaCha20-Poly1305" and "OpenPGP backend" (post-quantum only) | S |
| GA-87 | `docs/security-review-2026-10.md` | Status lines contradict the table (W2, W5, C5, R5 still under "Open"); P2 listed unfixed but `SecretPasteboard` exists (`KeyExportViews.swift:240-246`); file:line refs are to the review branch | S |
| GA-88 | `docs/web-viewer.md` | Threat model omits P3/P4; intro and key paragraph disagree on IndexedDB | S |
| GA-89 | `docs/release/app-store.md` §2 | Line numbers in the required-reason table drift (`release-check.sh --list` regenerates) | S |
| GA-90 | `docs/cli.md` / `sempere --help` | `--version` documented "on every command" but exists at the root only (`Root.swift:19`); root help lists exit codes 0–5, not 6 and 7 (`Root.swift:13-15` vs `Support.swift:23-24`); `export --format` help omits markdown and html (`Export.swift:87` vs `:11`); env table lacks `SEMPERE_PDFTOTEXT`, `SEMPERE_TITLE_FORMAT`, `SEMPERE_BUNDLED_FONTS`, `SEMPERE_FONT_DIR`, `SEMPERE_WEBDAV_PASSWORD`, `XDG_CACHE_HOME` (`cli.md:95-103`); `attach text --no-breaks` missing from the synopsis (`cli.md:442-445`); hidden `__rasterize-pdf` undocumented; ROADMAP lists `vault summaries` twice (lines 103, 119) | S |

## Checked, no gap found

Menu table in `mac.md` (every command exists with its shortcut); `.help` tooltips
(`scripts/check-help.py`: 155 files); Spanish catalog (1,069 entries, none missing or
stale); every §15 setting exists and is read by its feature, except GA-04 and GA-05;
post-quantum paths and CI requirements; release workflow vs `releasing.md`;
`scripts/release-check.sh` passes; CI jobs named in the docs all exist; web viewer
parity with the Swift newer-format rules; every CLI subcommand has at least one test; every long flag in `cli.md` exists in code and every flag in code is in `cli.md`; every app feature that reads or changes vault data has a command, apart from GA-01 to GA-03, GA-17 and stroke-level ink editing (by design, `cli.md:5-6`).
