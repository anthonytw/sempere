# Thin apps over the library

Decided by the owner on 2026-11-06. Move as much logic as possible out of `Apps/Sempere` into the
package, so that the iPad, iPhone and Mac apps are thin clients on top of the library. What stays in
the apps is views, UIKit/AppKit/SwiftUI glue and platform services. Each piece of logic exists once and
the CLI calls it too. The logic's tests then run on Linux with no simulator.

The inventory was taken on 2026-11-06, across 234 app source files and about 60k lines. Roughly 28k of
those lines can move:

| Area | Files | Lines | Movable |
| --- | --- | --- | --- |
| `AppModel` and the services it owns | 75 | 18.1k | ~13.9k |
| `NoteEditor`, items, editing commands | 75 | 20.2k | ~7.1k |
| Sync, capture, views, extension targets | 83 | 21.7k | ~7.2k |

## Rules

- **The library holds no user-facing text.** Logic returns typed values: an enum case with its data,
  such as `SyncProblem.folderUnreachable(path:)`. Each front end words them. The app localizes them
  through `SempereLocalization`; the CLI writes its own English. Tests assert on the values.
- **`SempereLocalization`** is a package target. It holds `Localizable.xcstrings`, moved from
  `Apps/Sempere/Localization/`, and the extensions that map library values to localized text. The app
  and the widget link it. `InfoPlist.xcstrings` and `AppShortcuts.xcstrings` stay in the app target,
  because the system reads them from the app bundle. **It is Apple-only.** Checked 2026-11-06 in
  `swift:6.4.2-noble`: SwiftPM on Linux has no rule for an `.xcstrings` resource (a warning, the file is
  not compiled), and Linux Foundation has no `String(localized:bundle:)`. So `Package.swift` declares the
  target only when not building for Linux (`#if !os(Linux)` around the target and its product). Nothing
  on Linux needs it, because the CLI stays English. Each library value's Spanish text is still checked on
  Linux, by `LocalizationCatalogTests` reading the catalog's JSON.
- **Platform services become protocols that the library declares and the app implements.** Each comes
  with a memory or no-op version for tests and the CLI:

  | Protocol | Wraps |
  | --- | --- |
  | `KeyValueStore` | `UserDefaults`, including change notification |
  | `PerfSink` | `os.Logger` and the `Perf` signposts |
  | `FolderBookmarks` | security-scoped bookmarks |
  | `FileCoordinating` | `NSFileCoordinator` |
  | `PlatformServices` | the `Platform.isMac` style flags, idle timer, haptics |
  | Existing | `DeviceKeyStore`, `CaptureProfileStore`, `WebDAVPasswordStore`, `WebDAVServerTrust`, `AudioCaptureBackend`, `AudioPlaybackBackend`, `PageRecognizing`, `MathRecognizing` |

- **`SempereAppCore`** is the new module for app-session state: `AppModel`, its extensions,
  `SyncCoordinator`/`SyncSession`, `VaultLibrary`, `NoteEditor`'s model half and the settings stores.
  It may use Observation (part of the Swift toolchain on Linux too). The hard rule in CLAUDE.md, that
  `Sources/` uses Foundation only, gains Observation for this module.
- **`SempereCaptureShared`** is a tiny module with no dependencies. It holds the voice-note status, the
  tap log and the status-item protocol, so the widget and the Mac status item do not link the whole
  core.
- **`NoteEditor` never names PencilKit in the library.** The canvas glue (`PKDrawing`, about 240
  lines) stays in the app, behind a widened `RemoteInkView` and a `NoteEditing` protocol.
- **Tests move with their code**, into `Tests/<Module>Tests` (Swift Testing is fine there). App tests
  that import UIKit, SwiftUI or PencilKit stay in the app's test target.

## Foundations in place (wave 3)

What the movers build on. Code that moves into the package takes these as parameters (or stored properties
of the type that moves), never the platform API itself, and its tests pass the memory versions.

### Strings: `SempereLocalization`

