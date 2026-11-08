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
  tap log and the intents' hooks, so the widget does not link the whole core (wave 5b). The Mac status item's
  `StatusItemProtocol` stays a file the app and its bundle both compile (decided in the review of #20).
- **`NoteEditor` never names PencilKit in the library.** The canvas glue (`PKDrawing`, about 240
  lines) stays in the app, behind the editor's `NoteCanvas` type parameter and a widened `RemoteInkView`
  (wave 5, decided for good: a type parameter rather than the `NoteEditing` protocol first planned, see below).
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

- **`KeyValueStore`** (`UserDefaults`/`@AppStorage`): `AppCommands`, `AppModel+SettingsSync`,
  `AppModel+Thinning`, `AppThemeWindows`, `AppearancePreferences`,
  `ColumnLayout`, `DragTestSettings`, `DrawingPaletteView`,
  `DrawingToolbox` (its `defaults:` parameter), `EraserPreference`,
  `ImagePreparation`, `InsertUI`, `MathEditor`, `MathModels`, `MathSettings`, `MouseInk`, `NoteCanvasView`,
  `NoteDragSource`, `NoteListView`, `NoteWindowView`, `PageCanvasHost+Appearance`, `PageCanvasView`,
  `PageLayoutChoice`, `PageRecognizer`, `PaperPreference`, `RecordingPreferences`, `RenderCache`, `RootView`,
  `SettingsGroups`, `SettingsSyncBridge`, `SettingsView`, `StatusItemBridge`, `ToolPalette`
  (and `DebugLaunch`, debug only).
- **`PerfSink`**: `Perf.begin`/`measure`/`event` in `AppModel+Backup`, `+History`, `+Thinning`, `BackgroundSync`, `ItemLayerView`, `ItemRendering`,
  `NoteEditor`, `PageCanvasView`; `os.Logger` in `AppModel+Inbox`,
  `+SettingsSync`, `+Suspension`, `AppModelEnvironment`, `DragLog`, `FolderPicker`. Phases are `Perf.Phase` raw values, so a moved `Perf.measure(.x, …)`
  becomes `perf.measure("x", …)`.
- **`FolderBookmarks`** (bookmarks and security scopes): `AppModel+Backup`, `+BulkExport`,
  `+DeviceNotices`, `+Import`, `+VaultDetails`,
  `+VaultStore`, `ExportSheet`, `FolderPicker`, `InsertUI`, `MathModels`, `NewVaultView`, `PDFPreparation`,
  `VaultLibrary+App` (`VaultBookmark`, the backup folder's).
- **`FileCoordinating`**: the callers of `CloudVault.coordinatedRead`/`Write` (`AppModel+Backup`, `+Thinning`,
  `+VaultStore`, `NewVaultView`, `NoteEditor`) pass `files:` once their code is in the library. Quick capture
  takes one (`QuickCapture.files`, for `CaptureDelivery.flushQueue(…files:)`; the app passes `SystemFileCoordinator`).
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

The `QuickCapture` class itself, the start/stop/sweep state machine, moved in wave 5b (below).

Wave 4 (sync half, 2026-11-07) added the sync scheduling: `SyncCoordinator` (with `SyncTargetRef`), `SyncSession`
(with `SyncRunMode`, `SyncRunRequest`, `SyncRunCancel`) and `SyncStatus`. The module now also depends on `SempereWebDAV`. The coordinator takes its
platform services as parameters: `deliveries` (the app passes `QuickCapture.deliveredNotification`), `settings` (`UserDefaults.standard`, for the background tasks' fairness
record) and `perf` (`AppPerfSink`). A run that waits for the device's first unlock is recognized by the
`DeviceUnlockWaiting` protocol, which the app's `WebDAVPasswordError` adopts. The words stay in the app
(`SyncStatus+Text.swift`: `SyncStatus.headline`, `SyncStatus.text(for:)`, `ProviderUploads.errorText`,
`CertificateDate.reason`). `ProviderUploads` has no session state, so it went to `SempereSync`. The coordinator's
and the sessions' tests are `Tests/SempereAppCoreTests/SyncCoordinatorTests.swift`. The two rules that stayed in
`AppModel` (a session's run closure, built by `AppModel+SyncTargets` and `AppModel+WebDAV`, decides two-way only for
`phase == .unlocked && !syncVaultStale`) moved with it in wave 5b part 2 (below): both closures now read one rule,
`AppModelCore.syncRunKeys(for:)`, pinned on Linux by `SyncRunRuleTests`.

Wave 5 (editor half, 2026-11-07) moved the `NoteEditor`'s model half: `NoteEditorModel<Canvas: NoteCanvas>`
(`Sources/SempereAppCore/NoteEditor/`), with loading and the drawing cache, autosave, page and item gestures,
images, PDFs and video, merges, recognition, recordings' data (save, place, rename, remove, playback highlight)
and search highlights. The seam is a type parameter rather than the `NoteEditing` protocol first planned, and it stays (decided in the
review of #18): the editor keeps
each page's canvas drawing next to the page's `StrokeLedger`, one canvas stroke per entry, and a merge, the end of a
cached open and ink taken off a page change both in one main-actor turn, so the drawing type has to be the
editor's own (`NoteCanvas.Drawing`, `CanvasStroke`) rather than state behind a protocol the app implements.
`NoteCanvas` also carries the conversion (`convert`, `matches`, `encode`/`decode` for the cache), the ledger update
of a canvas drawing, the text layout and matcher, and the app's hooks (the running recording's stamp, the part of a
page on screen, close, a removed recording, a failed rename or delete). The app's `NoteEditor` is
`NoteEditorModel<PencilCanvas>` (`PencilCanvas.swift`), whose per-editor state (canvas target, the math lasso and
its request, the recording session and player, recording errors) is `NoteEditorAppState`, read through
forwarding properties so no view changed. The library holds no words: `NoteReadOnly`, `saveFailure`,
`RecognitionPassFailure` and `RecordingChangeFailure` are worded in `PencilCanvas.swift`. `RemoteInkView` and
`PageRecognizing` are the package's; `PerfSink` gained `begin`/`end`. Still in the app: the microphone half of
recording (`NoteEditor+RecordingSession`: `RecordingSession`, `RecordingAssembly`, AVFoundation), typesetting
(`NoteEditor+Math`, `+Markdown`, `+MathInk`: SwiftMath, TextKit, UndoManager). The editor's tests are
`Tests/SempereAppCoreTests/NoteEditor` on a canvas of stored strokes (`TestCanvas`). `AppModel` is unchanged and
moves next.

Wave 5b, part 1 (capture, 2026-11-07) moved quick capture's state machine and what the widgets share with the app:

- **`SempereCaptureShared`** (`Sources/SempereCaptureShared`, Foundation only; a product the app and the widget link,
  and the widget does not link `SempereAppCore`): `VoiceNoteStatus` (with `VoiceNoteLink`, `VoiceNoteResult`,
  `VoiceNoteStatusStore`), `VoiceNoteActivityState` (the Live Activity's state, the same JSON as before), the intents'
  hooks `VoiceNoteActions` with `VoiceNoteStartSource`, `VoiceNoteStartRequest` and `VoiceNoteIntentError`, and the tap
  log (`VoiceNoteTap`, `VoiceNoteTapLog`; its unified-log lines go through the `VoiceNoteTapLog.logLine` hook, which
  `VoiceNoteTapLog+Logger.swift` in `Apps/Sempere/SempereShared` installs at launch in the app and the widget, because
  the module has no dependency to take a `PerfSink` from and `Sources/` imports no `os`). Its tests are `Tests/SempereCaptureSharedTests`. Still in
  `Apps/Sempere/SempereShared/`, which the app and the widget compile: the intents (AppIntents, with
  `VoiceNoteActions.startOrContinueInApp` and the text of `VoiceNoteIntentError`), `VoiceNoteAttributes` (ActivityKit,
  `ContentState = VoiceNoteActivityState`), the unified-log hook and the surfaces' words (`VoiceNoteStatus+Text.swift`: the status's
  `title` and `subtitle`, the result's `title` and `detail`).
- **`QuickCapture`** (`Sources/SempereAppCore/QuickCapture/`): the class, and the start diagnostics (`VoiceNoteStartLog`
  and its records, which log through `PerfSink`). Its platform is behind protocols in `QuickCapturePlatform.swift`,
  each with a version for tests and the CLI:

  | Protocol | Wraps (app) | Why a seam of its own |
  | --- | --- | --- |
  | `CaptureAudio` → `CaptureRecorder` → `CaptureRecording` | the microphone permission and the preferred format; per start, an `AudioCaptureBackend` and the audio session; the `RecordingSession` it records into, its files protected `completeUntilFirstUserAuthentication` | the start order (session before the Live Activity, the mixable retry) is the library's, the AVFoundation calls and the file protection class are the app's |
  | `CaptureAudioFiles` | `AVURLAsset` (what a segment holds), `RecordingAssembly.merge` | the seal's rule (`CaptureSegments.plan`) is the library's; decoding is AVFoundation |
  | `CaptureLiveActivity` | ActivityKit (`Activity.request`/`update`/`end`, orphans) | iPhone and iPad only; the app keeps the activity id and the ordered updates |
  | `CaptureAppState` | `UIApplication` state, protected data, `AppActivation.wait` | the decision to continue in the app is the library's |
  | `BackgroundTime` | `beginBackgroundTask` | the seal runs on borrowed time |

  The existing protocols cover the rest: `FolderBookmarks` (the profile's bookmark), `FileCoordinating` (a coordinated
  queue flush) and `PerfSink` (the start log). `RecordingTranscribing` moved into the module (the app's
  `SpeechRecordingTranscriber` adopts it). A refusal that may work in front is `CaptureStartRefusal` (the app's
  `RecordingError.cannotRecord`). The time and the banner's and heartbeat's waits are parameters (`now`, `sleep`), so
  tests wait on nothing. No words: the banner's titles are `Notice.Kind`, a kept recording is `Outcome.kept` and
  `Notice.kept`, a seal's own failures are `CaptureAssemblyError`, and the default title of a voice note is the app's
  (`noteTitle`); `QuickCapture+Text.swift` words them as before.
- **In the app** (`QuickCapture+App.swift`): `QuickCapture.shared`, made with the app's services by `QuickCapture.app()`;
  `register()` (the intents' hooks, the ActivityKit and protected-data observers); `KeychainCaptureProfileStore`;
  `AppCaptureAudio` and `AppCaptureRecorder` (`RecordingSession` with `QuickCapture.protection`); `AVCaptureAudioFiles`;
  `SystemLiveActivity`; `UIKitCaptureApp` and `UIKitBackgroundTime`. `AppActivation` stays (UIKit), and so does the
  in-note recorder (`NoteEditor+RecordingSession`, `RecordingSession`, `RecordingAssembly`: AVFoundation).
- **Decided in the review of #20**: file protection stays part of the recorder's contract (the recorder is what
  creates the files), not a protocol of its own. Both end-to-end capture tests stay: the package's on fakes (Linux)
  and the app's on the real recorder and AVFoundation. `VoiceNoteActivityState.saving` and
  `StoredCaptureProfile.suspended` stay optional: 1.0.0 compatibility. `StatusItemProtocol` stays a file the app and
  the Mac menu-bar bundle both compile: the bundle is a native macOS plug-in in the app's process, and linking a
  package product into both would put two copies of the module in one process. Quick capture no longer accepts
  `segment-NNN.m4a` leftovers (build 6 and earlier; no such data exists from 1.0.0 on).
- **Tests**: the state machine's are `Tests/SempereAppCoreTests/QuickCapture` (`QuickCaptureFlowTests`,
  `QuickCaptureStartTests`), on the fakes of `CaptureTestKit.swift` and one fixture vault copied per test. The app
  keeps what needs AVFoundation (ADTS cut-offs and merges, the zero-length segment, the real session's interruptions
  and file protection), ActivityKit, the intents (AppIntents), `AppActivation`, and the `AppModel` ones (wave 5b, part 2).

Wave 5b, part 2 (the first half of the `AppModel` family, 2026-11-07) moved the class itself:

- **`AppModelCore<Host: AppModelHost>`** (`Sources/SempereAppCore/AppModel/`): the stored state, opening, unlocking,
  the editor's open and close, `close()`, and the extensions every other part calls: `+Loading`, `+ListUpdates`,
  `+Reconcile`, `+RemoteMerge`, `+PublishedSummaries`, `+Join` (partial copies), `+Search` (search and Recognize All
  Notes), `+TranscriptSearch`, `+Activity` (`RecentActivity`), `+Notebooks`, `+ReadOnly` (the rules; the banner's words
  are the app's), `+Edits` (the sidebar's edits: create, rename, move, tags, delete; the drags stay in the app's
  `AppModel+Browser`), `+SyncTargets` and `+WebDAV` (the run closures and `syncVaultStale`), with what they need:
  `VaultIndex` (`VaultEnumeration`, `IndexDiff`), `UnlockKeys`, `ListAlert`, `DeviceWriteStores` (the Keychain-backed
  `app(storeRoot:)` stays in the app), `DeviceJoinError`, and the WebDAV types (`WebDAVTypes.swift`: `WebDAVRemote`,
  `WebDAVEndpoint`, `WebDAVLocationStore`, `WebDAVPasswordStore`, the download status; `LiveWebDAVRemote`,
  `PinnedServerTrust`, `WebDAVReachability` and `KeychainWebDAVPasswordStore` stay in the app).
- **Generic over a host**, as the editor is over its canvas: the app's `AppModel` is `AppModelCore<AppHost>`
  (`AppModel+Host.swift`), so no view and no app extension changed its spelling. The host gives the canvas
  (`NoteEditorModel<Host.Canvas>`), the platform services (`AppModelServices`: `PerfSink`, `KeyValueStore`,
  `FolderBookmarks`, `PlatformServices`, the WebDAV remote and passwords, `CloudVault.Hooks`, the transcriber and the
  revisions' `app` name; the app's are `UserDefaults.standard`, the Keychain, the network, as before; tests get
  `AppModelServices.headless()`) and, until part 3, two seams for the extensions still in the app:
  - `Host.State`: their stored state whose types are the app's (`AppModelAppState`: the drag payload, export and import
    requests, background tasks, reachability, the render cache, the item clipboard, takeover and settings-sync alerts,
    …), read through forwarding properties on `AppModel`. Stored state whose type is the library's is in the class even
    when only app-side code uses it yet.
  - the host's steps (`AppModelHost`'s requirements, no defaults: a host that forgets one does not compile): what
    `didUnlock`, `adoptReopened`, `close()`, the editor's open, the listing and the sync runs call in the app's code
    (quick-capture profile, inbox, takeovers and device state, backup reminder, settings sync, attachments and their
    index, recordings, thinning, note windows).
  `FolderBookmarks` gained `recordedPath(of:)` (a folder target on an absent drive is offline, not gone).
