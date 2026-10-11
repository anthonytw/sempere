# Importing from Notability

`Sources/SempereNotability` reads Notability's `.note` packages (and the newer
`.ntb` bundles) and writes them into a vault as ordinary notes. Notability's format is undocumented; everything
below was reverse-engineered from a real backup of 130 notes written by
Notability 10.2 through 14.9 (session format versions 5 to 9) and checked
against the thumbnails Notability stores in each package. Where a rule is
empirical it says so.

## Structure: a module you can delete

The importer is optional. Everything specific to Notability is in one directory, `Sources/SempereNotability`
(tests: `Tests/SempereNotabilityTests`, with its fixtures and the CLI tests of `import notability`), and
the rest of the package neither imports it nor names its types:

| Target | Holds | Depends on |
| --- | --- | --- |
| `SempereImport` | the generic readers every importer uses (`ZipArchive`, `BinaryPlist`, `XMLPlist`, `KeyedArchive`, `NotePackage`), all of them untrusted-input code (`format.md` §9), and the host interface: `VaultImporter` (id, display name, accepted file extensions, option specs, `run(request, clock:)`), `ImporterRequest`, `ImporterResult`, `ImporterRegistry` | `Sempere`, `SemperePDF`, `SempereRender` |
| `SempereNotability` | the importer (`NotabilityImporter`, the `.note` and `.ntb` readers, shapes, text, audio, attachments) and its adapter `NotabilityVaultImporter` (options, the CLI's report and JSON) | `SempereImport` and what that uses |
| `SempereCLI` | `sempere import <id>`: one subcommand per registered importer (`RegisteredImportCommand`), its flags from the importer's option specs, `--notebook`, `--dry-run`, `--pdf-text`, `--recognize` and the vault and output options of every import | `SempereImport` |
| the app | the Import entry of the File menu and the note list, the options sheet and the report sheet, built from the importer's option specs and result (`AppModel+Import`, `ImportViews`) | `SempereImport` |

Core (`Sources/Sempere`, `SempereRender`) holds no Notability code: an importer's derived ids,
`engine: notability-<version>` strings and stroke kinds are plain data (`format.md`
§5.5, §8.2.6) that core treats like any other.

**Registering.** Each host lists its importers in exactly one file, gated by `#if canImport(SempereNotability)`:
`Sources/SempereCLI/ImportRegistry.swift` and `Apps/Sempere/SempereApp/AppImporters.swift`.
`scripts/check-importer-isolation.sh` fails CI when any other file names a `Notability…` identifier or imports the module.
`Package.swift` adds the module's targets, its test target and the CLI's dependency on it only when
`Sources/SempereNotability` exists.

**Removing it.**

1. `rm -rf Sources/SempereNotability Tests/SempereNotabilityTests`. `swift build`, `swift test`, the CLI and the web goldens
   (they are data) are unaffected; `sempere import` then lists only `pdf`. `scripts/check-removable-importers.sh` does exactly this
   in a copy, builds the package and every test target, and runs the CLI's tests (the Linux CI job runs it on every
   package change; `check-importer-isolation.sh` covers the other targets).
2. The app (an Xcode project cannot test for a directory): `scripts/remove-notability-from-xcode.sh` removes the
   `SempereNotability` package product dependency from the app target (four spots in
   `Apps/Sempere/Sempere.xcodeproj/project.pbxproj`, ids `…B009` and `…D007`) and its row in
   `scripts/release-check.sh`. `AppImporters.registry` is then empty: the Import entry disappears from the menu and the toolbar,
   the rest of the app is unchanged. Only the CI `app` job builds this; it has not been run without the module.
3. Optionally delete the catalog strings of the Import options and report (`Localizable.xcstrings`: the "Import …" and
   "Tag Notes with Their %@ Folders" entries); nothing fails if they stay.

**Adding another importer** is the same shape: a module with a `VaultImporter`, one line in each registry, one product in the
Xcode project.

## Running a bulk import

Library call (`sempere import notability` wraps it through `NotabilityVaultImporter`):

```swift
var clock = HybridClock()
let report = try NotabilityImporter.import(
    paths: [URL(fileURLWithPath: "Notability-backup.zip")],
    into: vault, device: device, clock: &clock,
    options: .init(overwrite: false, notebook: nil, scaleToLetterWidth: true,
                   tagsFromFolders: true, extraTags: []))
for n in report.notes { print(n.status, n.source, n.strokes, n.dropped) }
```