- `Sources/SempereLocalization/Resources/Localizable.xcstrings` is the catalog. The one file is compiled into
  the package's bundle and, as a resource of the app and widget targets (`project.pbxproj`, group "String
  Catalog"), into their main bundles. App code does not change: SwiftUI literals and `String(localized: "…")`
  look in `Bundle.main` and find the same strings. This was chosen over giving every view a `bundle:`, which
  would have touched every literal in the app.
- Code in the package looks up `String(localized: "…", bundle: .sempereLocalization)` or
  `SempereStrings.localized("…")`. A library value's wording is an extension in this target, such as
  `extension SyncProblem { public var localizedDescription: String }`. The target has no dependencies yet. The
  first such extension adds the module it words (the widget then links that module too), or it goes in a
  second, app-only target if the widget should stay small.
- Manual entries carry `"generatesSymbol" : false`. A package target generates symbols for them, and keys that
  map to one symbol fail the build (`docs/localization.md` "Files").

### The platform protocols

They are in `Sources/Sempere/Platform/` (module `Sempere`, so every module that moves code can reach them). The
app's implementations are in `Apps/Sempere/SempereApp/PlatformServices.swift`.

| Protocol | Library's own version | App's version | Wired now |
| --- | --- | --- | --- |
| `KeyValueStore` (`object`/`bool`/`integer`/`double`/`string`/`data(forKey:)`, `set`, `removeObject`, `observeChanges` → `KeyValueObservation`) | `MemoryKeyValueStore` | `UserDefaults` itself (retroactive conformance; change = `didChangeNotification` of that defaults) | `KeepScreenOn.isOn`, `IdleTimerKeeper` (follows the setting through `observeChanges`), `BlobCache.configuredMaxBytes(in:)`, `DrawingCache.configuredCapBytes(in:)`, `ObjectEraserSize.load(from:)`/`save(_:to:)` |
| `PerfSink` (`measure`, `event`, `log(level, category, message)`) | `NoPerfSink`, `MemoryPerfSink` | `AppPerfSink` (`Perf` signposts, `os.Logger`) | `DeviceClock`'s writer reads (wave 2), `BundleBitRepair.clear(log:)` |
| `FolderBookmarks` (`bookmark(for:)`, `resolve(_:mounting:)` → `ResolvedBookmark`, `startAccessing`/`stopAccessing`, `withAccess`) | `PathBookmarks` (a path, no scope) | `SecurityScopedBookmarks` (`options: []`; no `mounting` → `.withoutMounting`) | `AppModel.enableQuickCapture`, `isProfileFolder(_:_:bookmarks:)` |
| `FileCoordinating` (`coordinateReading`/`coordinateWriting`, `coordinatedRead`/`coordinatedWrite` taking an optional URL) | `UncoordinatedFiles` | `SystemFileCoordinator` (`NSFileCoordinator`, the `reconcile.coordinate` signpost) | `CloudVault.coordinatedRead`/`coordinatedWrite(files:)`, so every caller of those already goes through it |
| `PlatformServices` (`isMac`, `isPhone`, `setIdleTimerDisabled`, `play(HapticFeedback)`) | `HeadlessPlatform` (records what it was asked) | `AppPlatform` | `IdleTimerKeeper(platform:)`, `PageCanvasView.snapFeedback` |

The call sites that are left, by file in `Apps/Sempere/SempereApp/` (2026-11-07). Switch one when its code moves.
View code (`@AppStorage` in a `View`, UIKit glue) stays in the app and keeps the platform API.

- **`KeyValueStore`** (`UserDefaults`/`@AppStorage`): `AppCommands`, `AppModel`, `AppModel+SettingsSync`,
  `AppModel+Thinning`, `AppModel+TranscriptSearch`, `AppThemeWindows`, `AppearancePreferences`,
  `ColumnLayout`, `DragTestSettings`, `DrawingPaletteView`,
  `DrawingToolbox` (its `defaults:` parameter), `EraserPreference`,
  `ImagePreparation`, `InsertUI`, `MathEditor`, `MathModels`, `MathSettings`, `MouseInk`, `NoteCanvasView`,
  `NoteDragSource`, `NoteListView`, `NoteWindowView`, `PageCanvasHost+Appearance`, `PageCanvasView`,
  `PageLayoutChoice`, `PageRecognizer`, `PaperPreference`, `RecordingPreferences`, `RenderCache`, `RootView`,
  `SettingsGroups`, `SettingsSyncBridge`, `SettingsView`, `StatusItemBridge`, `ToolPalette`
  (and `DebugLaunch`, debug only).
