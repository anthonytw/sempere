# Sempere — agent guide

Open-source, end-to-end-encrypted handwriting notes for iPad and Mac.
Read `DESIGN.md` (why) and `docs/format.md` (normative on-disk format)
before touching `Sources/`. `docs/plan.md` is the task board.

## Build and test

```bash
swift build                 # macOS or Linux
swift test                  # all targets
swift test --filter AgeTests
scripts/test-linux.sh       # on a Mac with Docker, or in a cloud VM: run tests in swift:6.4-noble
scripts/app.sh test         # iPad app: xcodebuild test on the newest iPadOS 27+ simulator
scripts/app.sh catalyst     # iPad app: unsigned Mac Catalyst build
SEMPERE_FUZZ_LONG=1 swift test --filter Fuzz   # deep fuzz run (quick mode runs in every swift test)
(cd web && npm ci && npm run lint && npm run typecheck && npm test)   # web viewer
```

The app lives in `Apps/Sempere/Sempere.xcodeproj` (open it in Xcode; scheme
`SempereApp`). It depends on this package as a local package (`../..`).

Toolchain floor is Swift 6.0 (`swift-tools-version: 6.0`, language mode 6).
Do not use features newer than Swift 6.0 in `Sources/`.

## Hard rules

- `Sources/*` and `Tests/*` must build on Linux: Foundation (plus FoundationNetworking in `SempereWebDAV` only), swift-crypto
  (`import Crypto`), `CZlib` and swift-argument-parser only. No UIKit,
  AppKit, PencilKit, CoreGraphics, Compression, CommonCrypto, Security.
  Apple-only code goes under `Apps/`. Apple-only *tests* (e.g. comparing
  against PencilKit) are allowed behind `#if canImport(PencilKit)`.
- Files under a vault's `notes/` (revisions and each note's `att/` blobs) are
  write-once. Never add code that modifies them in place except the
  recipient-change rewrap (and blob rename) in `format.md` §3.3 and §8.1.5.
- Crypto: use swift-crypto primitives; never hand-roll a cipher or MAC.
  scrypt and PBKDF2 are the only primitives implemented locally
  (swift-crypto lacks them); they must have RFC test vectors.
- No network code in `Sources/` except the `SempereWebDAV` target (`URLSession`, via
  `FoundationNetworking` on Linux). `scripts/check-portability.sh` enforces it.
- Keep the stock-CLI recovery path working:
  `age -d -i key FILE.age | tail -c +38 | gunzip | jq .` (with `age` 1.3+ for
  post-quantum keys), and for blobs
  `age -d -i key notes/ID/att/NAME.KIND.age | tail -c +46 | head -c LEN`
  (`format.md` §8.1.7).

## Optional importers

The Notability importer is a removable module (`Sources/SempereNotability`, `docs/import-notability.md`
"Structure"): the CLI and the app reach it only through `VaultImporter`, `ImportRegistry.swift` and
`AppImporters.swift` (each gated by `#if canImport(SempereNotability)`). Never name a `Notability…` type
outside the module and those two files (`scripts/check-importer-isolation.sh`); put anything importers share into
`SempereImport`. A new import option is an `ImporterOptionSpec`, not a new flag in the CLI or a new toggle in the app.
`scripts/check-removable-importers.sh` (Linux CI) deletes the module in a copy and builds and tests the rest.

## Style

Swift 6 strict concurrency. `Sendable` value types for the model. No
force-unwraps outside tests. Errors are typed enums per module. Tests use
XCTest (Linux-compatible). Keep public API documented with `///`.

## CLI first

Maintainer rule (2026-10-06): **the CLI is the first place to get features;
everything should be automatable (aside from the UI).** Every feature that
reads or changes vault data ships with a `sempere` command (with `--json`
output and CLI tests in `Tests/CLITests`) in the same PR as, or before, the
app UI for it, and `docs/cli.md` plus the CLI table in `docs/ROADMAP.md`
are updated. The logic lives once in `Sources/` (e.g. `NoteOps`,
`Vault.apply`) and both the app and the CLI call it; never fork it into the
app. CLI edits write one delta per note through `Vault.apply` with the
machine's `DeviceState`, and name notes by id, id prefix or exact title
(`Vault.resolveNote`). Apple-only features (Vision, PencilKit) get the CLI
command behind `#if canImport(...)`, with a clear error elsewhere.
Handwriting recognition is shared that way: `RecognitionPolicy.pagesToRead`
(Sempere), `RecognitionImage` and `VisionText` (SempereRender, the latter
behind `#if canImport(Vision)`) serve both the app and `sempere recognize`;
only the drawing differs (PencilKit in the app, the pure-Swift rasterizer in
the CLI).

## Workflow

Branch per task, PR to `main`, squash merge, CI green. Commit messages:
`area: imperative summary`. Co-author line as the harness instructs.

## Gotchas

- Untrusted input (`docs/format.md` §9): every byte from a vault folder, a
  sync server or an import may be hostile, and readers must fail with a typed
  error, never trap, hang or allocate without bound. Foundation's parsers are
  not safe on such bytes on Linux: `PropertyListSerialization` segfaults on a
  binary plist with a set, `ISO8601DateFormatter` dies in ICU on a long
  fraction, `XMLParser` crashes on non-UTF-8 names or data-less processing
  instructions. Use `BinaryPlist` (SempereImport), `RFC3339` / `InkJSON` and the
  `PropfindParser` pre-checks; read files with `BoundedRead`, never
  `Data(contentsOf:)`. Range-check decoded integers before arithmetic
  (`seq + 1`, count × size, `Int(someDouble)`), and bound work by input size,
  not by the extents or counts the input claims.
- Fuzzing: `Tests/FuzzSupport` is a seeded mutation fuzzer used by a
  `*FuzzTests` class in each test target (quick mode, at most 3 s per target, in
  every `swift test`). `SEMPERE_FUZZ_DUMP=dir` keeps the input being run as
  `dir/<target>.last` (a trap kills the process, so that file is the culprit);
  `SEMPERE_FUZZ_REPRO=dir/<target>.last` replays just it. A new parser of
  untrusted bytes gets a fuzz target; each fixed crash gets a regression test
  in that target's `Untrusted*Tests`.

- macOS file systems are case-insensitive: never create two paths that differ
  only by case (`Sources/sempere` vs `Sources/Sempere` collide). The CLI
  target is `SempereCLI` for exactly this reason; its product is `sempere`.
- `swift test` prints Swift Testing's "0 tests" summary after XCTest's; the
  XCTest `Executed N tests` line is the one that matters.
- CLI tests run the built binary as a subprocess (see `Tests/CLITests`);
  do not add the executable target as a test dependency.
- On Linux, `XMLParser` (and `XMLDocument`) live in `FoundationXML`, and
  `URLSession` in `FoundationNetworking`. Guard the import with
  `#if canImport(FoundationXML)`; macOS has them in Foundation.
- `swift build --static-swift-stdlib` on Linux (Swift 6.4) fails to link with
  undefined ICU / `_FoundationCollections` / Synchronization / CoreFoundation
  symbols: the default build system omits Foundation's static dependencies.
  Pass them explicitly, as CI does: `-Xlinker -lCoreFoundation -Xlinker
  -l_FoundationICU -Xlinker -l_FoundationCollections -Xlinker
  -l_FoundationCShims -Xlinker -lswiftSynchronization -Xlinker -l_CFXMLInterface
  -Xlinker -l_CFURLSessionInterface -Xlinker -lcurl -Xlinker -lxml2` (the last four for FoundationXML and
  FoundationNetworking, used by `SempereWebDAV`; libcurl and libxml2 stay dynamic). Do not put these in
  `linkerSettings` (they break dynamic builds and `swift test`).