Each path may be a single `.note` (a zip, or an unzipped package directory)
or `.ntb`, a directory (searched recursively, not descending into packages),
or a zip Notability's Google Drive backup produces (`Notability/<Subject>/
<Folder>/<name>.note`, `<name>.ntb`, and `<name>.pdf`, Notability's own PDF
export, which the import ignores). Google Drive splits a large backup into
several zips (`Notability-<date>-1-001.zip`, `-002`, …): **pass all of them
in one run**, so copies of a note in different parts are resolved together
(below). Each imported note becomes one delta: `addPage`, one `addStroke`
per stroke, one `addItem` per attachment (PDF page backgrounds and images,
"Attachments" below; their blobs are written first), `setMeta` for title,
notebook, paper and page size, one `addTag` per tag (`format.md` §5.4.1),
and `setPageRecognition`. An overwrite also
removes the old tags (`removeTag`). Every input file gets one report row,
whatever happens to it: nothing is silently ignored.

- **Notebook**: the directories under `Notability/` (`Research/Daily log`);
  for a directory input without one, the path relative to it; otherwise
  Notability's subject. `options.notebook` overrides all of these.
- **Tags**: Notability's own tags; with `tagsFromFolders` (the CLI's
  default, `--no-folder-tags` turns it off; off in the library) one more tag
  per segment of the folder path (`Research/Daily log` → `Research`,
  `Daily log`; the Notability subject when the path has no folder, never
  `options.notebook`); then `extraTags` (`--tag`, repeatable). The set is
  normalised as `format.md` §5.4 says (`NoteOps.normalizedTags`: whitespace
  collapsed, matched case-insensitively, first spelling kept) and written
  as one `addTag` per tag; an overwrite first removes every tag instance it
  sees (`removeTag`), so it drops the old folder's tags when a note moved,
  while a tag another device added concurrently survives (§5.4.1). The notebook is unchanged by this. One function builds the set
  (`NotabilityImporter.tags(for:folder:options:)`).
- **Idempotent**: the note id is `UUID.derived(from: "sempere-notability:"
  + uuidKey)` (SHA-256, RFC 9562 version 8). A note already in the vault is
  skipped; `overwrite` removes its pages and writes the content again with
  fresh page and stroke ids salted with the overwriting delta's
  `<device>-<seq>`, so no overwrite from any device re-mints a removed
  (tombstoned) id (`format.md` §5.2). Tags and notebook are always written,
  so an overwrite can clear them. The overwrite's clock first observes the
  note's revisions, so its writes win LWW (and are not superseded by a
  legacy tags write) even when another device's clock was ahead.
  Several sources of one note in a run are resolved as "Duplicates and
  versions" below says.
- **Created date**: the delta's `wall` is Notability's creation date, so the
  note's `created` (`format.md` §5.4) is preserved. Its `hlc` is current.
- **Scale**: by default (`scaleToLetterWidth`) every length (coordinates,
  widths, paper pitch, recognition boxes, break height) is multiplied by
  `612 / W`, so a page is US-letter width in points and exports paginate as
  letter-width pages (612 × 803.25 for Notability's 21/16 page). Off keeps
  Notability's document units.
- **Report**: per source `ok`, `skipped(reason)` or `failed(reason)`, its
  format (`note` / `ntb`), stroke count (shape-tool strokes included and
  also counted in `shapes`), recognised pages, Notability's original document
  width, what was dropped, and for a note with several sources
  `duplicateOf` (the source imported as the note), `extraVersion` and
  `selection` (why this source was or was not chosen). A corrupt note (bad
  zip, inconsistent point arrays, coordinates beyond ±10⁶, an undecodable
  bundle) fails with a reason and never stops the run.

## Duplicates and versions

A Google Drive backup is not a snapshot: Notability's auto-backup writes
each note under its current folder and never deletes what it wrote before.
A note that was moved (a class folder later moved under an archive folder,
or a flat copy at the top level from before folders were used) stays in the
backup at every path it ever had, each copy as of its last backup there; a
renamed note also keeps its old name, and Drive adds ` (1)` to clashing
names. In the 3-zip backup of 2026-10-05: 928 `.note` files hold 630
Notability uuids; 243 uuids have 2–4 copies (298 extra files, 120 groups
spanning two zips). In about 208 groups every copy has the same
`Session.plist` (same note, other folder); in 35 the copies differ, and the
older ones are, with four exceptions, strict subsets of the newest (ink added
later). In the four, an older copy holds strokes the newest does not have
(1, 39, 402 and 451 strokes: erased or lasso-moved later).

The importer therefore reads every source before writing anything and groups
them by Notability uuid (an `.ntb` by creation time, below). Per group:

1. **Primary** (imported as the note, id from the uuid as before): a copy
   with strokes before an empty one; among those, a `.note` before an `.ntb`;
   then the newest `noteModifiedDateKey` (the `.ntb`'s newest record); then
   the newest file (zip entry modification time); then the path, ascending.
   Each copy gets one sort key from these, so the choice does not depend on
   the order of the inputs. (The earlier pairwise rule, "a `.note` unless it
   is empty and the `.ntb` is not", was not a consistent order: with an
   empty newest `.note`, an older inked `.note` and an inked `.ntb`, the
   primary depended on which zip was passed first.) Its row's `selection`
   says which rule decided.
2. **Every other source**, newest first, is compared stroke by stroke with
   what is already imported for the group. A stroke matches when point count
   and colour are equal and its first x and its first-to-last vector agree
   within 0.3 units plus 1/512 of the value (half-float precision of an
   `.ntb`), and, between two sources of the same format, its first y as
   well. Between an `.ntb` and a `.note` y is not compared: the bundle
   places later pages of a PDF note at its own page stride, not the
   `.note`'s, so an `.ntb` whose only extra ink repeats a stroke of the
   `.note` at another height on the same x is still reported as superseded.
   (Before y was compared, an older `.note` holding a second copy of a
   shape further down, erased later, was skipped and that ink lost.) Then:
   - every stroke matches → **skipped**, naming the primary: `duplicate:`
     (same strokes: the same note in another folder), `older version:` (a
     subset), or `superseded:` (an `.ntb` copy);
   - otherwise → **imported as a separate note** (`extraVersion`), title
     `<title> (version modified <ISO date>)`, id derived from the uuid plus
     format and the SHA-256 of its ink (every curve's style, colour, width
     and points: two versions with different ink never share an id, and
     file times, which change between downloads of a backup, play no part),
     filed in its own folder's notebook. Nothing a user drew is lost; deleting the extra note is a
     user decision.

   The comparison is budgeted (`PrintIndex`: 256 comparisons per stroke
   plus 10⁶ per copy, `docs/format.md` §9): strokes that agree on
   everything but their height share a lookup bucket, and a hostile pair of
   copies could otherwise make it quadratic. A stroke not decided within
   the budget counts as not matching, so such a copy is imported separately.

Deterministic: the same inputs give the same choices and ids, so a second
run reports everything as "already in the vault". With the 2026-10-05
backup (`--dry-run` over all three zips: 1531 sources): 640 notes imported —
629 from `.note` files, 6 from `.ntb` bundles (5 with no `.note`, 1 whose
`.note` was empty), 5 separate versions (4 older `.note` copies, 1 `.ntb`
sharing a creation time with another bundle); 286 identical copies, 9 older
versions and 596 superseded `.ntb` copies skipped; 0 failed (5 before:
short `curvesstyles`).
The earlier rule ("the first one read wins") imported whichever copy sorted
first, often an old copy in an old folder.

## Shapes

Notes drawn with the shape tool store the shapes next to the curves, as
`InkedSpatialHash.shapes`: a nested binary plist `{shapes: [...], indices:
[...], kinds: [...]}` (9 notes, 287 shapes in the backup), in the same ink
coordinates as the curves (checked against the `.ntb` copies, which store
them as records). Each kind is converted to Bézier curves and imported as
pen strokes (width `appearance.strokeWidth`, colour `appearance.strokeColor`
RGBA 0…1):

| kind | keys | curve |
| --- | --- | --- |
| `line` | `startPt`, `endPt` | a straight segment |
| `circle` | `rotatedRect.corners` (4 points) | the inscribed ellipse, four quarter arcs |
| `partialshape` | `strokePath`: 4-byte tag, u32 element count, one type byte per element (Core Graphics: 0 move, 1 line, 2 quad, 3 cubic, 4 close), then float64 point pairs | one curve per subpath |

They are appended after the curves (`indices`, apparently their z-order
among the curves, is not used). A shape whose path does not decode is
counted in `dropped.unsupportedShapes`.

## Per-curve arrays shorter than the curve count

Two notes (four copies; format 5, Notability 4.4 and 10.1) have
`curvesstyles` 1 and 3 entries short of `numcurves`. Comparing them with
their `.ntb` copies shows the extra curves are pieces of strokes split by the
eraser (the `.ntb` stores such a stroke as one record with jumps). The
importer no longer fails such a note: every per-curve attribute array
(`curveswidth`, `curvescolors`, `curvesstyles`, `curveUUIDs`) shorter than
`numcurves` is padded with defaults (width 1.4, opaque black, pen, no uuid),
extra entries are ignored, and the curves concerned are counted in
`dropped.defaultedAttributeStrokes`. Point arrays (`curvesnumpoints`,
`curvespoints`, `curvesfractionalwidths`) must still agree: a mismatch there
makes the geometry ambiguous and fails the note. No other per-curve array
was short in the backup.

Real-data checks live in `Tests/SempereNotabilityTests/RealNotabilityTests.swift`
and are skipped unless `SEMPERE_NOTABILITY_SAMPLES` points at a backup zip
or directory, or several joined by `:` (`testBundlesMatchTheirNotes`
compares every `.ntb` with its `.note`):

```bash
SEMPERE_NOTABILITY_SAMPLES=data/Notability-backup.zip \
SEMPERE_NOTABILITY_RENDER_DIR=data/render \
  swift test --filter RealNotabilityTests            # parse all, render + compare, page geometry
SEMPERE_NOTABILITY_SAMPLES=data/Notability-backup.zip \
SEMPERE_NOTABILITY_BULK_VAULT=data/scratch.sempere \
  swift test --filter testBulkImport                 # full import, prints report
