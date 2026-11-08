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
  `AppThemeWindows`, `AppearancePreferences`,
  `ColumnLayout`, `DragTestSettings`, `DrawingPaletteView`,
  `DrawingToolbox` (its `defaults:` parameter), `EraserPreference`,
  `ImagePreparation`, `InsertUI`, `MathEditor`, `MathModels`, `MathSettings`, `MouseInk`, `NoteCanvasView`,
  `NoteDragSource`, `NoteListView`, `NoteWindowView`, `PageCanvasHost+Appearance`, `PageCanvasView`,
  `PageLayoutChoice`, `PageRecognizer`, `PaperPreference`, `RecordingPreferences`, `RenderCache`, `RootView`,
  `SettingsGroups`, `SettingsSyncBridge`, `SettingsView`, `StatusItemBridge`, `ToolPalette`
  (and `DebugLaunch`, debug only).
- **`PerfSink`**: `Perf.begin`/`measure`/`event` in `AppModel+History`, `BackgroundSync`, `ItemLayerView`, `ItemRendering`,
  `NoteEditor`, `PageCanvasView`; `os.Logger` in `AppModel+Inbox`,
  `+SettingsSync`, `+Suspension`, `AppModelEnvironment`, `DragLog`, `FolderPicker`. Phases are `Perf.Phase` raw values, so a moved `Perf.measure(.x, …)`
  becomes `perf.measure("x", …)`.
