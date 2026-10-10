# Plan

## Phase 0 — core library and CLI (Linux-buildable, cloud-friendly)

| # | Task | Owner target | Done when |
| --- | --- | --- | --- |
| 0.1 ✅ | age v1: X25519 + scrypt recipients, header, HMAC, STREAM payload, armor, Bech32 keys | `Sources/Age` | all C2SP CCTV vectors pass; round-trips with the `age` CLI |
| 0.2 ✅ | Vault: manifest, keys, vault secret, body framing + tag, revisions, HLC, merge, snapshot, compaction; on-disk vault I/O (`docs/io.md`) | `Sources/Sempere` | property tests for merge; concurrent-edit scenarios; `format.md` examples parse; vault round trip, tag binding, resumable recipient rewrap, `age -d … \| tail -c +38 \| gunzip` recovery test; fixture vault in `Tests/SempereTests/Fixtures` |
| 0.3 ✅ | Render: B-spline evaluation, variable-width outlines, paper, PDF writer, SVG writer | `Sources/SempereRender` | golden-file tests; PDF opens in Preview; matches PencilKit interpolation on macOS |
| 0.4 ✅ | CLI: `keys`, `vault init/info/recipients/verify`, `notes`, `export`, `recover`, `compact`, `snapshot` (done, `docs/cli.md`) | `Sources/SempereCLI` | end-to-end test: init → write revisions → export PDF → `age -d` recovery |
| 0.5 ✅ | CI: Linux (swift:6.4-noble) + macOS; static Linux CLI artifact; cloud setup script | `.github`, `scripts` | green on PR, binary downloadable |
| 0.6 ✅ | Notability importer: `.note` packages (and Notability's Google Drive backup zip) to notes, including Notability's recognised handwriting as page recognition (`docs/import-notability.md`); CLI `import notability` (done, `docs/cli.md`) | `Sources/SempereNotability`, `Sources/SempereCLI` | synthetic `.note` fixture tested in CI; whole personal backup imports; rendered output checked against Notability thumbnails |
| 0.7 ✅ | CLI `search` over page recognition text (done, `docs/cli.md`; matching note title, notebook and tags is not implemented) | `Sources/SempereCLI` | end-to-end test: import fixture → search finds a recognised word |
| 0.8 ✅ | Interop fixture vault committed under `Tests/Fixtures` with a throwaway key | tests | every target can load it |
| 0.9 ✅ | CLI parity with the app (CLI-first rule, `CLAUDE.md`): `notes new/rename/tag/move/paper/delete/undelete`, `notebooks`, `tags`, `pages list/add` (done, `docs/cli.md`); page add/move/delete/duplicate and `notes layout` (done in #52); `recognize`, `import notability --recognize missing`, `notes search` (#78) | `Sources/SempereCLI`, `Sources/Sempere` | each app edit has a command with `--json` and CLI tests |
| 0.10 ✅ | CLI for attachments (done, `docs/cli.md`): `attach image\|pdf\|text\|recording\|transcript`, `import pdf`, `search` over typed text and transcripts | `Sources/SempereCLI`, `Sources/Sempere` | end-to-end CLI tests in `Tests/CLITests/CLIAttachTests.swift` |
| 0.11 🚧 | Gap audit, search and import (#134, `docs/research/gap-audit-2026-10.md`): GA-06 transcripts in the app's search (`TranscriptSearch`), GA-07 highlights inside text boxes (`TextMatchBoxes`, `search --show-boxes`), GA-08 the app's Notability import options and report, GA-09 Notability transcripts as blobs, GA-10 GIF and TIFF converted to PNG, GA-27 feasibility (`docs/research/ntb-undecoded-kinds.md`) | `Sources/Sempere`, `Sources/SempereRender`, `Sources/SempereImport`, `Apps/` | CLI and core tests green; the app job on CI |
| 0.12 🚧 | The Notability importer as a removable module (#145): `SempereNotability` target and tests, a `VaultImporter` interface and registry in `SempereImport`, generic `sempere import <id>` and app Import entry, CI proof that deleting the directory builds and tests | `Sources/SempereImport`, `Sources/SempereNotability`, `Sources/SempereCLI`, `Apps/` | `scripts/check-removable-importers.sh` green; import eval fixtures unchanged |

## Phase 1 — iPad app

Xcode project under `Apps/`. SwiftUI shell; PencilKit canvas with the system
tool picker; paper layer; notebook/tag sidebar; autosave to the note log;
vault location picker (on device, iCloud Drive, Files-app folder); key
generate/import (AirDrop, QR, paste)/export; PDF share sheet; Face ID unlock;
on-device handwriting recognition (Vision `VNRecognizeTextRequest` on
rendered pages, iPadOS 26) writes page recognition (`format.md` §5.5); search
UI over it (done: `PageRecognizer.swift`, `NoteEditor` recognition,
`AppModel+Search.swift`, `Sources/Sempere/NoteSearch.swift`). Status: ✅ on `main`, handwriting search
not yet tried on the iPad.

Settings sync through the vault (`docs/settings-sync.md`, `format.md` §13): the shared
`settings.age` with per-key merge, device-type blocks, local overrides and versioned
compatibility rules; CLI `sempere settings`; the app's Settings ▸ Sync Settings with This
Vault. Status: 🚧 #144 (accepted by the maintainer 2026-10-09; device names later).

| # | Task | Owner target | Done when |
| --- | --- | --- | --- |
| 1.S 🚧 | Settings sync through the vault: core (`SharedSettings`, `SharedSettingsCatalog`, `SharedSettingsMigrations`, `SettingsSyncState`), CLI `settings`, WebDAV merge, backups, app (`SettingsSyncBridge`, `AppModel+SettingsSync`, Settings section, row overrides), Spanish | `Sources/Sempere`, `Sources/SempereCLI`, `Sources/SempereWebDAV`, `Apps/` | core, CLI and WebDAV tests green on Linux; the `app` job green; tried on two devices (needs the maintainer) |

The iPhone reader is the same target (`docs/iphone.md`, PR #65): compact stack, read-first note view,
finger annotation behind a button, tests at iPhone sizes, 6.9" screenshots. Status: ✅ #65, not yet tried on a physical iPhone.

Setting expectations (maintainer, 2026-10-09; #142): `sempere --version` and `sempere about` print the
GPL-3 notice and links (`SempereAbout`, shared with the app); the app's "About Your Key" notice (first
unlock of a vault with a key on a device, new vaults included), the quick tour (once per device),
Settings ▸ About (bundled licence and third-party notices) and the Mac's About and Help menus
(`Expectations.swift`, `ExpectationsViews.swift`); `docs/security.md` (what the encryption protects and
its limits) and the SECURITY.md advisory process; App Store licence agreement and §7 exception drafts
in `docs/appstore/` for the maintainer and a lawyer (not applied). Status: ✅ on the branch; the
notices are not yet tried on the iPad or a Mac.

## Phase 2 — Mac companion

Same target via Catalyst: menus, keyboard shortcuts, multi-window, drag and
drop export, key management, pointer input (`docs/mac.md`). Status: ✅ #46, #85 (bulk export from the app: #42); several items
need a hand test on a real Mac (`docs/mac.md` "To try by hand"); build 7 polish ✅ #101 and the launch fixes ✅ #116, #120 are not yet tried on a Mac; launch smoke tests ✅ #119 (CI on every run).

## Phase 3 — nice to have

Built-in WebDAV client (`sempere sync webdav`, `docs/io.md`; the app's WebDAV
vaults, a local copy pushed push-only, 🔀 #137); compaction UI (✅ #74 thinning setting and "Thin Now");
~~PNG export~~ (done: `sempere export --format png [--dpi N]`, pure-Swift rasterizer in
`Sources/SempereRender`, `docs/cli.md`); page backgrounds (PDF and image attachments: in the reference
Notability backup 26 of 130 notes are annotated PDFs and 4 hold images, all
imported today as ink on blank paper; now designed with text boxes and audio,
see "Attachments" below); ~~stroke
dedupe after concurrent slicing~~ (done in #126: `format.md` §5.6.1, the later of two
concurrent replacements of a stroke wins; `sempere notes dedupe` checks and repairs vaults
written before); ~~post-quantum recipient type~~ (done:
MLKEM768-X25519, `docs/post-quantum.md`); ~~read-only
access to vaults of a newer format version~~ (done in #94: `format.md` §7,
`Vault.readOnlyReasons`, CLI exit 7, app banner, web viewer).

Done from this list:

- **Security review and gap audit follow-ups** (`docs/security-review-2026-10.md`,
  `docs/research/gap-audit-2026-10.md`): P3 (web passkey records bound to the vault's
  location) and P5 (`vault summaries --plaintext` written 0600) ✅ #130; release hygiene
  GA-40 to GA-42 (exact network statements, the `release-check.sh` networking rule and
  SwiftMath pin and checkout scan, the CHANGELOG `TODO(user)` guard) ✅ #130. C2, C3, N3,
  P4 and C8 are #125's; the other `GA-nn` rows are in the ROADMAP's tables by area.

- **Recovery kit and backups** (`docs/cli.md` "Keys" and "Backup and restore",
  `DESIGN.md` "Recovery"): `sempere keys paper` prints the key (or the
  passphrase-wrapped key file) as a QR code and checked text with stock-tool
  recovery steps; `sempere backup` (incremental folder or tar), `backup
  verify`, `restore`. The app's Backups (✅ #110, not yet tried on a device; Settings ▸ Backups): Back
  Up Now, Verify Backup, reminder, Restore from Backup into a new vault, on
  the same core (`backup status` and `restore --dry-run` added for it); its
  footer points to Settings ▸ Device Keys ▸ Save Key… (the kit, ✅ #99).

- **History and restore, core + CLI** (`Sources/Sempere/History.swift`,
  `format.md` §5.7, `docs/cli.md`): restore points per revision, the note as of
  any revision, `Vault.restore` writing one delta (re-added items get new ids
  with `parent`), `sempere notes history`, `notes restore --to [--dry-run]`,
  `export --at`. Compacted revisions are not restore points. The
  history browser UI in the app is ✅ #41 (checkpoints and thinning ✅ #74), on top of `Vault.restorePoints`,
  `Vault.state(noteId:at:)` and `Vault.restore`.

## Attachments (typed text, images, audio, PDF pages)

Design: `docs/attachments.md` (rationale, task details and acceptance
criteria) and `docs/format.md` §8 (normative). Status: **decisions final**
(`docs/attachments.md` §16); no task starts before the design PR merges. A0
goes first; after it, the rest run in parallel along the dependencies in
`docs/attachments.md` §14. G1 (both parts; part 2 has no model yet), G2, E7 and L are done; none blocks anything.

Status per task: ✅ done on `main` (PR number) · 🚧 in progress (open PR) · 📋 planned for the first release. Checked against `main` at `ecc62ec` (#119) on 2026-10-08. Beyond this table, the
build 7 follow-ups are all ✅ merged, none yet tried on a device: selecting items and Replace Image (#104), audio items on the page (#103),
sidebar drops and shared Recently Recognized (#102), Mac polish (#101), quick voice fixes (#106, #107), bulk export (#109) and backups in the app (#110).

| # | Task | Owner target | Depends on | Done when (summary) |
| --- | --- | --- | --- | --- |
| A0 ✅ | Model types: items (integer layers), recordings, transcripts, blob refs, text (Unicode, `breaks`), `rec`, six ops, open fields (`JSONValue`). ✅ **Done (#47)**: `Sources/Sempere/Attachments.swift`, `JSONValue.swift`; snapshots refuse attachments until A1 | `Sources/Sempere` | — | every `format.md` §8 example round-trips; unknown kinds/fields/layers re-emitted verbatim |
| A1 ✅ | Merge, snapshots, tombstones, orphans, history/restore, summaries. ✅ **Done (#66)**: `NoteReducer.swift`, `AttachmentRegisters.swift`, `History.swift`, `NoteSummary.swift`; web `reducer.ts`, `registers.ts`; CLI `notes show`. Fixture note with items still to do | `Sources/Sempere` | A0 | shuffled-order property test with items; concurrency scenarios of §14 |
| B1 ✅ | ✅ **Done (#43)**: age streaming encrypt/decrypt, header-only rewrap, streaming re-encrypt | `Sources/Age` | — | CCTV via streaming; 300 MB bounded-memory round trip; `age` CLI interop |
| B2 ✅ | ✅ Per-note blob store (`notes/<id>/att/`): names, kinds, framing, Padmé, verify, copy, rewrap policy (header-only on add, re-encrypt on removal/PQ) + rename, per-note collection, `sempere blobs …`. **Done (#60)**: `Sources/Sempere/Blob*.swift`, `Sources/SempereCLI/Blobs.swift` | `Sources/Sempere`, CLI | A0 (B1) | binding tests; stock-tool recovery test; both rewrap methods resumable; GC rules 1–4 each tested per note |
| B3 ✅ | WebDAV sync of each note's `att/` (streaming, own size limit, GC-safe deletes). ✅ **Done (#67)**: `Sources/SempereWebDAV/BlobSync.swift`, `--max-blob-mib` | `Sources/SempereWebDAV` | B2 | write-once table tests with blobs; 300 MB blob with bounded memory |
| C1 ✅ | Export images (DCT passthrough with metadata stripped, PNG/JPEG decoders, SVG data URIs, HEIC placeholder). ✅ **Done (#62)**: `JPEG.swift`, `PNGDecoder.swift`, `Items.swift`, writers; blobs through B2's `BlobSource` (`MemoryBlobSource` for tests) | `Sources/SempereRender` | A0 | golden tests for orientations/crops/rotation; decoder fixtures; fuzz |
| C2 ✅ | Export text: full Unicode (Noto + optional font packs, OpenType reader, UAX #9/#14/#29, small shaper, stored `breaks`, font **subsets** in PDF/SVG, missing-script report). ✅ **Done (#64)**: `Sources/SempereRender/Text/`, `Sources/SempereFonts` | `Sources/SempereRender` | A0 | layout tests incl. RTL; CJK via font pack in `pdftotext`; subset-only fonts; goldens |
| C3 ✅ | `SemperePDF` minimal reader + PDF backgrounds as Form XObjects; SVG/PNG via optional Poppler (`pdftoppm`) process, else placeholder + warning. ✅ **Done (#61)**: `Sources/SemperePDF`, `SempereRender` (`Items.swift`, `PDFBackgrounds.swift`), CLI `PopplerRasterizer.swift`; reads blobs through B2's `BlobSource` | `Sources/SemperePDF`, `Sources/SempereRender`, CLI | A0 | xref/objstm/incremental/repair fixtures; poppler pixel check; hung/crashing renderer handled; fuzz |
| C4 ✅ | Recordings in exports. **Done (#87, #122)**: `--recordings attach` embeds recordings and transcripts in the PDF (#87); the attachment list page (`AttachmentList`, also `--recordings list`) and `--format media` (`MediaExport`, bulk too), with the app's "Media" (#122) | `Sources/SempereRender`, CLI, app | C2 | `pdfdetach` lists audio; `pdftotext` shows the list |
| D1 ✅ | Notability PDF backgrounds. ✅ **Done (#70)**: `NotabilityAttachments.swift`, `NotabilityMedia.swift`; CLI `--no-attachments` | `Sources/SempereNotability` | C3 | 26 PDF notes import with their pages; `dropped.pdfPages` 0 |
| D2 ✅ | Notability images. ✅ **Done (#70)**: media objects read without a schema (field names unconfirmed, reported); `SempereRender.ImageImport`; CLI `--keep-image-metadata` | `Sources/SempereNotability` | A0, B2 | 4 image notes match thumbnails |
| D3 ✅ | Notability typed text. ✅ **Done (#73)**: `NotabilityText.swift` (both archive shapes, blocks, runs, `lang`) | `Sources/SempereNotability` | A0 | styled synthetic fixture maps to runs |
| D4 ✅ | Notability recordings + ink sync. ✅ **Done (#73)**: `NotabilityAudio.swift` (library entries, MP4/CAF info, `eventTokens` as ms, guarded) | `Sources/SempereNotability` | A0, B2 | recordings import; strokes carry `rec` |
| E0 ✅ | App plumbing: `NoteWriter.addBlob`/`copyBlob`, blob cache, lazy per-kind iCloud download, item layer + selection. ✅ **Done (#68)**: shared `NoteOps` item builders + `ItemFrames` (`Sources/Sempere/ItemOps.swift`), `ItemRaster` (`Sources/SempereRender`), app `BlobCache`, `CloudBlobs`, `ItemLayerView`, `ItemSelection`, `ItemActions`, `NoteEditor+Items` | `Apps/` | A1, B2 | one delta per gesture; app tests |
| E1 ✅ | App images (Photos, camera, paste, privacy setting: HEIC→JPEG + metadata stripping on by default, crop). ✅ **Done (#81)**: `ImagePreparation`, `NoteEditor+Insert`, `AppModel+Insert`, `InsertUI` (menu, drops, crop sheet); shared `ImageIngest`, `NoteOps.placeImage` / `viewFrame` / `setCrop`; CLI `items crop` | `Apps/` | E0, C1 | GPS-free JPEG blobs by default; orientation correct |
| E2 ✅ | App text boxes (system fonts, any script, RTL, `breaks` from TextKit, CoreText `TextShaper` for exports). ✅ **Done (#82)**: shared `LayoutText`/`TextLineBreaks`/`OutlineFont` (`Sources/SempereRender/Text`), `NoteOps.setText` and the relayout-aware `setFrame`; app `TextBoxLayout` (TextKit breaks, CoreText layout, `CoreTextShaper`), `TextBoxEditing`, `TextBoxEditor`; CLI `attach text` stores `breaks` | `Apps/` | E0, C2 | same line breaks app vs app export vs CLI export (`Tests/SempereTests/Fixtures/text/line-breaks.json`) |
| E3 ✅ | App PDF import, tiled backgrounds, PDFKit rasterizer. ✅ **Done (#81)**: `PDFPreparation` (unlock + redraw without /Encrypt), `PDFTileLayer` (CATiledLayer, Core Graphics), shared `PDFIngest`, `NoteOps.newPDFNote` / `insertPDFPages` | `Apps/` | E0, C3 | 200-page PDF, no memory warnings |
| E4 ✅ | App recording (configurable codec/quality) + playback + ink sync; export sheet "PDF" / "PDF + attachments". ✅ **Done (#87)**: core `RecordingSupport.swift` (format, timeline, sync); app `AudioRecorder` (session, segments, recovery), `RecordingPlayer`, `NoteEditor+Recordings`, `RecordingViews`; `ShareOptions.pdfAttachments`, CLI `export --recordings attach` | `Apps/` | E0 | interruption test; tested on the user's iPad |
| E5 ✅ | App on-device transcription (segments + word timings/confidence, read-back highlighting). ✅ **Done (#87)**: `Sources/SempereSpeech` (SpeechTranscriber → SFSpeechRecognizer on device), core `TranscriptBuilder`, app `AppModel+Recordings`, `TranscriptView`; CLI `transcribe` (macOS) | `Apps/` | E4 | availability matrix on the user's iPad recorded |
| E6 ✅ | ✅ **Done (#86)**: App **Settings panel**: recording format, photo privacy, transcription, device-key rewrap modes (add; remove/PQ), storage | `Apps/` | E0 (E7 for storage) | defaults match `docs/attachments.md` §15; each setting tested |
| E7 ✅ | ✅ **Done (#95)**: App **attachment index** + "Unused attachments: N items, X MB" browsable list (preview, note history, delete after 30 days): core `AttachmentIndex.swift` (`AttachmentIndexer`, `AttachmentStorageReport`, `BlobRetention`), `AttachmentIndexStore.swift`, `collectBlobs(note:records:only:)`; app `AppModel+AttachmentIndex`, `UnusedAttachmentsView` (SettingsView), `AttachmentThumbnail`; CLI `blobs unused`/`gc` | `Apps/` | E0, A1, B2 | per-note updates only; 30-day window and reset tested |
| F ✅ | ✅ **Done (#69)**: CLI: `notes show`, `search` (text, transcripts), `import pdf`, `attach`, export wiring | `Sources/SempereCLI` | A1, B2, C* | end-to-end CLI test |
| G1 ✅ | `math` items (LaTeX source, typeset on device with SwiftMath/MIT, rendered PDF blob). ✅ **Done (#96)**: `format.md` §8.2.8; core `MathItems.swift` (`MathContent`, `MathSource` limits, `NoteOps.placeMath`/`setMath`); render `MathRendering.swift`; CLI `attach math`, `items math`; app `MathTypesetter`, `MathEditor`; web viewer. Handwriting→LaTeX (part 2) ✅ #118: researched in `docs/research/handwriting-to-latex.md`; the pipeline is built behind a setting (CLI `recognize-math`, app Convert to Math), no model offered until the training-data question is settled | `Apps/`, `Sources/` | C3, E2 | format §8.2.8 defined; exports embed the rendering |
| G2 ✅ | `video` items (blob kind `video`, 1 GiB cap, poster, AVPlayer, attached in "PDF + attachments"); ✅ **done (#93)**: format §8.2.7, CLI, exports, sync, app, web viewer | `Apps/`, `Sources/`, `web/` | E4 | format §8.2.7 defined |
| L ✅ | ✅ **Done (#92)**: app UI localization with String Catalogs (`Apps/Sempere/Localization/`: `Localizable`, `InfoPlist`, `AppShortcuts`); Spanish complete (plurals, device variants, glossary in `docs/localization.md`); `LocalizationCatalogTests` (Linux), `scripts/app.sh pseudo` layout check (double-length, right-to-left, Spanish); CONTRIBUTING "Adding a language". CLI stays English | `Apps/` | — | Spanish catalog complete; contributor guide |
| E8 🚧 | 🚧 **#129**: **Markdown text boxes with LaTeX math** (maintainer request 2026-10-09: Markdown over the font-styling bar). Format `format.md` §8.2.4 "Markdown text", §8.5.4 (source as the box's text, `markup`, hash-tied `layout`, typeset `math` entries); core `Markdown.swift`, `MarkdownPlan.swift`, `MarkdownText.swift`, `MarkdownEditing.swift`; render `MarkdownLayout.swift`, `MarkdownItems.swift`, `MarkdownHTML.swift`; CLI `attach text --markdown`, `items text`; app Markdown bar, `NoteEditor+Markdown`; web `format/markdown.ts`, `render/markdown.ts` | `Sources/`, CLI, `Apps/`, `web/` | E2, G1 | same lines in the CLI, the app and the web viewer (`Tests/SempereTests/Fixtures/text/markdown.json`, web goldens) |

## Gap audit follow-ups

From `docs/research/gap-audit-2026-10.md` (rows `GA-nn`; `docs/ROADMAP.md` "Gap audit" has the full list).
Done in 🚧 #131: GA-01 favorites (`notes favorite`, the app's menu, toolbar and Favorites list), GA-02 rotate items in the
app (quarter-turn menu entries, two-finger turn), GA-04 one voice-notebook setting (Quick Voice Notes; the New Notes field
is gone and its stored value migrated), GA-05 the transcription download button (`SpeechTranscription.downloadModel`,
`transcribe --download-model`), GA-13 Mac shortcuts for item actions and recording. Open: the rest of the audit.

The gap audit (`docs/research/gap-audit-2026-10.md`) rows are not tasks here: they sit in their
component sections of `docs/ROADMAP.md` with their `GA-nn` ids, all planned for the first release
except the ones the maintainer dropped (GA-11, GA-12, GA-22, GA-24, GA-25, GA-26). The "First release" section there (one public
"Initial commit" with the history archived privately, the project website at
`sempere.anthonywertz.com`, a legal review of the Notability importer) is the maintainer's.

## Working agreements

- One task → one branch → one PR → squash merge. CI must be green.
- `Sources/` never imports UIKit, AppKit, PencilKit, CoreGraphics or
  Compression. Linux CI enforces it by failing to build.
- Format changes go through `docs/format.md` first.
- Spawned agents: Sonnet 5.5 by default, Opus 5.5 for crypto and merge logic.