- **Words**: `AppModel+Text.swift` words `AppModelError`, `AppModelNotice` (the two `errorMessage`s of a reopen),
  `SyncTargetProblem`, `WebDAVVaultError`, `WebDAVPasswordError`, `NoteSort`, `SearchScope`, the progress headlines,
  `WebDAVLeftover` and the read-only banner, unchanged.
- **Public surface**: every member of the moved files that was internal is public, because the views and the app-side
  extensions (part 3) use the class through another module. Part 3 can narrow it to what the views read once nothing
  else is left in the app.
- **Tests**: `Tests/SempereAppCoreTests/AppModel` (one `.serialized` parent suite, `AppModelSuites`; fixture vaults copied
  off the main actor, `ModelFixture`) holds `IndexTests`, `ListEpochTests`, `MassChangeTests` and the parts of
  `AppModelTests`, `BrowserTests`, `SearchTests` and `VaultOpeningTests` that need no app-side code, on a host of their
  own (`TestHost`, `AppModelTestKit.swift`), plus `SyncRunRuleTests` (the two run rules, and that a stale open vault's
  runs place nothing). The rest of those files stays in the app until what they touch moves.

Wave 5b, part 3, steps 1 and 2 (attachments and recordings, 2026-11-08) moved:

- **Attachments** (`AppModel+Attachments`, `+AttachmentIndex`): the blob cache, the prefetch policy (`BlobFetchPolicy`),
  blob fetches of a partial copy, the item clipboard (`ItemClipboard`; `clipboardPaste(onto:of:)` gives the entry, its
  offset and the blobs' fetch, and the app's `ItemActions.paste` writes it with its undo step) and the
  unused-attachments index. The render cache is the library's `RenderStore<Codec>` (labels, sealed files, the memory
  and disk limits, `schemaVersion`); the app's `RenderCache` is `RenderStore<CGPictureCodec>` (`RenderPicture`, JPEG
  and LZFSE encoding, the PDF preview drawing, the fonts' salt, UIKit's memory warning). The model keeps it as
  `any RenderCaching` (`close`), made by `AppModelServices.makeRenderCache`; the item layer takes it back as the app's
  type (`itemLayerSource`). `AttachmentDeletion.problems` are typed (`Problem`: the note and why), worded by the app
  with the note's title (`AppModel+Attachments.swift`).