- `Sources/` must also compile for iOS and Mac Catalyst (the app links it), not
  just macOS and Linux. Some Foundation API is macOS-only:
  `FileManager.homeDirectoryForCurrentUser` is unavailable there (use
  `NSHomeDirectory()`). `scripts/app.sh catalyst` catches these.
- The app target is `SempereApp` with `PRODUCT_NAME = Sempere` and
  `PRODUCT_MODULE_NAME = SempereApp`: a module named `Sempere` would collide
  with the package's `Sempere` library. Tests use `@testable import SempereApp`.
- `project.pbxproj` is hand-maintained and uses folder-synchronized groups
  (Xcode 16+): add or remove `.swift` files under `Apps/Sempere/SempereApp/` or
  `SempereAppTests/` without touching the project file. Only new targets,
  package products, build settings or resources need a pbxproj edit; keep object
  ids as 24 hex digits and check with `plutil -lint`. Two branches that each take the next
  free id merge cleanly into a broken project: `release-check.sh` fails on a duplicate id.
- App tests read the package's fixture vault through a folder reference to
  `Tests/SempereTests/Fixtures` (copied into the test bundle as `Fixtures/`);
  copy the vault to a temp dir before anything could write to it.
- A fresh Xcode install may fail every `xcodebuild` with "A required plugin
  failed to load": run `xcodebuild -runFirstLaunch`. It also ships without an
  iOS simulator runtime: `xcodebuild -downloadPlatform iOS` (about 8 GB).
- App writes go through `NoteWriter` (`DeviceClock.swift`): canvas autosave and
  browser edits (`NoteWriter.append`) alike, one delta each, with the one
  `DeviceClock` the `AppModel` owns (device id and clock in Application Support).
  Never write vault files from `Apps/` any other way, and never tick a second
  clock on the same state file (`Vault.apply` is for the CLI and tests). Async
  `AppModel` work re-checks the `generation` token (`ensureCurrent`) after
  every await before publishing. Security-scoped URLs from the picker need
  `startAccessingSecurityScopedResource()` for the whole time the vault is used;
  vault bookmarks use `options: []` (no `.withSecurityScope` on iOS/Catalyst).
- The app's non-UI logic (`AppModel*.swift`, `VaultLibrary.swift`, their tests)
  can be typechecked and run on Linux with a scratch package that symlinks the
  files and shims the Apple-only URL bookmark and scoped-resource APIs; SwiftUI
  views cannot, only the CI `app` job builds them.
- Notebook names are `/`-separated display paths (`format.md` §5.4): use
  `NotebookPath` / `NotebookNode` (`Sources/Sempere/Notebooks.swift`), never
  `==` on raw names (`" A//B "` and `A/B` are the same notebook; `A/Bc` is not
  inside `A/B`).
- iCloud Drive vaults: evicted files are `.<name>.icloud` placeholders, or,
  on iPadOS 26 (seen on 26.7.1), dataless files under their real names with
  status "not downloaded" (`FakeCloud.evictDataless` in tests). A plain
  listing skips the stand-ins, so the vault or a note looks empty; a note
  folder iCloud has not listed yet is empty too and must be treated as
  pending, never as an empty note (`FakeCloud.unlist`). The app downloads them first and coordinates
  reads/writes (`CloudVault.swift`, `docs/io.md` "iCloud Drive"); this is
  app-only code, `Sources/` stays plain `FileManager`. The simulator has no
  iCloud: only the pure logic (`CloudScan.swift`) is tested there; the
  Linux scratch package needs shims for `isUbiquitousItem`,
  `startDownloadingUbiquitousItem`, `ubiquitousItemDownloading*` resource
  values and `NSFileCoordinator` as well.
- The app's deployment target is iPadOS/iOS 27 and Mac Catalyst 27 (the
  user's iPad runs 27): iOS 27 APIs are used directly in `Apps/`, with no
  `#available` gate and no iOS 26 path. The package keeps its own minimum
  (`Package.swift`: macOS 14 / iOS 17) so the CLI builds on older macOS and
  Linux; code in `Sources/` still gates newer Apple APIs with `#available`.
- PencilKit stores control points in reduced precision (Float32 locations,
  quantized opacity/azimuth/altitude): compare converted strokes within a
  tolerance, never with `==`. Stroke identity across canvas edits comes from
  `StrokeLedger`'s fingerprints, which are always taken from the `PKStroke`.
- `PKStrokePoint.size` is not the drawn width: a pen or monoline of size `s`
  is drawn `2s − 4` wide (invisible below 2), markers and textured inks
  differ again. Point sizes go through `NibSize` (StrokeConversion.swift);
  never pass a format `w` to PencilKit directly. `ImportedStrokeRenderingTests`
  pins the relation, so an iPadOS change to it fails there first.
  That relation was measured on the simulator and Mac Catalyst only. Strokes
  drawn on the user's iPad (iPad Pro 12.9" 4th gen) record pen sizes of about
  3.2 to 4.9 for tool widths 0.88 to 25.7, and monoline size 3.25 whatever
  the width, with the width carried inside the (opaque) `PKInk`; on hardware
  the drawn width may depend on that ink, which the simulator ignores. Check
  ink-width changes on a device, not only in tests.
