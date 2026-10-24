# Sempere — agent guide

Open-source, end-to-end-encrypted handwriting notes for iPad and Mac.
Read `DESIGN.md` (why) and `docs/format.md` (normative on-disk format)
before touching `Sources/`.

## Build and test

```bash
swift build                 # macOS or Linux
swift test                  # all targets
swift test --filter AgeTests
scripts/test-linux.sh       # on a Mac with Docker, or in a cloud VM: run tests in swift:6.4-noble
scripts/app.sh test         # iPad app: xcodebuild test on the newest iPadOS 27+ simulator
scripts/app.sh test -only-testing:SempereAppTests/FooTests   # one suite (any test-* subcommand)
scripts/app.sh catalyst     # iPad app: unsigned Mac Catalyst build
scripts/local-ci.sh         # the PR gate (package, Mac Catalyst unit tests, iOS compile check); see Workflow
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
- Files under a vault's `notes/` (revisions and each note's `att/` blobs), `notebooks/` and `epochs/`
  are write-once. Never add code that modifies them in place; re-encrypting everything (key hierarchy
  KH6, `docs/design/key-hierarchy.md` §7, `VaultReencrypt.swift`, rewrap-replace in `ReencryptSync.swift`) is the
  one exception.
- Crypto: use swift-crypto primitives; never hand-roll a cipher or MAC.
  scrypt and PBKDF2 are the only primitives implemented locally
  (swift-crypto lacks them); they must have RFC test vectors.
- No network code in `Sources/` except the `SempereWebDAV` target (`URLSession`, via
  `FoundationNetworking` on Linux). `scripts/check-portability.sh` enforces it. The sync engine is
  `SempereSync` (network-free, Foundation only); transports reach it through `SyncRemote`
  (docs/io.md "Sync engine and transports"), and WebDAV's is `WebDAVSyncRemote`.
- `sempere/1` is the first released format and must stay stable: do not change what an existing field,
  op or file means. A change that older readers cannot handle needs a new `features` marker or format
  major, so they open the vault read-only (`format.md` §7).
- Keep the stock-CLI recovery path working (`age` 1.3+). Files are encrypted to the vault identity,
  so the path is the kit's frozen script (`format.md` §15.13, `KitRecovery.script`, byte for byte):
  `jq -r '.keys[] | select(.role == "recovery") | .wrap' vault.json | age -d -i recovery.txt > vault-keys.txt`,
  then `age -d -i vault-keys.txt FILE.age | tail -c +38 | gunzip | jq .`, and for blobs
  `age -d -i vault-keys.txt notes/ID/att/NAME.KIND.age | tail -c +46 | head -c LEN` (§8.1.7). Under the key hierarchy (KH2 on, `format.md` §15) the key is `vault-keys.txt`
  from the kit's frozen script (`KitRecovery.script`, §15.13): never change it, the record and journal
  framing, the wrap or the passphrase copy without `EpochChainTests.testFrozenRecoveryScriptOpensEveryEpoch`
  and `testRecoveryScriptMatchesTheDocuments` passing. KH1's pure key-hierarchy code is
  `Sources/Sempere/Epoch*.swift` and `JoinCodes.swift`, mirrored in `web/src/vault/epoch.ts`; vectors in
  `Fixtures/epoch-vectors.json` (`web/scripts/make-epoch-vectors.ts`, then
  `SEMPERE_WRITE_EPOCH_VECTORS=1 swift test --filter "EpochKeysTests|EpochChainTests"`),
  `epoch-chain-vectors.json` and `epoch-precedence-vectors.json`. Only the home device signs list
  changes; a takeover by the recovery key is the one other signer (design §5.6).

## Optional importers

The Notability importer is a removable module (`Sources/SempereNotability`, `docs/import-notability.md`
"Structure"): the CLI and the app reach it only through `VaultImporter`, `ImportRegistry.swift` and
`AppImporters.swift` (each gated by `#if canImport(SempereNotability)`). Never name a `Notability…` type
outside the module and those two files (`scripts/check-importer-isolation.sh`); put anything importers share into
`SempereImport`. A new import option is an `ImporterOptionSpec`, not a new flag in the CLI or a new toggle in the app.
`scripts/check-removable-importers.sh` (Linux CI) deletes the module in a copy, builds every target and test target without it,
and runs the CLI's tests (`CLITests`; `check-importer-isolation.sh` covers the references).

## Style

Swift 6 strict concurrency. `Sendable` value types for the model. No
force-unwraps outside tests. Errors are typed enums per module. Tests use
XCTest (Linux-compatible). Keep public API documented with `///`.

## CLI first