```

## Fidelity evaluation

A repeatable, exhaustive check of every imported note against Notability's
own rendering, and of the app's canvas against the export, to re-run after
any importer, renderer or canvas change:

```bash
scripts/import-eval.sh data/Notability-backup.zip      # writes data/eval/report.html, summary.json
scripts/import-eval.sh --out data/eval-full data/Notability-*-1-00{1,2,3}.zip   # a split backup: all parts
SEMPERE_EVAL_SKIP_CANVAS=1 scripts/import-eval.sh …   # import + PDF + thumbnails only (minutes, no simulator)
```

It needs macOS, Xcode with an iPadOS 27+ simulator (`SEMPERE_SIM_ID`
picks one) and `uv`.
The output directory (default `data/eval`, git-ignored) must be ignored by
git, since everything in it is derived from personal notes; the script
refuses otherwise. Notes are named only by the first 8 hex digits of their
vault id (a hash of Notability's uuid). Three stages:

1. **Import oracle** (`ImportFidelityEvalTests`, gated on
   `SEMPERE_NOTABILITY_SAMPLES` and `SEMPERE_EVAL_DIR`): imports the backup
   into a fresh scratch vault (`work/vault.sempere`, new key
   `work/identity.key`) with the normal importer, reads every note back from
   the vault, and renders its first Notability page (`PNGWriter`, no paper,
   one `breakHeight` tall) at the width of each thumbnail in the package
   (`thumb.png` 48 px … `thumb12x.png` 576 px), so the known geometry aligns
   the two images with no search: 612 pt ↔ thumbnail width, y from the top.
   It also copies the thumbnails and, for notes made from a PDF, the PDF and
   the page number of the note's first page (`pageLayoutArray`). When the
   backup holds **Notability's own PDF export** of the note (`<name>.pdf`
   next to `<name>.note`: 395 of the 2026-10 backup's notes, 286 of the
   chosen sources), it also writes that (`notability.pdf`) and **every**
   export page of the note at 1.5 px/pt (`ours-page-NNN.png`, one
   `breakHeight` each, no paper), plus the PDFs the note's pages sit on and
   the PDF page of every Notability page (`pages.json`). The stage runs as a
   release build with testability (`swift test -c release -Xswiftc
   -enable-testing`): rendering every page in a debug build is ten times
   slower (about 5 minutes for the full backup in release).
2. **Canvas vs export** (`CanvasExportEvalTests` in the app tests, gated on
   `SEMPERE_EVAL_VAULT`, `SEMPERE_EVAL_IDENTITY`, `SEMPERE_EVAL_OUT`, passed
   as `TEST_RUNNER_…` to `xcodebuild test`): for every band (export page,
   one `breakHeight`) of every page of every note, including every band of
   tall infinite pages, an on-screen snapshot of a `PageCanvasHost` showing
   `NoteEditor.drawing(for:)` (Stroke → PKStroke → PKDrawing, what the editor
   displays) in a window one band in size at fit-width zoom 1, scrolled to the
   band; `PKDrawing.image` of the same rect; and `PNGWriter`'s page for the band.
   The canvas page is extended to whole bands so the last band scrolls to the
   top like the others. About 3 s per band plus about 20 s per note (PencilKit tiles settle for
   `SEMPERE_EVAL_SETTLE_MS`, default 1200).
3. **Metrics and report** (`scripts/import_eval.py`, run with `uv`, one
   worker process per CPU): writes
   `summary.json` (every metric per thumbnail and per band, aggregates,
   thresholds) and a self-contained `report.html` (per-note table worst
   first, distributions, and ours / reference / overlay images for the worst
   20 notes and every flagged one, also saved under `img/`).

**Notability's PDF export, every page.** Page *n* of `notability.pdf` is
compared with our export page *n* (the same `breakHeight` band), both at the
same pixel width (918 px ↔ 612 pt; a landscape page is 792 pt wide in the
PDF and 612 pt in the vault, so the scale differs, the pixels agree). The
PDF draws, in order: white image tiles, the page content (the paper pattern
as **one page-wide filled path of colour (163, 183, 211)**, or the source
PDF page re-embedded), invisible text (Notability's handwriting OCR), then
the ink as filled, unstroked paths. Paper pages: the tiles, the text and the
paper path are removed with pdfium and both images go through the ink
classifier below. Pages on a PDF: the page is rendered twice, as is and
without its trailing run of filled, unstroked paths (the ink); a pixel is
Notability ink when it differs from that ink-less render **and** from the
source PDF page in the note (each with the 5 × 5 tolerance below; the first
alone also removes a slide's last filled shapes, the second alone flags
re-embedded glyphs), and blobs under 8 pixels are dropped. Our page is
composited on the ink-less render and judged the same way. Per page: the
metrics below; per note: worst page, median; flags `pdf-f1` (< 0.85),
`pdf-chamfer` (> 1 pt), `pdf-ratio` (outside 0.7–1.4), `pdf-bbox` (> 4 pt),
`pdf-content-not-imported`, `pdf-ink-beyond-last-page`. When the PDF export
exists, its flags replace the thumbnail's (the thumbnails show only page 1
and are often stale); the thumbnail flags stay in `oracleFlags`.

**Ink masks.** Both images of a pair go through the same classifier. On
paper, a pixel is ink when its luminance is below 170 (Notability's dot paper
is 181 and lighter) or its chroma (max − min of RGB) is above 60 (coloured ink
and highlighter); our renders are composited on white first. On a PDF page the
reference is the PDF page rendered with pdfium at the thumbnail size, and a
pixel is ink when its RGB distance from the page exceeds 60 for every page
pixel in its 5 × 5 neighbourhood: Notability's own raster of the page is about
a pixel off pdfium's, and without that tolerance page edges show up as ink.
Our render is composited on the same PDF raster, so both sides are judged the
same way. A thumbnail that differs from our PDF raster in under 1 % of its
pixels counts as showing no ink.

**Metrics** (oracle: our page 1 vs each thumbnail; canvas: canvas vs export
per band, plus `PKDrawing.image` vs export and canvas vs `PKDrawing.image`):
ink pixel ratio, IoU, F1 with one pixel of tolerance (precision: our ink
pixels within a pixel of reference ink; recall the other way), symmetric mean
chamfer distance in points (and the larger 95th percentile), ink bounding-box
edge deltas in points, and, for thumbnails at least 288 px wide, the integer
pixel shift within ±4 px that maximises IoU (the residual offset; zero means
the geometry needs no correction). A darkness correlation (Pearson, after a
one-pixel blur) covers the low-resolution thumbnails, where thin ink is too
faint for a mask.

**Which thumbnail.** Notability leaves some thumbnail sizes stale: blank
paper, or an older state of the page, while other sizes are current. The
primary thumbnail is the largest one at least 288 px wide that shows ink;
sizes that are blank where we have ink are listed as stale. A note whose only
current thumbnails are low resolution is judged by darkness correlation.

**Flags.** Oracle: chamfer > 1.5 pt, F1 < 0.80, ink ratio outside 0.6–1.6, an
ink bounding-box edge off by > 6 pt, every thumbnail blank, or the thumbnail
showing content where we have no ink. Canvas, per band: F1 < 0.90, ink ratio
outside 0.75–1.33 (as `CanvasHostRenderingTests`), a bounding-box edge off by
> 3 pt, or a scroll position that does not reach the band. Informational, not
failures: `stale-thumbnails`, `has-media`, `pdf-template`, `low-res-thumbnail-only` (judged by darkness correlation ≥ 0.6 instead). Each flagged note
gets a first-guess root cause (canvas conversion, stale thumbnail,
unsupported images or PDF template paper, else importer geometry) that the
images confirm or correct.

**Limits.** The thumbnail oracle sees only the first page; notes without a
Notability PDF export (most extra copies, bundles) are judged by it alone. Thumbnails of notes with images
or PDF template paper show content the importer drops; those notes'
geometry metrics are not meaningful. `thumbnail` / `thumbnail2x` (binary
plists, newer notes) are not read.

**Results on the 2026-10-05 backup** (3 zips, `data/eval-full`, canvas
stage not run): 640 imported notes; 286 with Notability's PDF export, 249
with ink, 753 inked pages compared (582 paper, 171 on PDFs). Per page F1
with 1 px tolerance: median 1.000, 10th percentile 0.998; chamfer median
0.013 pt (90th percentile 0.12 pt); ink ratio median 0.990. Worst page per
note: median F1 1.000, 10th percentile 0.995. Thumbnail oracle (512 notes
with ink on both sides): F1 median 0.999, chamfer median 0.06 pt. 49 notes
flagged, none with a suspected importer cause left:

| Category | Notes |
| --- | --- |
| measurement: the thumbnail's raster of the PDF page differs from pdfium's (our ink all on it) | 14 |
| measurement: rasterization specks of a PDF page (< 64 px) | 6 |
| measurement: faint ink at the mask threshold | 4 |
| measurement: highlighter over PDF text (Notability draws it behind the text) | 1 |
| PDF page raster differs, no ink on page 1 | 3 |
| stale thumbnails | 4 |
| format limit: paper pages inserted into a PDF note (one `breakHeight`) | 4 |
| not imported: PDF pages of an `.ntb` (the PDF is not in the bundle) | 4 |
| not imported: images | 4 |
| not imported: PDF template paper | 3 |
| not imported: typed text | 2 |

Bugs this found and fixed (synthetic regression tests): PDF page stride from
rounded-down thumbnail heights (10 notes drifting up to a page), the x inset
(0.11 pt), erased strokes in log-style `.ntb` bundles, and the duplicate
choice (an old copy imported instead of the newest).

## .ntb format

Notability 16 writes, next to each `.note` in a Drive backup, a `.ntb` with
the same name (603 in the 2026-10-05 backup, all from Notability 16.12.4;
594 next to a `.note` of the same path, 9 alone). It is a zip of `version`
(`1`), `manifest.json` (`{"appVersion": …}`), `thumbnail.png` (first page)
and `noteBundle`, a [FlatBuffers](https://flatbuffers.dev) buffer (656 B to
4.2 MB). No schema ships with it; `NotabilityBundle.swift` reads it with a
small bounds-checked table/vector reader and the layout below, decoded by
comparing bundles with the `.note` of the same note. Every multi-byte value
is little-endian; "field N" is the N-th vtable slot.

**Root table**: fields 3 and 5 a uuid string (the same in every bundle of
the backup, so not the note's id: pairing by id is impossible), field 4 the
note's creation time (int64 ms since 1970; equal to the `.note`'s
`noteCreationDateKey` to the millisecond in all 502 pairs compared), field 6
a vector of **records**. A record: field 0 a struct (u32, u32 sequence
number), field 1 an int64 ms time (the edit; the newest is the note's
modification time), field 2 an unknown int64, field 4 the record type (u8),
field 5 the payload table. Types seen (counts over the backup): 15 stroke
(632 880), 3 (1 126) and 7 (630) structural, 1 document (604), 18 shape
(273), 2 PDF reference (145: a 68-byte name, `<64 hex digits>.pdf`), 25 (69,
only in bundles without a `.note`), 12 (46), 13 (40), 22 media (21), 8 (8).
Unknown types are ignored. PDF and media records name top-level files of the
bundle (".ntb attachments" below).

**Document (1)**: field 0 → table, field 0 the title. Field 1 → table, field
0 → layout table: field 0 → paper (field 0 pattern: 0 ruled, 1 dots, 2 grid,
absent blank; field 1 float32 spacing in document units, 16.6 for 5 mm dots),
field 3 the page size (2 × float32, 716.8 × 940.8), field 4 four float32
(0, 0, left margin, right margin): the margin is `W / 38.4` (18.667 on a
716.8-wide page, 14.896 on 572). The last document record wins.

**Stroke (15)** payload: field 0 a struct (u32, u32, u32 page index from
0), field 1 the origin (2 × float32, page coordinates: x from the page edge,
y from the page top), field 4 the tool (2 highlighter, absent pen), field 5
a dash pattern (1, 2; absent solid), field 7 RGBA bytes, field 8 the width
(float32, as `curveswidth`), field 9 the geometry bytes, field 14 a u32
(999 999 on highlighters).

**Geometry** (field 9): an 8-byte header — precision (0 half floats, 1
float32), node count (u16), kind (3; kind 7, 14 strokes, is not decoded and
counted in `dropped.unsupportedStrokes`), four zero bytes — then 4 more zero
bytes for float32 precision, then the first node, then one segment per
further node. A **node** is 6 bytes: width multiplier (as
`curvesfractionalwidths`) and force as half floats, then altitude and
azimuth bytes (`0xFF`, `0x00` everywhere: π/2 and 0). A **segment** is a
flags byte, then (x, y) offsets **from the stroke's origin** (not from the
previous point) for the first control point, the second control point and
the end point, then the end node: 19 bytes in half precision. Flags 3 (no
control points) is a jump: the end point starts a new piece and nothing is
drawn in between — where a `.note` has separate curves (pieces of a stroke
the eraser split). Other flags were never seen and are rejected.

**Shape (18)** payload: field 0 as a stroke's (page), field 1 the origin,
field 4 the kind (1 line), field 5 → table, field 3 the end point as an
offset (2 × float32), field 9 RGBA, field 10 the width. Lines are imported;
other kinds are counted as unsupported shapes.

**Coordinates.** Bundle points are page coordinates: `.note` x + `W / 38.4`
(which is also the recorded margin on 716.8- and 572-wide notes; newer
612-wide letter notes record 36 but their points are still page
coordinates), `.note` y − page × page height. The reader converts back to
`.note` coordinates (x − `insetX`, y + page × the document record's page
height), so everything after parsing is shared with `.note` import. On a note made from a PDF the `.note`
stride is the PDF page's (`⌈W × aspect⌉`, below), which the bundle does not
record: ink on later pages of a bundle-only PDF note may sit at the wrong
height. In 382 strokes (all on notes whose ink overhangs the right page
edge) the stored origin is clamped to the page width: their shape is right,
their position is lost (`Curve.originClamped`, `dropped.clampedStrokes`;
the duplicate comparison ignores their x).

**Verification** (`RealNotabilityTests.testBundlesMatchTheirNotes`, gated):
597 bundles have a `.note` with the same creation time. Of their 628 278
strokes (pieces), 624 779 match a `.note` curve of the same point count and
colour point for point; the largest difference of any point is 0.0625
units (median 0.002, 99th percentile 0.016, 99.9th 0.06: half-float
rounding). 591 of the 597 bundles match completely; the rest are other
versions of the note (a `.note` with no ink while the bundle has 127 strokes,
and edited versions).

**Erase (25)** payload: field 0 a vector of 8-byte structs, the ids (record
field 0) of the stroke and shape records it removes. Only bundles without a
`.note` next to them hold any (they are a log, 44 erase records in one of
them); bundles next to a `.note` are compacted. Erased records are skipped
(`erasedRecords`); before this, one bundle-only note imported erased strokes
on top of their rewrites, which the thumbnail comparison caught.

## .ntb attachments

Newer bundles keep each PDF they show, and sometimes JPEG or PNG images, as
**top-level files named by their SHA-256**: `<64 hex>.pdf`, `<64 hex>.jpeg`,
`<64 hex>.png` (found by the driver's structure survey of the reference
backup: 4 of the 7 imported bundles lost their PDF before this). The PDF (2)
and media (22) records name them. Their layout is decoded without a schema
and without real content in hand, so the reader looks for what it can verify
(`NotabilityBundle.attachment`):

- **The file.** Any string or byte vector reachable from the record's payload
  (three tables deep) holding a 64-hex-digit name (`<hash>.<ext>`, or a bare
  hash, matched to the bundle file with that hash and the record's kind), or
  32 raw bytes read as the SHA-256. A record naming no file of the bundle is
  counted in `dropped.bundleRecordsWithoutFile`.
- **Field sizes.** FlatBuffers stores fields inline; without a schema their
  sizes come from the vtable (a field ends where the next one starts). That
  tells a reference (4 bytes) from a 2 × float32 struct (8), a 12-byte page
  header and a 4 × float32 rectangle (16). Each record's layout is listed in
  its warning (`fields 0:12,2:4,3:16`: index and size only, no content), so a
  run on the reference backup shows which fields are real.
- **Page.** A 12-byte field 0 is the stroke header: its third word is the
  0-based page.
- **PDF pages.** The PDFs, in the order the records name them (a PDF no
  record names is used when no record names any, in file-name order, with a
  warning), become `pdfPage` backgrounds exactly as a `.note`'s (D1): **one
  Notability page per PDF page, from the first page**, each at the document
  width and `⌈W · H'/W'⌉` high, stacked from the top. This is the layout of
  every `.note` made from a PDF in the samples (no inserted pages); a bundle
  with inserted paper pages would be misplaced from the insert on (the
  records' page numbers are not decoded yet; the warning says the layout is
  unconfirmed).
- **Ink on PDF pages.** Bundle strokes are page coordinates, placed `page ×`
  the document record's page height down; on a PDF note the `.note` stride is
  the PDF page's, which the bundle does not record. With the PDFs in hand the
  importer now moves each stroke of page `n` to the top of PDF page `n`
  (`⌈W · H'/W'⌉` stride), and the `ios/HandwritingIndex.fb` boxes with it.
- **Images.** Placed as `image` items (D2) on the record's page, by the first
  16-byte rectangle `(x, y, w, h)` (page coordinates, as strokes), else an
  8-byte origin and the next 8-byte size, else the origin and the image's
  pixel size (capped to the page width; a guess, said in the warning). The
  bytes go through the same preparation as a `.note`'s (metadata stripped,
  formats checked).
- Bundle files no record names (and not used as the only PDFs) are counted
  in `dropped.bundleFilesUnreferenced` and listed by hash prefix.

Report: `attachments.bundlePDFRecords`, `bundleMediaRecords`, `bundleFiles`
(top-level `<hash>.<ext>` files), `bundleFilesImported`; the CLI summary adds
`ntbPDFPages`, `ntbImages` and `ntbDroppedPDFs` over the bundles imported.

**What the import does.** A bundle takes the uuid of the `.note` created in
the same millisecond and joins its group ("Duplicates and versions"); the
`.note` is preferred (full-precision points, recognition, PDF layout,
subject) unless it has no strokes and the bundle has, so the 596 bundles
whose strokes are all in it are reported as `superseded: .ntb copy of the
note imported from …`. A bundle without such a `.note` (6: 3 of the 9 alone
by path have their `.note` in another folder) is imported on its own (id
derived from `ntb-created:<ms>`, title from the document record, notebook
from its folder; recognition from `ios/HandwritingIndex.fb` when present; its
PDFs and images from the bundle's top-level files, ".ntb attachments"). Bundles are never silently
ignored: each gets a report row.

## Attachments

PDF page backgrounds, images, typed text and recordings (tasks D1–D4 of
`docs/attachments.md` §14) are read from the package when a note is written
(`NotabilityAttachments.resolve`) and placed as items of the note's one
page; their bytes become blobs of the note (`format.md` §8.1), written before
the delta. `--no-attachments` (`Options.attachments = false`) leaves them out
and reports them as before. Nothing in a package can fail a note through its
attachments: what cannot be placed is counted in `dropped` and explained in
the report's `warnings`, one line each (file names and Notability field
names, never note content). These mappings were built on synthetic packages;
the driver checks them against the reference backup.

**PDF pages (D1).** Every `pageLayoutArray` entry that names a PDF (by
`kPageLayoutPDFFileNameKey`, or a non-null `kPageLayoutPDFFileKey`) becomes
one `pdfPage` item in the background layer (`0`):

- blob: `PDFs/<name>`, stored byte for byte (`application/pdf`), one blob per
  content however many pages show it. The PDF is read with `SemperePDF`; an
  encrypted, missing or unreadable file leaves its pages out (`dropped.pdfPages`,
  and the file in `dropped.pdfs`).
- `pageIndex`: `kPageLayoutPDFPageNumberKey − 1` (1-based, as the fidelity
  evaluation reads it; a note holding a 0 is read as 0-based, with a warning).
  A page beyond the PDF is left out.
- `pageSize`: the page's effective size (CropBox ∩ MediaBox, turned by
  `/Rotate`), `W' × H'` points.
- order: by `kPageLayoutDocumentPageNumberKey` when the entries number 1…n,
  else as stored.
- frame: `[0, top, W, W · H'/W']` in document units (full page width, no x
  inset), × `612 / W` when scaling, where `top` is the sum of the heights of
  the Notability pages above: a PDF page is `⌈W · H'/W'⌉` high (the stride
  measured on real notes, now from the PDF's own box instead of the
  thumbnail), any other page (an inserted paper page) `paper.pageHeight`.
  With one page size this is the old `(n − 1) · stride`. With several
  (unknown 4 of `docs/attachments.md` §11; never seen in the samples) each
  page is stacked on the ones above, which is unverified; the report warns.
- the note's `breakHeight` is the first PDF page's height, and recognition
  boxes of page `n` move by its `top`.
- the page extent covers every background, so a PDF that was never written on
  imports with all its pages.
- a note that would be taller than the renderer's extent (200 000 pt,
  `format.md` §8.4; a PDF of about 250 letter pages or more) is not one
  infinite page: it is cut into pages of its page height, as `sempere notes
  layout paged` does (`format.md` §5.4.3), with ids still derived from the
  note, so it can be exported. Shorter notes keep the one infinite page.
  At most 64 blank pages are kept (`NotabilityImporter.maxBlankSheets`):
  further blank ones are left out, so a stray point far down the page cannot
  turn a small note into thousands of empty pages.

`PDFFile.highlights` (always empty in the samples) are counted in
`dropped.pdfHighlights`. A `TemplatePDF:<uuid>` paper uses a PDF under `PDFs/`
whose name holds the uuid, if there is one (where Notability keeps it is not
known): page 1 of it as a background on every page down to the lowest ink;
otherwise `dropped.templatePDFs` is 1 and the note keeps blank paper. `.ntb`
bundles keep their PDFs as top-level files (".ntb attachments").

**PDF text.** Every placed PDF page (template paper aside, whose one page
would match everywhere) gets its text as the item's `pageText`
(`format.md` §8.2.6), so search finds words on PDF pages:

- From **Notability's index** when it can be tied to pages. A `.note` may have
  `NBPDFIndex/PDFIndex.zip` (107 in the reference backup) holding
  `PDFTextIndex.txt`, `PDFLayoutIndex.nbpdflayout`, `PDFMetadataIndex.plist`
  and `PDFImageIndex.plist`; an `.ntb` may have `ios/PDFIndex.fb`. Their
  layouts are unknown (structure only was surveyed), so they are read by
  rules that cannot attach text to the wrong page: `PDFTextIndex.txt` split
  at form feeds when that gives exactly the PDF's page count; else at an
  array of page-count (start) or page-count + 1 (boundary) ascending integers
  found in `PDFMetadataIndex.plist`, as UTF-16 then UTF-8 offsets;
  `PDFIndex.fb` read with `ios/HandwritingIndex.fb`'s layout (root field 2 →
  field 0 page tables: field 0's third word the 0-based page, field 1 the
  text). Only on a note that shows one PDF. Engine `notability-<version>`.
  The warnings describe what was found (entry names and sizes, form-feed part
  count, plist top-level keys, `PDFIndex.fb` root field sizes; never text), so
  the reference run says which rule holds.
- Otherwise **extracted from the PDF** (`Options.pdfText`, the CLI's
  `--pdf-text`: `pdftotext` when installed, else `SemperePDF.PDFText`).
- Counted: `attachments.pdfTextPages`, `pdfTextFromIndex`, `pdfTextExtracted`,
  and `dropped.pdfTextPages` for pages left without text (scans, or no
  extractor).

**Images (D2).** Notability's field names for `mediaObjects` are not known
(unknown 1 of `docs/attachments.md` §11), so `MediaObject.read` walks each
object (6 levels, 4 096 values at most; a dictionary costs its field count,
and every walk of one note, media objects, typed text styles and recording
entries together, shares a budget of 262 144 values, since an archive can
list one shared object any number of times) and takes the shallowest field of each
candidate name, case-insensitively:

| Part | Candidate fields | Value |
| --- | --- | --- |
| file | any string naming a package file (whole relative path, a path ending in it, or its file name), `Images/` and `Assets/` first | e.g. `figure.FigureBackgroundObjectKey.kImageObjectSnapshotKey.relativePath` |
| frame | `frame`, `documentFrame`, `contentFrame`, `bounds`, `rect`, … | `{{x, y}, {w, h}}` (also inside an `NSValue`), or four float64s |
| or origin + size | `documentContentOrigin`, `origin`, `position`, … and `unscaledContentSize`, `contentSize`, `size`, … times `contentScale` / `scale` (or a transform's scale) | `{x, y}`, `{w, h}` |
| rotation | `rotation`, `rotationAngle`, `angle`, … (radians unless the name says degrees), else a `transform`'s angle | number |
| crop | `cropRect`, `crop`, `contentsRect`, … | rect, in pixels, or unit coordinates when every value is within 0…1 |

The frame is in ink coordinates (the x inset is added, then everything is
scaled with the ink); the item goes into the content layer (`100`) in
Notability's order. The bytes are sniffed: JPEG and PNG are stored with
metadata stripped (`format.md` §8.2.5; the EXIF orientation becomes the
item's `orientation`, `pixelSize` is after it) unless `--keep-image-metadata`;
HEIC is stored as is (sized from its `ispe`, metadata not stripped, with a
warning); a GIF (its first frame, on a transparent canvas of the logical
screen) or a baseline TIFF (grey, palette or RGB(A), 1–16 bits, strips,
uncompressed, PackBits, LZW or Deflate, orientation applied) is decoded by the
importer itself (pure Swift, so on Linux too) and stored as a PNG; a TIFF
with tiles, planar data, CMYK or YCbCr is left out. WebP, BMP and AVIF are
left out (no decoder here; converting them needs the app's ImageIO), and so is an image over
100 megapixels (`format.md` §8.4). At most 2 GiB of PDFs and images is held for
one note while it is imported, recordings included (a package entry may be
1 GiB, and a small zip can hold many): past that an attachment is left out with
a warning. At most 1 000 media objects are read. A media object with no
file, no frame, a frame that is not a finite box of at least 1 × 1 unit or
that, rotated and scaled, would lie beyond the renderer's extent (or be over
a quarter of it tall, `format.md` §8.4), or
any class that is not an image is counted in `dropped.media`; its warning
names its class and top-level field names, and every placed image's warning
names the fields its geometry came from, so a run on the reference backup
shows which names are real.

**Typed text (D3).** `richText.attributedString` is read in either of two
shapes: Notability's dictionary (`stringKey`, and `subRangesKey` entries
walked for a range, `rangeKey` `{location, length}` or `location`/`length`
in UTF-16 units, and the candidate style fields `fontName`/`font`,
`fontSize`/`size`, a colour field (`#RRGGBBAA`, `NSRGB`, `UIRed`…), and
`underline`/`strikethrough`), or a standard archived `NSAttributedString`
(`NSString`, `NSAttributes` indexed by the `NSAttributeInfo` run lengths,
`NSFont` → `NSName`/`NSSize`, `NSColor`, `NSUnderline`, `NSStrikethrough`).
Only the samples' empty text was ever seen, so both mappings are unconfirmed;
the report names the fields the styles came from. The text becomes one
`text` item per block of lines (blocks are separated by a blank line),
stacked from the top of the page at the ink's left edge (`W / 38.4`), `W − 2 ·
W / 38.4` wide, without `breaks` (renderers break the lines). Heights are an
estimate (1.2 × size per line, wrapping at half an em per character), since
Notability's margins and line metrics are not known and Notability reflows
the ink around its text; text is never clipped, so a wrong height only moves
the next block. An estimate is capped at a quarter of the renderer's extent,
and blocks stacked below 1 000 000 units are left out (counted in
`dropped.typedTextCharacters`, with a warning). Per block, the style covering the most characters gives the
box's font (`Helvetica*`, `SF*`, `Avenir*` and anything unknown → `sans`;
`Times*`, `Georgia*`, `NewYork*`, `Palatino*`, … → `serif`; `Courier*`,
`Menlo*`, `Monaco*`, `SFMono*` → `mono`), size (16 document units where
none is stored) and colour (black); runs carry bold and italic from the font
name (`-Bold`, `-Heavy`, `-Italic`, `-Oblique`, …), underline, strikethrough
and a colour or size that differs from the box. A run in Chinese, Japanese,
Korean, Arabic or Hebrew gets `lang` (`zh`, `ja` when it holds kana, `ko`,
`ar`, `he`). Text is stored in NFC; `\r\n`, `\r`, U+2028 and U+2029 become
`\n`; other control characters and U+FFFC (Notability's inline attachment
marker) are removed. A block over the per-item limits (65 536 bytes, 1 000
runs, `format.md` §8.4) is split at line breaks; what still does not fit is
counted in `dropped.typedTextCharacters`. Sizes scale with the ink. A media
object whose class name contains `Text` becomes a `text` item in its own
frame (held to the extent like an image's), with its longest
`string`/`text`/`NSString` value, in the default style.

**Recordings (D4).** `Recordings/library.plist`'s `recordings` entries are
read for candidate fields: a string naming a file in `Recordings/`, a title
(`name`, `title`, `displayName`, …), a start date (a date in a field whose
name holds `date`, `start` or `created`) and a duration (`duration`,
`length`). Entries that name no file are paired with the unclaimed audio
files in name order when the counts agree (with a warning); audio files
without any library are imported without a title. The audio is stored as is
(`format.md` §8.3.1 allows importers other types): `audio/mp4` (read by
`AudioProbe`, as `sempere attach recording` does: duration, codec, channels and
rate; a file it cannot read keeps its bytes without them), `audio/x-caf`
(`desc`, `pakt`; a rate below 1 Hz or a duration over 10⁷ s is not believed),
`audio/wav`, `audio/aiff`, `audio/mpeg`; anything else
is dropped. Without a start date the note's creation date is used.
`eventTokens` (4 bytes per curve, `ffffffff` none) are read as **milliseconds
from the start of the recording** — a hypothesis (unknown 7 of
`docs/attachments.md` §11) applied only when it is plausible: the note has
exactly one recording with a duration, every token lies within it, and the
tokens of successive curves ascend at least 90 % of the time. Then each such
stroke gets `rec: {id, at: token / 1000}` and the report says so ("check by
listening"); otherwise no `rec` is written, the strokes are counted in
`dropped.recLinks` and the warning gives the tokens' range. Format 8–9 notes
keep their sync elsewhere (not known); they import without `rec`.

**Notability's transcripts (GA-09).** A library entry field whose name holds
`transcript` (the entry's own or one level down) is read as the recording's
transcript: a string (one segment over the whole recording), an array of
strings or of dictionaries, or a dictionary holding such an array under
`segments`, `results`, `items` or `entries`. A dictionary's text is its first
string among `text`, `string`, `substring`, `content`, `value`; its start the
first number among `start`, `startTime`, `timestamp`, `time`, `offset`,
`begin`; its end `end`/`endTime`, else start plus `duration`/`length`. Times
are seconds, or milliseconds when that reading keeps them inside the recording
(and the seconds one does not). Items are sorted by start when all have one,
made non-overlapping, empty text dropped, at most 20 000 segments of 8 192
characters and 8 MiB of text in all (an eighth of the 64 MiB a transcript blob may
hold, so the blob decodes even if JSON escapes every character). The result is a `sempere-transcript/1` blob
(`format.md` §8.3.2) named by the recording's `transcript` register, with
`engine` `notability-<bundle version>` (`notability-unknown` without one),
`created` the note's modification date, and `language` from the entry's
`locale`/`language` (else `und`). **The layout is a hypothesis**: no public
fixture holds a real Notability transcript, so a field that looks like one
but reads as nothing is reported in the warnings and nothing is written.
Counted in the report as `attachments.transcripts`. `--no-attachments` skips it
with the recordings.

**Report.** Per note `attachments` (`pdfs`, `pdfPages`, `templatePages`,
`images`, `textItems`, `textCharacters`, `recordings`, `recLinkedStrokes`,
`blobs`, `blobBytes`, `pdfTextPages`, `pdfTextFromIndex`, `pdfTextExtracted`,
and for bundles `bundlePDFRecords`, `bundleMediaRecords`, `bundleFiles`,
`bundleFilesImported`), `dropped` (adding `bundleRecordsWithoutFile`,
`bundleFilesUnreferenced`, `pdfTextPages`), `lang`, `markersBehindText`,
`paperColor` and `warnings`; the CLI's `--json` summary adds the totals and,
to compare with a backup survey, `languages` (tag → notes),
`markersBehindText` and `paperColors` (notes), `ntbPDFPages`, `ntbImages`,
`ntbDroppedPDFs`, `pdfTextPages`, `pdfTextFromIndex`, `pdfTextExtracted` and
`pdfPagesWithoutText`. On the reference backup the driver should see
`languages` `{en-US: 876, es-ES: 52}` minus notes not imported, every note
`markersBehindText`, `paperColors` 1, and `ntbDroppedPDFs` 0.

## Package layout

A `.note` is a zip holding one directory named after the note:

| Path | Content |
| --- | --- |
| `<name>/Session.plist` | the note (NSKeyedArchiver, `$top` key `$0`) |
| `<name>/metadata.plist` | title, subject, tags, dates, uuid (NSKeyedArchiver, `$top` key `root`) |
| `<name>/HandwritingIndex/index.plist` | Notability's handwriting recognition (plain binary plist); absent on notes without ink |
| `<name>/Recordings/library.plist` | audio recordings (`recordings` dictionary) |
| `<name>/thumb.png`, `thumb2x` … `thumb12x.png` | first-page thumbnails, 48 px wide × scale. Some are stale (blank paper). |
| `<name>/PDFs/*.pdf`, `NBPDFIndex/` | imported PDFs the ink sits on |
| `<name>/Images/`, `Assets/` | media |

File names inside the zip contain `:` (the note's creation time).

## metadata.plist

`noteName`, `noteSubject` (`unsortedNotesKey` means none), `noteTags`
(string; empty in every sample, treated as comma or newline separated),
`noteCreationDateKey`, `noteModifiedDateKey` (NSDate: seconds since
2001-01-01), `uuidKey` (uppercase UUID string, Notability's stable id),
`notePackagePath`, plus `noteLastChangeDatePerTypeKey`,
`galleryPublishHistoryKey`, `noteHasRecordingKey`, `associatedProductsKey`.
`Session.plist` repeats `name` (as NSData holding UTF-8), `subject`, `tags`
and `creationDate`; they are the fallback.

## Session.plist

Root class `NoteTakingSession`:

- `sessionFormatVersion` (5–9), `NBNoteTakingSessionBundleVersionNumberKey`
  (app version, e.g. `14.2.6`).
- `NBNoteTakingSessionDocumentPaperLayoutModelKey` →
  `documentPaperAttributes` (absent before format 6): `paperIdentifier`
  (`Legacy:13`, or `TemplatePDF:<uuid>:#FFFFFF` for a PDF template),
  `paperSize` (`letter`, or `custom:<width/height>`), `paperOrientation`,
  `paperSizingBehavior` (`lockedWidth:<w>:<device>`, `deviceBasedWidth`,
  `staticWidth`), `lineStyle` (integer, older) and/or `lineStyle2` (string).
- `paperLineStyle`, `paperIndex`: the older integer paper fields at the root.
- `richText` (`FormattedString`): `attributedString` (typed text,
  `stringKey`), `Handwriting Overlay` → `SpatialHash` (the ink, below),
  `reflowState` (`NBReflowStateLocked` with `pageWidthInDocumentCoordsKey`,
  or `NBReflowStateReflowable`), `pdfFiles` (`PDFFile` objects: `pdfFileName`
  under `PDFs/`, `highlights`, always empty in the samples), `pageLayoutArray`
  (one dictionary per page of a note made from a PDF:
  `kPageLayoutDocumentPageNumberKey`, `kPageLayoutPDFFileNameKey`,
  `kPageLayoutPDFFileKey`, `kPageLayoutPDFPageNumberKey`,
  `kPageLayoutPDFIsOriginalPageKey`, `kPageLayoutPageIsBookmarkedKey`; empty
  on paper notes), and `mediaObjects` (`ImageMediaObject`, …).
- `NBNoteTakingSessionIsHighlighterBehindTextKey` (true in every note of the
  reference backup): Notability draws highlighter strokes beneath typed text.
  Imported as `meta.markersBehindText` (`format.md` §5.4, §8.2.3).
- `NBNoteTakingSessionHandwritingLanguageKey`: the handwriting language,
  `en_US` (876 notes) or `es_ES` (52). Imported as `meta.lang` in BCP 47 form
  (`en-US`, `es-ES`; a value that is not a language tag is left out);
  recognition (`sempere recognize`, the app) reads the note in it.
- `Notability.NBPaperStyle.paperColor` (1 note): the paper's colour. Read from
  a `paperColor` field (of a `Notability.NBPaperStyle` object, or a key named
  `….paperColor`) under the paper layout model or a root field whose name
  holds `paper`, as any archived colour (`#RRGGBB[AA]`, `UIRed`…, `NSRGB`);
  imported as the paper's `background` (opaque). The exact archive shape was
  not seen; the report's `paperColor` says what was read.

### Ink: `InkedSpatialHash`

All arrays are little-endian and concatenated over curves in drawing order.

| Key | Encoding | Meaning |
| --- | --- | --- |
| `numcurves` | int | curve count *n* |
| `numpoints` | int | total stored points |
| `numfractionalwidths` | int | total on-curve points (see below) |
| `curvesnumpoints` | int32 × *n* | points per curve, always `3k + 1` (a curve that is not is read as a polyline with one value per point; never seen) |
| `curvespoints` | float32 (x, y) × numpoints | **piecewise cubic Bézier control polygons**: on-curve, control, control, on-curve, … |
| `curveswidth` | float32 × *n* | base width, document units |
| `curvesfractionalwidths` | float32 × numfractionalwidths | width multiplier per **on-curve** point (`k + 1` per curve) |
| `curvesforces` | float32, per on-curve point | force (format ≥ 8; always 1.0 in the samples) |
| `curvesaltitudeangles` | float32, per on-curve point | radians (always π/2 in the samples) |
| `curvesazimuthunitvector` | float32 (x, y), per on-curve point | unit vector (always (1, 0) in the samples) |
| `curvescolors` | 4 bytes × *n* | **RGBA** (`000000ff` black, `006fffff` blue, `ed3624ff` red, highlighter `ffff006b`) |
| `curvesstyles` | uint8 × *n* | **3 pen, 4 highlighter**; nothing else seen |
| `curveUUIDs` | 16 bytes × *n* | per-curve UUID (format ≥ 8) |
| `options` | 8 bytes × *n* | all zero in the samples; unknown |
| `eventTokens` | 4 bytes × *n* | playback sync with recordings (older formats); `ffffffff` when none |
| `dashStyles` | nested binary plist | `{objectPatterns: {"<curve index>": {pattern: 1}}}`: dashed curves |
| `groupsArrays`, `bezierPathsDataDictionary` | | always empty in the samples |

The count relation `numfractionalwidths = Σ (numpoints_i − 1) / 3 + 1` holds
for every curve of every sample, which is what identifies the points as
Bézier control polygons rather than samples. Segments are short (median
chord 1.2 units, 90th percentile 3.9).

Highlighter alpha is stored in the colour (`0x6B` ≈ 0.42); pens are opaque.
Rendered stroke diameter is `curveswidth × fractional width`: rendering
that way matches the total ink darkness of Notability's thumbnails within
2 %. Typical pen widths are 0.933, 1.4 and 1.867 units; highlighters 6 and 28.

### Coordinates and pages

Document units: the page is `W` units wide, where `W` comes from
`lockedWidth:<W>:…`, else `reflowState.pageWidthInDocumentCoordsKey`
(716.8 for iPad notes, 572 for Mac notes, 583.8 / 610 seen). Ink x is offset:
**x = 0 lies `W / 38.4` units in from the left page edge** (18.667 on a
716.8 page). It was first measured as 18.8 ± 1 against thumbnails; the
`.ntb` copies, whose points are page coordinates, give exactly `W / 38.4` in
every pair, and the comparison with Notability's PDF export moved by the
0.11 pt difference (mean left-edge delta 0.107 pt before, 0 after). y is not
offset. The importer adds `W / 38.4` to every x.

Notability pages stack vertically without gaps. One page is `W × aspect`
high, where the aspect is `1 / r` for `paperSize = custom:<r>`, else the
height/width of the widest thumbnail (`thumb12x.png` is 576 px wide, so its
aspect is more precise than `thumb.png`'s 48), else 21/16. A thumbnail's
height is rounded **down** to whole pixels (letter at 576 px: 745.4 → 744),
so a thumbnail aspect within two pixels of a standard one (21/16, letter and
A4 either way up, 4:3, 3:4, 16:9, 9:16, 1) is snapped to it. Without that,
the stride of letter PDF pages came out 739 instead of 741 on 572-wide notes
and 926 instead of 928 on 716.8-wide ones: ink drifted 2 units per page
against Notability's PDF export (F1 0.75 on page 2 down to 0 by page 8 on
the worst note; 10 notes affected). Thumbnails are
hints: one that cannot be read is skipped, and an aspect outside 1/16…16 (from
a thumbnail or `custom:`) is ignored, as is a document width outside
16…100 000, so a corrupt note cannot produce a page height of 0, of 10¹² or
of infinity. Every "letter" note has 48 × 63
thumbnails (21/16 = 1.3125, not letter's 1.294), and fitting the handwriting
index origins to stroke positions gives a page height of 940.8 = 716.8 ×
21/16 independently.

**PDF pages.** In a note made from a PDF every page is a PDF page
(`pageLayoutArray`, in PDF page order; no blank pages inserted in any sample),
laid out at the document width, and the thumbnails show the PDF's aspect. The
ink of such a note is in the same `InkedSpatialHash`, in the same continuous
coordinates. Its pages repeat every `⌈W × aspect⌉` units, not `W × aspect`:
fitting the handwriting index origins to the ink (26 recognised pages of
PDF notes, up to page 64) gives 538.02 for 716.8 × 0.75 = 537.6 and 429.01 for
572 × 0.75 = 429. Without the rounding, page 39 is 16 units off. Rounding to
the nearest unit fits the same data; 16:9 slides (403.2 → 404) have no
recognised pages in the samples, so that case is unverified. All PDF pages
of one note had the same size in the samples; a PDF with mixed page sizes
would need the PDF's page boxes, which the importer does not read. A PDF note
without a usable thumbnail falls back to 21/16 like paper, rounded up too
(941 on a 716.8 note): a guess either way.

### Paper

| `lineStyle2` | Pattern | Pitch |
| --- | --- | --- |
| `No Lines` | blank | |
| `Dots:<s>` (two fields, older) | dot | `s × 37.6 × W / 716.8` (0.5 → 18.8; measured) |
| `Lines:<s>` | ruled | same rule |
| `Dots:<a>:<b>:<s>` (four fields, newer) | dot | `s` inches on the physical paper: `s × W / 8.5` for letter (0.25 → 21.08, 0.1968505 = 5 mm → 16.6; measured) |
| `Grid:…` | grid | same rules (not seen) |
| anything else | blank | |

Without `lineStyle2`, the integer `lineStyle` / `paperLineStyle` is used:
0 blank, 1 ruled, 9 dot (pitch as `…:0.5`), matching how they co-occur
with `lineStyle2`. The two boolean fields of the newer form are unknown.
A note's `paperColor` (one note in the reference backup) becomes the paper's
`background`; otherwise the defaults are used.

The imported `paper` (format.md §5.4.2) takes `kind` and `spacing` from this
table and every other parameter from the kind's defaults (white page, default
line colour and width, dot radius 0.9 pt). The reverse-engineered data has no
line colour, line width, margin or page colour, and no Cornell, staff or
isometric styles (`lineStyle2` values for them are not known and import as
blank paper), so nothing richer is mapped; the importer's output is unchanged
by the parametric paper. A note imported before can be restyled in the app
(paper picker, "Apply to all pages").

## HandwritingIndex/index.plist

`version` and `minCompatibleVersion` (7), and `pages`: a dictionary keyed by
1-based page number (as a string) with:

- `text`: recognised handwriting, lines separated by `\n`.
- `characterRects`: per UTF-16 unit of `text`, four little-endian
  **IEEE half floats** (x, y, w, h) — 8 bytes per character, relative to
  `pageContentOrigin`. Whitespace has `(inf, inf, 0, 0)`.
- `pageContentOrigin`: `[x, y]` within the page, in ink coordinates (it is
  the top-left of the page's ink, less about 0.7).
- `returnIndexes` (line breaks), `sha256Hash` (of the page content).

Only pages with recognised ink are listed. The importer merges them into
the single page's `recognition`: texts joined with `\n` in page order,
words grouped between whitespace with the union of their character boxes,
moved by `pageContentOrigin`, the 18.8-unit inset and `(n − 1) × page
height`. `engine` is `notability-<app version>`.

## ios/HandwritingIndex.fb (.ntb)

Newer bundles keep Notability's recognition in `ios/HandwritingIndex.fb`, a
FlatBuffers buffer read without a schema. Its fields mirror
`HandwritingIndex/index.plist`. It exists only where Notability has indexed the
note (2 of 603 `.ntb` files in the reference backup).

- Root: field 0 and field 1 are bytes (4 and 5, versions); field 3 is 8 bytes;
  field 2 is a table whose field 0 lists the page tables. Its field 1 lists them again.
- Page table:
  - field 0: three 32-bit words, the third being the **0-based page index**
    (the same convention as stroke records);
  - field 1: the text, lines separated by `\n`;
  - field 2: one 8-byte struct per UTF-16 unit of the text, four IEEE half
    floats `(x, y, w, h)`, with whitespace stored as infinities (the `.note`
    `characterRects` encoding);
  - field 3: a 32-byte hash (presumably `sha256Hash`).
- Boxes are **page coordinates**, as the bundle's strokes are. The importer
  gives each page the origin `(−inset, 0)`, so the usual merge
  (`(n − 1) × page height`, plus the inset) places the words exactly where the
  strokes go. On the reference notes every word box contains ink.
- Recognition is auxiliary: a missing or malformed index imports the note
  without text, never without its ink.

## Mapping

| Notability | Sempere |
| --- | --- |
| `noteName` | `title` |
| folders under `Notability/`, else subject | `notebook` |
| `noteTags` | `tags` |
| `noteCreationDateKey` | `created` (via the delta's `wall`) |
| document width, content extent | one infinite page: `pageSize.width = W`, `height` = lowest ink (at least one Notability page), `breakHeight` = one Notability page (`W × aspect`, usually 21/16; `⌈W × aspect⌉` on PDF pages), all × `612 / W` when scaling |
| `lineStyle2` / `lineStyle` | `paper.kind`, `paper.spacing` |
| curve | one `Stroke`; id derived from the note uuid and curve index |
| style 3 / 4 | `pen` / `marker` (highlighters are written first so they sit behind the ink) |
| colour bytes | `ink.color`; for markers alpha is set to opaque, since the marker tool supplies the translucency (as PencilKit's does; SempereRender draws markers at 50 %, where Notability's stored alpha 0x6B shows highlighters at about 42 %) |
| `curveswidth` | `ink.width` |
| Bézier polygon | B-spline control points (below) |
| width × fractional width | `w`, `h` |
| force, altitude, atan2(azimuth vector) | `f`, `al`, `az` (0, π/2, 0 when absent) |
| | `o = 1`, `t = index / 120 s` (no timing is stored) |
| handwriting index | page `recognition` |
| `pageLayoutArray` PDF page | `pdfPage` item, layer 0 ("Attachments") |
| `mediaObjects` image | `image` item, layer 100 ("Attachments") |
| `attributedString` | `text` items, layer 100 ("Attachments") |
| `Recordings/` | note `recordings`; `eventTokens` → stroke `rec` ("Attachments") |
| `NBPDFIndex/PDFIndex.zip`, `ios/PDFIndex.fb` (else the PDF) | `pdfPage` `pageText` ("PDF text") |
| `NBNoteTakingSessionHandwritingLanguageKey` | `meta.lang` |
| `NBNoteTakingSessionIsHighlighterBehindTextKey` | `meta.markersBehindText` |
| `paperColor` | `paper.background` |
| `.ntb` `<sha256>.pdf` / `.jpeg` / `.png` files | `pdfPage` and `image` items (".ntb attachments") |

**Curves.** Each Bézier segment is sampled (one sample per 3 units of
control-polygon length, 1–8 per segment), attributes interpolated linearly
between its two on-curve points, and the B-spline control points solved
(one tridiagonal system per stroke) so the uniform cubic B-spline passes
through every sample, using the renderer's end rule (the curve starts and
ends exactly on the first and last control point, so no duplicated end
points are needed). The result interpolates Notability's own on-curve
points; between samples it is a C² cubic within a small fraction of a unit
of the Bézier.

## Not imported

PDF backgrounds, images, typed text and recordings are imported
("Attachments"); what remains is below.

| What | Why |
| --- | --- |
| Pages of two heights (paper pages inserted into a note made from a PDF: 4 of the notes with a Notability PDF export) | the note has one `breakHeight`, so exports break where the PDF pages do throughout; ink positions are exact, page breaks after an inserted page and recognition boxes on later pages are not |
| PDF pages whose PDF is missing, encrypted or unreadable; `.ntb` records naming no bundle file; template PDFs not found in the package; PDF highlights | counted (`dropped.pdfPages`, `pdfs`, `bundleRecordsWithoutFile`, `templatePDFs`, `pdfHighlights`) with a warning |
| Media objects that are not images, or have no file or frame; WebP, BMP and AVIF images, TIFFs the decoder does not read (tiles, planar, CMYK, YCbCr) and unreadable GIFs | counted in `dropped.media` with a warning naming the class and fields (GIF and readable TIFF are converted to PNG) |
| Typed text beyond the per-item limits | counted in `dropped.typedTextCharacters` |
| Recordings without an audio file, or in an unknown container; `eventTokens` that do not read as times in the one recording | counted (`dropped.recordings`, `dropped.recLinks`) with a warning |
| Dashed strokes | no dash attribute; imported solid and counted |
| Highlighter behind the text of a PDF page | `markersBehindText` puts markers below text boxes and images, not below a PDF background (layer 0): over a PDF a highlighter still covers the page's text (drawn at 50 %, so it stays legible) |
| Page structure | the note becomes one infinite page; its `breakHeight` makes exports break where Notability's pages did |
| `options`, `groupsArrays`, `bezierPathsDataDictionary` | empty or unknown |

**Notes that import with no strokes.** 17 of the 127 imported sample notes
have none, and none of them has any ink to import: their `InkedSpatialHash`
is empty (`numcurves` 0, empty arrays), they have no
`HandwritingIndex/index.plist`, their `PDFFile.highlights` are empty, and
their PDFs carry no ink annotations. 15 are PDFs that were never written on
and 2 are blank paper notes. The 15 now import with their PDF pages as
backgrounds ("Attachments"). `testNotesWithoutCurvesAreInkless`
checks this on a backup.

`deviceBasedWidth` notes without a recorded width (two empty samples) use
716.8, widened to fit any ink beyond it.