- `PKToolPicker.init` restores PencilKit's own saved tools
  (`PKPaletteNamedDefaults` in the app's defaults) over the items it is
  given, and its saved eraser is the pixel eraser. `EraserPreference` drops
  that saved eraser entry before building a picker, so the object eraser is
  the default and the user's last choice (stored under `Sempere.eraserType`)
  wins. On iPadOS 26 the picker's pixel eraser is `.fixedWidthBitmap`: a
  `.bitmap` eraser item comes back as that; macOS 27 Catalyst does not keep a
  `.fixedWidthBitmap` item. So the preference is two modes (object, pixel:
  `EraserPreference.canonical`) and the picker gets the pixel type the
  platform keeps (`pixelPickerType`, probed); never compare eraser types
  with `==` across platforms, use `isPixel`.
- Debug builds open a vault and note from launch environment variables, for
  scripted simulator or Catalyst runs (`DebugLaunch.swift`):
  `SEMPERE_DEBUG_VAULT`, `SEMPERE_DEBUG_IDENTITY`, `SEMPERE_DEBUG_NOTE`
  (id prefix), `SEMPERE_DEBUG_SCROLL_Y`, `SEMPERE_DEBUG_ZOOM`,
  `SEMPERE_DEBUG_SNAPSHOT` (PNG of the canvas); paths may start with `~/` (the
  app's data container: on a real device, copy a vault in with `xcrun devicectl
  device copy to --domain-type appDataContainer`). With `xcrun simctl launch`
  prefix each with `SIMCTL_CHILD_`. Point it at a copy of a vault: the editor
  autosaves.
- App Store release (`docs/release/`): `scripts/release-check.sh` (Linux, CI job `release`,
  its tests `scripts/test-release-check.sh`) fails on differing MARKETING_VERSION /
  CURRENT_PROJECT_VERSION between targets, any DEVELOPMENT_TEAM, an entitlement outside its
  allow-list, a Mac bundle id of its own, or a required-reason API (UserDefaults, file timestamps,
  disk space, boot time, keyboards) used in a shipping target's sources (including the `Sources/`
  targets it links) but not declared in its `PrivacyInfo.xcprivacy` (app: `SempereApp/`, widget:
  `SempereWidgets/`). A new entitlement, package product or API category means updating the
  script's tables, the manifest and `docs/release/app-store.md` in the same PR.
  It also fails on networking (`URLSession`, Network.framework, sockets, WebKit, …) in any
  non-test folder of `Apps/Sempere` or a linked `Sources/` target outside `NETWORK_ALLOWED` (the
  WebDAV client: `WebDAVRemote.swift`, `SempereWebDAV`'s transport and client; and the dormant
  math-model downloader, `MathModels.swift`) and on a non-empty `MathModelCatalog.entries`: the
  privacy policy names the only connections (a WebDAV server the user sets up; DESIGN.md "Network"). The CLI release refuses a CHANGELOG section with `TODO(user)` or no date
  (`scripts/changelog-section.sh`); never fill in the release date yourself.
  `ITSAppUsesNonExemptEncryption` stays `NO` while France is excluded
  (`docs/release/export-compliance.md`). The privacy policy has two copies
  (`docs/privacy/index.html` for Pages, `docs/appstore/privacy-policy.md`): edit both, same date.
- App Store screenshots (`scripts/screenshots.sh`, `docs/appstore/screenshots.md`):
  `SEMPERE_DEMO=1` builds a synthetic vault in code (`DemoVault`,
  `DemoHandwriting`, DEBUG only, Linux-typecheckable like the other non-UI
  logic) and opens it; `SEMPERE_DEMO_*` pick note, sidebar, locked state and
  the paper picker. The `SempereScreenshots` scheme runs `SempereAppUITests`
  (not part of `SempereApp`'s test action, so `scripts/app.sh test` never
  builds it); CI runs it only by dispatch (`-f screenshots=true`). Never put
  real notes in a demo.
- `PKCanvasView` inverts ink colours in dark mode; the canvas forces
  `.light` because ink colours are stored as drawn on (light) paper.
- Vaults are one item in Files: `SempereInfo.plist` (referenced by `INFOPLIST_FILE`,
  outside the synchronized group so it is not copied as a resource) exports the
  `.sempere` package UTType. `VaultLocator.resolve` maps whatever was picked
  to the vault folder (never upward: a pick inside a vault is an error, its scope
  does not cover the vault); `openVault(at:accessing:)` holds the security scope of the
  picked URL, not the derived one.
- iCloud notes load progressively (`ProgressiveLoad`, `AppModel+Cloud`): never
  await the whole vault before listing. Tests fake placeholders with
  `FakeCloud` (`ProgressiveLoadTests.swift`) and `CloudVault.Hooks`; the model
  takes `cloudHooks`, `cloudPollInterval`, `cloudWindow`. Anything that opens or
  edits one note calls `downloadNote` first (a fresh listing of its folder, not
  `pendingNoteIDs`): never write a delta while any of its revisions is missing.
  The editor's read re-checks with `CloudVault.requireLocal`, and a note that
  cannot be opened shows `editorFailure` in the detail pane, never a blank
  canvas. The sync loop never ends while a vault is open (idle pace after it
  settles) and starts when the vault opens, before unlocking; stalls go to
  `cloudSync.problem` (the list's bar), not an alert. Set
  `cloudIdleInterval` short in tests that wait for a recovery.
- Note listings (`AppModel+Loading`): `unlock` only checks the key and starts
  `startLoadingNotes`, a task the model owns (UI callers pass `awaitNotes:
  false`; a view's `.task` must never own a listing, SwiftUI cancels it when
  the view goes). Summaries come in batches (`loadBatchSize`) through
  `Vault.summaries(of:cache:)`, never one `summary(of:)` per note; listings
  are serialised by `loadGate`. The per-device `SummaryCache` (format.md §10)
  is keyed by revision file names, so bump `SummaryCache.schemaVersion` when
  `NoteSummary` gains or changes a field. `RevisionDetail.withoutStrokePoints`
  revisions are for listings and search only: never write, snapshot, render
  or diff them. Tests get no cache unless they pass `summaryCacheDirectory`.
- The list is change-driven (`AppModel+Reconcile`, docs/io.md "Opening a vault
  fast"): passes list note folders by NAME (`VaultEnumeration`) and read only
  notes whose names differ from `indexedNames` (`IndexDiff`); never ask iCloud
  for every file's state in a foreground pass (`ProgressiveLoad.pass(notes:)`
  for the changed ones; the full scan is `validateVault`, background only).
  An evicted note with unchanged names is NOT pending and is not downloaded
  for the list. Apply summaries through `queueListUpdate` (throttled) or
  `merge` (an edit's own re-read, immediate), never by assigning `notes`
  wholesale. Tests that need "another device wrote a revision" use
  `TS.writeAsAnotherDevice` (an eviction alone changes nothing now).
- Remote changes reach an open note in place (`AppModel+RemoteMerge`,
  `NoteEditor.mergeRevisions`, docs/io.md "Changes from other devices while a
  note is open"): a listing names a revision the editor does not know
  (`knownRevisionNames`), the note is downloaded, the editor saves, re-reads
  and applies the result synchronously. Never replace a canvas's drawing for
  a merge except through `RemoteInkView.reloadInk` in that same main-actor
  turn, after `StrokeLedger.mergeStored`: a canvas reporting a drawing the
  ledger does not know is taken as the user's edit (echo deltas). Every write
  an editor starts bumps `writeEpoch`. Tests: `RemoteMergeTests`.
- Thinning (`format.md` §5.8.4) is decided from revision metadata first
  (`RevisionMeta`, kept per entry in the `SummaryCache`; `CompactionPlanner.select` /
  `mayDelete` take hollow revisions): never add a rule to `select` that needs ops or
  states, or the metadata stage stops being exact. Imports are checkpoints (§5.8.1).
  The app thins through `thinVault(rule:)` (`ThinningRule`: the window, or everything
  except checkpoints), the CLI through `Vault.prepareCompactions`.
- Drawing cache (`DrawingCache`, format.md §10.1): keyed by note id + revision
  file names; a note opened from it is `isPreparing` (read-only) until its
  revisions are read and every shown cached drawing passed
  `DrawingPreparation.matches`. The canvas gets its drawing through
  `readyDrawing`/`prepareDrawing` (off-main, visible strokes first), not
  `drawing(for:)` (synchronous, tests). Bump `DrawingCache.schemaVersion` when
  `StrokeConversion` or the layout changes. Tests get no cache unless they pass
  `drawingCacheRoot`.
- Attachment caches outlive note opens and launches (docs/io.md "Opening a note
  fast"): `BlobCache` (plaintext verified blob files, keyed names, a file of an
  earlier launch re-hashed before use; on a Mac, which has no data protection,
  deleted at launch instead: `blobCacheAcrossLaunches`) and `RenderCache` (sealed image pictures
  and PDF page previews, memory + disk). Both are per vault secret and go when
  the vault closes (`dropAttachments`). Bump `RenderCache.schemaVersion` when
  `ItemRaster`, `PDFItemDrawing` or the preview drawing changes. Tests get a
  per-model blob folder and a memory-only render cache unless they pass
  `blobCacheRoot` / `renderCacheRoot`.
- Sidebar drops: a drag the app started is dropped from `AppModel.draggedPayload`
  (`beginDrag` / `takeDrop`), never by loading the item provider, which iPadOS 26
  releases as soon as `onDrag` returns (the model holds it anyway). `onDrag`
  reports no end, so the payload of a cancelled drag lingers: only a drop that
  carries the app's own types (`carriesAppTypes`) may use it, never a photo or
  text dragged in from another app. Rows propose `.copy`, never `.move`
  (`SidebarDrop.proposedOperation`): `onDrag` sessions from a `List` row allow
  no move, and UIKit cancels such a drop at the release (highlight, then
  `dropExited`, no `performDrop`; builds 6 and 7). A `List` handles drags it
  started itself and never asks its rows' drop delegates, so notebook rows drag
  from a `UIDragInteraction` of their own that also carries their context menu
  (`NotebookDragSource.swift`; one view, or the menu takes the long press on the
  iPad); never put `onDrag`/`draggable` or a SwiftUI `contextMenu` back on them.
  `SidebarDropUITests` drags for real (`scripts/app.sh test-ui`,
  `SEMPERE_DEBUG_DROPS` trace, `SEMPERE_DEBUG_NOTEBOOK_DRAG` styles).
- Per-vault device memory (`RecentActivity`, sealed, Application Support):
  "Recently Recognized" (7 days) and recent searches; `activityNow` is the test clock.
- Timing: wrap new slow phases in `Perf` (os_signpost in every build; debug log
  `Library/Logs/SemperePerf.log`), counts and 8-hex id prefixes only.
  `PerformanceReportTests` prints `PERF-REPORT` lines in the CI `app` log.
- Debug device runs against the user's iCloud vault: `SEMPERE_DEBUG_RECENT=1`
  opens the most recent vault through its bookmark (the picker's scope), with
  `SEMPERE_DEBUG_PROBE=1` (log how iCloud presents the files),
  `SEMPERE_DEBUG_EVICT=1|dirs|notes` (evict from this device first),
  `SEMPERE_DEBUG_WATCH=<s>` and `SEMPERE_DEBUG_OPEN_ALL=<n>` (open n notes,
  log page and stroke counts only). Read the log with `devicectl device
  process launch --console`. Never put note titles or content in logs.
- Infinite pages scroll one screen beyond both their ink and their stored
  height (`PageExtent.scrollHeight`). "Keep Screen On" (`KeepScreenOn`) disables the
  idle timer only while a note is open and the scene is active.
- Paged notes scroll through all pages in one view (`PageStackView` /
  `PageStackHost`, layout math in `PageStackLayout`, Linux-testable): one
  embedded `PageCanvasHost` per page within a screen of the visible band
  (recycled, at most `spareLimit` spares), each at the stack's scale with its
  own undo manager and the stack's shared `PKToolPicker`. The stack zooms
  natively during a pinch and bakes the scale into the page canvases when it
  ends (`bake`); never zoom an inner canvas. The current page follows the
  scroll (`NoteEditor.scrolledToPage`, no flush); `NoteEditor.pageJump` (bumped
  by `selectPage` and page adds/restores) scrolls to `pageIndex`. Ink and items
  stay in page coordinates: only page frames come from the layout. A recycled
  canvas drops its page before its drawing (`Coordinator.forget`), so clearing
  it is never an erase. Pageless notes (and history previews) keep the
  one-page `PageCanvasView`, whose finite pages end with Add Page / Next Page.
  Whatever a page canvas needs goes through `PageCanvasContent` and
  `Coordinator.apply` (both paths), never set on the one-page host alone (drops,
  item commands, highlights). Insertions fit into `visibleRect(ofPage:)` of the
  page they land on (the stack's `PageStackLayout.visiblePart`). The stack gives
  a page canvas the focus only when no canvas has it and no text box is being
  typed in (`ensureFocus`, `PageCanvasHost.focus`): the text view keeps the keyboard.
- Paged vs pageless is only `pageSize.infinite` (`format.md` §5.4.3). Page
  gestures (add, move, delete, undo, duplicate) and the layout switch are built
  by `NoteOps` (`Sources/Sempere/PageLayout.swift`), which also predicts the
  resulting pages, and are written by `NoteEditor`, one delta per gesture. A
  stroke that changes page is re-added under a new id with its `transform`'s
  `ty` shifted, never edited in place. A note keeps at least one page.
- `NavigationSplitView` ignores a programmatic column change that arrives
  while the view is first being built, so the stored choice (`ColumnLayout`,
  `@AppStorage`) is never made to depend on selection state.
- `PKToolPicker` has no minimised/docked API (see `ToolPalette.swift`): the app
  can hide it (`setVisible`) and build a picker with fewer tools; the user
  minimises or docks the system palette by dragging it to an edge or tapping its
  collapse handle. Changing the compact option swaps the picker object.
- Tags match case-insensitively (`NoteOps.tagKey`); titles are never keys.
  Tags merge per tag (`format.md` §5.4.1): write `addTag` / `removeTag` via
  `NoteOps.addTag` / `removeTag` / `setTags` (a remove lists the instances it
  observed, so it needs the note's state), never `setMeta(.tags)` (legacy,
  read only). A snapshot without `tagSet` is a legacy one: keep the committed
  fixture vault that way.
- Vaults are post-quantum only: new keys and recipients are MLKEM768-X25519
  (`age1pq1…`); public `Vault` API throws `classicRecipient` for X25519.
  Legacy vaults (any X25519 recipient, mixed included) are migrate-only:
  every note-content API calls `requireMigrated()` and throws `legacyVault`;
  only open/unlock, keys/, add (PQ)/remove/replace/resumeRewrap work. The CLI
  passes `migration: true` to `openVault` only for those commands (exit 5
  otherwise); the app shows `MigrationView` only. `Fixtures/sample.*` is
  post-quantum, `Fixtures/legacy.*` the X25519 migration input. Tests that
  need a legacy vault use the internal X25519 `Vault.create` overload or
  `Vault.createUnchecked`, and `allowingLegacyContent()` (`@testable`) to
  write notes into it. Keys are `NativeIdentity` /
  `NativeRecipient` (Sources/Age/NativeKeys.swift). X-Wing comes from swift-crypto 4 (CryptoKit on Apple 26+,
  BoringSSL on Linux); never implement ML-KEM here. `postQuantumAvailable` is
  false on Apple OSes before 26 or SDKs before Xcode 26, so gate PQ tests
  with it. PQ recipients are 1959 characters: abbreviate in UI, and PQ key
  files are `keys/age1pq-<sha256 hex>.key.age` (`IdentityFile.fileName`);
  `identityFiles()` lists only current recipients' key files (a migrated
  vault keeps its old X25519 key file, which must not be offered).
  Vault writes use `Vault.encrypt` (mixed PQ + X25519 allowed during a
  migration); plain `AgeFile.encrypt` refuses that mix, as `age` does.
  Interop tests need `age` ≥ 1.3 on PATH (the official release; Ubuntu ships
  1.1); CI sets `SEMPERE_REQUIRE_AGE_PQ` so they fail instead of skipping.
  See `docs/post-quantum.md`.
- Authenticated recipients (`format.md` §2.1, `Sources/Sempere/RecipientsAuth.swift`):
  `vault.json` carries `recipientsTag` (HMAC of vault id + keys under an HKDF
  key of the secret) and, after a rotation, `secretLink` (Ed25519 + ML-DSA-65
  signatures by keys derived from the outgoing secret, `SecretLink.swift`;
  both must verify; trust records `sempere-trust/2` hold only the public
  keys; a legacy `sempere-trust/1` HMAC record confirms only its own secret
  and is replaced at the first write; never accept a legacy link under a
  record; shared vectors `Fixtures/secret-link-vectors.json`, mirrored in
  `web/src/vault/link.ts`); `Vault.open(…, trust:)`
  classifies the list (`recipientsStatus`) against the device's trust record
  (CLI `$XDG_STATE_HOME/sempere/trust/`, app `AppModel.defaultTrustDirectory`,
  tests `MemoryRecipientsTrustStore`). `requireWritable` refuses a tampered list
  (`VaultError.untrustedRecipients`, CLI exit 6), tags an untagged vault and
  saves the record: only writers keep records, reads never write. Anything
  that encrypts to the recipients outside `requireWritable` (capture
  profiles) calls `requireTrustedRecipients`. Never copy a `vault.json` from
  elsewhere without `Vault.incomingManifestProblem`. The committed
  `Fixtures/sample.sempere` is tagged; copies share its vault id, so an
  untagged copy reads as a downgrade on a device that wrote to a tagged one.
  `format` and `features` are authenticated too (`markersTag`, §2.1 "Version
  markers", `MarkersAuth.swift`, mirrored in `web/src/vault/vault.ts`): every
  `vault.json` write goes through `Vault.writeManifest(…, secret:)`, which tags
  them; a test that edits `features` the way an older build would also drops
  `markersTag` and `markers-tag`, or it reads as tampering (`markers*` reasons).
  Capture profiles hold their device's capture key (`CaptureKey.derive(from:device:)`,
  §11.1); `Vault.captureKeyRing` is what verifies inbox files, never one key alone.
- Remembered vault keys (`VaultKeyStore.swift`, `RememberedKeys.swift`): the
  age identity text is stored only in the Keychain, never logged, never in
  `UserDefaults` or files. Device-only items are
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `SecAccessControl`
  `.biometryCurrentSet` (`.userPresence` without enrolled biometrics; a new
  Face ID enrollment invalidates the item, which reads as "no key").
  Synchronizable (iCloud Keychain) items cannot carry an access control or a
  `ThisDeviceOnly` class: reading one is gated by `LAContext.evaluatePolicy`
  in the app, and the UI says so. No entitlement is added: items use the
  app's default access group (its application identifier), which free
  personal-team builds have. Unsigned builds (CI, simulator tests) get
  `errSecMissingEntitlement`, so tests use `FakeKeyStore`, never the real
  Keychain. Face ID needs `INFOPLIST_KEY_NSFaceIDUsageDescription` (pbxproj).
  Generic-password items from apps are generally not listed in the Passwords app.
  Saving never deletes before the new key is stored: `KeychainVaultKeyStore.replace`
  adds (or updates the same-storage item) first and only then deletes the
  other storage's copy (`KeychainReplaceTests` pin the order with
  `FakeKeychainItems`). Device-only keys are Face ID only, no passcode
  fallback: after a lockout the user unlocks with the key or passphrase, and
  the remember sheet says so (`RememberedKeys.deviceOnlyFooter`).
- The object eraser is the app's (`ObjectEraser.swift`, `EraserGeometry.swift`):
  PencilKit's `.vector` eraser has no size. When the picker's eraser is in
  object mode, `PageCanvasHost` disables `drawingGestureRecognizer` and
  `ObjectEraserController` takes the touches (Pencil, plus one finger when
  fingers draw; scrolling then needs two), removes every stroke whose sampled
  outline the swept capsule touches by setting `canvas.drawing`, and registers
  one undo step per gesture on the canvas's undo manager. The ledger turns
  that into ordinary `removeStroke` ops. The pixel eraser stays PencilKit's.
  Radius presets (`ObjectEraserSize`, page points) are in `UserDefaults`
  under `Sempere.objectEraserRadius`; the size menu is in the editor toolbar.
- The Mac menu-bar item (`docs/mac.md` "Menu-bar item") is an AppKit bundle, target
  `SempereStatusItem` (`Apps/Sempere/SempereStatusItem/`, SDK macOS, Swift 5 mode), embedded in
  `PlugIns` for Catalyst only (`platformFilter = maccatalyst` on the dependency and the embed
  phase). The Catalyst app cannot link AppKit types, so `StatusItemHost` loads the bundle and the
  two only post notifications on the default center (`StatusItemProtocol`, in `StatusItemShared/`,
  compiled into both): state and localized titles go in, the chosen entry comes out. The bundle
  has no strings, no logic and no network; keep it that way. The app must work with it missing.
  A new entry is a case of `StatusItemProtocol.Action` handled in `StatusItemHost.run`.
- Mac (Catalyst) behaviour is in `docs/mac.md`. Menu entries are cases of
  `MenuCommand` (title, shortcut, enabling in one place; `MenuCommandTests`
  checks shortcut clashes); never add a menu item elsewhere. Menus act through
  the focused window's `CommandRouter`. A note has at most one `NoteEditor`:
  note windows go through `AppModel.claimNote` / `openWindowNote` /
  `releaseNote`, and anything that changes the vault under open editors (key
  changes) closes them all first and bumps `keyEpoch`. Sheets and alerts that
  commands open live in `WindowUI`, attached by `windowSheets` to a view that
  is always on screen (the note list is not when the columns are hidden).
  Gate Mac-only behaviour on `Platform.isMac` (compiles on the iPad, so the
  simulator CI checks it) rather than `#if targetEnvironment(macCatalyst)`:
  the Catalyst build runs on `main` only (or `gh workflow run CI --ref <branch>`).
  Only the `.commands` line and the entitlements/scene build settings are
  Catalyst-only.
- Every `WindowGroup` gets `appEnvironment(model:library:keys:)` and every
  non-library window's root is a `RestoredScene` (`SceneRestoration.swift`): the
  iPad build on a Mac shares the Catalyst build's container and is handed its
  saved windows. A new window scene gets both and a `SceneRestoration.Kind`.
- Views read the app-wide objects with `@AppModelEnvironment` (the model) and
  `@AppEnvironmentObject` (`VaultLibrary`, `RememberedKeys`), never
  `@Environment(X.self)`: a view updated outside its window's environment
  then falls back to the app's instance (`.current`) and logs a fault
  (category `environment`) instead of trapping (Mac launch crash, #120).
  Tests still inject their own; `AppModelEnvironment.fallbacks` counts
  fallbacks, since the test host sets `.current`.
- The Mac menu bar starts from UIKit's own (New Window ⌘N, Open… ⌘O, Find…
  ⌘F, document commands). UIKit drops a whole SwiftUI command group if one of
  its shortcuts is taken (log: "Replacement elements conflict"), so a new
  `MenuCommand` shortcut must not collide with UIKit's; ⌘O and ⌘F are UIKit's
  items renamed by `MacMenus` (`MenuCommand.nativeOnMac`). Check menus on a
  real Catalyst runtime: `scripts/app.sh test-mac` (every app suite, ad-hoc
  signed and sandboxed) and `test-mac-ui` (`MacWindowUITests`), run by CI on
  `main` and on dispatch. A test that needs pixels on a Mac puts its view in a
  window of the host app's scene (a window without one is never drawn there).
- Launch smoke tests (`LaunchSmokeUITests`; `scripts/app.sh test-mac-smoke` on
  every CI run, the iPad layouts in `test-ui`) start from fresh state
  (`SEMPERE_DEBUG_FRESH`), unlock the demo vault through the unlock sheet
  (`SEMPERE_DEMO_PASSPHRASE`) and open every column layout, window and sheet.
  A new window, sheet or column layout gets a step there; a new scene must
  inject the app environment, which `AppSceneEnvironmentTests` (Linux) checks,
  along with the wrapper rule above: no view reads the three with a plain `@Environment`.
- Expectations (`Expectations.swift`, `ExpectationsViews.swift`, `docs/security.md`): "About Your Key"
  shows by itself once per (vault, key) on a device (`OnboardingMemory`, digests only), then the
  quick tour once per device; both only in the canvas window, after the unlock sheet and never over
  the new-vault sheet (`holdsOnboarding`). Scripted debug launches skip them unless
  `SEMPERE_DEBUG_ONBOARDING` is set. Tour pages claim only what `main` does. The CLI's `--version`
  and the app's About share `SempereAbout` (Sources/Sempere/About.swift); a new dependency goes in
  its `components` and the app's `ThirdPartyNotices.txt` (`AboutTests` checks both). Wording: describe
  the design and its limits, never promise outcomes.
- Every icon-only control in the app has `.help("…")` (Mac tooltips);
  `scripts/check-help.py` fails the `app` CI job otherwise (`docs/mac.md`
  "Tooltips"). Menu-only view builders are marked `// help-lint: titled`.
- PDFs opened with the app (`onOpenURL`) are imported as new notes, never
  opened as vaults (`AppModel+OpenedFiles`, `OpenedFile.kind`). The app's
  Notability import (`AppModel+NotabilityImport`) is the one app write that
  does not go through `NoteWriter`: it runs the CLI's `NotabilityImporter`
  on the model's `DeviceClock` (`withClock`) under the edit gate, never with
  overwrite, so no open note changes under its editor.
- The object eraser must list `indirectPointer` among its touch types on a Mac
  (`ObjectEraserController.pressTouchTypes`), or the default eraser ignores
  the mouse; PencilKit's own gesture is off while it is active.
- Bulk export ("Export Notes…", `sempere export --all --format pdf|png`) is one
  shared core in SempereRender (`BulkExportPlan`, `BulkExportSession`,
  `ZipWriter`; docs/io.md "Bulk export"): one note in memory at a time, never
  load every state first. The folder's `.sempere-export-bulk.json` is
  untrusted (it may only cause a skip). App: `AppModel.runBulkExport`,
  `BulkExportRun`, `BulkExportSheet`; zips stage under `tmp/SempereBulkExports`.
- Dragging a note out writes a plaintext PDF under `$TMPDIR/SempereExport/`
  (`NotePDFExport`); keep it per model and purge it when the vault closes.
- Attachment blobs (`Sources/Sempere/Blob*.swift`, `format.md` §8.1): write with
  `Vault.writeBlob` / `copyBlob` before the delta that references them; read only
  through a reference of the same note (`readBlob`, `streamBlob`, `withBlobFile`,
  `blobSource`), which check framing, padding, hash and keyed name; content a
  streaming read handed out is unusable if it then throws. Delete blobs only via
  `collectBlobs` (rules 1–4, per note, device-local `BlobCollectorState`); recipient
  changes rewrap them by `RewrapPolicy`. References are found structurally (any
  object with `sha256`) with `JSONSerialization`, whose `NSNumber` says `is Bool`
  for 0 and 1: test `objCType == "c"` for booleans instead.
- Unused-attachments index (task E7, `docs/attachments.md` §4): per-note
  `AttachmentIndexEntry` (core `AttachmentIndex.swift`), updated by
  `AttachmentIndexer.update` for the changed note only (writes via
  `DeviceClock`'s write hook, arrivals via `readSummaries`/`refresh` →
  `summariesRead`); never add a whole-vault pass outside Settings' explicit
  "Check". Numbers come from `AttachmentStorageReport` (app and `sempere blobs
  unused` alike). Delete only through `collectBlobs(note:records:only:)` with the
  entry's `unusedSince`; iCloud notes not local decide nothing (`local: false`).
  Bump `AttachmentIndexEntry.schemaVersion` when the entry changes. App tests
  set `attachmentIndexDelay = .zero`, `attachmentNow`, and count reads with an
  `attachmentIndexSource`.
- Placed items on the canvas (task E0, `docs/attachments.md` §14): build item ops
  with the `NoteOps` item builders (`Sources/Sempere/ItemOps.swift`), apply them in
  the app through `NoteEditor+Items` (`applyItemEdit`: one delta per gesture) and
  `ItemActions` (undo; a deleted item comes back under a new id with `parent`, item
  tombstones are permanent). New attachments: `NoteEditor.addAttachment(file:|data:…)`
  (blob first, then the delta). The item layer (`ItemLayerView`, between `PaperView`
  and PencilKit's ink) draws through `ItemRaster` from the model's `BlobCache` (cleared
  whenever `AppModel.vault` changes); never read blobs for display any other way.
  Copied items live in `ItemClipboard`, never the system pasteboard. Selection mode
  turns PencilKit's drawing gesture off like the object eraser does.
- Adding images and PDFs (tasks E1, E3): bytes go through `ImagePreparation` /
  `PDFPreparation` (app) into the shared `ImageIngest` / `PDFIngest` and the
  `NoteOps` builders the CLI uses (`placeImage`, `viewFrame`, `newPDFNote`,
  `insertPDFPages`, `setCrop`); never decide stored bytes, sizes or frames in
  the app alone. The photo privacy setting (`PhotoPrivacy`, on by default)
  strips metadata and turns HEIC into JPEG. Stored PDFs never carry `/Encrypt`
  (encrypted ones are redrawn). Picked PDFs are copied to a work folder
  (`PDFPreparation.copyPicked`, plaintext: `discard` it). PDF page items are
  drawn by `PDFTileLayer` (a `CATiledLayer`, `draw(in:)` on Core Animation's
  threads, so `nonisolated` and lock-protected), not as `ItemRaster` bitmaps.
- Handwriting search (`PageRecognizer.swift`, `NoteEditor` extension, `AppModel+Search.swift`;
  pure logic in `Sources/Sempere/RecognitionSupport.swift` and `NoteSearch.swift`, tested on
  Linux). Recognition carries `basis` = `RecognitionBasis.digest` of the page's live stroke ids
  (`format.md` §5.5): current iff equal. Recognition without a basis (Notability import) is
  never replaced unless the editor itself changed that page's strokes (`touchedPages`), via
  `RecognitionPolicy.needsRecognition`. The editor saves strokes first, recognises off the main
  actor (`VisionPageRecognizer`, ink drawn black on white, markers skipped), re-checks the digest
  before writing and drops the result if strokes changed meanwhile; it writes one delta per
  pass (all pages read) through its own `NoteWriter`, and stops without writing once closed or
  switched off. A page that cannot be drawn is an error, never stored as empty text. Vault-wide reading ("Recognize N Notes Now") goes through `commit(_:building:)`
  and rewrites each page only if its digest still matches. App tests inject `FakeRecognizer`;
  `AppModel()` defaults to no recognizer so existing tests write no extra deltas. Search is
  `NoteSearch.search` over `NoteSummary.pageTexts` (filled by `Vault.summary`), run off the main
  actor with a debounce; the matching words are highlighted on the page (below).
- Notebook fields are combo boxes (`NotebookField`, `NotebookPath.suggestions`): plain views in
  the form's flow, not a popover or `Menu`, so the same code runs on iPad, iPhone and Mac. Moving
  is `NotebookPath.moved(_:into:)` (a notebook keeps its last level; never into itself or a
  descendant) feeding the prefix rename; drops (`SidebarDrop.swift`) carry ids or a path as
  `.ownProcess` item providers only, and the model holds `draggedPayload` so a row can refuse a drag
  while it hovers (`SidebarDrop.accepts`). One drop = one `commit(ids:)`, one `UndoManager` step
  (`NotebookMoveRecord`) on the undo manager of the window it happened in, passed to `move` (the
  model is shared by every Mac window, so it keeps none). The `DropDelegate`s need a real drag session: test the rules, not the UI.
- Search highlights (`NoteEditor+SearchHighlight.swift`, `SearchMatchCursor`): boxes come from the
  page's recognition; recognition whose basis no longer matches the strokes, or of a page edited in
  this session (`dirtyPages`), is left out. The layer is a plain `UIView` of `CALayer`s inside the
  canvas, above the paper and the items, below the ink; it follows `zoomChanged()`. In a paged note's stack (`PageStackHost`) each page's canvas draws its own highlights
  (`Coordinator.apply`) and the stack scrolls the match into view (`performReveal`,
  `PageStackLayout.revealOffset`): embedded canvases never scroll. "Recognize All" results
  (`recognitionResults`) live in the model until the next run or `close()`, never on disk.
  A run writes each page only if its digest still matches (`RecognitionJob.ops`).
- Favorites (`meta.favorite`): written only via `NoteOps.setFavorite` (CLI `notes favorite`, the app's
  `AppModel.setFavorite`); the sidebar's Favorites is `SidebarItem.favorites`. The quick-voice-notes notebook is
  the capture profile's alone (Settings ▸ Quick Voice Notes); `LegacyVoiceNotebook` only carries over what
  older builds stored in New Notes. The Mac's item commands (`duplicateItem`, `bringItemToFront`, `deleteItem`)
  run on the selected item through `CanvasCommandTarget.perform(itemCommand:)`, enabled from
  `NoteEditor.hasItemSelection` (each canvas reports its page); rotation is `ItemActions.rotate` (menu quarter
  turns, the controller's `UIRotationGestureRecognizer`).
- Newer format versions (`format.md` §7): a vault whose `format` is a later
  `sempere/<major>` or whose `features` are unknown, and revisions marked newer
  (their `format`/`features`), open read-only. Newer revisions decode
  leniently (`NewerDecoding`, `LenientOp`, `decodeElements`) and say what was
  skipped (`Revision.newer`, `LoadedNote.newer`, `NoteSummary.newer`); an
  unmarked revision with an unknown op still fails closed. Reading one sets
  the vault's shared `ReadOnlyLatch`, so every later write through that
  `Vault` (or a copy) throws `VaultError.readOnly`: every write path calls
  `requireWritable()` (add it to any new one). The tag label is
  `SempereFormat.tagLabel`, never `identifier`. CLI: exit 7; app:
  `AppModel.isVaultReadOnly` / `requireWritableVault()` gate model writes;
  fixture `Fixtures/newer.sempere`. Mirror changes in `web/src/format/newer.ts`.
- Note `lang` and `markersBehindText` (`format.md` §5.4) are optional meta
  registers: a snapshot without their value or clock never set them
  (`ClockKey.isOptional`), and writers omit them when unset. Recognisers pass
  `meta.lang` to Vision (`RecognitionLanguage.preferred`, `VisionText.lines(language:)`).
  `markersBehindText` draws markers after background items and before content
  items (`PreparedPage.underIndex`; the canvas instead multiplies a copy of the
  text boxes over the ink, `MarkerOrder`). PDF page text is the pdfPage
  item's `pageText` register, kept in `extra` (`Item.pageText`): fill it with a
  `PDFTextExtracting` (`BuiltinPDFTextExtractor`, the CLI's `pdftotext`,
  the app's `PDFKitTextExtractor`) through `PDFIngest.withText`.
- Markdown text boxes (`format.md` §8.2.4 "Markdown text", §8.5.4, PR #129): `markup: "markdown"`; the source
  IS the box's text (one run, no `breaks`), so older readers show and edit it as plain text. Readers ignore run
  attributes and `breaks` of such a box; `layout` (rendered breaks as SOURCE offsets) counts only when its `of`
  equals `MarkdownText.hash` of the text (an older editor keeps the field after changing the source); `math`
  entries match a formula by latex/display/size/colour (stale ones are ignored, their blobs still referenced).
  One parser and layout: `MarkdownDocument` / `MarkdownPlan` (core), `MarkdownLayout` / `MarkdownItems`
  (SempereRender: a box is expanded at `PreparedPage` into text items with fixed breaks, `math` items and an
  `underlay` of shapes, so every writer and `ItemRaster` draws it), ported in `web/src/format/markdown.ts` and
  `web/src/render/markdown.ts`: change all of them together and regenerate `Fixtures/text/markdown.json`
  (`SEMPERE_WRITE_MARKDOWN_FIXTURE=1 swift test --filter MarkdownLayoutTests`) and the web goldens. Writers relayout
  with `MarkdownLayout.relayout` (the app through `TextKitBreaks.relayout`, the CLI through `laidOutText`). Search
  and reports use `MarkdownText.searchText`. The app typesets formulas on close (`NoteEditor.preparedMarkdown`:
  renders first, then one delta); the CLI never typesets.
- Recordings (tasks E4, E5, `docs/attachments.md` §14): pure logic (format, `RecordingTimeline`,
  `RecordingSync`, `TranscriptBuilder`, `TranscriptionLanguage`) in `Sources/Sempere/RecordingSupport.swift`;
  the Speech framework only in `Sources/SempereSpeech` (behind `#if canImport(Speech)`, shared by the app and
  `sempere transcribe`), never server recognition. Strokes get `rec` when the ledger converts them
  (`StrokeLedger.items(for:tool:stamp:)`, from `PKStrokePath.creationDate` through the session's timeline,
  never wall-clock minus start). One `RecordingSession` app-wide (`RecordingSession.active`); its plaintext
  segments stay in Application Support/Sempere/Recordings until the blob (and the transcript) is written,
  and a session left by a crash is saved by `RecordingRecovery` when its note opens. Transcripts are written
  by the model (`storeTranscript`: blob, then one delta through `commit`), not by the editor, so a job
  survives the note closing. App tests use `FakeCapture` / `FakePlayback` / `FakeTranscriber` and a
  serialized suite.
- Recordings on the page (`format.md` §8.2.9): an `audio` item names a recording of its note
  (immutable `recording`, resolved like `rec` through a restored copy's `parent`); title, length and
  transcript are the recording's. The card's layout is `AudioCard` (Sources/Sempere/AudioItems.swift),
  drawn by `AudioCards` (SempereRender) for every exporter and by `ItemRaster` in the app, and ported
  in `web/src/render/audio.ts`. Stopping a recording writes `addRecording` and the card's `addItem` in
  one delta (`NoteEditor.addRecording(place:)`); deleting a recording uses `NoteOps.removeRecording`
  (its cards too); cards are never pasted or copied into another note (`copyableToOtherNote`). The
  card's play/pause control is a `UIButton` in the canvas (`AudioCardControls`), never a gesture: a
  click or Pencil tap on it must not draw.
- Exports hand off to the system through `ExportHandOff` (ExportSheet.swift): callbacks the system
  may call off the main thread (share completion, document picker delegate) are `@Sendable` and hop
  to the main actor; on a Mac the share picker and save panel are presented by UIKit from an anchor
  view, never hosted inside a SwiftUI sheet.
- Quick capture (`format.md` §11, `docs/quick-capture.md`): voice notes are sealed WITHOUT the identity or the
  vault secret, with a capture profile (public recipients + `CaptureKey`, HKDF of the secret, which can only
  authenticate inbox files) into `inbox/<id>.capture.age`; adoption (`Vault.readCapture`, `CaptureAdoption`,
  `AppModel+Inbox`, `sempere inbox import`) turns them into ordinary revisions and blobs. Never store the vault
  secret or an identity outside Face ID for capture. Note/page/recording ids derive from the capture id
  (concurrent adoption converges). Intents live in `Apps/Sempere/SempereShared/` (compiled by the app and the
  `SempereWidgets` extension, iOS only, `platformFilter = ios`) and run in the app's process; the profile is a
  Keychain item `AfterFirstUnlockThisDeviceOnly` (`KeychainCaptureProfileStore`, tests use
  `MemoryCaptureProfileStore`). Plaintext audio lives only in `QuickCapture.root`
  (`completeUntilFirstUserAuthentication`, `QuickCapture.protection`: Lock Screen notes are sealed from closed
  files before any unlock, which `completeUnlessOpen` forbids) until sealed and transcribed; running out of
  background time leaves it for `sweep()` rather than losing the note. A recipient change rewraps and re-tags
  `inbox/` too (`Vault.rewrapInbox`; in iCloud `downloadEverything` fetches it first) and the app refreshes the
  profile after it. A note "exists" for adoption once it has a revision (a folder holding only `att/` is still
  new), and a waiting transcript writes nothing.
- Video items (`format.md` §8.2.7, task G2): a container is read only by
  `VideoProbe` (pure Swift, bounded reads, fuzzed); location metadata is
  removed in place by `ByteEdit`s applied while the file streams into the blob
  (`Vault.writeVideo`, `writeBlob(contentsOf:type:edits:)`), never by
  rewriting or loading the file. A clip is never held in memory: blobs stream
  (`BlobSource.stream`), PDFs with clips are written with `PDFWriter.write(…to:)`,
  Markdown/HTML copies with `ExportVideos.write`. Renderers and the app's item
  layer draw a video as its `poster` (an image blob, a register; `ItemRendering`
  acquires the poster, never the clip) under the play mark; the clip is fetched
  from iCloud only to play (`AppModel.acquireVideo`, `releaseVideo` after).
  Posters come from `VideoPoster` (AVFoundation, shared by the app and the CLI
  on macOS); the Linux CLI stores none without `--poster`.
- Equations (`math` items, `format.md` §8.2.8, task G1): the whole `math` object is ONE register
  (source, style, size, colour, `render`, `renderSize`, `engine`); a value whose source or style
  changed carries a new render or none (`MathContent.withoutRender`, `typesetsLike`). Build edits
  with `NoteOps.math` / `placeMath` / `setMath` (frame follows the render at the same scale,
  `mathFrame`). Every LaTeX source goes through `MathSource.check` before any parser sees it.
  SwiftMath is in the app target only (exact 1.7.3), never in `Sources/`; the CLI has no typesetter
  and draws the stored render, else the source text. The app writes the render blob before the delta
  (`NoteEditor.insertMath` / `setItemMath`); undo restores old values without re-typesetting.
- Handwriting → math (G1 part 2, `docs/research/handwriting-to-latex.md`): the pick (`InkLasso`), the
  conversion (`NoteOps.convertInk`: ONE delta of `removeStroke`s and the math item's `addItem`, render
  blob first), the model's image (`MathInkImage`, pure Swift in the app too, never PencilKit), the
  vocabulary, beam search and clean-up are shared by the app's Convert to Math and `sempere
  recognize-math`; the model runs only behind `MathRecognizing` (`CoreMLMathRecognizer`, `#if
  canImport(CoreML)`; tests use fakes and the tiny random model `Fixtures/math-tiny`, made by
  `tools/math-model/convert.py --tiny`). Models are `sempere-math-model/1` folders whose every file
  is checked against the manifest's SHA-256 (`MathModelStore`) before use; the app's catalogue
  (`MathModelCatalog.entries`) pins each manifest's hash and is EMPTY until the maintainer settles the
  training-data question, so the app's downloader (`MathModels`, its only network code) never runs;
  offering a model also needs the Mac `network.client` entitlement and a privacy-policy change. The
  app removes converted ink through the ledger (`NoteEditor.takeInk` / `putInkBack`, like an erase),
  never by editing `pages` directly; undo and redo of a conversion pass `keepUndo` so `reloadInk`
  does not clear the undo manager in the middle of an undo. Our own lasso (`MathLassoController`):
  PencilKit's selection has no API on iPadOS 26.
- Localization (`docs/localization.md`, task L): every interface string is in
  `Apps/Sempere/Localization/Localizable.xcstrings` (plus `InfoPlist`, `AppShortcuts`), a
  synchronized group of the app and widget targets. SwiftUI literals localize themselves;
  strings built in code use `String(localized: "…")` at the point they are defined (a
  `Text(someString)` never localizes), counts are plural variations (es: one/many/other),
  and the catalog key's specifier must match the Swift type (`%lld` for `Int`, `%@` for
  `String`) or the lookup silently shows English. Text the app writes into a vault stays
  English; the CLI stays English. A new string needs its catalog entry and Spanish value
  (`scripts/l10n.py merge`): `LocalizationCatalogTests` (Linux, runs in `swift test` and in
  its own CI job for `Apps/`-only changes) fails otherwise. The Linux scratch package for
  `AppModel*` needs a `String(localized:)` shim (the Linux Foundation lacks the interpolated
  form and `comment:`). `scripts/app.sh pseudo` checks double-length, right-to-left and
  Spanish layouts.
- WebDAV vaults in the app (`AppModel+WebDAV`, `WebDAVSession`, docs/io.md "WebDAV vaults in the
  app"): a local copy in Application Support (`WebDAVLocalCopy`, `WebDAVLocationStore`) opened like any
  folder, and a push-only sync (`WebDAVLocalCopy.push`: `pushOnly` + `keepServerChanges`) scheduled by
  `WebDAVPushSchedule`; never take anything from the server except through a download into a new copy
  (`download`, `redownload`). The password is only in the Keychain (`KeychainWebDAVPasswordStore`);
  certificate pins are checked by `PinnedServerTrust` (Security, app only) behind the library's
  `WebDAVServerTrust` hook, never by disabling evaluation. Key changes are refused for a WebDAV copy
  (`requireLocalKeyChanges`): a rewrap in place never reaches the server. App tests use
  `FakeWebDAVRemote` and `MemoryWebDAVPasswordStore`; the library's sync runs against wsgidav
  (`scripts/test-webdav.sh`). A recent WebDAV vault is a `RecentVault` with `webdav` set and no bookmark.
- Vaults in another app's provider storage (`StorageLocation`) are coordinated like iCloud ones
  (`isCloudVault`), even when the provider does not report its files as ubiquitous.
- Web viewer (`web/`, `docs/web-viewer.md`): a TypeScript port of the reader
  (`NoteReducer`, `SempereRender`, framing, decoding rules). A change to
  merging, decoding or rendering in Swift needs the same change in
  `web/src/`; `web/scripts/golden.sh` re-exports `web/test/golden` with the
  CLI and the `web-golden` CI job diffs it. The viewer never parses markup
  (DOM nodes only, Trusted Types CSP) and never stores or sends the key. Pin
  npm dependencies exactly; install with `npm ci`. Interface text is localized
  (`web/src/i18n/catalog.ts`, English keys, Spanish complete, typed `t` / `tn`; `docs/web-viewer.md`
  "Languages"): every string `src/ui` shows goes through `t`, counts are plural entries, vault data
  (titles, notebook and tag names) is never translated, and `i18n.test.ts` fails on a key without Spanish.