- **Recordings** (`AppModel+Recordings`): playback (`RecordingPlayer`, `AudioPlaybackBackend`; the editor holds its
  `player`), transcripts (load, transcribe, store), and recovery of recordings a crash left (`RecordingRecovery`, which
  reads the segment files through `CaptureAudioFiles` and leaves alone the recordings `recordingsInUse` names).
  `AppModelServices` gained `makePlaybackBackend` (`AVAudioPlaybackBackend`), `recordingRoot`
  (`RecordingSession.root`), `recordingsInUse` (`RecordingSession.active`/`busy`) and `audioFiles`
  (`AVCaptureAudioFiles`). The microphone half stays in the app: what happens to a recording made in a note once
  saved (`configureRecordingSaves`, the `prepareEditor` step) asks the model `transcribesSavedRecordings` and
  `transcribeSaved`. `RecordingTranscriptionError` is the library's; its sentence, and the errors' (new
  `AppModelNotice` cases: `recordingUnplayable`, `recordingUnreadable`, `recordingNotTranscribed`,
  `transcriptionModelMissing`), are the app's; a failed recovery is `RecordingChangeFailure.recover`.
- **Host steps gone**: `vaultChanged`, `noteWritten`, `summariesRead`, `notesRemoved` (the core calls the index and
  `dropAttachments` itself) and `play`. `AppModelAppState` lost the render cache, the clipboard, the playback backend
  and the recording root.