- **`FolderBookmarks`** (bookmarks and security scopes): `AppModel+BulkExport`,
  `+DeviceNotices`, `+Import`, `ExportSheet`, `FolderPicker`, `InsertUI`, `MathModels`, `NewVaultView`, `PDFPreparation`.
  (`VaultBookmark` went in step 5a: the backup folder's bookmark is `services.bookmarks`.)
- **`FileCoordinating`**: the callers of `CloudVault.coordinatedRead`/`Write` (`NewVaultView`, `NoteEditor`) pass
  `files:` once their code is in the library; the model's copy-in, restore and thinning read `services.files` (step 5a). Quick capture
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

Wave 5b, part 3, step 3 (inbox and settings sync, 2026-11-08) moved:

- **Inbox** (`AppModel+Inbox`): the quick-capture profile on the model's side (`QuickCaptureSetting`, the switch's
  states, turning it on and off, the refresh after a key change, `syncQuickCaptureSuspension` from `+DeviceNotices`,
  `isProfileFolder` on `services.bookmarks`), `quickCaptureBecameActive`, and adoption of the inbox (the delivery
  observer, `adoptInbox`, transcription of captures without a transcript). The capture is `quickCapture`, made by
  `AppModelServices.makeQuickCapture` (the app's `QuickCapture.shared`; headless, `QuickCapture`'s defaults in the
  model's scratch folder) and copied to the model property, which tests replace. Its sentences are new
  `AppModelNotice` cases (`inboxUnreadable`, `voiceNoteNotAdded`, `voiceNoteUnreadable`), worded by the app as before.
- **Settings sync** (`AppModel+SettingsSync`): the passes, the switch and the rows, on `services.settings` (the
  `UserDefaults` observer became `KeyValueStore.observeChanges`; the `settingsDefaults` seam and its
  "standard or not" branches are gone). `SettingsSyncProblem` and `SettingsSyncPrompt` are the library's; the
  problem's sentence (`text`) is the app's. `SettingsSyncBridge`'s pure part is the library's (`SettingsSyncBridge`:
  the device type, `Extras`, `modelKeys`, the values loop and the split of `apply`), and it reads the model's own keys
  itself (`RecognitionPreference` moved into the library for that); every other key goes through
  `SettingsSyncStorage`, a service (`AppModelServices.settingsStorage`): the app's `AppSettingsStorage` (the
  `UserDefaults` table of 1.0.0, unchanged; its preference types now read `any KeyValueStore`), headless
  `StoredSettingsSyncStorage` (JSON per key, the catalog default when unset). The app icon is behind
  `PlatformServices` (`appIcon`, `setAppIcon`; `AppPlatform` wraps `UIApplication`'s alternate icons), and
  `setHandwritingRecognition` is the model's, its Vision recognizer from `AppModelServices.makePageRecognizer`.
- **Pulled forward from step 5**: the backup reminder (`AppModel+BackupReminder`: `setBackupReminder`,
  `rescheduleBackupReminder`), because settings sync applies `backup.reminderDays`. `BackupNotifying.schedule` takes a
  typed `LocalNotice` (`.backupReminder(vaultName:record:)`, `.takeover(TakeoverAlert)`), worded by the app's notifier
  (`LocalNotice.text`); so `TakeoverAlert` moved into the library now too (its `title` and `message` stay the app's).
  The backups themselves stay in the app until step 5.
- **Host steps gone**: `scheduleSettingsSync` and `startInboxAdoption`; `didUnlock`, `didReopen` and `willClose` keep
  only takeovers and the device state (step 4) and the app-side state of the vault. `AppModelAppState` lost
  `quickCapture`, `settingsSyncProblem`, `settingsSyncPrompt` and `settingsDefaults`.
- **Tests**: `SettingsSyncTests` (the model's passes of the former `SettingsSyncAppTests`, on `StoredSettingsSyncStorage`,
  plus the model's own keys and a change picked up without being asked) and `InboxTests` (the parts of `QuickCaptureTests`
  that need no recorder) in `Tests/SempereAppCoreTests/AppModel`. The app keeps `AppSettingsStorage`'s round trips
  (`SettingsSyncAppTests`) and what records with the app's recorder (`QuickCaptureTests`).

Wave 5b, part 3, step 4a (devices, joins and re-encryption: the model's code, 2026-11-08) moved:

- **`+Devices`, `+DeviceNotices`, `+JoinDevice`, `+Reencrypt`, `+Keys` and the model's half of `+ListAlert`** into
  `Sources/SempereAppCore/AppModel/`: the device list and its changes (`performDeviceChange` and the pull before it),
  takeover alerts, the banners, the unlisted screen's facts, Repair (set-aside files, sightings), joins and takeovers,
  Re-encrypt Everything's start and steps, and their types (`DeviceRow`, `DeviceListSnapshot`, `DeviceChangeOutcome`,
  `UnreachableTarget`, `DeviceNotice`, `UndoneRemoval`, `UnlistedFacts`, `SightingRow`, `JoinStage`, `JoinReply`,
  `JoinRequestLookout`, `JoinDelivery`, `TakeoverDraft`, `ReencryptProgress`, `VaultDevice`). Note windows go through the
  host's existing `closeWindowEditors`/`openWindowNote` steps.
- **This device's keys and the owner check, as protocols** (`Sources/SempereAppCore/DeviceKeyStore.swift`):
  `DeviceKeyStore` with `MemoryDeviceKeyStore` and `DeviceKeyStoreError`; `OwnerAuthenticator` with `ScriptedOwnerCheck`
  (tests; it records what it was asked) and `OwnerCheckUnavailable`. Reads and checks take typed reasons
  (`DeviceKeyReason`: unlock, join, takeover, a withdrawn join; `OwnerCheckReason`: a passphrase copy, an approval, a
  kit replacement, a re-encryption), worded as the prompts by the app (`DeviceKeyReason.text` in `DeviceKeyStore.swift`,
  `OwnerCheckReason.text` in `KeyExport.swift`), same strings. The Keychain store, the Secure Enclave signer and
  `SystemOwnerAuthenticator` stay in the app. The owner check is `AppModelServices.ownerAuthenticator` (headless: none can
  be asked, every check fails), copied to the model's `ownerAuthenticator`, which tests replace.
- **`ThisDevice` behind `PlatformServices`**: `deviceKind` and `deviceName` (the app's `AppPlatform` answers with
  `ThisDevice`; `HeadlessPlatform` with its flags and a name it is given). The kind's rule is `DeviceKind.of` (Sempere),
  which `ThisDevice.kind(isMac:isPhone:)` calls.
- **Typed values the app words** (`Devices+Text.swift`): `AppModelKeyError` (`AppModel.KeyError`), `KeyProblem`
  (`.recoveryKeyNeeded`: Add Passphrase Copy now takes the identity, `nil` when none was given; the sheet passes
  `ExistingKeyInput.Status.identity`), `DeviceNotice.text`/`symbol`, `DeviceRow.symbol`, `JoinDelivery.text`,
  `DeviceJoinError.description` and `TakeoverAlert`'s words. Re-encryption's refusals are `ReencryptRefusal`
  (`.targetUnreachable(name:error:)`, `.targetCannotBeOpened`), worded by `DeviceChangeText.message`, so no localized
  text sits inside an English `VaultError` any more. `AddDeviceApproval` stays in the app as the sheet's model
  (`AddDeviceApproval.swift`); `ListAlert`'s words are `ListAlert+Text.swift`.
- **`takeoverDefaults` is `deviceMemory`**: `services.settings` copied to a model property (acknowledged takeovers,
  remembered device names, the join marker; read with `object(forKey:) as? [String]`), which tests replace.
- **Host steps gone**: `didUnlock`, `didReopen`, `reopenIfUnlisted` and `refreshDeviceState` (the core checks takeovers
  and reads the device state itself). `willClose` keeps only the app's own state. `AppModelAppState` lost
  `takeoverAlert`, `takeoverDefaults`, `ownerAuthenticator`, `sightingRowsState` and `undoneRemovalsSource` (now
  `UndoneRemoval.recorded` by default).
- **Tests**: `DevicesTests` in `Tests/SempereAppCoreTests/AppModel` (the model's half of `DevicesAppTests`, the
  passphrase copy of `PassphraseCopyAppTests`, the three vault-without-targets cases of `ReencryptAppTests`, the
  memory store of `JoinTakeoverAppTests`; new: a join named from the platform, the owner check's and the key store's
  reasons, a failed owner check, removals a takeover undid, the takeover notification), on `DeviceWorld` (made off the
  main actor). The app keeps the words (`DevicesAppTests`: history lines, the takeover alert, the typed refusals, the
  removal sheet, the kit line check) and every suite that needs `RememberedKeys` or the WebDAV fakes (below).

Wave 5b, part 3, step 4b (the unlock sheet's model and the sync suites, 2026-11-08) moved:

- **`RememberedKeys`** (`Sources/SempereAppCore/AppModel/RememberedKeys.swift`): unlocking with this device's keys, the
  join stage, forgetting keys, the created vault's keys and "Require Face ID". Its methods are generic over the host
  (`AppModelCore<Host>`), so the class keeps its name and the views their spelling. The key problems are typed:
  `Attempt.keyProblem(DeviceKeyProblem)` (`.unreadable`, `.expired`, `.stray`) and `Attempt.failed(DeviceUnlockFailure)`
  (`.keysNotRead`, `.keysDidNotUnlock`, carrying the error), worded by the app as before (`RememberedKeys+App.swift`:
  `DeviceKeyProblem.text`, `DeviceUnlockFailure.text`, plus the Keychain store as the default, `deviceName`, `name(isMac:isPhone:)`
  and `biometryName`, which need `LocalAuthentication`). `Attempt` is no longer `Equatable` (its failure carries an error).
- **The owner check is the model's for every change that needs it**: `replaceRecoveryKit` and `startReencryption` ask
  `ownerAuthenticator` themselves (`.replaceRecoveryKit`, `.reencrypt`; after the unlocked and writable checks, before
  anything else), as `addPassphraseCopy` and `approveDevice` already did, so no front end can leave it out.
  `ReplaceKitSheet` lost its own check, so the prompt now comes when the change is made (design §6.5 step 3), not before
  the new kit is shown; the vault is checked again after it (`checkOwner`: on Mac Catalyst the passcode dialog leaves
  the menus usable, so another vault may be open by then).
  The headless default is `NoOwnerCheck` (every check throws `OwnerCheckUnavailable`).
- **Add WebDAV Server…** (`probeWebDAVTarget`, `addWebDAVTarget`; `AppModel+WebDAVTarget.swift`), pulled forward from
  step 5 for its test. Its "holds another vault or other files" refusal is `SyncTargetProblem.serverFolderTaken`, worded
  as the same sentence.
- **Tests, moved as one** into `Tests/SempereAppCoreTests/AppModel` with their fakes (`WebDAVTestKit.swift`:
  `FakeWebDAVRemote`, `FolderDAVTransport`, `EngineWebDAVRemote`, and `WebDAVFixture` for the listing, the server's seed,
  a big attachment and a model's WebDAV settings, all off the main actor): `WebDAVTests` (and the WebDAV case of
  `VaultDetailsAppTests`), `WebDAVPartialTests`, `TwoDeviceSyncTests`, `JoinTests`, `UnlistedOverSyncTests` (its quick
  capture on the fakes of `CaptureTestKit.swift`), `JoinTakeoverTests` and `JoinOverSyncTests`. Assertions on words
  became the typed values (`SyncStatus.kind`, `JoinProgress.server`, `DeviceKeyProblem`); the words got app tests instead
  (`WebDAVAppTests.theBarSaysOfflineAndNamesTheServerOfAFill`, `DevicesAppTests`). `aRecentWebDAVVaultReopensFromItsCopy`
  checks `joiningWebDAVLocation`, what Open Recent (`open(recent:)`, the app's until step 5: it calls `copyIn`) uses.
  New: the owner checks of a kit replacement and a re-encryption (`DevicesTests.replacingTheKitAndReencryptingNeedTheOwner`)
  and a takeover seen on a reopen (`aTakeoverSeenOnAReopenRaisesTheAlert`, review of #26).
- **Test seams gone**: `DevicesAppTests.World`, `defaults()` and `PassingOwner` (and `JoinTakeoverAppTests.PassingOwner`):
  the app suites that stay use `MemoryKeyValueStore` and `ScriptedOwnerCheck(.pass)`. The app keeps the words
  (`DevicesAppTests`: the history lines from values, the done line, the unlock sheet's words, the notices with
  `DeviceRow.symbol`; `WebDAVAppTests` in `WebDAVTextAppTests.swift`, `StorageLocationTests`), and what needs the app:
  `JoinTakeoverAppTests` (`JoinTakeoverPlatformTests.swift`: `KeyRemoval`, the takeover screen's codes, `TypedWords`,
  `StoredSigning`, the Secure Enclave), `KeychainDeviceKeyStoreTests`, `JoinThroughProviderTests`, `OfflineModeTests`.
  `DeviceHistoryEvent` and `EpochChangeReport` (Sempere) got public initializers for the word tests.

Wave 5b, part 3, step 5a (vault store, backups, thinning, storage and Vault Details, 2026-11-08) moved:

- **`+VaultStore`, `open(recent:)` of `+Browser`, `+Backup`, `+Thinning`, `+Storage` and `+VaultDetails`** into
  `Sources/SempereAppCore/AppModel/`: Open Vault… (`copyIn`, `openStored`, `downloadSourceFolder`), the store's list
  (`VaultLibrary.refreshStoredVaults(log:)`, `copyIn(_:coordinated:files:progress:)`, `removeStored`,
  `storedVaultsByUse`), backups and restores, thinning (`NoteWriter.thin`, `thinVault`, `thinIfDue`), the cache sizes
  and Vault Details' Repair, with their types (`CopyInFollowUp`, `VaultCopyProgress`, `VaultStoreProblem`,
  `InvalidVaultName`, `RestoreOutcome`, `ThinningPreference`, `ThinningReport`, `NoteThinning`, `ThinningProgress`,
  `CacheSizes`, `VaultDetailsSnapshot`, `RepairProblem`). `AppModel.BackupAppError` is `AppModelBackupError`.
  `vaultCopy` and `thinningProgress` are the model's stored properties.
- **Services, not the platform**: every security scope and bookmark goes through `services.bookmarks` (the backup
  folder's stale bookmark is made again with its scope held, as `VaultBookmark.resolve` did), the coordinated reads of
  a copy-in, a restore and thinning through `services.files` (new: `AppModelServices.files`, the app's
  `SystemFileCoordinator`, headless `UncoordinatedFiles`), the signposts through `services.perf` ("backup", "thin",
  "thin.note"), and thinning's window and last runs through `services.settings`
  (`ThinningPreference.days(in:)`). The Open Vault sheet asks `CopyInFollowUp` on the app's services (glue in
  `AppModel+VaultStore.swift`: `.live`, `SecurityScopedBookmarks`, `SystemFileCoordinator`). "Can this account write
  here" is `FolderAccess.isWritableFolder` (the model's `isWritableFolder` calls it).
- **Words** stay in the app, same strings: `VaultCopyProgress.text`, `VaultStoreProblem`, `InvalidVaultName` and
  `AppModelBackupError` (retroactive `CustomStringConvertible`), `ThinningPreference.label`, `ThinningProgress.headline`,
  `RepairProblem`.
- **Seams gone**: the host step `listingFinished` (the listing ends in the core's `thinIfDue`; the app's scripted
  launches, demo and debug, turn `automaticThinning` off instead of `thinIfDue` asking `DemoLaunch`), and
  `AppModelAppState`'s `thinningProgress` and `vaultCopy`. In the app, `VaultBookmark` (its last callers moved) and
  `FolderReach` (`SecurityScopedBookmarks.recordedPath(of:)` reads the path itself; the rule is `FolderReachability`).
  New test seam: `automaticThinningRun`, the task `thinIfDue` started.
- **Tests** in `Tests/SempereAppCoreTests/AppModel`: `VaultStoreTests`, `BackupTests` (with `FakeBackupNotifier` on
  `LocalNotice`), `FolderTargetTests`, `VaultDetailsTests` (with `ReencryptOverFolderTests`, all of the former
  `ReencryptAppTests`), `ThinningTests` (the cases of `VersionHistoryAppTests` that need no Save Version, and the
  automatic run after a listing), `JoinThroughProviderTests` (the model's half, and the join over a drive of
  `OfflineModeTests`). The app keeps the words (`VaultStoreAppTests`, `BackupAppTests`, the words' case of
  `JoinThroughProviderTests`), the vault types it declares (`theVaultTypeIsAFolderNeverAPackage`), what needs the
  system's bookmarks (`FolderTargetAppTests.aMovedTargetFolderIsFollowed`), Add Device's sheet model
  (`JoinThroughProviderTests`: `AddDeviceApproval`) and the two thinning runs after a Save Version
  (`VersionHistoryAppTests`, until `+History` moves).

Wave 5b, part 3, step 5b (history, export and import, 2026-11-08) moved:

- **`+History`, `+Export`, `+BulkExport` and `+Import`** into `Sources/SempereAppCore/AppModel/`, with `ExportJob`
  (the export sheet's run) and `OpenedFile` (the pure part of `+OpenedFiles`: `kind`, `Stage`, `shows`, which
  `WindowTargeted` needs): `loadHistory`, `readHistory` (on `services.perf`, "history.read"), `historyPreview`,
  `restoreVersion`, `saveVersion`, `HistoryData`, `HistoryPreviews`, `HistoryEntry`, `HistoryGroupRow`; `exportNotes`,
  `requestExport` (now taking a `ShareFormat`; `ShareFormat.isAvailable(for:)` is the rule `ExportCommand` enables
  with), `flushEditors`, `loadNoteForExport`, `ExportRequest`, `ExportProgress`, `LoadedForExport`,
  `UnsavedChangesError`; `runBulkExport` with its read-ahead, `BulkExportRequest`, `BulkExportTarget`,
  `BulkExportProgress`, `BulkExportRun`; `importFromApp`, `cancelImport`, `ImportOptions`, `ImportDetails`,
  `ImportSummary`, `ImportProgressRelay`. The drag-out folder and its purge (`NotePDFExport.folder`, `purge`) and
  `ExportEpoch` are the core's too; rendering the dragged note (`NotePDFExport.render`, `write`, PDFKit) stays in the
  app.
- **Services**: what exports draw with is `AppModelServices.exportRendering` (a `RenderOptions` with the app's
  `PDFKitRasterizer`, `ImageIODecoder` and `CoreTextShaper`; headless, none), the PDF page text of an import
  `pdfTextExtractor` (`PDFKitTextExtractor`; headless, none), reading handwriting after an import
  `makePageRecognizer` (Vision; headless, none, and nothing is read), and the picked folders' and files' security
  scopes `services.bookmarks`. The import's progress hops to the main actor with a task, not `DispatchQueue.main`.
- **Library values for the platform's types**: the import picker's types are `ImportFileKind` (`.zip`, `.folder`,
  `.fileExtension`; `AppModel.importFileKinds(for:)`), which the app turns into `UTType`s (`importTypes(for:)`);
  `OpenedFile.kind(of:isPDFType:)` takes a `Bool`, the app reads the URL's `UTType`. No `CGRect` was left in the moved
  code (the editor's `visible:` rectangles are Foundation's `CGRect`, already portable).
- **Typed values the app words**, same strings (`History+Text.swift`, `Export+Text.swift`, `Import+Text.swift`):
  `HistoryEntry.kind` (`.savedVersion`, `.snapshot`, `.edit`), `devicePrefix` and `needsCompactionNotice` (the app's
  `deviceLabel`, `kindLabel`, `checkpointTitle`, `unavailableReason`, `compactionNotice`, `HistoryGroupRow.summary`
  and `timeRange`); the progress lines (`ExportProgress.description`, `BulkExportProgress.description`),
  `BulkExportRequest.title`, why a run failed (`ExportRunFailure`: `.error`, `.noteFailed`, `.noMedia`,
  `.nothingExported`, `.noNotes`, `.folderInsideVault`; `text`) and `UnsavedChangesError`'s sentence; an import
  report's rows are the importer's count ids (`Row.key`, `english`; the app's `label`), the alert's `title` and
  `message`, and the saved report (`ImportSummary.reportText`, from `details.noteLines` and `date`).
  `AppModelError.unsavedChanges` carries the editor's `saveFailure`, which the app words as the editor does.
  `Sempere` has a `HistoryEntry` of its own, so the app's `History+Text.swift` names the core's with a typealias.
- **State that left `AppModelAppState`**: `exportRequest`, `bulkExportRequest`, `importSummary`, `lastImportReport`
  (now the whole `ImportSummary`, which the report sheet takes), `exportFolder` and `exportEpoch`; the core's
  `close()` forgets them (and purges the drag-out folder), so `willClose` keeps only the drags.
- **Tests** in `Tests/SempereAppCoreTests/AppModel`: `HistoryTests` (all of the app's `HistoryTests`, the model's
  cases of `VersionHistoryAppTests`, new: the read's signpost and the refusals without a vault), `ReadOnlyVaultTests`,
  `ThinningTests` (gained the two runs after a Save Version), `ExportTests` and `BulkExportTests` (every case of the
  app's but the words, on the headless rendering) and `ImportTests` (the model's cases of `ImportReportTests` and
  `ImportProgressTests`; progress and Cancel now act from the importer's own thread at a set note, so nothing polls
  or races the import). The app keeps the words (`VersionHistoryAppTests`, `ReadOnlyVaultTextTests`, `ExportTests`,
  `BulkExportAppTests`, `ImportReportTests`), what needs the app's renderers (`ExportTests.theAppRendersWithPDFKitImageIOAndCoreText`),
  the device checks with the real debounce (`ExportStressAppTests`), and the real importer on a synthetic backup
  (`ImportProgressTests`).
- **Review of #28, folded in**: `RecordingFiles` (`AppModelTestKit.swift`) checks that a copy-in and a restore from a
  provider's folder coordinate through `services.files` with the folder's URL and thinning never does
  (`VaultStoreTests`, `ThinningTests`), and `VaultStoreAppTests` that the app's is `SystemFileCoordinator`; models are
  closed when a test's setup throws (`BackupTests.model`, `FolderTargetTests.world`, `JoinThroughProviderTests`,
  `ThinningTests.unlockedModel`); `FolderTargetTests.world(withB: false)` for the two tests that only use A, and an
  arrival wait of 0.1 s for the two that wait for files that never arrive within a run.

**Wave 5b, part 3 (the rest of the plan).** Steps 1 to 4b, 5a and 5b are done (above). The rest of the family, in an
order that empties `AppModelAppState` and the host's steps:

5. c. Opened files and the PDF and image inserts (`+OpenedFiles`' extension, `+Insert`, `+Video`): `handleOpened`,
   `receiveOpenedPDF`, `importOpenedPDFs` and `discardOpenedPDFs` call the app's PDF import (`importPDF(copy:to:password:)`,
   `PDFPreparation` on PDFKit), so they move with it, PDFKit and AVFoundation behind services. Host state that goes:
   `openedPDFs`.
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