- **`PerfSink`**: `Perf.begin`/`measure`/`event` in `AppModel`, `AppModel+Backup`, `+History`, `+ListUpdates`,
  `+Loading`, `+Reconcile`, `+RemoteMerge`, `+Thinning`, `BackgroundSync`, `ItemLayerView`, `ItemRendering`,
  `NoteEditor`, `PageCanvasView`; `os.Logger` in `AppModel+Inbox`, `+Notebooks`,
  `+SettingsSync`, `+Suspension`, `+SyncTargets`, `AppModelEnvironment`, `DragLog`, `FolderPicker`,
  `VoiceNoteStartLog`, `VoiceNoteTapLog`. Phases are `Perf.Phase` raw values, so a moved `Perf.measure(.x, …)`
  becomes `perf.measure("x", …)`.
- **`FolderBookmarks`** (bookmarks and security scopes): `AppModel`, `AppModel+Backup`, `+BulkExport`,
  `+DeviceNotices`, `+Import`, `+SyncTargets` (`FolderTargetAccess.open` resolves with `mounting:`), `+VaultDetails`,
  `+VaultStore`, `ExportSheet`, `FolderPicker`, `InsertUI`, `MathModels`, `NewVaultView`, `PDFPreparation`,
  `QuickCapture` (its profile's bookmark at setup), `VaultLibrary+App` (`VaultBookmark`, the backup folder's).
- **`FileCoordinating`**: the callers of `CloudVault.coordinatedRead`/`Write` (`AppModel+Backup`, `+Thinning`,
  `+VaultStore`, `NewVaultView`, `NoteEditor`) pass `files:` once their code is in the library. Quick capture's
  queue flush takes one already (`CaptureDelivery.flushQueue(…files:)`, the app passes `SystemFileCoordinator`).
  `Sources/SempereSync/UbiquitousFolderHooks.swift` calls `NSFileCoordinator` itself (Darwin only, already in the
  library): it can take a `FileCoordinating` when a second implementation is wanted.