- **Tests**: `AttachmentIndexTests`, `AttachmentCacheTests`, `RenderStoreTests` (in `AttachmentCacheTests.swift`), `RecordingModelTests` and
  `TranscriptSearchTests` (all of the former `TranscriptSearchAppTests`) in `Tests/SempereAppCoreTests/AppModel`. The
  app keeps Settings' storage words (`AttachmentIndexAppTests`), the CoreGraphics codec and drawing
  (`AttachmentPersistenceTests`), the recording session (`RecordingTests`), the missing-model sentence
  (`OfflineTranscriptionTests`) and the 600-transcript device check (`TranscriptSearchDeviceCheckTests`).

**Wave 5b, part 3 (the rest of the plan).** Steps 1 and 2 are done (above). The rest of the family, in an order that
empties `AppModelAppState` and the host's steps:

3. Inbox and settings sync (`+Inbox`, `+SettingsSync`): `QuickCapture.shared` as a service, `SettingsSyncBridge`'s pure
   part, the app icon behind `PlatformServices`; `SettingsSyncAppTests`.
4. Devices, joins and re-encryption (`+Devices`, `+DeviceNotices`, `+JoinDevice`, `+Reencrypt`, `+Keys`, `+ListAlert`):
   `OwnerAuthenticator` as a service, `TakeoverAlert`, `SightingRow`, `UndoneRemoval` into the library; with them
   `WebDAVAppTests`, `TwoDeviceSyncAppTests`, `JoinAppTests`, `DevicesAppTests` and `JoinTakeoverAppTests`, whose shared
   fakes (`FakeWebDAVRemote`, `EngineWebDAVRemote`) move as one.