**The CLI is the first place to get features; everything is automatable
(aside from the UI).** Every feature that
reads or changes vault data ships with a `sempere` command (with `--json`
output and CLI tests in `Tests/CLITests`) in the same PR as, or before, the
app UI for it, and `docs/cli.md` is updated. The logic lives once in `Sources/` (e.g. `NoteOps`,
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
`area: imperative summary`. Co-author line as the harness instructs. Testing layers (docs/ci.md):

- **PR gate**: `scripts/local-ci.sh` (a Mac with Xcode) runs the package tests, the Mac Catalyst
  unit tests and an iOS compile check (no simulator, no screen, about ten minutes) on a pushed,
  clean commit and posts `local/app-tests`, which a PR needs to merge. Logs in `build/local-ci/`;
  `--list` prints the steps.
- **Your targeted tests**: the gate runs no UI test and nothing on a simulator. Pick the tests
  your change calls for, run them, and list each with its result under `## Tests run` in the PR
  description (the template has the section; the `PR lists tests run` check fails without it).
  For example a window or menu change: `scripts/app.sh test-mac-ui
  -only-testing:SempereAppUITests/MacWindowUITests`; an iPad drag: `scripts/app.sh test-ui
  -only-testing:SempereAppUITests/SidebarDropUITests`; an iPhone layout: `scripts/app.sh
  test-phone`; a new window or sheet:
  `scripts/app.sh test-mac-smoke`. Nothing beyond the gate is a valid answer only with the reason
  ("None beyond the gate: docs only").
- **Before TestFlight**: `scripts/local-ci.sh --testflight` (the gate plus every Mac UI test and the
  Mac launch smoke tests; posts `local/testflight-suite`).
- **Before a release**: `scripts/local-ci.sh --release` (everything, iPad and iPhone simulators
  included; posts `local/release-sweep`, which `release.yml` requires on the tagged commit).

### Parallel agents

- Changelog: add a fragment `changelog.d/<topic>.md` ([format](changelog.d/README.md)); never edit
  `CHANGELOG.md` (`scripts/changelog-collect.py` folds fragments at release time, docs/ci.md).
- Run all Xcode work (`xcodebuild`, `scripts/app.sh`, `scripts/local-ci.sh`) through the build lock your
  environment provides (the agent harness's `xc-lock`); never start Xcode work outside it. It admits a few
  jobs at once in arrival order: Catalyst runs (`test-mac*`, `catalyst`, any `local-ci.sh`) one at a time,
  since they share the app's container and the UI tests drive the real screen; simulator runs side by side,
  each on its own throwaway simulator clone (`SEMPERE_SIM_ID`); builds and package tests in any free slot.
- A test that depends on a simulator's leftover state is a bug: every run may start on a fresh clone.
- Cancel only your own processes, by PID; never `pkill -f` or `killall` patterns (they kill other agents' runs).
- Temp files go in your own scratch directory, never shared names (`/tmp/out.log`).
- Tests never use `FileManager.default.temporaryDirectory` directly: use `TestTemp` (app tests:
  `SempereAppTests/TestTemp.swift`; SwiftPM: `TempDirSupport`), which removes everything at process exit
  (docs/ci.md "Temp-folder guard").

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
- Every vault the app opens is an in-app copy (`VaultStore`; P7 removed reading vaults in place). iCloud
  Drive and other providers reach the app only as a folder copied in (`copyIn`, a restore: every file
  downloaded first, `downloadSourceFolder`, `CloudVault.download`, `CloudScan` maps `.<name>.icloud` and
  dataless stand-ins) or as a folder sync target, whose provider hazards (evicted files, unlisted folders,
  conflict versions) belong to the sync engine (`FolderRemote`, `UbiquitousFolderHooks`, `ConflictVersions`;
  docs/io.md "Folder targets in providers"). Never add code that reads a vault in a provider in place, and
  never add file coordination around reads of the open vault: it is local. The simulator has no iCloud:
  copy-in is tested with fake hooks; the Linux scratch package needs shims for `isUbiquitousItem`,
  `startDownloadingUbiquitousItem`, `ubiquitousItemDownloading*` resource values and `NSFileCoordinator`.
- The app's deployment target is iPadOS/iOS 27 and Mac Catalyst 27: iOS 27 APIs
  are used directly in `Apps/`, with no `#available` gate. The package keeps its own minimum
  (`Package.swift`: macOS 14 / iOS 17) so the CLI builds on older macOS and
  Linux; code in `Sources/` still gates newer Apple APIs with `#available`.
- PencilKit stores control points in reduced precision (Float32 locations,
  quantized opacity/azimuth/altitude): compare converted strokes within a
  tolerance, never with `==`. Stroke identity across canvas edits comes from
  `StrokeLedger`'s fingerprints, which are always taken from the `PKStroke`.
  A loaded stroke's `PKStroke.id` is its stored id; the ledger uses a canvas
  stroke's id only to name an edit's parent (PencilKit gives erased pieces
  new ids), and never writes it. What a stroke keeps through save and reload is its texture seed: a
  canvas stroke is saved under an id whose first four bytes are its `PKStroke.randomSeed`
  (`StrokeConversion.id(seed:)`), and a load takes the seed back from the id, so pencil, crayon and
  watercolor grain does not change on reopening (`InkRoundTripTests`).
- `PKStrokePoint.size` is not the drawn width: a pen or monoline of size `s`
  is drawn `2s − 4` wide (invisible below 2), markers and textured inks
  differ again. Point sizes go through `NibSize` (StrokeConversion.swift);
  never pass a format `w` to PencilKit directly. `ImportedStrokeRenderingTests`
  pins the relation, so an iPadOS change to it fails there first.
  That relation was measured on the simulator and Mac Catalyst only. Strokes
  drawn on an iPad Pro 12.9" (4th gen) record pen sizes of about
  3.2 to 4.9 for tool widths 0.88 to 25.7, and monoline size 3.25 whatever
  the width, with the width carried inside the (opaque) `PKInk`; on hardware
  the drawn width may depend on that ink, which the simulator ignores. Check
  ink-width changes on a device, not only in tests.
- The drawing palette is Sempere's own on every device (`DrawingPaletteView`, docs/iphone.md "The drawing
  palette"): PencilKit's `PKToolPicker` never shows in a Mac Catalyst app, so never make one. One tool state
  (`DrawingToolbox.shared`; the pure `DrawingToolState` in `Sources/Sempere/DrawingTools.swift`, Linux-tested)
  drives every canvas: each `PageCanvasHost` sets `PKCanvasView.tool` from `pkTool` on `DrawingToolbox.didChange`.
  Change it through the toolbox (or `CanvasCommandTarget.select(drawingTool:)`, which also ends the Hand, the text
  tool and the math lasso on that canvas), never by setting a canvas's tool. Tests give hosts their own
  `DrawingToolbox(defaults:)` (Swift Testing runs suites in parallel; the shared one is app-wide state).
  The eraser mode stays `EraserPreference`'s two modes (object, pixel: `canonical`, compare with `isPixel`,
  never `==` across types) under `Sempere.eraserType`, which settings sync writes; the pixel eraser is
  `.fixedWidthBitmap` at the palette's width.
- Debug builds open a vault and note from launch environment variables, for
  scripted simulator or Catalyst runs (`DebugLaunch.swift`):
  `SEMPERE_DEBUG_VAULT`, `SEMPERE_DEBUG_IDENTITY`, `SEMPERE_DEBUG_NOTE`
  (id prefix), `SEMPERE_DEBUG_SCROLL_Y`, `SEMPERE_DEBUG_ZOOM`,
  `SEMPERE_DEBUG_SNAPSHOT` (PNG of the canvas); paths may start with `~/` (the
  app's data container: on a real device, copy a vault in with `xcrun devicectl
  device copy to --domain-type appDataContainer`). With `xcrun simctl launch`
  prefix each with `SIMCTL_CHILD_`. Point it at a copy of a vault: the editor
  autosaves.
- App Store release: `scripts/release-check.sh` (Linux, CI job `release`,
  its tests `scripts/test-release-check.sh`) fails on differing MARKETING_VERSION /
  CURRENT_PROJECT_VERSION between targets, any DEVELOPMENT_TEAM, an entitlement outside its
  allow-list, a Mac bundle id of its own, or a required-reason API (UserDefaults, file timestamps,
  disk space, boot time, keyboards) used in a shipping target's sources (including the `Sources/`
  targets it links) but not declared in its `PrivacyInfo.xcprivacy` (app: `SempereApp/`, widget:
  `SempereWidgets/`). A new entitlement, package product or API category means updating the
  script's tables, and the manifest in the same PR.
  It also fails on networking (`URLSession`, Network.framework, sockets, WebKit, …) in any
  non-test folder of `Apps/Sempere` or a linked `Sources/` target outside `NETWORK_ALLOWED` (the
  WebDAV client: `WebDAVRemote.swift`, `SempereWebDAV`'s transport and client; and the dormant
  math-model downloader, `MathModels.swift`) and on a non-empty `MathModelCatalog.entries`: the
  privacy policy names the only connections (a WebDAV server the user sets up; DESIGN.md "Network"). The CLI release refuses a CHANGELOG section with `TODO(user)` or no date
  (`scripts/changelog-section.sh`); never fill in the release date yourself.
  `ITSAppUsesNonExemptEncryption` stays `NO` while France is excluded
  (France is excluded from availability until the ANSSI declaration is approved). The privacy policy has two copies
  (`docs/privacy/index.html` for Pages, `docs/appstore/privacy-policy.md`): edit both, same date.
- App Store screenshots (`scripts/screenshots.sh`, `docs/appstore/screenshots.md`):
  `SEMPERE_DEMO=1` builds a synthetic vault in code (`DemoVault`,
  `DemoHandwriting`, DEBUG only, Linux-typecheckable like the other non-UI
  logic) and opens it; `SEMPERE_DEMO_*` pick note, sidebar, locked state and
  the paper picker. The `SempereScreenshots` scheme runs `SempereAppUITests`
  (not part of `SempereApp`'s test action, so `scripts/app.sh test` never
  builds it); CI runs it only by dispatch (`-f screenshots=true`). Never put
  real notes in a demo.
- `PKCanvasView` inverts ink colors in dark mode; the canvas forces
  `.light` because ink colors are stored as drawn on (light) paper. Only Settings ▸ Appearance ▸
  Note Pages ▸ Dark turns it `.dark` (`PageCanvasHost+Appearance`): display only, the picker stays
  `.light` so stored colors do not change; the paper and the app-drawn items go through
  `PageColorInversion` (never pictures, PDF pages, video), and exports never do.
- Vaults are plain folders: `SempereInfo.plist` (referenced by `INFOPLIST_FILE`,
  outside the synchronized group so it is not copied as a resource) exports the
  `.sempere` UTType as `public.folder`, NEVER `com.apple.package`: iCloud Drive syncs a
  package as one item, and a whole-vault conflict lost a note in TestFlight 1.0.0
  (`theVaultTypeIsAFolderNeverAPackage`, docs/io.md "Vaults are folders"). `VaultLocator.resolve` maps whatever was picked
  to the vault folder (never upward: a pick inside a vault is an error, its scope
  does not cover the vault); `openVault(at:accessing:)` holds the security scope of the
  picked URL, not the derived one.
- In-app vault store (P5a of docs/design/device-first-sync.md; `Sources/Sempere/VaultStore.swift`,
  `VaultFileLock.swift`): New Vault (`VaultLibrary.create`) and Open Vault… (`AppModel.copyIn`, which
  copies the picked vault in and opens the copy, or opens the copy already there) and Restore from Backup
  (`VaultStore.restore`, `--replace` swaps a copy: old aside, new in, `sweep` restores an interrupted one) put every vault in `VaultLibrary.vaultStore`
  (`Application Support/Sempere/Vaults/<vaultId>/<name>.sempere`; tests get one next to their
  `recents.json`). Nothing creates or reads an in-place vault (a recent of an earlier build is copied in). A
  vault appears in the store only complete (built or copied under `.staging`, checked, one `rename`;
  `sweep` removes leftovers), so never write into a store folder by hand. One copy per vault id. Recents
  of store vaults carry `storeID` and no bookmark; an open store vault holds a `VaultStore.Lease`, and every
  writer of a vault's files shares its `VaultFileLock` (`VaultStore.writeLock(for:)`). CLI: `sempere store` (list, path, create, import, restore, remove).
- A WebDAV join opens a partial copy (format.md §1.2) at once (`AppModel+Join`, docs/io.md "WebDAV vaults in
  the app"): notes marked incomplete are pending rows (`pendingNoteIDs`, from published summaries) and never
  read; the vault's two-way runs fill the copy. Anything that opens or edits one note calls `downloadNote`
  first (a one-note `LocalCopy.fetch`, bounded by `noteFetchTimeout`, cancellable), and every write re-checks
  with `partialNoteVerifier` (`commit(ids:)`, the editor's read): never write a delta to an incomplete note.
  A note that cannot be opened shows `editorFailure` in the detail pane, never a blank canvas. Tests:
  `JoinAppTests` (real engine, `EngineWebDAVRemote.gating`/`gatingFetches`), `WebDAVPartialAppTests`.
- Note listings (`AppModel+Loading`): `unlock` only checks the key and starts
  `startLoadingNotes`, a task the model owns (UI callers pass `awaitNotes:
  false`; a view's `.task` must never own a listing, SwiftUI cancels it when
  the view goes). Summaries come in batches (`loadBatchSize`) through
  `Vault.summaries(of:cache:)`, never one `summary(of:)` per note; listings
  are serialized by `loadGate`. The per-device `SummaryCache` (format.md §10)
  is keyed by revision file names, so bump `SummaryCache.schemaVersion` when
  `NoteSummary` gains or changes a field. `RevisionDetail.withoutStrokePoints`
  revisions are for listings and search only: never write, snapshot, render
  or diff them. Exception: a state merged from them may feed metadata-only
  ops (`NoteWriter.append(to:detail: .withoutStrokePoints)`, guarded by
  `Op.isMetadataOnly`, which re-runs the builder on the full note otherwise),
  and they feed a writer's readings and `seq` (`Vault.writeReadings`). Tests get no cache unless they pass `summaryCacheDirectory`.
- The list is change-driven (`AppModel+Reconcile`, docs/io.md "Opening a vault
  fast"): passes list note folders by NAME (`VaultEnumeration`) and read only
  notes whose names differ from `indexedNames` (`IndexDiff`). Apply summaries through `queueListUpdate` (throttled) or
  `merge` (an edit's own re-read, immediate), never by assigning `notes`
  wholesale. Tests that need "another device wrote a revision" use
  `TS.writeAsAnotherDevice` (an eviction alone changes nothing).
- Remote changes reach an open note in place (`AppModel+RemoteMerge`,
  `NoteEditor.mergeRevisions`, docs/io.md "Changes from other devices while a
  note is open"): a listing names a revision the editor does not know
  (`knownRevisionNames`), the note is downloaded, the editor saves, re-reads
  and applies the result synchronously. Never replace a canvas's drawing for
  a merge except through `RemoteInkView.reloadInk` in that same main-actor
  turn, after `StrokeLedger.mergeStored`: a canvas reporting a drawing the
  ledger does not know is taken as the user's edit (echo deltas). Every write
  an editor starts bumps `writeEpoch`. From the second merge on, the read
  applies only the new revisions to the editor's `ReducedNote` (exact, or it
  falls back to a full read) and the apply compares only the pages they
  changed: any change to the reducer must keep `ReducedNoteTests` (incremental
  == full read) passing. Tests: `RemoteMergeTests`, `RemoteMergeIncrementalTests`.
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
  deleted at quit and at launch instead: `blobCacheAcrossLaunches`, `purgeAtQuit`, `purgeAtLaunch`;
  audio, video and transcripts never stay: `isTransient`) and `RenderCache` (sealed image pictures
  and PDF page previews, memory + disk). Both are per vault key and go when
  the vault closes (`dropAttachments`). Bump `RenderCache.schemaVersion` when
  `ItemRaster`, `PDFItemDrawing` or the preview drawing changes. Tests get a
  per-model blob folder and a memory-only render cache unless they pass
  `blobCacheRoot` / `renderCacheRoot`.
- Sidebar drops: a drag the app started is dropped from `AppModel.draggedPayload`
  (`beginDrag` / `takeDrop`), never by loading the item provider (the system
  releases it as soon as `onDrag` returned). `onDrag`
  reports no end, so the payload of a canceled drag lingers: only a drop that
  carries the app's own types (`carriesAppTypes`) may use it, never a photo or
  text dragged in from another app. Rows propose `.copy`, never `.move`
  (`SidebarDrop.proposedOperation`): `onDrag` sessions from a `List` row allow
  no move, and UIKit cancels such a drop at the release (highlight, then
  `dropExited`, no `performDrop`). A `List` handles drags it
  started itself and never asks its rows' drop delegates, so notebook rows drag
  from a `UIDragInteraction` of their own that also carries their context menu
  (`NotebookDragSource.swift`; one view, or the menu takes the long press on the
  iPad); never put `onDrag`/`draggable` or a SwiftUI `contextMenu` back on them. Their lift and menu
  previews are the row's cell (`SidebarCellPreview`; the handle is clear, and a device showed nothing
  lifting). Notebook rows take drops on the handle (`UIKitSidebarDrop`); All Notes through its SwiftUI
  `onDrop`. A drop that moved something flashes its row (`AppModel.landedDrop`).
  `SidebarDropUITests` drags for real (`scripts/app.sh test-ui`,
  `SEMPERE_DEBUG_DROPS` trace, `SEMPERE_DEBUG_NOTEBOOK_DRAG` styles).
- Per-vault device memory (`RecentActivity`, sealed, Application Support):
  "Recently Recognized" (7 days) and recent searches; `activityNow` is the test clock.
- Timing: wrap new slow phases in `Perf` (os_signpost in every build; debug log
  `Library/Logs/SemperePerf.log`), counts and 8-hex id prefixes only.
  `PerformanceReportTests` prints `PERF-REPORT` lines in the CI `app` log.
- Infinite pages scroll one screen beyond both their ink and their stored
  height (`PageExtent.scrollHeight`). Their paper is drawn in bands near the screen
  (`PaperView.setVisible`, fed by the canvas's scroll): never one layer the height of the note.
  The one-page canvas zooms out to half the fit, centered with `contentInset` (an iPhone stops at
  the fit, `ZoomDetent.minimumFactor`); `fitWidth` sets the zoom only when the fit itself changes,
  never on a SwiftUI update or during a pinch. "Keep Screen On" (`KeepScreenOn`) disables the
  idle timer only while a note is open and the scene is active.
- Paged notes scroll through all pages in one view (`PageStackView` /
  `PageStackHost`, layout math in `PageStackLayout`, Linux-testable): one
  embedded `PageCanvasHost` per page within a screen of the visible band
  (recycled, at most `spareLimit` spares), each at the stack's scale with its
  own undo manager, drawing with the palette's tool (`DrawingToolbox`; PencilKit's ruler only on the page with
  the focus, `PageStackHost.placeRuler`). The stack zooms
  natively during a pinch and bakes the scale into the page canvases when it
  ends (`bake`, which settles it with `ZoomDetent`: the fitted width is a detent, and
  the pages zoom out to half of it, centered); never zoom an inner canvas. The current page follows the
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
  A canvas takes the first responder by itself (layout, opening, a box ending, its
  window becoming key) only through `focusUnlessKeyboardElsewhere` (`CanvasFocus`):
  never from a text input elsewhere (search, rename, sheets), from a list holding the
  keyboard focus, or in a window that is not key; only a stroke calls `focus()` directly,
  and a touch on the canvas takes it back (`PageCanvasHost.hitTest` →
  `reclaimFocus`: the user's own focus, after the sidebar or a list took it).
  Calling `becomeFirstResponder` on a canvas from layout or `updateUIView` took the
  search field's keyboard after every key on a Mac (`CanvasFocusTests`, `MacFocusUITests`).
- Paged vs pageless is only `pageSize.infinite` (`format.md` §5.4.3). Page
  gestures (add, move, delete, undo, duplicate) and the layout switch are built
  by `NoteOps` (`Sources/Sempere/PageLayout.swift`), which also predicts the
  resulting pages, and are written by `NoteEditor`, one delta per gesture. A
  stroke that changes page is re-added under a new id with its `transform`'s
  `ty` shifted, never edited in place. A note keeps at least one page.
- `NavigationSplitView` ignores a programmatic column change that arrives
  while the view is first being built, so the stored choice (`ColumnLayout`,
  `@AppStorage`) is never made to depend on selection state.
- The palette shows only while annotating, docked at the bottom of the note (an overlay of `EditorView`): full
  (`ViewThatFits`: choices inline, else behind the color button, else the compact bar) or compact (Compact Palette,
  `ToolPalette.compactKey`; always on an iPhone, `PhoneReading.paletteCompact`). It needs no first responder: never
  give a canvas the focus for the palette's sake (`CanvasFocus`). Its container keeps PencilKit's accessibility
  identifier `Drawing-Palette` and its tools their names ("Pen", "Object Eraser"…), which UI tests use.
- Tags match case-insensitively (`NoteOps.tagKey`); titles are never keys.
  Tags merge per tag (`format.md` §5.4.1): write `addTag` / `removeTag` via
  `NoteOps.addTag` / `removeTag` / `setTags` (a remove lists the instances it
  observed, so it needs the note's state), never `setMeta(.tags)` (read only).
- Vaults are post-quantum only: every key is MLKEM768-X25519 (`age1pq1…`); public `Vault` API throws
  `classicRecipient` for X25519, and `Vault.readManifest` refuses a `vault.json` listing a classic key
  (`manifestCorrupt`). CLI exit code 5 is unused. Keys are `NativeIdentity` / `NativeRecipient`
  (Sources/Age/NativeKeys.swift). X-Wing comes from swift-crypto 4 (CryptoKit on Apple 26+, BoringSSL
  on Linux); never implement ML-KEM here. `postQuantumAvailable` is false on Apple OSes before 26 or
  SDKs before Xcode 26, so gate PQ tests with it. PQ keys are 1959 characters: abbreviate in UI.
  Interop tests need `age` ≥ 1.3 on PATH (the official release; Ubuntu ships 1.1); CI sets
  `SEMPERE_REQUIRE_AGE_PQ` so they fail instead of skipping. See `docs/post-quantum.md`.
- Key hierarchy (`format.md` §2, §15; `docs/design/key-hierarchy.md`; phase KH2: vaults of one epoch).
  `vault.json` (`EpochManifest`) wraps the epoch key `K_e` (`VaultEpochKey`) once per listed key: one
  entry per device and exactly one recovery entry. Every vault file is encrypted to the vault identity
  `v_e` derived from `K_e`, in ONE stanza (`Vault.encrypt`); body tags use `tagKey`, blob names
  `blobNameKey`, capture keys and the caches/summaries their own HKDF info with `K_e` as input. Device
  keys (`DeviceKeys`: age key + P-256/ML-DSA-65 signing pair) never enter the vault (CLI:
  `$XDG_STATE_HOME/sempere/devices/<vault id>/device.key`); `keys/` holds only the recovery key's
  passphrase copy (`RecoveryPassphraseCopy`, work factor 20, `PassphraseStrength` ≥ about 70 bits, no
  override). One writer: only the home device writes `vault.json` (approve, rename; signed with
  `authorSig`, `Vault.seal`); any listed device may change only `label` (covered by nothing). Joining
  is `Vault.writeJoinRequest` → home's `approveDevice` → `confirmJoin` with the reply words; until
  then the device reads but never writes (`rootUnconfirmed`). The recovery key opens read-only
  (`recoveryKeyReadOnly`, CLI exit 7). Removal, handoff, takeover and kit replacement are new epochs
  (KH3: `VaultEpochChange.swift`; record final name first, then `vault.json`, under the write lock), and
  files under earlier keys go by the acceptance rule (`VaultEpochs.swift`: accepted only when the record
  closing their epoch seals their exact bytes, else set aside in `SetAsideStore`, never deleted). Every
  own write is in the device's write ledger BEFORE it is placed (`recordWrite`, `WriteLedger.swift`;
  captures via `CaptureWriter.record`), and `catchUp` re-encrypts its unsealed entries after a change;
  a ledger that cannot record fails the write closed. The app's ledger and set-aside store are
  `DeviceWriteStores` (App Group, Keychain key `AfterFirstUnlockThisDeviceOnly`); tests pass none.
  `EpochInvariantTests` (J1–J8) and `EpochVaultPropertyTests` require each test-only mutation to break ITS
  invariant. Over sync (KH4, `format.md` §15.15, `Sources/SempereSync/EpochSync.swift`, `VaultIncomingEpoch.swift`)
  `epochs/` goes first (never a `vault.json` to a target without its record), a `vault.json` of another epoch
  is judged by `Vault.judgeIncoming` (taken, record-pending, waiting = a sighting in the trust store that holds
  every run's uploads back (J5b), unlisted, behind, conflict), received files the acceptance rule does not take
  are set aside or pending (never quarantined or placed), and an accepted copy replaces an unaccepted one after
  it is set aside (`replaceUnaccepted`, strong version tags only). `EpochInterleavingTests` (J1–J6, J8–J10)
  requires each mutation (`EpochMutation`, `SyncEpochMutation`, `PrecedenceMutation`) to break ITS invariant;
  `SEMPERE_EPOCH_TRACE=1` prints a failing run's ops. Re-encrypt everything (KH6, `format.md` §15.8, §15.16; design
  §16.12) is home's: `prepareReencryption` (journal written unbound) → `ReencryptCoordinator.claim` on every target →
  `beginReencryption` (a `reencrypt` epoch whose record carries no parent key; `vault.json` binds the journal in
  `reencryptPending`, which `authorSig` covers) → `ReencryptCoordinator.advance` (the pass, runs, `confirm` per
  target, `finishReencryption`); CLI `vault reencrypt [--resume|--status]`. While pending every epoch change carries
  the binding, and the keyring takes the keys below the record from the bound journal (after: the device's own
  pinned keys). Runs never upload, take or delete an unbound journal. J7 and J9 are in `EpochInterleavingTests`.
  There is no recipients list, no vault secret, no migration from the old format. The app creates vaults (this device home, a recovery kit,
  an optional passphrase copy) and unlocks with the remembered device key (`DeviceKeys.fileText` in the
  Keychain); the recovery key and its passphrase copy open read-only. The device list (KH5,
  `DevicesView`, `AppModel+Devices`, design §16.11) renames, removes, hands home over and replaces the kit
  through the package's calls (`Vault.removeDevices` …, history and review in `DeviceOverview.swift`, shared
  with `sempere devices`), each after `performDeviceChange`'s bounded run of every target, with the editors
  closed and the vault reopened under the new epoch; banners and the unlisted screen are
  `AppModel+DeviceNotices`. Joining devices and takeovers in the app are stubbed with `TODO(KH5)`.
- `vault.json` is authenticated (`format.md` §2.1, `VaultCheck.swift`, `VaultTrust.swift`): `listTag`
  and `markersTag` (HMACs under keys derived from `K_e`), `epochSig`, `authorSig`, `addSig` (home's
  signatures). `Vault.open(…, trust:, root:)` classifies it (`listStatus`) against the device's trust
  record (`sempere-trust/3`, §15.10; CLI `$XDG_STATE_HOME/sempere/trust/`, app
  `AppModel.defaultTrustDirectory`, tests `MemoryEpochTrustStore`) and the given root.
  `requireWritable` refuses a refused list (`VaultError.untrustedList`, CLI exit 6) and saves the
  record: only writers keep records, reads never write. Anything that encrypts outside
  `requireWritable` (capture profiles) calls `requireTrustedList`. Never copy a `vault.json` from
  elsewhere without `Vault.incomingManifestProblem` (label-only differences are the same vault; a later
  version by home is taken, `isLaterVersion`; anything else is a conflict, never merged). Tests that
  change a manifest field re-seal it as home (`writeResealedManifest`), else it reads as tampering.
  Capture profiles hold their device's capture key (`CaptureKey.derive(from:device:)`, §11.1, keyed by
  `fingerprint(of:)` of the device's `age1pq1…` key, not the §15.4 fingerprint) and `v_e`;
  `Vault.captureKeyRing` is what verifies inbox files, never one key alone.
- Remembered vault keys (`VaultKeyStore.swift`, `RememberedKeys.swift`): a remembered key is the
  secret text of an age identity (`AGE-SECRET-KEY-PQ-1…`) whose key `vault.json` lists; it is stored only in the Keychain, never logged, never in
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
  A remembered key is offered only at folders it opened (`RememberedKeyLocations`, S16); a manual
  unlock elsewhere binds the folder silently only when the trust record confirms the list, and
  otherwise brings the remember sheet (`Offer.replacing`), never nothing: a WebDAV copy's list is a
  first use until the device writes, so without the sheet the key was needed at every launch
  (`RememberedKeysWebDAVTests`).
- The object eraser is the app's (`ObjectEraser.swift`, `EraserGeometry.swift`):
  PencilKit's `.vector` eraser has no size. When the palette's eraser is in
  object mode, `PageCanvasHost` disables `drawingGestureRecognizer` and
  `ObjectEraserController` takes the touches (Pencil, plus one finger when
  fingers draw; scrolling then needs two), removes every stroke whose sampled
  outline the swept capsule touches by setting `canvas.drawing`, and registers
  one undo step per gesture on the canvas's undo manager. The ledger turns
  that into ordinary `removeStroke` ops. The pixel eraser stays PencilKit's.
  Radius presets (`ObjectEraserSize`, page points) are in `UserDefaults`
  under `Sempere.objectEraserRadius`; the size is in the palette's eraser choices and the editor toolbar's menu.
- The Mac menu-bar item (`docs/mac.md` "Menu-bar item") is an AppKit bundle, target
  `SempereStatusItem` (`Apps/Sempere/SempereStatusItem/`, SDK macOS, Swift 5 mode), embedded in
  `PlugIns` for Catalyst only (`platformFilter = maccatalyst` on the dependency and the embed
  phase). The Catalyst app cannot link AppKit types, so `StatusItemHost` loads the bundle and the
  two only post notifications on the default center (`StatusItemProtocol`, in `StatusItemShared/`,
  compiled into both): state and localized titles go in, the chosen entry comes out. The bundle
  has no strings, no logic and no network; keep it that way. The app must work with it missing.
  A new entry is a case of `StatusItemProtocol.Action` handled in `StatusItemHost.run`.
- Mac (Catalyst) behavior is in `docs/mac.md`. Menu entries are cases of
  `MenuCommand` (title, shortcut, enabling in one place; `MenuCommandTests`
  checks shortcut clashes); never add a menu item elsewhere. Menus act through
  the focused window's `CommandRouter`. A note has at most one `NoteEditor`:
  note windows go through `AppModel.claimNote` / `openWindowNote` /
  `releaseNote`, and anything that changes the vault under open editors (key
  changes) closes them all first and bumps `keyEpoch`. Sheets and alerts that
  commands open live in `WindowUI`, attached by `windowSheets` to a view that
  is always on screen (the note list is not when the columns are hidden).
  Gate Mac-only behavior on `Platform.isMac` (compiles on the iPad, so the
  iOS compile check covers it) rather than `#if targetEnvironment(macCatalyst)`:
  the hosted Catalyst build runs on `main` only (or `gh workflow run CI --ref <branch>`).
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
  (category `environment`) instead of trapping (a Mac launch crash).
  Tests still inject their own; `AppModelEnvironment.fallbacks` counts
  fallbacks, since the test host sets `.current`.
- The Mac menu bar starts from UIKit's own (New Window ⌘N, Open… ⌘O, Find…
  ⌘F, document commands). UIKit drops a whole SwiftUI command group if one of
  its shortcuts is taken (log: "Replacement elements conflict"), so a new
  `MenuCommand` shortcut must not collide with UIKit's; ⌘O and ⌘F are UIKit's
  items renamed by `MacMenus` (`MenuCommand.nativeOnMac`). Check menus on a
  real Catalyst runtime: `scripts/app.sh test-mac` (every app suite, ad-hoc
  signed and sandboxed; the PR gate) and `test-mac-ui` (`MacWindowUITests`; CI on
  `main` and on dispatch, `local-ci.sh --testflight`). A test that needs pixels
  on a Mac puts its view in a window of the host app's scene (a window without
  one is never drawn there).
- Launch smoke tests (`LaunchSmokeUITests`; `scripts/app.sh test-mac-smoke` on
  `main` and in `scripts/local-ci.sh --testflight`, the iPad layouts in `test-ui`) start from fresh state
  (`SEMPERE_DEBUG_FRESH`), unlock the demo vault through the unlock sheet
  (`SEMPERE_DEMO_PASSPHRASE`) and open every column layout, window and sheet.
  A new window, sheet or column layout gets a step there; a new scene must
  inject the app environment, which `AppSceneEnvironmentTests` (Linux) checks,
  along with the wrapper rule above: no view reads the three with a plain `@Environment`.
- Expectations (`Expectations.swift`, `ExpectationsViews.swift`, `docs/security.md`): "About Your Key"
  shows by itself once per (vault, key) on a device (`OnboardingMemory`, digests only), then the
  quick tour once per device; both only in the canvas window, after the unlock sheet and never over
  the new-vault sheet (`holdsOnboarding`). Scripted debug launches skip them unless
  `SEMPERE_DEBUG_ONBOARDING` is set. Tour pages claim only what the app does. The CLI's `--version`
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
  `collectBlobs` (rules 1–4, per note, device-local `BlobCollectorState`); nothing rewraps or renames
  them (adding a device touches no file). References are found structurally (any
  object with `sha256`) with `JSONSerialization`, whose `NSNumber` says `is Bool`
  for 0 and 1: test `objCType == "c"` for booleans instead.
- Unused-attachments index (task E7, `docs/attachments.md` §4): per-note
  `AttachmentIndexEntry` (core `AttachmentIndex.swift`), updated by
  `AttachmentIndexer.update` for the changed note only (writes via
  `DeviceClock`'s write hook, arrivals via `readSummaries`/`refresh` →
  `summariesRead`); never add a whole-vault pass outside Settings' explicit
  "Check". Numbers come from `AttachmentStorageReport` (app and `sempere blobs
  unused` alike). Delete only through `collectBlobs(note:records:only:)` with the
  entry's `unusedSince`; a partial copy's notes not downloaded decide nothing (`local: false`).
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
  (`format.md` §5.5): current iff equal. Recognition without a basis (imported) is
  never replaced unless the editor itself changed that page's strokes (`touchedPages`), via
  `RecognitionPolicy.needsRecognition`. The editor saves strokes first, recognizes off the main
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
  `PageStackLayout.revealOffset`): embedded canvases never scroll. A match's page is made current with
  `showPageOfMatch`, never `selectPage`/`showPage`: the stack reads `revealToken` live but `pageJump` from its
  configuration, so the two can arrive in separate updates and a late jump to the page's top undid the reveal
  (TestFlight 1.0.0 (6)). `SearchHighlightUITests` (`SEMPERE_DEMO_SEARCH`, the canvas report's `hl=`/`hlRect=`)
  walks every match on an iPhone (zoomed too) and an iPad. "Recognize All" results
  (`recognitionResults`) live in the model until the next run or `close()`, never on disk.
  A run writes each page only if its digest still matches (`RecognitionJob.ops`).
  Stepping is incremental: `SearchMatchCursor` keeps matches per page with the input they came from
  (recognition, items, place), so `refreshed` searches only changed pages and `matches(onPage:)` is a slice;
  `pagesForHighlight` caches its stale-judged pages (`highlightCache`) and judges only pages whose value or dirty flag changed.
- Favorites (`meta.favorite`): written only via `NoteOps.setFavorite` (CLI `notes favorite`, the app's
  `AppModel.setFavorite`); the sidebar's Favorites is `SidebarItem.favorites`. The note list's order
  (title, modified, created, favorites first) is the package's `NoteOrder`, shared with `notes list --sort`;
  never sort notes in the app by another rule. The quick-voice-notes notebook is
  the capture profile's alone (Settings ▸ Quick Voice Notes). The Mac's item commands (`duplicateItem`, `bringItemToFront`, `deleteItem`)
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
- Note `lang` and `markersBehindText` (`format.md` §5.4) are ordinary LWW registers
  (a snapshot records all nine clocks, the zero stamp for one never set), and writers omit their
  values when unset. Recognizers pass
  `meta.lang` to Vision (`RecognitionLanguage.preferred`, `VisionText.lines(language:)`).
  `markersBehindText` draws markers after background items and before content
  items (`PreparedPage.underIndex`; the canvas instead multiplies a copy of the
  text boxes over the ink, `MarkerOrder`). PDF page text is the pdfPage
  item's `pageText` register, kept in `extra` (`Item.pageText`): fill it with a
  `PDFTextExtracting` (`BuiltinPDFTextExtractor`, the CLI's `pdftotext`,
  the app's `PDFKitTextExtractor`) through `PDFIngest.withText`.
- Markdown text boxes (`format.md` §8.2.4 "Markdown text", §8.5.4): `markup: "markdown"`; the source
  IS the box's text (one run, no `breaks`), so a reader without Markdown shows and edits it as plain text. Readers ignore run
  attributes and `breaks` of such a box; `layout` (rendered breaks as SOURCE offsets) counts only when its `of`
  equals `MarkdownText.hash` of the text (an editor without Markdown keeps the field after changing the source); `math`
  entries match a formula by latex/display/size/color (stale ones are ignored, their blobs still referenced).
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
- Quick capture (`format.md` §11, `docs/quick-capture.md`): voice notes are sealed WITHOUT the device key or the
  vault key, with a capture profile (the vault identity's public `v_e` + `CaptureKey`, HKDF of `K_e`, which can only
  authenticate inbox files) into `inbox/<id>.capture.age`; adoption (`Vault.readCapture`, `CaptureAdoption`,
  `AppModel+Inbox`, `sempere inbox import`) turns them into ordinary revisions and blobs. Never store the vault
  key or an identity outside Face ID for capture. Note/page/recording ids derive from the capture id
  (concurrent adoption converges). Intents live in `Apps/Sempere/SempereShared/` (compiled by the app and the
  `SempereWidgets` extension, iOS only, `platformFilter = ios`) and run in the app's process; the profile is a
  Keychain item `AfterFirstUnlockThisDeviceOnly` (`KeychainCaptureProfileStore`, tests use
  `MemoryCaptureProfileStore`). Plaintext audio lives only in `QuickCapture.root`
  (`completeUntilFirstUserAuthentication`, `QuickCapture.protection`: Lock Screen notes are sealed from closed
  files before any unlock, which `completeUnlessOpen` forbids) until sealed and transcribed; running out of
  background time leaves it for `sweep()` rather than losing the note. Nothing rewrites `inbox/` files except
  catch-up, which re-seals this device's own captures of an earlier epoch from its ledger (format.md §15.14); a
  new epoch changes the capture key, and the profile must then be made again. A note "exists" for adoption once it has a revision (a folder holding only `att/` is still
  new), and a waiting transcript writes nothing. Quick-capture segments are ADTS (`QuickCapture.segmentExtension`:
  an MPEG-4 segment cut off by a restart or force quit does not decode at all), and a start activates the audio
  session BEFORE requesting the Live Activity (iOS ends the intent's fake-foreground assertion when the activity
  begins, and a non-mixable activation after that is refused '!int'; docs/quick-capture.md "Start order").
- Video items (`format.md` §8.2.7, task G2): a container is read only by
  `VideoProbe` (pure Swift, bounded reads, fuzzed); location metadata is
  removed in place by `ByteEdit`s applied while the file streams into the blob
  (`Vault.writeVideo`, `writeBlob(contentsOf:type:edits:)`), never by
  rewriting or loading the file. A clip is never held in memory: blobs stream
  (`BlobSource.stream`), PDFs with clips are written with `PDFWriter.write(…to:)`,
  Markdown/HTML copies with `ExportVideos.write`. Renderers and the app's item
  layer draw a video as its `poster` (an image blob, a register; `ItemRendering`
  acquires the poster, never the clip) under the play mark; the clip is fetched
  only to play (`AppModel.acquireVideo`, `releaseVideo` after; a partial copy fetches it then).
  Posters come from `VideoPoster` (AVFoundation, shared by the app and the CLI
  on macOS); the Linux CLI stores none without `--poster`.
- Equations (`math` items, `format.md` §8.2.8, task G1): the whole `math` object is ONE register
  (source, style, size, color, `render`, `renderSize`, `engine`); a value whose source or style
  changed carries a new render or none (`MathContent.withoutRender`, `typesetsLike`). Build edits
  with `NoteOps.math` / `placeMath` / `setMath` (frame follows the render at the same scale,
  `mathFrame`). Every LaTeX source goes through `MathSource.check` before any parser sees it.
  SwiftMath is in the app target only (exact 1.7.3), never in `Sources/`; the CLI has no typesetter
  and draws the stored render, else the source text. The app writes the render blob before the delta
  (`NoteEditor.insertMath` / `setItemMath`); undo restores old values without re-typesetting.
- Handwriting → math (G1 part 2): the pick (`InkLasso`), the
  conversion (`NoteOps.convertInk`: ONE delta of `removeStroke`s and the math item's `addItem`, render
  blob first), the model's image (`MathInkImage`, pure Swift in the app too, never PencilKit), the
  vocabulary, beam search and clean-up are shared by the app's Convert to Math and `sempere
  recognize-math`; the model runs only behind `MathRecognizing` (`CoreMLMathRecognizer`, `#if
  canImport(CoreML)`; tests use fakes and the tiny random model `Fixtures/math-tiny`, made by
  `tools/math-model/convert.py --tiny`). Models are `sempere-math-model/1` folders whose every file
  is checked against the manifest's SHA-256 (`MathModelStore`) before use; the app's catalog
  (`MathModelCatalog.entries`) pins each manifest's hash and is EMPTY until the maintainer settles the
  training-data question, so the app's downloader (`MathModels`, its only network code) never runs;
  offering a model also needs the Mac `network.client` entitlement and a privacy-policy change. The
  app removes converted ink through the ledger (`NoteEditor.takeInk` / `putInkBack`, like an erase),
  never by editing `pages` directly; undo and redo of a conversion pass `keepUndo` so `reloadInk`
  does not clear the undo manager in the middle of an undo. Our own lasso (`MathLassoController`):
  `InkLasso` picks the strokes, as in the CLI; `PKCanvasView.selection` (iOS 27) gives only ids
  picked by PencilKit's own rule, so it is not used.
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
  form and `comment:`). `PseudoLanguageLayoutTests` (a hosted unit test, Mac Catalyst only, so in
  the PR gate's `test-mac`) checks the main screens in double-length, right-to-left and Spanish at
  a narrow and a wide window, in process (`PseudoLanguageHarness.swift` swaps `NSBundle`'s string
  lookups; docs/localization.md "Checking layouts" has the limits). A new screen worth checking
  gets a `Screen` case there. `scripts/app.sh pseudo` (iPad, in `local-ci.sh --release`) and
  `pseudo-mac` (by hand) run the UI-test version.
- Sync targets (`AppModel+SyncTargets`, `AppModel+WebDAV`, docs/io.md "Sync targets in the app", "WebDAV vaults in
  the app"): every vault is a store vault (`VaultStore`, in the App Group container on iPhone and iPad,
  `VaultStoreRoot`); its targets (folder or WebDAV, any number) are `SyncTarget`s in the store's registry
  (`SyncTargetRegistry`, `<store>/.sync/<vault id>/`, shared with `sempere store target`), each with its own sync
  state and quarantine. A WebDAV vault is a store vault with a WebDAV target (`WebDAVLocationStore` is a view of
  the registry; `LocalCopy(folder:stateDirectory:)`). The app's one `SyncCoordinator` runs a `SyncSession` per
  (vault, target), every vault open or not, at most two runs at once; only the open, unlocked vault's runs are
  two-way, every other run is upload-only (nothing unverified is placed in a vault nobody unlocked). Folder runs
  go through `FolderTargetRun` (the CLI's `store sync`); never open a target folder in place. What a two-way run
  wrote locally (`SyncReport.changed`, `LocalChanges`) goes through `applySyncChanges`: `reconcile(scope:)` for the
  notes (open editors merge in place, RemoteMerge), the settings pass, inbox adoption, notebooks; a changed `vault.json`
  (an approval, a rename, a label) reopens the vault with the same keys, and until that reopen is applied (or for good if it fails) the open
  vault's runs only upload (`syncVaultStale`). Never write a store vault's `vault.json` or `settings.age` without
  its `VaultStore.writeLock` (`vaultWriteLock`; the engine holds it through `SyncOptions.localWriteLock`). The
  WebDAV password is only in the Keychain (`KeychainWebDAVPasswordStore`, keyed by target id); certificate pins
  are checked by `PinnedServerTrust` (Security, app only) behind the library's `WebDAVServerTrust` hook, never by
  disabling evaluation. `epochs/`, `joins/` and `keys/` are synced (KH4, `format.md` §15.15); key
  management in the app is KH5 (the device list; joins and takeovers next). Two-way runs record `synced` (`SyncOptions.recordSynced`, the app and the CLI). A folder target synced before that is gone is never recreated (`FolderTargetRun.check`).
  App tests use `FakeWebDAVRemote` (scripted), `EngineWebDAVRemote` (the real engine on a shared `MemoryStore`:
  `TwoDeviceSyncAppTests`), folders under `EvictingFolderProvider` (`AppModel.folderProvider`:
  `FolderTargetAppTests`) and `MemoryWebDAVPasswordStore`; the library's sync runs against wsgidav
  (`scripts/test-webdav.sh`).
- A folder copied in from another app's provider storage (`StorageLocation`) is read under one coordinated
  read, even when the provider does not report its files as ubiquitous.
- Folder targets (`FolderRemote`, `sempere sync folder`, docs/io.md "Folder targets in providers"): a
  provider's evicted file or a folder listed before its files is *arriving* (`RemoteEntry.availability`,
  `SyncReport.arriving`), never missing: the engine asks for it and waits at most `arrivalWait` per run,
  folders only for `unlistedTimeout`, and reports stalls after `arrivalStall` (`Arrivals.swift`). Never
  read a file a provider has not downloaded, and never nest two coordinated writes of one item (the second
  waits for the first for ever). Tests simulate providers with `EvictingFolderProvider` and
  `MemoryStore.Behavior.evictOnWrite`, never real iCloud.
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
- `RenderOutputVersion.current` (SempereRender) must be bumped in the same change whenever the
  bytes an exporter writes for the same note change (the moment you regenerate goldens or
  fixtures). Tree exports key each note's files on it (and on a hash of the program itself in the
  CLI), so a re-run after an upgrade renders again instead of keeping older files.
