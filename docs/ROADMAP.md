# Roadmap

Where every feature sits, by component. Status: ✅ done on `main` (with the PR number) · 🚧 in progress (open PR number) ·
📋 planned for the first release. A note "not yet tried on the iPad" means it is on `main` and
passed CI, but nobody has used it on a device. Statuses last checked against `main` at
`ecc62ec` (#119) on 2026-10-08. Task ids (A0, E2, …) are in `docs/plan.md`, with
details in `docs/attachments.md` §14. `docs/HANDOFF.md` has the current
working state. Everything here is in scope for the first release (maintainer,
2026-10-09), so 📋 means planned, "(needs the maintainer)" marks what only the maintainer can do
(device hand tests, an account), and nothing is parked as future. Rows with a `GA-nn` id come from
`docs/research/gap-audit-2026-10.md` (evidence and `file:line` there); size S under a day · M a PR with
choices · L a design question or a format change. Dropped by the maintainer, not planned: GA-11,
GA-12, GA-22, GA-24, GA-25, GA-26.

## Order of work

| Step | What | Blocks | Status |
| --- | --- | --- | --- |
| 1 | Merge the reviewed batch: #25 → #23 → #33, #24 → #28, #30 → #27 → #26 | everything below | ✅ |
| 2 | Rename sweep to Sempere (one PR; touches every file) | new feature branches; start them after this to avoid conflicts | ✅ (2026-10-05) |
| 3 | Rebuild the test vault (post-quantum key, full import) → first TestFlight | device testing | ✅ (TestFlight builds 6 and 7 are out) |
| 4 | iPad round 2 and attachments A0 (in parallel) | the rest of attachments | ✅ |
| 5 | Attachments, batches of 3–4 cloud sessions along the §14 dependencies | math, video | ✅ every §14 task on `main` (video #93, math #96, E7 #95, L #92); open: C4's `--recordings list` and `--format media` 🔀 #122, handwriting → math has no model yet (#118) |
| 6 | Mac polish → App Store submission (iPad + Mac) → `/ultrareview` | public release | 🚧 Mac polish ✅ #101, submission prep ✅ #113; the submission (the maintainer's) and `/ultrareview` 📋 |

## Shared library (`Sources/`: Age, Sempere, SempereRender, SempereImport, SempereNotability, SempereWebDAV)

| Area | Feature | Status |
| --- | --- | --- |
| Crypto | age v1: X25519, scrypt, armor, STREAM; CCTV vectors | ✅ |
| Crypto | Post-quantum ML-KEM-768 + X25519 recipients; vaults post-quantum only, legacy vaults open only to migrate | ✅ #33 |
| Crypto | Streaming encrypt/decrypt, header-only rewrap, streaming re-encrypt (B1) | ✅ #43 |
| Crypto | Authenticated recipients (`format.md` §2.1): `recipientsTag` over the device list, `secretLink` on rotations (signed, Ed25519 + ML-DSA-65, ✅ #115), per-device trust records (public keys only, ✅ #115); writes, rewraps and capture profiles refuse a tampered list; repair and confirm (repair with chosen keys in the app too, ✅ #135); untagged vaults tagged by their first writer | ✅ #98 |
| Crypto | Asymmetric hybrid `secretLink` (security review R2, `format.md` §2.1): Ed25519 + ML-DSA-65 signatures by keys derived from the outgoing secret, both must verify; trust records `sempere-trust/2` hold only the public keys, a legacy `sempere-trust/1` record is replaced at the first write; shared vectors (`Fixtures/secret-link-vectors.json`) mirrored in the web viewer | ✅ #115 |
| Vault | Write-once revisions, HLC, merge, snapshots, compaction | ✅ |
| Vault | History and restore points | ✅ |
| Vault | Version history round 2 (`format.md` §5.8): checkpoints, editing-session ids, positioned snapshots (`asOf`), thinning with stated and property-tested guarantees; compaction keeps checkpoints complete | ✅ #74 |
| Vault | Fast summaries (no stroke points, parallel) and per-device encrypted summary cache (`format.md` §10) | ✅ #54 |
| Vault | Published summaries `sempere-summaries.sealed` (`format.md` §12): AES-256-GCM under an HKDF key of the vault secret, entries keyed by revision names, a hint | ✅ #100 |
| Vault | Fast exact decoding of stroke points; per-device cache keys (`format.md` §10.1) | ✅ #56 |
| Vault | Tags merge per tag (add wins) | ✅ #23 |
| Vault | Hardened parsers + fuzz harness (untrusted input) | ✅ #25 |
| Vault | Attachment model types and ops (A0) | ✅ |
| Vault | Per-note blob store, rewrap policy, GC, repair (B2) | ✅ |
| Vault | Attachment merge (A1): items and recordings in merge, snapshots, history/restore, summaries | ✅ #66 |
| Vault | Video items (G2, `format.md` §8.2.7): `VideoProbe` (pure-Swift MP4/MOV reader, fuzzed), location metadata blanked in place, clips streamed into blobs (never in memory), `poster` register | ✅ #93 |
| Vault | Concurrent replacements of one stroke (`format.md` §5.6.1): two devices slicing, moving or recolouring the same stroke keep the later edit, not both sets of pieces; property-tested (any order, compaction, snapshots), snapshots keep `replaces` / `lineage` / `superseded`; web viewer ported (shared vectors); app links moved and recoloured strokes to their originals | ✅ #126 |
| Vault | Shared settings `settings.age` (`format.md` §13, `docs/settings-sync.md`): a VS Code-style settings.json encrypted and tagged like a revision; flat keys, `[mac]` / `[ipad]` / `[iphone]` blocks, per-key last-writer-wins merge (`$meta`), `$schemaVersion` with additive migrations and dual-written legacy keys, `$minReaderVersion` (older readers pause, never write); JSON Schema generated from the registry; rewrapped with the revisions, backed up, merged by WebDAV sync; fuzzed | 🚧 #144 |
| Vault | Read-only access to newer format versions (`format.md` §7): vaults and revisions of a later `format` open read-only, unknown ops, fields and snapshot elements are skipped and reported, every write refused; CLI exit 7, app banner, web viewer | ✅ #94 |
| Render | PDF, SVG, PNG export of ink and paper | ✅ |
| Render | Pageless pages cut at gaps in the ink; paged notes one PDF page per page (`format.md` §5.4.3) | ✅ #52 |
| Render | Parametric paper templates (line width, spacing) | ✅ #28 |
| Render | PDF page backgrounds in exports (Form XObjects in PDF, rasterizer in SVG/PNG, placeholders, export report) and the `SemperePDF` reader (C3) | ✅ |
| Render | Images in exports: JPEG passthrough, PNG/JPEG decoders, SVG data URIs or `--assets`, placeholders (C1) | ✅ #62 |
| Render | Unicode text in exports: bundled Noto + font packs, UAX #9/#14/#29, shaper, font subsets in PDF/SVG, missing-script report (C2) | ✅ #64 |
| Render | Recordings in exports (C4): embedded in PDFs with their transcripts ("PDF + attachments"); the attachment list page (kind, title, pages, duration, size; links to the embedded files and pages) and `--format media` (recordings, transcripts, clips, images, PDFs as files with `media.json`), shared by the CLI and the app (`AttachmentList`, `MediaExport`) | ✅ #87; list page and media 🔀 #122 |
| Import | Notability `.note` / `.ntb` / full Google Drive backup, recognised text | ✅ |
| Import | Notability PDF backgrounds and images (D1, D2) | ✅ #70 |
| Import | Notability typed text, recordings and stroke links (D3, D4) | ✅ #73 |
| Import | Notability remaining gaps: `.ntb` PDF and image files, PDF page text from Notability's index, handwriting language (`meta.lang`), highlighter behind text (`meta.markersBehindText`), paper colour | ✅ #79 |
| Vault | PDF page text (`pageText` on pdfPage items, `format.md` §8.2.6) searched with recognition and text boxes; note `lang` and `markersBehindText` registers (§5.4) | ✅ #79 |
| Render | `markersBehindText`: markers drawn below content items (§8.2.3) in PDF/SVG/PNG and the web viewer; pure-Swift PDF text extraction (`SemperePDF.PDFText`) | ✅ #79 |
| Sync | WebDAV | ✅ |
| Sync | WebDAV for attachments (B3): streamed, resumable, GC-safe deletes | ✅ #67 |
| Sync | WebDAV push-only mirror: server never feeds back (`PushOnlySync.swift`) | ✅ #97 |
| Sync | WebDAV: HTTPS server trust left to the system (sync failed on macOS) | ✅ #105 |
| Vault | Attachment index and unused-attachment report (E7, `format.md` §10.1) | ✅ #95 |
| Vault | Math items (G1, `format.md` §8.2.8): LaTeX source, `MathSource.check`, `NoteOps.placeMath` | ✅ #96 |
| Vault, Render | Markdown text boxes (`format.md` §8.2.4 "Markdown text", §8.5.4): the source as the box's text (`markup`), the rendered text's `layout` (hash-tied) and typeset `math` entries; the shared parser (`MarkdownDocument`), rendered paragraphs (`MarkdownPlan`), layout (`MarkdownLayout`) drawn as text items, formula renders and shapes by every writer; plain text for search; HTML rendering; `MarkdownEditing` helpers; shared fixtures `Tests/SempereTests/Fixtures/text/markdown.json` | 🚧 #129 |
| Vault | Handwriting → math (G1 part 2): `InkLasso` (stroke pick), `NoteOps.convertInk` (one delta: `removeStroke`s + the math item, replace or beside), `MathInkImage` (the model's image), vocabulary, beam search, clean-up, `sempere-math-model/1` manifests and the hash-verified `MathModelStore`, `CoreMLMathRecognizer` (Apple only); no model in the catalogue yet (training-data question, `docs/research/handwriting-to-latex.md`) | ✅ #118 (no model yet) |
| Vault | Audio items: a recording placed on the page as a card (`format.md` §8.2.9) | ✅ #103 |
| Vault | Recently Recognized shared across devices (stored in the vault) | ✅ #102 |
| Render | Video in exports: poster with a play mark in PDF/SVG/PNG, clips embedded in "PDF + attachments" streamed from the vault (`PDFWriter.write(to:)`), clips written next to Markdown/HTML and linked | ✅ #93 |
| Import | The Notability importer is a removable module: `SempereNotability`, a `VaultImporter` interface and registry, generic `import <id>` in the CLI and Import entry in the app, CI deletes the module and builds and tests the rest (docs/import-notability.md "Structure") | 🚧 #145 |
| Import | Notability's own transcripts become transcript blobs (`engine: notability-<version>`); the library layout is a hypothesis, no real sample (GA-09, S) | 🚧 #134 |
| Import | GIF (first frame) and baseline TIFF in a Notability bundle are converted to PNG; WebP, BMP and AVIF stay counted in `dropped.media` (GA-10, S) | 🚧 #134 |
| Import | Undecoded `.ntb` stroke and shape kinds, dashed strokes imported solid, highlighter behind a PDF, pages of two heights (GA-27, M–L): feasibility in `docs/research/ntb-undecoded-kinds.md`; the report now names each unconverted kind; decoding needs samples from the backup, dashes a format change | 🚧 #134 (feasibility) |
| Capture | C2: a forged capture's attribution (the capturing device is not stored, the notebook comes from the manifest) (GA-31, M) | 📋 |
| Crypto | C3: a removed device's captures are adopted while its rewrap is unfinished; needs an authenticated names list (format change) (GA-32, L) | 📋 |
| Crypto | N3: `format` and `features` in `vault.json` are not covered by `recipientsTag` (format change) (GA-33, L) | 📋 |
| CI | Run the WebDAV integration tests against a server (`webdav` job, wsgidav) (GA-50, M) | 🚧 #133 |
| CI | Fail instead of skip for zbar, zip, pdftotext, `BidiTest.txt` and macOS poppler (`SEMPERE_REQUIRE_TOOLS`) (GA-61, S) | 🚧 #133 |
| Tests | Fixture vault with a note that has items (GA-63, S) | 🚧 #133 |

## CLI (`sempere`; one codebase for both platforms)

The CLI gets every feature first, or at the latest with the app (`CLAUDE.md`
"CLI first"): anything that reads or changes vault data has a command with
`--json`.

| Feature | Linux | macOS |
| --- | --- | --- |
| keys, vault init/info/recipients/verify, notes, history/restore, compact, snapshot | ✅ | ✅ |
| `settings list/get/set/reset/edit/validate/schema` (`--type mac\|ipad\|iphone` for type blocks; no device overrides) | 🚧 #144 | 🚧 #144 |
| `notes layout paged\|pageless`, `export --breaks gaps\|fixed` | ✅ #52 | ✅ #52 |
| `notes dedupe (ID… \| --all) [--dry-run]`: strokes left over by concurrent edits of one stroke (`format.md` §5.6.1), check and repair | ✅ #126 | ✅ #126 |
| import notability, search (recognised text) | ✅ | ✅ |
| `notes checkpoint [--name]`, `notes history --sessions` (checkpoints and editing sessions, `--json`), `compact --thin-older-than 30d [--dry-run]` | ✅ #74 | ✅ #74 |
| `compact --thin-all [--dry-run]` (thin everything except checkpoints), imports written as checkpoints, thinning from indexed revision metadata | ✅ #88 | ✅ #88 |
| import notability: PDF backgrounds and images, `--no-attachments`, `--keep-image-metadata` (D1, D2) | ✅ #70 | ✅ #70 |
| import notability: typed text and recordings (D3, D4) | ✅ #73 | ✅ #73 |
| import notability: `.ntb` attachments, PDF text, language, highlighter flag, paper colour, new report counts; `--pdf-text` for `import notability\|pdf` and `attach pdf` (pdftotext or built in); `search` reports PDF hits (page, PDF page, item); `notes language`, `notes markers`; `recognize` reads in the note's language | ✅ #79 | ✅ #79 |
| Note editing as in the app: `notes new/rename/tag/move/paper/delete/undelete`, `notebooks list/rename` (subtree), `tags list`, `pages list/add`, `notes list --notebook` over sub-notebooks | ✅ #58 | ✅ #58 |
| `notebooks move NOTEBOOK PARENT` (nest or un-nest a notebook: the app's drag and drop) | ✅ #72 | ✅ #72 |
| Pages: `pages add --after`, `move`, `delete`, `duplicate`; paged/pageless (`notes layout`) | ✅ #52 | ✅ #52 |
| Notes: `notes favorite NOTE [--off]`, `notes list --favorites`, `favorite` in the `NoteJSON` of every note listing (GA-01) | ✅ #131 | ✅ #131 |
| `transcribe --download-model` (SpeechTranscriber's on-device model; the app's Settings button, GA-05) | — (error) | ✅ #131 |
| Items: `items list`, `move`, `rotate`, `front`, `delete`, `duplicate`, `copy` (the app's item gestures) | ✅ #68 | ✅ #68 |
| `search --show-boxes` (match locations, numbered across the note, as the app's highlights) | ✅ #72 | ✅ #72 |
| Items: `items crop` (the app's Crop: the visible part stays in place) | ✅ #81 | ✅ #81 |
| Items: `items replace` (the app's Replace Image: one delta, the new picture fitted into the old frame, `parent`) | ✅ #104 | ✅ #104 |
| `recognize` (Vision on rendered pages, the app's selection, image plan and mapping) and `import notability --recognize missing`; Linux gives a clear error (`--dry-run` works) | — (error) | ✅ #78 |
| `notes search`: the app's ranked search over titles, tags, notebooks and recognised text | ✅ #78 | ✅ #78 |
| `recognize --recent [--days N]`: the shared "Recently Recognized" (`meta.recognized`, written by every `recognize` run and the app's "Recognize All") | ✅ #102 | ✅ #102 |
| `transcribe` (on-device Speech framework: SpeechTranscriber, else SFSpeechRecognizer on device; `--check` lists the engines); Linux gives a clear error (`--dry-run`, `--check` work) | — (error) | ✅ #87 |
| `export --recordings attach` (recordings and transcripts embedded in the PDF, the app's "PDF + attachments") | ✅ #87 | ✅ #87 |
| `export --recordings list` and the attachment list page of every PDF that embeds files; `export --format media` (single note and `--all`, with `--layout`, `--zip`, resuming) | 🔀 #122 | 🔀 #122 |
| `notes new` without a title: named after the date and time, `--title-format` (the app's default title) | ✅ #84 | ✅ #84 |
| `notes new --title-format`: strftime too, validated with the app's messages (exit 2), `SEMPERE_TITLE_FORMAT` as this machine's default | ✅ #102 | ✅ #102 |
| `inbox enable/capture/transcript/list/import`: voice notes sealed without the key (capture profile), adopted as notes with it (`format.md` §11) | ✅ #89 | ✅ #89 |
| Fast `notes list` / `search` (parallel, summary cache in `~/.cache/sempere`) | ✅ #54 | ✅ #54 |
| export PDF / SVG / PNG | ✅ | ✅ |
| Bulk export: `export --all --format pdf\|png` one note at a time (bounded memory), `--layout notebooks`, `--zip`, re-runs skip unchanged notes (`--overwrite`), the app's "Export Notes…" (`BulkExportSession`) | ✅ #109 | ✅ #109 |
| sync webdav | ✅ | ✅ |
| sync webdav of attachment blobs (`--max-blob-mib`) | ✅ #67 | ✅ #67 |
| sync webdav `--push-only` (one-way mirror, `--delete-extraneous`) | ✅ #97 | ✅ #97 |
| sync webdav `--keep-server-changes` (a push-only run keeps a `vault.json` another writer changed); `webdav check` (test a URL, list its vaults) | 🔀 #137 | 🔀 #137 |
| `vault summaries` (published summaries for the web viewer, `format.md` §12), kept current by unlocked commands and `sync webdav` (`--web-viewer` creates them and the index on the server) | ✅ #100 | ✅ #100 |
| Authenticated device list (`format.md` §2.1): `vault info`/`verify` report it (`recipientsAuth`), exit 6 for writes to a tampered list, `vault recipients repair [--keep] [--dry-run]` and `confirm`, `sync webdav` rejects an unchecked remote `vault.json` (exit 6) | ✅ #98 | ✅ #98 |
| Signed secret links (`format.md` §2.1, security review R2): `secretLink` = Ed25519 + ML-DSA-65 signatures, trust records hold public keys only; `vault link [status]` and `vault link upgrade` (one-time migration, `--json`); the app upgrades after unlock | ✅ #115 | ✅ #115 |
| Authenticated version markers (`format.md` §2.1, security review N3): `markersTag` over `format` and `features`, kept in trust records; `vault markers [status]`, `markers tag`, `markers repair` (`--json`), exit 6 for writes to downgraded markers; the app tags at unlock and alerts; the web viewer reports them | 🚧 #125 | 🚧 #125 |
| Capture attribution (`format.md` §11.1, security review C2/C3): per-device capture keys, `captured` on adopted recordings, `inbox list`/`import` show who captured, a removed device's captures refused | 🚧 #125 | 🚧 #125 |
| Recovery kit (paper key), backup / verify / restore | ✅ #30 | ✅ #30 |
| `backup status DIR` (last run, last complete run, notes, files, bytes from `backup.json`), `restore --dry-run` (preview: notes, revisions, attachments, newest revision; checks the target), restore never into `--vault` / `$SEMPERE_VAULT` (the app's Backups) | ✅ #110 | ✅ #110 |
| Markdown (Obsidian) and single-file HTML export | ✅ #27 | ✅ #27 |
| Release builds: static binary (Linux x86_64 + aarch64), universal (macOS), Homebrew formula, provenance | ✅ #26 | ✅ #26 |
| Attachments: `blobs` (list, verify, extract, add, copy, unused, gc, repair), `recipients --rewrap`, `recover` of a blob (B2) | ✅ #60 | ✅ #60 |
| `blobs unused` / `gc` report Settings' storage numbers (held by history, eligibility, `gc --file`) (E7) | ✅ #95 | ✅ #95 |
| Attachments: `notes show` lists items and recordings, `notes list --json` counts them, `search` finds typed text (A1) | ✅ #66 | ✅ #66 |
| Attachments: `attach image\|pdf\|text\|recording\|transcript`, `import pdf`, `search` over text boxes and (`--transcripts`) transcripts, typed text in Markdown/HTML exports (F) | ✅ #69 | ✅ #69 |
| Text boxes: `attach text` stores the `breaks` of its layout (`--no-breaks` to leave wrapping to renderers), `items move` lays a text box out again at a new width (E2) | ✅ #82 | ✅ #82 |
| PDF backgrounds in export (PDF exact; SVG/PNG via Poppler if installed, `--pdf-renderer`) | ✅ #61 | ✅ #61 (Poppler too; the app uses PDFKit) |
| `attach video` (pure-Swift probe; poster from `--poster`, or from the clip on macOS), `items poster`, `export --videos attach` / `--attachments`, clips linked in Markdown/HTML (G2) | ✅ #93 (no poster without `--poster`) | ✅ #93 |
| Markdown text boxes: `attach text --markdown`, `items text` (`--markdown`/`--no-markdown`), `items list` (`text`, `markup`), `items move` relayout, `search` over the text without markup; exports draw them rendered (formulas from their renders, else their source with a warning), Markdown export passes the source through, HTML renders it | 🚧 #129 | 🚧 #129 |
| Equations (G1): `attach math` (`--latex`, `--inline`, `--size`, `--color`, `--render` a PDF typeset elsewhere), `items math`, `items list`/`notes show`/`search` over the LaTeX source; exports draw the stored rendering (PDF form; SVG/PNG via Poppler as coverage of its colour), else the source as monospace text with a warning; `$$…$$` in Markdown/HTML | ✅ #96 | ✅ #96 |
| Recordings on the page (`format.md` §8.2.9): `recordings list\|place\|rename\|delete`, `attach recording --place`, audio items in `items list` and `notes show`, the card drawn in PDF/SVG/PNG exports; long recordings streamed into `--recordings attach` | ✅ #103 | ✅ #103 |
| `vault summaries` | ✅ #100 | ✅ #100 |
| Handwritten math (G1 part 2): `recognize-math` (`--strokes`/`--rect`/`--lasso`/`--all-ink`, `--model DIR` on Core ML, `--latex` anywhere, `--place replace\|beside`, `--save-image`) | ✅ #118 (`--model`: macOS only) | ✅ #118 |
| Vaults of a newer format version (`format.md` §7): read commands work and report `readOnly`, `readOnlyReasons` and per-note `newer` in `--json`; every write exits 7 | ✅ #94 | ✅ #94 |
| `--version` prints the GPL-3 notice (copyright, no warranty, free to redistribute) with links to the licence and `SECURITY.md`; `about` (`--json`) adds the source, vulnerability reporting, the security limits page and the third-party list (`SempereAbout`, shared with the app's About) | ✅ #142 | ✅ #142 |
| `notes favorite NOTE [--off]` and `notes list --favorites` (GA-01, M) | ✅ #131 | ✅ #131 |
| `items text` (edit a text box's text and style, on `NoteOps.setText`) (GA-03, M) | 📋 | 📋 |
| `backup status DIR --max-age DAYS`: overdue check for the app's "Remind Me" (exit 3; `backup.json` records the last complete run, `completed`) (GA-18, S) | ✅ #135 | ✅ #135 |
| `vault summaries --plaintext --out` writes the file mode 0600 (P5) (GA-30, S) | ✅ #130 | — |
| Tests: exit 7 for every write command (GA-65, M); documented flags never exercised (GA-66, S–M); Linux errors of `recognize` and `attach video --from-clip` (GA-53, S); `sync webdav --retry-quarantined` and the restore resume marker through the commands (GA-60, S) | 🚧 #133 | 📋 |

## iPad app (`Apps/`, SwiftUI + PencilKit, iPadOS 26)

| Area | Feature | Status |
| --- | --- | --- |
| Vaults | Open/create vaults, recents, iCloud Drive (dataless files handled), always-on sync loop with progress | ✅ |
| Expectations | "About Your Key" (only the key opens the notes; lose every copy and nobody can recover them; Save Key and Recovery Kit…; Backup Settings…), shown once per vault and key on a device at its first unlock (a new vault included) and closed only by "I Understand"; quick tour (six pages, once per device, after the vault is open, skippable); Settings ▸ About (version and build, GPL notice, bundled licence and third-party notices, security limits, Report a Vulnerability, source, acknowledgments, Show Quick Tour, About Your Key); scripted debug launches skip the notices (`SEMPERE_DEBUG_ONBOARDING` shows them) | ✅ #142 (not yet tried on the iPad) |
| Vaults | Background sync (iOS): a sync in flight finishes off screen (`beginBackgroundTask`); `BGProcessingTask` / `BGAppRefreshTask` continue it when iOS grants them (`docs/io.md` "Background sync") | ✅ #102 (not yet tried on a device) |
| Vaults | Keys in the Keychain / password manager | ✅ #24 |
| Vaults | Save Key… (this device's key after Face ID, to Files / the share sheet / a password manager, with the paper kit) and New Key… (a key for another device) in Settings → Device Keys; New Key…, adding a pasted key and the recovery kit need the same owner check (P1) | ✅ #99 (not yet tried on the iPad) |
| Vaults | Vaults of a newer format version open read-only: banner over the list, notes open read-only with what was skipped, New Note / Import / Recognize disabled, no autosave, thinning, inbox adoption or transcripts (`format.md` §7.3) | ✅ #94 (not yet tried on the iPad) |
| Vaults | Authenticated device list (`format.md` §2.1): blocking alert "This vault's device list was changed without its key" naming the unknown devices, Remove (restore the last checked list, rotate, rewrap) or Cancel (read only); one-time "Device List Protected" notice when an older vault is tagged at unlock; quick capture never takes an unchecked list; the web viewer reports the status; version markers (`format.md` §2.1, N3): tagged once at unlock, "This vault's format was changed without its key" alert | ✅ #98, markers 🚧 #125 (not yet tried on the iPad) |
| Vaults | Fast opening: background listing with "Opening vault: n of m", list fills in as notes are read, encrypted summary cache for instant reopen, empty list always explained | ✅ #54 |
| Vaults | Instant reopen from the local index; change-driven iCloud updates (names diff, file presenter), low-priority validation, throttled diff list updates; signposts + debug timing log | ✅ #56 |
| Canvas | Fast note open: encrypted per-page drawing cache (LRU, 200 MB), off-main visible-first conversion, fast point decoding | ✅ #56 |
| Canvas | Attachments cached across note opens and launches: decrypted blobs (re-verified), image pictures and PDF page previews (sealed), shown before the PDF is opened | ✅ #84 (not yet tried on the iPad) |
| Notes | Notebook tree, tags (with tag UI), rename, move, delete/restore, duplicate titles allowed | ✅ (title rename ✅ #24) |
| Canvas | PencilKit drawing, tool palette (full / compact), scrolling past the end, Keep Screen On | ✅ |
| Canvas | Object eraser by default, eraser sizes and cursor | ✅ #24 |
| Canvas | Visual paper picker (line width, spacing) | ✅ #28 |
| Canvas | Pages vs pageless (switch without moving ink; add after current / at end, delete with undo, duplicate, drag to reorder in a thumbnail strip) | ✅ #52 |
| Canvas | Continuous page scrolling: paged notes scroll from one page to the next (gap and shadow between pages), lazy per-page canvases, zoom across pages, current page follows the scroll | ✅ #80 (not yet tried on the iPad) |
| Canvas | Remote changes merged into an open note: new revisions of the open note are downloaded and merged in place (unsaved ink kept, no echo deltas, only changed pages redrawn), "Updated from another device" notice | ✅ #91 (not yet tried on the iPad) |
| Search | Handwriting search: Vision on rendered pages writes page recognition (`format.md` §5.5), search over text, title, notebook, tag, jump to the page | ✅ (not yet tried on the iPad) |
| Search | Matching words highlighted on the canvas from the recognition boxes, previous/next across pages, match count (`SearchMatchCursor`) | ✅ #72 |
| Search | "Recognize All Notes" results: a "Recently Recognized" sidebar section like Recently Deleted (notes read in the last 7 days, kept across launches, gone when empty); recent searches as the search field's suggestions, with Clear | ✅ #72, #84 |
| Search | "Recently Recognized" shared by every device (each note's `meta.recognized`, `format.md` §5.4, synced like the trash) and listed under All Notes with the smart lists | ✅ #102 (not yet tried on the iPad) |
| Search | A running search follows the sidebar: choosing a notebook or tag keeps the query and scopes it there (scope bar "In “Math”" / All Notes) | ✅ #84 |
| Notes | Notebook combo box (new note, move note); drag notes and notebooks onto the sidebar (move, nest, un-nest), "Move Notebook To…", one commit and one undo step per drop | ✅ #72 |
| Notes | Drops on the sidebar fixed on iPadOS 26 (the drop no longer depends on the released item provider) | ✅ #84; build 7 said drops still did nothing, fixed in ✅ #102 (next row) |
| Notes | Drops on the sidebar, build 7: rows proposed a `.move` the drag session does not allow, so UIKit cancelled every drop at the release; they propose `.copy` now. Notebook rows drag from a UIKit drag interaction of their own (a list never routes its own drags to its rows), which also carries their context menu. Real-drag UI tests on the iPad simulator (every app CI run) and Mac Catalyst | ✅ #102 (not yet tried on the iPad) |
| Notes | Default title of a new note from its date and time (app: Settings → New Notes, `NewNoteSettings` #86; CLI: `notes new` without a title, any date pattern with `--title-format`) | ✅ #84, #86 |
| Notes | Title presets (date and time, date, year-month-day time, weekday) and a custom pattern (Unicode or strftime) checked as it is typed, with a live preview, the reason it is refused and an Insert menu of fields | ✅ #102 (not yet tried on the iPad) |
| App | Share/export from the app: PDF, PNG pages, Text (Markdown, PDF optional), one note or a multi-selection, share sheet + Save to Files, progress and cancel (`ShareExport`, `ExportJob`; Catalyst menu bar via `ExportMenuCommands`); HTML in the CLI only | ✅ #42, text export ✅ #56, Media (and in "Export Notes…") 🔀 #122 (not yet tried on a device) |
| App | Import from Notability in the app (the note list's toolbar, and the File menu on the Mac): `.note`/`.ntb` files, folders or backup zips through the CLI's importer (`NotabilityImporter`, same defaults: folder tags, attachments, existing notes skipped), filed in the sidebar's notebook, result alert | ✅ #101 (not yet tried on the iPad or a Mac) |
| App | PDFs opened with Sempere (iPad share sheet / Open In; Mac Finder Open With) become new notes of the open vault, waiting for a vault to be opened and unlocked; Sempere is a PDF Viewer at rank Alternate, never the default | ✅ #101 (not yet tried on the iPad or a Mac) |
| App | Bulk export ("Export Notes…"): list selection, notebook or whole vault; PDF, PDF + attachments, PNG pages; notebook folders or flat; a chosen folder (resumable: unchanged notes skipped) or a zip (share sheet / Save to Files); progress with Stop, per-note failures at the end; File menu on a Mac (docs/io.md "Bulk export") | ✅ #109 (not yet tried on the iPad or a Mac) |
| App | History browser: restore points, read-only preview, restore through `NoteWriter`, compaction notice | ✅ #41 |
| App | Version history round 2: Save Version (note toolbar, Mac Note menu ⌥⌘S), history grouped into checkpoints and collapsed editing sessions, thinning setting (default 30 days, or never) in a minimal Settings sheet with "Thin Now" preview, automatic thinning once a day | ✅ #74 (not yet tried on the iPad) |
| Search | Recognition in the note's language (`meta.lang`); PDF page text searched; the app's PDF import stores each page's text from PDFKit | ✅ #79 |
| App | Performance round 3: mass-changed vault reconcile without quadratic iCloud checks ("Updating N changed notes"), thinning with progress, "Thin Versions Older Than N Days" and "Thin Everything Except Checkpoints" | ✅ #88 (not yet tried on the iPad) |
| App | Settings panel (E6): one screen (sidebar gear on iPad and iPhone, Settings… ⌘, on the Mac) with General, New Notes, Recording, Transcription, Photos, Version History, Device Keys and Storage; the recording, transcription, voice-notebook and title-format settings are stored now and read by their features (recording and transcription since #87) | ✅ #86 (not yet tried on the iPad) |
| App | Backups (Settings → Backups): Back Up Now to a chosen folder (bookmark kept; another drive or cloud provider), incremental on the CLI's core, Stop; Verify Backup (decrypts with the unlocked key) with the problems listed and repaired by the next run; last backup date and size; reminder after N days without a backup (local notification, "overdue" in Settings); Restore from Backup (also on the welcome screen) into a new vault after a preview, never over the open vault | ✅ #110 (not yet tried on a device) |
| App | Spanish localization (L): String Catalogs for every interface string (plurals, iPhone/iPad/Mac wording), permission prompts, Siri phrases and the widget/intents text; glossary and contributor guide (`docs/localization.md`); layouts checked with the double-length and right-to-left pseudo-languages. Note content and the CLI stay as they are | ✅ #92 (not yet tried on a device) |
| App | App icon: a keyhole-in-a-nib default (with iOS 18 dark and tinted variants) and three alternates (Cemetery Door, Shadow S, Ink Wind) chosen in Settings → App Icon (`AppIconSettings.swift`, per device, hidden on the Mac); sources and a render script in `Apps/Sempere/IconSources/` | 🔀 #140 (not yet tried on a device) |
| Attachments | Plumbing (E0): items drawn between paper and ink (placeholders for missing blobs), select/move/resize/delete/duplicate/copy-paste with undo, blob cache, lazy per-kind iCloud download | ✅ #68 |
| Attachments | Images (E1): Photos, camera, paste, drag-in, the photo privacy setting (on: HEIC → JPEG, no location or camera data), orientation, crop. PDFs (E3): import as a new note or insert pages into the open note (one finite page per PDF page), encrypted PDFs unlocked and stored without the password, backgrounds drawn in tiles by Core Graphics | ✅ #81 (not yet tried on the iPad) |
| Attachments | Text boxes (E2): text tool (tap to add or edit), selection's Edit Text, style bar (bold, italic, underline, strikethrough, size, colour, font, alignment, direction), any script incl. right to left, Scribble; `breaks` from TextKit stored with every edit and resize; CoreText layout on the canvas and in the app's PDF/SVG/PNG (`CoreTextShaper`, glyph outlines embedded); same lines as `sempere export` (shared fixtures) | ✅ #82 (not yet tried on the iPad) |
| Attachments | Audio recording (codec and quality settings, interruptions, 10-minute segments with crash recovery), playback with ink sync (tap ink to play, strokes highlighted as the recording plays), on-device transcription (opt-in, SpeechTranscriber → SFSpeechRecognizer on device) with a read-back transcript view; export sheet "PDF" / "PDF + attachments" (E4, E5) | ✅ #87 (not yet tried on the iPad; recordings tried on an iPhone and a Mac in build 7, feedback in ✅ #103) |
| Capture | Quick voice notes without unlocking: Lock Screen / Home Screen widget, Control Center control, Action button, Siri and Shortcuts; sealed to the vault's inbox with a capture key (`format.md` §11, `docs/quick-capture.md`), queued when the vault folder is out of reach, transcribed on device, adopted into the inbox notebook on unlock; attributed to the capturing device ("Voice note from iPad" in the recording's menu; profiles made before attribution are replaced at unlock; a removed device's captures are refused, security review C2/C3) | ✅ #89; tried on an iPhone in build 7, fixes ✅ #106, ✅ #107; attribution 🚧 #125 |
| Capture | Quick voice notes, build 7 feedback: widgets and the Control Center control show the state (set up or not, Live Activities off, recording, saving) from an App Group status and open Settings ▸ Quick Voice Notes when it is not set up; Stop from the control and the widgets; a Live Activity with a pulsing dot, the elapsed time and a large Stop, then "Saved to Inbox" for a few seconds; an in-app recording banner with Stop (`sempere://quick-voice/…` deep links); the Lock Screen widget no longer blank before the first unlock | ✅ #107 (not yet tried on a device) |
| Attachments | Unused-attachment index (E7): per-note device-local index updated by every write and arrival, Settings → Storage list (previews, history links, 30-day Delete, Delete All Eligible, held by history); `blobs unused`/`gc` show the same numbers | ✅ #95 (not yet tried on the iPad) |
| Attachments | Selecting items (build 7 feedback): one selection model for every kind; Select always in the toolbar; while drawing, a lasso tap, a held finger or a right-click picks an item; outline, handles (text boxes by their sides) and menu on selection; text boxes: tap selects, tap again or double-tap edits; Replace Image… (Photos or Files); text colour swatches from the pen palette; Insert menu grouped, with "Insert PDF Pages After Page N…" (also in the Add Page menu) | ✅ #104 (not yet tried on the iPad) |
| Attachments | Recordings on the page (build 7 feedback, `format.md` §8.2.9): stopping a recording places its card on the page being looked at (microphone, title, length, transcript; a play/pause button on the card), movable, resizable and deletable like any item; Recordings… list (play or pause, place on the page, transcript, transcribe, rename, delete) in the note's menu, the Recordings menu and Note > Recordings… (⌃⌘R) on the Mac; deleting a recording takes its cards | ✅ #103 (not yet tried on a device) |
| App | Mac export of a note with a recording no longer crashes: the share picker and save panel are presented by UIKit from the export sheet (not hosted in a SwiftUI sheet), their callbacks hop to the main actor, long recordings are streamed into "PDF + attachments" | ✅ #103 (not yet tried on a Mac) |
| Attachments | Markdown text boxes (maintainer request 2026-10-09): new text boxes are Markdown; the source is edited with a Markdown bar (bold, italic, strikethrough, code, heading, lists, task lists, quote, link, inline and display math, box size, colour, font, alignment); drawn rendered on the canvas through the shared layout; closing an edit typesets the formulas with SwiftMath and writes their renders before the one delta; styled boxes keep the style bar | 🚧 #129 (not yet tried on the iPad) |
| Attachments | Equations (G1): Insert → Equation, a LaTeX sheet with a live SwiftMath preview (display/inline, size, colour), the rendered PDF stored before the delta, drawn on the item layer, edit/move/resize/undo like other items | ✅ #96 (not yet tried on the iPad) |
| Attachments | Handwriting → LaTeX on device (G1 part 2): Settings ▸ Handwritten Math (off by default; models downloaded on request, size shown first, every file hash-checked), Insert ▸ Equation from Handwriting… → lasso → the equation sheet reads the ink on device, readings and editable LaTeX with the SwiftMath preview → Replace Ink / Place Beside, one delta, one undo step. Research and numbers: `docs/research/handwriting-to-latex.md`. No model is offered until the maintainer settles the training-data question | ✅ #118 behind the setting (no model yet; not yet tried on the iPad) |
| Attachments | Video (G2): record with the camera, pick from Photos or Files, drag in; poster from the clip (AVAssetImageGenerator); tap to play (AVPlayer from a verified temporary file); location removed by the photo privacy setting; clip downloaded from iCloud only when played; item gestures and undo; "PDF + attachments" embeds clips | ✅ #93 (not yet tried on the iPad) |
| Release | TestFlight | ✅ builds 6 and 7 (internal group) |
| Release | App Store submission prep (export compliance, privacy manifests for the app and widget, App Privacy / age rating / review notes / listing, privacy policy page, `scripts/release-check.sh` in CI; `docs/release/`) | ✅ #113; the submission itself is 📋 (the maintainer submits) |
| Release | App Store screenshots generated from a synthetic demo vault (`scripts/screenshots.sh`, CI dispatch) | ✅ #53 |
| Notes | Favorites in the app: the note's context menu and toolbar set and clear `meta.favorite`, and the sidebar lists Favorites (GA-01, M) | 🚧 #131 |
| Items | Rotate an item: Rotate 90° Left / Right in the selection menu and a two-finger turn (GA-02, M) | 🚧 #131 |
| Settings | One notebook setting for quick voice notes (Quick Voice Notes ▸ Notebook); the inert New Notes field is gone and its stored value migrated (GA-04, S) | 🚧 #131 |
| Settings | Transcription model download button wired to `SpeechTranscription.downloadModel` (also `transcribe --download-model`), and the panel lists the speech engines and which one is used (GA-05, M) | 🚧 #131 |
| Search | Transcripts in the app's search (`TranscriptSearch`, shared with `search --transcripts`) (GA-06, M); highlights inside text boxes (`TextMatchBoxes`; CLI `search --show-boxes` too) (GA-07, M) | ✅ #134 (not yet tried on the iPad) |
| Import | App Notability import: an options sheet (attachments, photo metadata, PDF page text, folder tags, read handwriting) and the full report (`dropped.*`, warnings) (GA-08, M) | ✅ #134 (not yet tried on the iPad) |
| Keys | Recipient `repair --keep` and replace-recipient in the app: the recipients alert's Choose Devices to Keep… and the key window's Replace… (GA-17, M); `--prune` and `--archive` stay CLI-only on purpose (`docs/cli.md` "The app's Backups", GA-18) | ✅ #135 (not yet tried on a device) |
| Settings | Settings sync through the vault (`docs/settings-sync.md`): Settings ▸ Sync Settings with This Vault (opt-in per device and vault; first enable seeds or asks Use the Vault's / Replace with This Device's), every setting synced (per-type keys ignored by other types), Only on This Device overrides (explicit until Use Synced Value), Only on iPads / Macs / iPhones type blocks, pause banner for a file that needs a newer Sempere | 🚧 #144 (not yet tried on a device) |
| Settings | Device names: tell devices of one type apart ("my Mac", "the family Mac") so a setting can be scoped to one named device; until then all devices of a type share its block and a local override covers one device (maintainer, 2026-10-09: later) | later |
| Capture | C8: stale `completeUnlessOpen` comments in `QuickCapture.swift` (GA-34, S) | 📋 |
| Release | Privacy policy (both copies), App Store answers and `DESIGN.md` describe the dormant model downloader exactly; `release-check.sh` fails on networking in the app outside it and on a non-empty catalogue, checks the SwiftMath pin and (CI `app` job) scans its checkout; the CLI release refuses a CHANGELOG section with `TODO(user)` or no date (GA-40 to GA-42, M) | ✅ #130 (the 0.5.0 date itself is the maintainer's) |
| Tests | `writeEpoch`, `summaryEpochs`, `DerivedLists`, `validateVault`, `backgroundTimeExpired`, quick-capture intents and Live Activity, menu handlers and scene restore, key export, PDF-drag purge (GA-54 to GA-57, GA-59, M); settings confirmations (GA-64, S) | 🚧 #133 |
| Export | HTML and SVG export (`ShareFormat.html` is never offered), `--clean` and `--breaks` in the app; today CLI-only (GA-19, S) | 📋 |
| Release | App Store review notes and listing draft claim highlighted words on the page; check against the iPhone, which has none yet (GA-43, S) | 📋 |
| Tests | Pseudo-language layout test (double-length, right to left, Spanish) in CI on the iPad simulator (iPhone by hand with `SEMPERE_PSEUDO_DEVICE=iPhone`, Catalyst not yet) (GA-51, S–M) | 🚧 #133 |
| Device | Hand tests of the "not yet tried on the iPad" rows, in particular background sync, remote merge, page scrolling and sidebar drops (GA-72, M) | 📋 (needs the maintainer) |

## macOS app (the iPad app via Mac Catalyst; same target, same code)

The gap to the iPad is small for features and moderate for polish. Every
iPad feature above is in the Mac build automatically, because it is the same
target, and CI compiles it on every PR. What is missing is Mac-specific
behaviour and testing on a real Mac.

| Feature | Status |
| --- | --- |
| Builds and launches under Catalyst (CI `app` job) | ✅ |
| Launch without trapping: every window gets the whole environment and survives scenes restored from the other build (the iPad build on a Mac) (#116); views read the model through `@AppModelEnvironment` / `@AppEnvironmentObject` and, outside their window's environment, fall back to the app's instance and log a fault instead of trapping (the Mac launch crash of macOS build 5) (#120) | ✅ #116, #120 (not yet tried on a Mac) |
| Everything in the iPad table | same status as the iPad |
| Tested by hand on a Mac (vault open, iCloud, Keychain; the `docs/mac.md` list, GA-70, L; reopen of a bookmarked vault in the sandboxed Catalyst build, GA-73, M) | 📋 (needs the maintainer) |
| Saved folder access in a sandboxed Mac build | ✅ #46, #85: access check, entitlements and a DEBUG probe on main; reopen after relaunch under the sandbox is on the by-hand list (`docs/mac.md`), not confirmed here |
| Menus and keyboard shortcuts | ✅ #46, #85 (`docs/mac.md`); File/Edit commands restored after build 6 (UIKit shortcut clashes), checked on Catalyst in CI; File menu import/export ✅ #101 |
| Export menu (File ▸ Export) | ✅ #42 (`ExportMenuCommands`); acts on the focused window's notes since build 6; File > Export… (⇧⌘E, the sheet picks the format) replaces the submenu on the Mac ✅ #101 |
| File menu: Import PDF as New Note… (⇧⌘I), Import from Notability…, Insert PDF Pages…, Insert Photo… (⌥⌘I), Export… (⇧⌘E), same paths as the toolbars | ✅ #101 (not yet tried on a Mac) |
| Double-click a note in the list opens it in its own window | ✅ #101 (`MacWindowUITests`; not yet tried on a Mac) |
| ⌘, (app menu Settings…) opens the app's Settings; Catalyst's generated pane (touch alternatives) is replaced | ✅ #101 (`MacWindowUITests`; not yet tried on a Mac) |
| Sempere ▸ About Sempere (the app's About, not the standard panel) and Help ▸ Quick Tour / About Your Key (`MacMenus`) | ✅ #142 (`LaunchSmokeUITests`; not yet tried on a Mac) |
| Tooltips (`.help`) on every icon-only control, enforced by `scripts/check-help.py` in the `app` job | ✅ #101 |
| Finder Open With on a PDF: imported as a new note (vault chosen, unlocked first) | ✅ #101; needs a hand test on a Mac |
| PDF page attachments on the canvas | ✅ #85 (blank in build 6; tile redraw on scale change fixed, checked on Catalyst in CI); iCloud vault needs a hand test |
| App tests on Mac Catalyst (`scripts/app.sh test-mac`, `test-mac-ui`) | ✅ CI on `main` and dispatch |
| Launch smoke tests: fresh state, unlock sheet, every column layout, every window and sheet (`LaunchSmokeUITests`, `test-mac-smoke`; iPad layouts in `test-ui`); every scene injects the app environment (`AppSceneEnvironmentTests`, Linux) | ✅ #119, CI on every run (not yet tried on a Mac) |
| Multiple windows (one note per window), state restoration | ✅ #46 (`docs/mac.md`); note windows checked on Catalyst in CI; restoration needs a hand test; double-click opens a window ✅ #101 |
| Drag a note to the Finder as PDF | ✅ #46, #85 (`docs/mac.md`); file promise served off the main thread after build 6; Finder drop needs a hand test |
| Bulk export from the app | ✅ #42 (multi-selection export, `ShareExport`); File ▸ Export Notes… (selection, notebook or vault; PDF, PDF + attachments, PNG; folder (resumable) or zip), shared with `sempere export --all` (`BulkExportSession`): ✅ #109 (not yet tried on a Mac) |
| Key management window (recipients, add/remove device key, paper kit) | ✅ #46 (`docs/mac.md`); save/create key actions ✅ #99; replace a device key ✅ #135 |
| Drawing with mouse/trackpad (any input, object eraser takes the pointer, tool-sized cursor, ruler) | ✅ #46 (`docs/mac.md`); mouse stroke smoothing (Settings → General: Off / Light / Strong) ✅ #123 |
| Mac App Store build (same bundle, universal purchase) | ✅ #113: project checked (one bundle id, sandbox, entitlements allow-list in `scripts/release-check.sh`), steps in `docs/release/app-store.md` §6; the submission is 📋 |
| Mac App Store screenshots (Catalyst, 2880 × 1800, best effort) | ✅ #53 |
| Keyboard shortcuts for item actions and recording: ⌘D, ⌥⇧⌘F, ⌃⌘⌫, ⌃⌘M (GA-13, S) | 🚧 #131 |
| Menu parity: Version History, page duplicate / delete / undo delete, Add Page After This One, layout toggle, Show Pages, Text and Select tools, eraser size and Compact Palette as Note / Tools / View entries (GA-14, M) | ✅ #136 (not yet tried on a Mac) |
| CI: run the Mac Catalyst app suites on PRs, not only on `main` and dispatch (GA-62, S; a decision on macOS runner time) | 📋 (needs the maintainer) |
| Menu-bar item for quick capture (GA-23, M): File > Start/Stop Voice Note (⇧⌘M) ✅ #136; a status-bar icon with Quick Voice Note and New Note, from a small AppKit bundle loaded by the Catalyst app, with a Settings toggle 🚧 | 🔀 follow-up PR for the icon (not yet tried on a Mac) |

## iPhone and web

| Feature | Status | Notes |
| --- | --- | --- |
| iPhone: "Don't see iCloud Drive?" help (iCloud Drive's per-device sync setting, Files' hidden locations; `docs/iphone.md`) | ✅ #84 | The picker needs no entitlement; the cause is a device setting. |
| iPhone app as a reader | ✅ #65 (`docs/iphone.md`) | Same SwiftUI target, device family 1,2. Compact stack (vault, notebooks and tags, list, note); read-first note view (pan, zoom, page bar, finger annotation behind a pencil button); search, export, history and Face ID unlock shared with the iPad; tests at iPhone sizes run on an iPhone simulator in the `app` job; 6.9" screenshots (`scripts/screenshots.sh iphone`). Not yet tried on a physical iPhone. |
| Web viewer with in-browser decryption | ✅ #63; attachments ✅ #75 | `web/` (TypeScript, Vite, no backend; `docs/web-viewer.md`): opens a vault from a static or WebDAV URL or a local folder, decrypts with typage (MLKEM768-X25519) in the page, merges and draws notes exactly as the CLI's JSON and SVG exports (cross-checked in CI), notebooks, tags, search, pan and zoom. Key pasted, memory only; strict CSP. Attachments (#75): images, text boxes (stored `breaks`), PDF pages (pinned pdf.js), placeholders, recordings with playback and transcripts; blobs fetched lazily and verified (hash and keyed name). Newer-format vaults and revisions (`format.md` §7) open and show what this version understands (✅ #94). Opt-in passkey (WebAuthn PRF) to remember the key on a device ✅ #99. Fast opening with `config.json`, published summaries and a ciphertext cache ✅ #100. Transcript search (CLI rules, shared goldens) and passphrase-wrapped keys (stored `keys/` file or a recovery kit's locked copy, scrypt in a worker) ✅ #117. Markdown text boxes (the shared parser and layout ported, formulas from their stored renders through pdf.js, cross-checked with the CLI) 🚧 #129. Hosted in the maintainer's home lab behind the existing Caddy/TLS. |
| Web viewer: Spanish interface | 🚧 this PR | `web/src/i18n/` (typed catalog, English + complete Spanish, plurals), language from `navigator.languages` with a selector override kept in the browser; vault data untranslated; `i18n.test.ts` (every key has Spanish, glossary, no English literals in `src/ui`) and `smoke-language.mjs`. `docs/web-viewer.md` "Languages", `docs/localization.md` "Web viewer". |
| Web viewer: transcript search (the CLI's rules, shared goldens) and passphrase-wrapped keys (a stored `keys/` file or a recovery kit's locked copy, scrypt in a worker) | ✅ #117 | `docs/web-viewer.md`. |
| WebDAV mirror for the viewer | ✅ CLI part #97 (`sync webdav --push-only`); the push-only mirror and Caddy are set up on the maintainer's side | A WebDAV share on the NAS behind Caddy, plus a macOS `launchd` agent running `sempere sync webdav --push-only` every few minutes from the iCloud vault, so the NAS can never feed back a changed recipient list. #63 documents the Caddy + `sync webdav` setup (`docs/web-viewer.md`); static hosts use `sempere vault index`. The setup itself lives in the sysadmin repo, outside this one. |
| WebDAV as a vault location in the app | 🔀 #137 | Open Vault ▸ WebDAV… (URL, user, password in the Keychain only, Test Connection, vault list), https only with a loud certificate-pin opt-in for self-signed servers, a local copy that works offline and is pushed (push-only, `--keep-server-changes`) after writes, on activation and every 5 minutes, status bar with Sync Now, Download Again… (other devices' notes) and Server Settings…; key changes refused for such a vault. `docs/io.md` "WebDAV vaults in the app". Mac build gains `network.client`. |
| Proton Drive in the Files app (privacy first: no other providers targeted) | 🔀 #137 (guards); needs a device test | Code paths that assume local files audited (`docs/io.md` "Other Files providers"); vaults in another app's provider storage are coordinated even when not ubiquitous (`StorageLocation`). Proton Drive on iPadOS and Mac needs the maintainer's device test (list in the doc). |
| iPhone: page layout switch, Duplicate / Delete / Undo Delete Page, Add Page After This One, Insert PDF at page and the thumbnail strip on the phone toolbar (GA-15, M) | ✅ #136 (not yet tried on an iPhone) | The Pages submenu of the overflow menu (`PhonePageMenu`). |
| iPhone: swipe to turn pages, search-hit highlights on the phone, paper picker layout pass (GA-16, M) | ✅ #136 (not yet tried on an iPhone) | Swipe and the compact paper picker added; the highlights already worked (shared canvas code), now tested at phone size. |
| iPhone: tests of the overflow menu and Annotate, the "wide landscape ignores the stored column" and pageless one-screen rules at phone size (GA-58, M) | 🚧 #133 | `PhoneLayoutTests.swift`. |
| iPhone: hand test on a physical iPhone (Face ID, folder picker, finger annotation) (GA-71, M) | 📋 (needs the maintainer) | Needs a phone. |
| Web viewer: cache ciphertext from before a rewrap stays openable by a removed key (P4) (GA-28, S) | 📋 (#125) | `web/src/vault/cache.ts`; `security-review-2026-10.md`. |
| Web viewer: passkey record bound to the vault's location, not only its (unauthenticated) id; version 1 records migrated; no IndexedDB database before opting in (P3) (GA-28, S) | ✅ #130 | `web/src/vault/passkey.ts`; `docs/web-viewer.md` "The location". |
| Web viewer CI: run all 7 browser smoke scripts (`web-smoke` job, `smoke-all.sh`), give `smoke-cache` a fixture with summaries and an index (GA-52, M) | 🚧 #133 | `ci.yml`, `web/scripts/`. |

## First release

Steps only the maintainer can take. None of them is code in this repo, so they are not tasks in `docs/plan.md` beyond a pointer.

| Feature | Status | Notes |
| --- | --- | --- |
| Release shape: squash the whole history into one public "Initial commit", as kidsplay did. This repo, with its PRs, keeps the development history as a private archive repo; a fresh public `anthonytw/sempere` gets the single commit. Includes the CHANGELOG and version, the App Store submission, TestFlight → release, and the GitHub rulesets on the new repo | 📋 (needs the maintainer) | Related rows: App Store submission (iPad app Release and macOS app sections), CHANGELOG `TODO(user)` date (GA-41). |
| Project website on GitHub Pages at `sempere.anthonywertz.com` (custom domain CNAME): capabilities, demo videos, spec sheet (formats, crypto, platforms), the security design, an in-browser web-viewer demo on a sample vault, download links, and hosting of the privacy policy and support URL the App Store needs | 📋 (needs the maintainer) | The privacy policy already has two copies (`docs/privacy/index.html` for Pages, `docs/appstore/privacy-policy.md`). The viewer demo reuses `web/` with the fixture vault; it must never send a key anywhere. |
| Licence terms for the App Store: review the custom licence agreement draft (`docs/appstore/eula.md`: the GPL's no-warranty and liability terms in plain form, Apple's minimum terms; fill its `TODO(user)` contact, governing law and EU/UK consumer wording) and paste it into App Store Connect; decide on the revised App Store exception draft (`docs/appstore/app-store-exception-draft.md`, not applied: `LICENSE-EXCEPTION` is unchanged) with a lawyer | 📋 (needs the maintainer) | `docs/release/app-store.md` §5 "License agreement" and §9. |
| Legal review of the Notability importer before release: reverse engineering and interoperability, Notability's terms of use, trademark use of the name. Option: ship the importer as a separate tool or repo | 📋 (needs the maintainer) | `Sources/SempereNotability`, `docs/import-notability.md`. The importer is now a removable module (one directory, CI-checked), which keeps the options open. |
| Large-scale audit after feature freeze: parallel task forces for bugs, security, inefficiency, inconsistency (code, docs, CLI vs app) and reuse (duplicated logic). Findings are verified, then fixed in batched PRs before the documentation pass | 📋 | Run once the open feature PRs have merged, so findings are not stale. Many Sonnet agents plus a few Opus agents. |
| Documentation and comments pass, the last step before release: every Markdown document (README, DESIGN, docs/, CONTRIBUTING, SECURITY, App Store texts) and code comments rewritten to be simple, objective, clear and concise. Plain statements of fact, no marketing; remove stale status lines (README still calls the app "a scaffold") | 📋 | After the audit fixes. Keep `docs/format.md` normative; change wording, not meaning. |
| CLI packaging, only if minimal: Homebrew tap, plus tarball, `.deb` and `.rpm` built with nfpm. No MacPorts | 📋 | `packaging/homebrew/` has the formula template. |
| On the fresh public repo: enable private vulnerability reporting and the branch rulesets | 📋 (needs the maintainer) | Private vulnerability reporting is already on for this repo. The rulesets are also part of the Release shape row above. |
| Lawyer consult: Notability importer, the GPL App Store exception (`LICENSE-EXCEPTION`), the EULA | 📋 (needs the maintainer) | Drafts from the expectations PR (#142). The importer part is the Notability legal review row above: one consult closes both. |