5. Vault store, backups, thinning, history, export and import (`+VaultStore`, `+Backup`, `+Thinning`, `+History`,
   `+Export`, `+BulkExport`, `+Import`, `+OpenedFiles`, `+Storage`, `+VaultDetails`): `UTType` and `CGRect` uses become
   library values; `FolderTargetAppTests`, `BackupAppTests`, `ReadOnlyVaultTests`, `VaultStoreAppTests`.
6. App lifecycle and windows (`+Background`, `+Suspension`, `+Windows`, `+MenuBar`, the drags of `+Browser`): the
   background-task and lifecycle protocols move, UIKit's implementations stay; `DragPayload`/`DropTarget` leave
   `SidebarDrop.swift`. "Keep Screen On" (`editorsChanged`, the UIKit `IdleTimerKeeper`) follows the open editors
   through `PlatformServices.setIdleTimerDisabled`.
7. Then `AppModelAppState`, the host's steps and `Host.State` go; `AppHost` keeps only the canvas and the services, and
   the public surface is narrowed to what the views use. The words still made for the model go with them:
   `unreadableText` returns words, so `editorFailure` becomes a typed value the detail pane words; `errorMessage` and
   `loadFailure` are strings today whose text comes from the app's `@retroactive CustomStringConvertible`
   conformances (`AppModelError`, `AppModelNotice`, …), and become typed values the views word.