- **`PlatformServices`**: `Platform.isMac`/`isPhone` in 33 files (they stay for views; logic that moves takes
  `platform.isMac`, as `NoteDevice.of(_:)` does: the app's `NoteDevice.current` passes `AppPlatform`).

### `SempereAppCore`

The package target and product exist (wave 3, 2026-11-07): Foundation, `Sempere`, `Age` and `SempereImporters`
(Observation once `AppModel` moves). The app links it; the widget does not. It holds, from the app:
`CanvasModes`, `NoteModes` (`NoteDevice`, `NoteMode`, `NoteModeInput`), `NoteToolbar` (and `PageMenu`),
`MenuCommand` and `MenuLayout`, the device settings (`RecordingSettings`, `TranscriptionSettings`, `NewNoteSettings`,
`UnusedAttachmentGroups`), `Expectations` (`OnboardingMemory`, `OnboardingPolicy`, `QuickTour`, `AboutInfo`),
`NoteListDiff`, and the demo generators (`DemoVault`, `DemoHandwriting`, `DemoSearchNotes`), which are `#if DEBUG`
so no release build has them. Their tests are `Tests/SempereAppCoreTests`.

Wave 4 (library and capture half, 2026-11-07) added: `VaultLibrary` (recents, the store's vaults, `create`),
`VaultLocator`, `FolderAccess`, `NewVaultRequest`/`CreatedVault`; the backup settings (`BackupRecord`, `BackupStore` on
a `KeyValueStore`, `BackupLocation`, `BackupReminder`'s dates, `BackupNotifying`, `BackupProgress`, `BackupRunControl`);
and quick capture's logic (`QuickCaptureLogic.swift`: `StoredCaptureProfile`, `CaptureProfileStore`,
`QuickCaptureError`, `RecordingManifest`, `CaptureSegments` with the seal's rule `plan`, `CaptureDelivery`). Vault
creation itself is `VaultCreation` in `Sempere` (no session state, and the CLI links `Sempere`, not this module):
`VaultLibrary.create` and `vault init`/`store create` call it (duplicate 4). The module now also depends on
`SempereSync` (placeholders) and `SempereRender` (the kit's `VaultInfo`).

The `QuickCapture` class itself, the start/stop/sweep state machine, stays in the app for now: it drives the app's
`RecordingSession` (`AudioRecorder.swift`, AVAudioSession observers and file protection, shared with the in-note
recorder that moves with `NoteEditor` in wave 5) and speaks `VoiceNoteStatus`, `VoiceNoteActions` and the tap log of
`SempereShared`, which the widget compiles and which wait for `SempereCaptureShared`. With those two in the package,
the class moves behind protocols for the Live Activity, the app's state and background time. Its decisions that need
no platform service are already in the module and tested on Linux.

Wave 4 (sync half, 2026-11-07) added the sync scheduling: `SyncCoordinator` (with `SyncTargetRef`), `SyncSession`
(with `SyncRunMode`, `SyncRunRequest`, `SyncRunCancel`) and `SyncStatus`. The module now also depends on `SempereWebDAV`. The coordinator takes its
platform services as parameters: `deliveries` (the app passes `QuickCapture.deliveredNotification`), `settings` (`UserDefaults.standard`, for the background tasks' fairness
record) and `perf` (`AppPerfSink`). A run that waits for the device's first unlock is recognized by the
`DeviceUnlockWaiting` protocol, which the app's `WebDAVPasswordError` adopts. The words stay in the app
(`SyncStatus+Text.swift`: `SyncStatus.headline`, `SyncStatus.text(for:)`, `ProviderUploads.errorText`,
`CertificateDate.reason`). `ProviderUploads` has no session state, so it went to `SempereSync`. The coordinator's
and the sessions' tests are `Tests/SempereAppCoreTests/SyncCoordinatorTests.swift`. Two rules are still in
`AppModel` and move in wave 5: a session's run closure is built by `AppModel+SyncTargets` and `AppModel+WebDAV`, and
it decides two-way only for `phase == .unlocked && !syncVaultStale`.

The words stayed in the app, next to the views that show them, so the string catalog's checks still see them
(`LocalizationCatalogTests` scans `Apps/`): `MenuCommand+Titles.swift` words `MenuCommand.titleKind(in:)`,
`DeviceSettings+Text.swift` the settings' choices and `StorageText`, `Expectations+Text.swift` the tour pages
(`TourPage.topic`), `VaultLibrary+App.swift`, `BackupSettings+Text.swift` and `QuickCapture+Text.swift` the errors,
progress, reminder and restore name of wave 4 (retroactive `CustomStringConvertible`, as `CloudVault+Live.swift`). So did the glue that reads the process or the bundle for the app: `OnboardingPolicy.automatic`
(debug launch variables), `OnboardingMemory()` (`UserDefaults.standard`), the transcription hooks
(`TranscriptionSettings.statusProvider` and the others, set at launch) and `DemoLaunch`.

## Duplicates to remove first

These are cases where the app and the CLI each implement the same logic, and the two can disagree.
Each one becomes a single implementation in the library that both call.

1. **The revision writer.** `NoteWriter`/`DeviceClock` in the app and `Vault.apply`/`writeDelta` in
   the CLI handle the clock and `seq` differently. Make one writer in `Sempere`. It keeps the app's
   rule of one `DeviceClock` per state file, which CLAUDE.md requires.
2. **Where a sync folder's vault copy goes.** Done: `FolderTargetPlacement.location` (SempereSync), the app's rule
   of 1.0.0, which the app's pickers and `sempere store target add --folder` / `store import --keep-syncing` call
   (`FolderTargetPlacementTests`). The CLI used to sync into the folder given itself.
3. **The importers.** Done: one list, `BuiltInImporters` (target `SempereImporters`, the only file naming an
   importer module), read by the app and by the CLI's `ImportRegistry` (one subcommand slot per entry). The CLI's
   own device-key files are `CLIDeviceKeyFiles`, no longer a second `DeviceKeyStore`.
4. **Sync problem classification** (`SyncStatus.problem(from:)` and `WebDAVSyncProblem.from`), the
   WebDAV connection check, how `SyncOptions` limits are filled in, the settings catalog accessors, and
   vault creation (`VaultLibrary.create` and `vault init`). Vault creation is done: `VaultCreation` (Sempere), the
   app's 1.0.0 behavior, with `VaultStore.folderName` as the one name rule. So are the catalog accessors: the CLI's
   own copies (the specs a device type uses, a spec's device types, what can be a setting key) are
   `SharedSettingsCatalog.specs(for:)` (nil: all), `SharedSettingSpec.deviceTypes` and
   `SharedSettingsCatalog.isSettingKey`; the app already read the catalog through the library.
   The sync parts are done (wave 4). A thrown error is
   classified once, by `WebDAVSyncProblem.from(error:)` (folder errors, then the certificate's dates as
   `.certificateDate`, then the server's). A finished run is assessed by `SyncRunAssessment`: its problems,
   whether it was cut short, and whether it counts as a last success. The app's sessions and `store sync` both read
   it. The connection check is `WebDAVConnection.probe` and `probeTarget`, used by the app's Test Connection and by
   `webdav check` and `store target add --check`. A failure's message is `WebDAVErrorText.message`. Run bounds are
   `SyncBounds`: the CLI's `--max-*` flags and the app's background bound fill `SyncOptions` through it. Tests:
   `SyncProblemsTests`.
5. **Editor operations.** Items, insert, math, video and recordings in `NoteEditor+*` duplicate the
   CLI's `Items`/`Attach`/`AttachVideo`/`Recordings`/`NoteEdit` commands. So do the app's image
   preparation and item drawing (`ImagePreparation`, `ItemRendering`), next to `ImageIngest` and
   `ItemRaster`.
6. **Thinning, the bulk-export driver, notebook rename, join approval, history rendering and the demo
   generators.**

## Waves

Each wave is one batch branch and one PR on Gitea. It passes the PR gate, plus the targeted app tests
for what it moved.

| Wave | Contents |
| --- | --- |
| 0 | **Tooling.** Port the scripts from `gh` to the Gitea API, and add the local release build and the GitHub squash commit (`docs/design/local-first.md`). |
| 1 | **Test cleanup** from the 2026-11-06 sweep. Delete the low-value tests. Move benchmarks into `<Module>Benchmarks` targets built on package-benchmark. Replace sleeps and wall-clock checks with injected clocks. Fix the two known flakes. Either wire up the UI tests that never run or delete them. |
| 2 | **Duplicates 1–3** above, the riskiest first, each with tests that pin the shared behavior. |
| 3 | **Leaves with no `AppModel` edge.** `CloudScan`, `CloudVault`'s download loop, `BlobCache`, `NoteListDiff`, `BundleBitRepair`, `AppSupport`, `CanvasModes`, the `Demo*` generators, `StrokeLedger`, `DrawingCache`, `EraserGeometry`, `MarkerOrder`, `NoteModes`, `NoteToolbar`, `DeviceSettings`, `MenuCommand`, `Expectations`. Also create `SempereLocalization` and the protocols. |
| 4 | **`BackupSettings`, `QuickCapture`'s state machine, `SyncSession`/`SyncCoordinator`, `VaultLibrary`**, and duplicate 4. |
| 5 | **The `NoteEditor` cut, then the `AppModel` family**, as one unit into `SempereAppCore`, together with duplicate 5. About 51 of the 84 app test files that build an `AppModel` move to Linux with it. |
| 6 | **The rest of the splits**, duplicate 6, and new CLI commands for anything the app can now do that the CLI cannot. |
| 7 | **CI.** Test targets split into logic and OS-dependent, hash-based skipping of unchanged targets, the lean Gitea gate, and the scheduled benchmark run. |

## Done when

- `Apps/Sempere/SempereApp` holds views, glue and the platform implementations of the protocols, and
  nothing else.
- No logic exists in both the app and the CLI.
- The app's test target holds only tests that need UIKit, SwiftUI, PencilKit or the screen.