The words stayed in the app, next to the views that show them, so the string catalog's checks still see them
(`LocalizationCatalogTests` scans `Apps/`): `MenuCommand+Titles.swift` words `MenuCommand.titleKind(in:)`,
`DeviceSettings+Text.swift` the settings' choices and `StorageText`, `Expectations+Text.swift` the tour pages
(`TourPage.topic`), `VaultLibrary+App.swift`, `BackupSettings+Text.swift` and `QuickCapture+Text.swift` the errors (and, since wave 5b, the banner's titles and the kept-on-device line),
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
   `ItemRaster`. Done (wave 5): the frames, z order, pages and ops were already the `NoteOps` builders on both
   sides; what each side did on top of them is now shared where it was the same rule. Image bytes:
   `ImageIngest.prepare(_:privacy:converter:)` (SempereRender), the app with its ImageIO `ImageIOConverter`, the
   CLI without one. A recording's rename: `NoteOps.renameRecording`. A file's planned blob reference:
   `Vault.blobRef` (the app's own `BlobPlanning` hash went). Item drawing: `ItemScale`, `ItemRenderKey` and
   `ItemRaster.drawnBlobs(of:)` (SempereRender); `ItemRendering` keeps the CoreText and ImageIO drawing. What
   stays different is the platform's, not a rule: the app places on what is on screen (`viewFrame`,
   `unoccupied`) where the CLI takes flags, lays text out with TextKit, and typesets equations.
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
