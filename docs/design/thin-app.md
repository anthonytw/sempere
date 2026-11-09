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
| `KeyValueStore` (`object`/`bool`/`integer`/`double`/`string`/`data(forKey:)`, `set`, `removeObject`, `observeChanges` → `KeyValueObservation`) | `MemoryKeyValueStore` | `UserDefaults` itself (retroactive conformance; change = `didChangeNotification` of that defaults) | `KeepScreenOn.isOn`, `IdleTimerKeeper` (follows the setting through `observeChanges`; SempereAppCore since step 6), `BlobCache.configuredMaxBytes(in:)`, `DrawingCache.configuredCapBytes(in:)`, `ObjectEraserSize.load(from:)`/`save(_:to:)` |
| `PerfSink` (`measure`, `event`, `log(level, category, message)`) | `NoPerfSink`, `MemoryPerfSink` | `AppPerfSink` (`Perf` signposts, `os.Logger`) | `DeviceClock`'s writer reads (wave 2), `BundleBitRepair.clear(log:)` |
| `FolderBookmarks` (`bookmark(for:)`, `resolve(_:mounting:)` → `ResolvedBookmark`, `startAccessing`/`stopAccessing`, `withAccess`) | `PathBookmarks` (a path, no scope) | `SecurityScopedBookmarks` (`options: []`; no `mounting` → `.withoutMounting`) | `AppModel.enableQuickCapture`, `isProfileFolder(_:_:bookmarks:)` |
| `FileCoordinating` (`coordinateReading`/`coordinateWriting`, `coordinatedRead`/`coordinatedWrite` taking an optional URL) | `UncoordinatedFiles` | `SystemFileCoordinator` (`NSFileCoordinator`, the `reconcile.coordinate` signpost) | `CloudVault.coordinatedRead`/`coordinatedWrite(files:)`, so every caller of those already goes through it |
| `PlatformServices` (`isMac`, `isPhone`, `setIdleTimerDisabled`, `play(HapticFeedback)`) | `HeadlessPlatform` (records what it was asked) | `AppPlatform` | `IdleTimerKeeper(settings:platform:lifecycle:)` (the model's `keepScreenOn`, `services.platform`), `PageCanvasView.snapFeedback` |

The call sites that are left, by file in `Apps/Sempere/SempereApp/` (2026-11-07). Switch one when its code moves.
View code (`@AppStorage` in a `View`, UIKit glue) stays in the app and keeps the platform API.

- **`KeyValueStore`** (`UserDefaults`/`@AppStorage`): `AppCommands`, `AppModel+SettingsSync`,
  `AppThemeWindows`, `AppearancePreferences`,
  `ColumnLayout`, `DragTestSettings`, `DrawingPaletteView`,
  `DrawingToolbox` (its `defaults:` parameter), `EraserPreference`,
  `InsertUI`, `MathEditor`, `MathModels`, `MathSettings`, `MouseInk`, `NoteCanvasView`,
  `NoteDragSource`, `NoteListView`, `NoteWindowView`, `PageCanvasHost+Appearance`, `PageCanvasView`,
  `PageLayoutChoice`, `PageRecognizer`, `PaperPreference`, `RecordingPreferences`, `RenderCache`, `RootView`,
  `SettingsGroups`, `SettingsSyncBridge`, `SettingsView`, `StatusItemBridge`, `ToolPalette`
  (and `DebugLaunch`, debug only).
- **`PerfSink`**: `Perf.begin`/`measure`/`event` in `AppModel+History`, `BackgroundSync`, `ItemLayerView`, `ItemRendering`,
  `NoteEditor`, `PageCanvasView`; `os.Logger` in `AppModel+Inbox`,
  `+SettingsSync`, `AppModelEnvironment`, `DragLog`, `FolderPicker`. Phases are `Perf.Phase` raw values, so a moved `Perf.measure(.x, …)`
  becomes `perf.measure("x", …)`.
- **`FolderBookmarks`** (bookmarks and security scopes): `AppModel+BulkExport`,
  `+DeviceNotices`, `+Import`, `ExportSheet`, `FolderPicker`, `InsertUI`, `MathModels`, `NewVaultView`.
  (`PDFPreparation`'s scope went in step 5c: a picked file's copy is `ImportWorkFolder.copyPicked(_:bookmarks:)`.)
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
  `AppModelServices.headless()`) and, until part 3 step 7a removed them, two seams for the extensions still in the app:
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
  extensions (part 3) use the class through another module. Narrowed to what the app uses in step 7b (below).
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
  `restoreVersion`, `saveVersion`, `HistoryData`, `HistoryPreviews`, `HistoryRow` (`HistoryEntry` until step 5c), `HistoryGroupRow`; `exportNotes`,
  `requestExport` (now taking a `ShareFormat`; `ShareFormat.isAvailable(for:)` is the rule `ExportCommand` enables
  with), `flushEditors`, `loadNoteForExport`, `ExportRequest`, `ExportProgress`, `LoadedForExport`,
  `UnsavedChangesError`; `runBulkExport` with its read-ahead, `BulkExportRequest`, `BulkExportTarget`,
  `BulkExportProgress`, `BulkExportRun`; `importFromApp`, `cancelImport`, `ImportOptions`, `ImportDetails`,
  `ImportSummary`, `ImportProgressRelay`. The drag-out folder and its purge (`NotePDFExport.folder`, `purge`) and
  `ExportEpoch` are the core's too; rendering the dragged note (`NotePDFExport.render`, `write`, PDFKit) stays in the
  app.
- **Services**: what exports draw with is `AppModelServices.exportRendering` (a `RenderOptions` with the app's
  `PDFKitRasterizer`, `ImageIODecoder` and `CoreTextShaper`; headless, none), the PDF page text of an import
  `pdfTextExtractor` (`PDFKitTextExtractor`; headless, the built-in `BuiltinPDFTextExtractor` since step 6, as
  `PortableAttachmentPreparation` and the CLI), reading handwriting after an import
  `makePageRecognizer` (Vision; headless, none, and nothing is read), and the picked folders' and files' security
  scopes `services.bookmarks`. The import's progress hops to the main actor with a task, not `DispatchQueue.main`.
- **Library values for the platform's types**: the import picker's types are `ImportFileKind` (`.zip`, `.folder`,
  `.fileExtension`; `AppModel.importFileKinds(for:)`), which the app turns into `UTType`s (`importTypes(for:)`);
  `OpenedFile.kind(of:isPDFType:)` takes a `Bool`, the app reads the URL's `UTType`. No `CGRect` was left in the moved
  code (the editor's `visible:` rectangles are Foundation's `CGRect`, already portable).
- **Typed values the app words**, same strings (`History+Text.swift`, `Export+Text.swift`, `Import+Text.swift`):
  `HistoryRow.kind` (`.savedVersion`, `.snapshot`, `.edit`), `devicePrefix` and `needsCompactionNotice` (the app's
  `deviceLabel`, `kindLabel`, `checkpointTitle`, `unavailableReason`, `compactionNotice`, `HistoryGroupRow.summary`
  and `timeRange`); the progress lines (`ExportProgress.description`, `BulkExportProgress.description`),
  `BulkExportRequest.title`, why a run failed (`ExportRunFailure`: `.error`, `.noteFailed`, `.noMedia`,
  `.nothingExported`, `.noNotes`, `.folderInsideVault`; `text`) and `UnsavedChangesError`'s sentence; an import
  report's rows are the importer's count ids (`Row.key`, `english`; the app's `label`), the alert's `title` and
  `message`, and the saved report (`ImportSummary.reportText`, from `details.noteLines` and `date`).
  `AppModelError.unsavedChanges` carries the editor's `saveFailure`, which the app words as the editor does.
  `Sempere` has a `HistoryEntry` of its own, so the app's `History+Text.swift` named the core's with a typealias (until
  step 5c renamed it `HistoryRow`).
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

Wave 5b, part 3, step 5c (opened files and the PDF, image and video inserts, 2026-11-08) moved:

- **`+OpenedFiles`, `+Insert` and `+Video`** into `Sources/SempereAppCore/AppModel/`: `handleOpened`, `receiveOpenedPDF`,
  `importOpenedPDFs`, `discardOpenedPDFs`, `sidebarNotebook`, `openedPDFStage`, `OpenedPDF` and
  `OpenedVaultConfirmation` (whose `current` is now the vault's name or nil: the app's `currentName` words "Vault");
  `insertImage`, `replaceImage` (it returns the old and the new image; the app's `replaceImage(…actions:)` in
  `ItemActions.swift` registers the undo step), `importPDF(picked:to:)`, `importPDF(copy:to:password:)`,
  `importPDF(_:title:notebook:)`, `continuePDFImport`, `cancelPDFImport`, and `PDFDestination`, `PDFImportRequest`,
  `PDFImportOutcome` (nested in `AppModelCore`, since `.insert` holds the editor; the app's `Insert+Text.swift`
  keeps the old names as typealiases); `insertVideo`, `acquireVideo`, `releaseVideo`, `addPosterIfMissing`. The photo
  privacy setting is the core's `PhotoPrivacy` (`isOn(_ settings: any KeyValueStore)`; the inserts read
  `services.settings` when the caller passes no `privacy`), and `SettingsSyncBridge` uses its key instead of a copy.
- **The work folders** (`PDFPreparation.workFolder`, `copyPicked`, `discard`, `purge`) are the core's
  `ImportWorkFolder` (`make`, `copyPicked(_:fallbackName:limit:bookmarks:)`, the scope through `FolderBookmarks`,
  `discard`, `purge`, `maxPDFBytes`); `VideoPreparation.copyPicked` passes the clip's name and no limit.
- **Services**: a new `AppModelServices.attachmentPreparation` (`AttachmentPreparing`: `preparePDF`, `prepareImage`,
  `prepareVideo`, `videoPoster`, `isPDFType`), read from `services` when used. The app's `AppAttachmentPreparation`
  is PDFKit and Core Graphics (`PDFPreparation`: unlock and redraw), ImageIO (`ImagePreparation`), AVFoundation
  (`VideoPreparation`, `VideoPoster`) and `UTType` for an opened file's type. Headless, `PortableAttachmentPreparation`
  does what the CLI does on Linux: `PDFIngest` with the built-in page text, `ImageIngest` without a converter,
  `VideoProbe` and `VideoMetadata` (no conversion, no poster frame, nothing typed as a PDF but by its extension).
  The video audio session (`AVAudioSession`) stays in the app as `VideoAudioSession` in `VideoViews.swift`.
- **Typed values the model tells apart**: a PDF that needs its password throws `PDFLocked` (`.needsPassword`,
  `.wrongPassword`; they left `PDFPreparation.Failure`), a file over the format's limit `AttachmentTooLarge` (`.pdf`,
  `.video`; they left `PDFPreparation.Failure` and `VideoPreparation.Failure`). A failure is `errorMessage =
  "\(InsertNotice.…(error))"` (`.imageNotAdded`, `.imageNotReplaced`, `.pdfNotImported`, `.videoNotAdded`,
  `.fileNotOpened(name:_:)`).
- **Words** stay in the app, same strings (`Insert+Text.swift`): `InsertNotice`, `PDFLocked` and `AttachmentTooLarge`
  (retroactive `CustomStringConvertible`), `AppModel.describe(_:)` (also used by `InsertUI`, `MathEditor` and
  `VideoViews`), `OpenedVaultConfirmation.currentName`.
- **State that left `AppModelAppState`**: `openedPDFs` (a stored property of the core; `close()` keeps it: the PDFs
  wait for the next vault). No host step became unused.
- **Review of #29, folded in**: the core's `HistoryEntry` is `HistoryRow` and the app's typealias is gone (the history
  list's private row view is `HistoryRowView`); `ImportTests.recognitionAfterTheImportIsReported` runs the
  recognition loop (the importer reports the fixture's "Lecture" as written, two pages are read); the app's
  `ImportReportTests` checks the report's "Handwriting read on N pages." line; "Show Report" is offered when
  `summary.details.date != nil` rather than building the report text.
- **Tests** in `Tests/SempereAppCoreTests/AppModel`: `InsertTests` (images, PDFs and clips through the model on the
  package's preparation or `FakeAttachmentPreparation`: one blob and one delta, the privacy setting from
  `services.settings`, the password flow with a "redrawn" copy, a pageless note, a picked file's copy and limit, a
  clip without its location, a codec only the app converts, the poster on first play; the discard case of the app's
  `KeyExportGapTests`; small hand-written PDFs and a PNG from `PNGEncoder`, the fixture clips) and `OpenedFilesTests`
  (the opened-PDF cases of `MacPolishBuild7Tests`, the open-without-asking case of `OpenedVaultTests`, a PDF known by
  its type). The app keeps the platform's preparation (`PDFImportTests`' preparing cases, `VideoTests`,
  `ImageInsertTests`), the import with Core Graphics' encryption end to end, the canvas and drawing cases
  (`PhoneInsertTests`, `CanvasSelectionTests`, the display and the 200-page PDF), and the words (`InsertTextTests`,
  new; `PDFImportTests.aPagelessNoteSaysWhyItTakesNoPDFPages`).

Wave 5b, part 3, step 6 (app lifecycle and windows, 2026-11-08) moved:

- **`+Background`, `+Suspension`, `+Windows` (the note windows and state restoration), `+MenuBar` and the drags of
  `+Browser`** into `Sources/SempereAppCore/AppModel/`: `enterBackground`, `enterForeground`,
  `scheduleBackgroundRefresh`, `processingRequest`, `finishTargetRunsInBackground`, `endTargetsBackgroundTime`,
  `runBackgroundTask`, `startReachability`; `observeAppLifecycle`, `prepareForSuspension`, `finishSuspension`,
  `resumeAfterSuspension`, `reacquireStoreLease` (their warnings on `services.perf`, category "suspension");
  `noteWindowValue`, `claimNote`, `releaseNote`, `openWindowNote` (on `services.perf`; its editor gets the host's
  `prepareEditor` too), `reopenWindowNote`, `closeWindowEditors`, `shouldOpenLibraryWindow`, `selectionDigest`,
  `restorableSelection`, `restore(_:)`, with `NoteWindowValue` and `RestorableSelection` (`WindowValues.swift`, out
  of `MacSupport.swift`); the menu-bar item's New Note (`requestNewNoteFromMenuBar`, `menuBarNewNoteStep`,
  `takeMenuBarNewNote`); `moveNotes`, `moveNotebook`, `restoreNotebooks`, `move(_:to:)` (it returns the
  `NotebookMoveRecord` the caller's undo step takes), `beginDrag(_:)`, `setDropTarget`, `acceptsDrop`, `takeDrop`,
  `endDrag`, `flashLandedDrop`, and `KeepScreenOn` with `IdleTimerKeeper` (`KeepScreenOn.swift`; the model's
  `keepScreenOn(debugLaunch:lifecycle:)` makes and starts it).
- **The drag types** leave `SidebarDrop.swift`: the core's `SidebarDrop.swift` has `DragPayload` (its `kind`, `data`
  and `decode(_:kind:)`), `DropTarget`, `SidebarDrop.accepts`, `NotebookMoveRecord`, `NotebookPathMove` and
  `LandedDrop`. The app keeps the `UTType`s, `DragPayload.type`, `decode(_:as:)` and `provider(…)`, the drop delegates,
  `SidebarDrop.proposedOperation` (SwiftUI's `DropOperation`) and the undo step: `move(_:to:undoManager:)` and
  `beginDrag(_:provider:)` in its `AppModel+Drags.swift` call the core's and add the window's undo step and the
  debug drop trace.
- **Lifecycle and background protocols** (`AppLifecycle.swift`): `AppLifecycle` (`isInBackground`, `isActive`,
  `observe` → `AppLifecycleObservation`, events `AppLifecycleEvent`), `BackgroundTaskRunning` with
  `BackgroundTaskToken`, `BackgroundSyncScheduling` with `BackgroundSyncRequest`, and `NetworkReachability`. New
  services: `AppModelServices.lifecycle` (the app's `UIKitAppLifecycle`: `UIApplication`'s four notifications, observed
  with no queue so they run in the posting turn; headless `ManualAppLifecycle`, which a test drives with `send`),
  `backgroundTasks` (`UIKitBackgroundTasks`; headless `NoBackgroundTasks`, which gives no time) and `syncScheduler`
  (`BGTaskSyncScheduler`; headless `NoBackgroundSyncScheduler`), both copied into model properties because tests
  replace them, and `makeReachability` (`WebDAVReachability`; headless none). `BackgroundSync`, the `BGTaskRequest`s
  and the UIKit implementations stay in the app (`BackgroundSync.swift`).
- **"Keep Screen On"** follows the open editors: `editor`'s and `windowEditors`' `didSet` call `idleTimer?.update()`,
  and the keeper sets `services.platform.setIdleTimerDisabled` from the setting (`services.settings`), the app's state
  (`services.lifecycle`) and whether an editor is open. `PlatformServices` already had the call, so no service was
  added for it.
- **Words**: the undo step's name is a typed value, `NotebookMoveRecord.moved` (`.notes(count:)`, `.notebook`); the app's
  `NotebookMoveRecord.actionName` and `SidebarDrop.actionName(_:)` word it with the same strings ("Move Note", "Move
  Notes", "Move Notebook").
- **State that left `AppModelAppState`**: all of it (`draggedPayload`, `dropTarget`, `landedDrop`, `backgroundTasks`,
  `syncScheduler`, `targetsBackgroundToken`, `reachability`, `suspensionToken`, `idleTimer`): the class is empty and
  goes with `Host.State` in step 7. `lifecycleObservers` became `lifecycleObservation`.
- **Host steps gone**: `willClose` (the core's `close()` forgets the drag), `editorsChanged` (the core tells the idle
  timer), `closeWindowEditors`, `openWindowNote` and `reopenWindowNote` (the core calls its own). Left: `prepareEditor`
  (now for note windows' editors too) and `unreadableText` (step 7).
- **Split out (step 6b, below)**: the PDF a note dragged to the Finder becomes (`exportPDF`, `prepareExport`,
  `PreparedExport`, `NotePDFExport.render`/`write`, `AppModel.ExportError`) stayed in the app as
  `AppModel+DragExport.swift`, with the Markdown and HTML drag formats (`NoteDragFormats.swift`) and `ExportFileName`
  that build on it, until step 6b moved them.
- **Review of #30, folded in**: `InsertTests.playingReadsTheVerifiedClip…` and the app's `VideoTests` case release the
  clip after the last `addPosterIfMissing` (the release task raced the deferred close); `BrowserTests.unlockedFixtureModel`
  closes the model when its setup throws (so `OpenedFilesTests.closingAVaultKeepsTheWaitingPDFs` does);
  `PDFImportTests.aPasswordProtectedImportWaitsForThePassword` and `VideoTests.insertingWritesTwoBlobsAndOneDelta` close
  their models, and the password case checks that the work folder, with Core Graphics' `redrawn-*.pdf`, is gone after
  `.done`; `PortableAttachmentPreparation.preparePDF` says that it never uses the password (an encrypted PDF is
  refused), and `prepareVideo` checks the size before the probe; headless imports read PDF page text with
  `BuiltinPDFTextExtractor`, as headless inserts already did.
- **Tests** in `Tests/SempereAppCoreTests/AppModel`: `LifecycleTests.swift` (`SuspensionLockTests`, `IdleTimerKeeperTests`,
  `BackgroundTargetsTests` and `MenuBarNewNoteTests`, moved from the app on `ManualAppLifecycle` and the fakes there;
  new: a scripted launch stays awake, the model's editors and the app's state reach the idle timer through
  `services.platform`, reachability comes from the services), `NoteWindowTests` (every case but the drag-out PDF) and
  `DragTests` (the payloads by kind, the rules, the moves, the flash and the drag session); `HostStepTests` checks
  `prepareEditor` for both kinds of editor and that `close()` forgets a drag. The app keeps `LifecycleAppTests` (the app's
  services, `UIKitAppLifecycle`'s notifications, the keeper on the real `UserDefaults`, the `BGTaskRequest`s),
  `NoteWindowTests` (the drag-out PDF, `SelectionStorage`), `DragAndDropTests` (the `UTType`s and item providers, the
  proposed operation, the undo steps and their names, the Move Notebook sheet) and `MenuBarItemTests` (the item).

Wave 5b, part 3, step 6b (the drag-out export, 2026-11-08) moved:

- **`AppModel+DragExport.swift` and `NoteDragFormats.swift`** into `Sources/SempereAppCore/AppModel/AppModel+DragExport.swift`:
  `exportPDF`, `prepareExport`, `PreparedExport` (`write()`, `write(format:)`), `NotePDFExport.Rendered`, `render` and
  `write` (next to the core's folder and purge), `NoteDragExport` (Markdown and HTML through `ShareExport`), the pure
  part of `DragExportFormat` (the cases, `key`, `defaultValue`, `load(from:)`/`save(_:to:)` on a `KeyValueStore`,
  `fileExtension`) and `ExportFileName` (with `base(title:)`, the name without its extension, which
  `NoteFileDrag.suggestedName` now returns).
- **Services, not the platform**: the drag-out draws with `services.exportRendering`, read when the export is prepared
  and carried in `PreparedExport.rendering` (so the file is still written off the main actor, from any thread); its
  blobs are set to the note's `vault.blobSource(note:)` for the PDF, and the Markdown and HTML files take its PDF
  rasterizer, shaper and image decoder. Nothing in the core names PDFKit, ImageIO or CoreText. No service was added.
- **Typed values the app words**: `AppModel.ExportError` is the core's `DragExportError` (`.unreadableRevisions(n)`);
  the app's `Export+Text.swift` words it with the same string and catalog key (retroactive
  `CustomStringConvertible`). `DragExportFormat.title` and the v1 switch `showsInSettings` stay in the app
  (`AppearancePreferences.swift`); since step 7a the drag source reads the stored format from `model.services.settings`.
- **What stays in the app**: `NoteFileDrag` (the `UTType` of each format, the item providers, the file request's wait
  and timeout, `DragLog`) and the drag source. They take the core's `PreparedExport`.
- **Review of #31, folded in**: `ManualAppLifecycle`'s cancel removes the handler at once on the main thread
  (`MainActor.assumeIsolated`), and hops with a task only from another thread (a release elsewhere);
  `BackgroundTargetsTests` stop their coordinators in a `defer` right after making them; `FakeBackgroundTasks` keeps
  one expiry handler per token (`expire(_:)`, all running ones by default); `LifecycleAppTests.leavingTheScreenReachesTheModel`
  runs on a fake `backgroundTasks` and checks that nothing was asked of the scheduler or the background time; `close()`
  forgets `landedDrop` (`HostStepTests`).
- **Tests** in `Tests/SempereAppCoreTests/AppModel/DragExportTests.swift`: `DragExportTests` (the named file in the
  model's export folder, no collisions, unsaved ink, the refusals without a vault and with an unreadable revision in
  every format, nothing written after a close, a PDF background and a text box drawn through the services' rendering
  with its blobs, Markdown and HTML, the purge, the stored format) and `ExportFileNameTests` (from the app's
  `MacSupportTests`). The app keeps the check that its renderers draw the same pages through the services as before
  (`NoteWindowTests.theDraggedPDFDrawsThroughTheServicesAsBefore`: a note with a PDF background and a text box, the PDF
  byte for byte as PDFKit, ImageIO and CoreText named directly drew it), `MacDragOutTests` (the file promise with the
  main thread blocked, the providers), `RobustnessAuditTests`' timeouts, `AppearanceSettingsTests`' drags (the `UTType`s,
  Markdown and HTML on the app's renderers) and the words (`ExportTests.progressAndFailureLines`).

Wave 5b, part 3, step 7a (the host's seams and the model's words, 2026-11-08) finished what `AppModelHost` carried for the
app:

- **Gone**: `AppModelAppState` (empty since step 6), `Host.State`, `makeState`, the model's `appState`, and the last two
  host steps. `AppModelHost` is the canvas and `makeServices()`; `AppHost` and the tests' `TestHost` give nothing else.
- **`prepareEditor` is a service**: the core's `configureRecordings`, which every editor the model opens already got
  (library window and note windows), also sets the editor's `onRecordingSaved` (now `NoteEditorModel`'s, out of
  `NoteEditorAppState`): with "Transcribe Recordings on This Device" on, it transcribes the saved recording
  (`transcribeSaved`), then hands the session folder to `AppModelServices.finishRecordingSave` (the app's
  `AppModel.finishRecordingSave` deletes the folder and clears `RecordingSession.busy`; headless, the folder is
  deleted). The app's `configureRecordingSaves` is gone.
- **`unreadableText` is a typed value**: `editorFailure` is `(id:, reason: EditorFailure)` (`.unreadable(NoteReadOnly?)`,
  the editor's read-only reason; `.failed(any Error)`), and the editor's `onLoadFailed` passes the error, not its
  description. The detail pane words it (`EditorFailure.text` in `AppModel+Text.swift`: the read-only banner's words,
  "This note could not be read.", or the error's description; the same strings).
- **`errorMessage` is `alert: AppModelAlert?`** (`AppModelAlert.swift`): `.error(any Error)` (`report`, a listing nobody
  awaits), `.notice(AppModelNotice)`, `.insert(InsertNotice)`, and `.worded(String)` for a sentence the app made itself
  (a paste, a photo pick, a reopen; the model only carries it). `RootView`'s alert shows `alert.text`. `loadFailure` is
  `(any Error)?` and `EmptyListReason.failed` carries the error; the list words it with its description.
  `AppModelNotice` and `InsertNotice` lost their retroactive `CustomStringConvertible`: the app words them with `text`,
  same strings. Thrown errors keep theirs (`AppModelError` and the others), because `.error` and `.failed` word any
  error by its description.
- **Comparable reasons**: `AppModelAlert`, `EditorFailure`, `InsertNotice` and `EmptyListReason` are `Equatable` through
  `sameError` (equal values of one `Equatable` error type, else the same type and description), so core tests assert the
  reason: `.insert(.pdfNotImported(AttachmentOpsError.pagelessNote))`, `.imageNotAdded(ImageIngestError.unsupportedFormat)`,
  `.imageNotReplaced(AttachmentOpsError.noSuchImage(…))`, `.pdfNotImported(PDFIngestError.unreadable(.notAPDF))`,
  `.videoNotAdded(VideoProbeError.unsupportedCodec("mp4v"))`, a missing file's `CocoaError.fileReadNoSuchFile`,
  `.notice(.transcriptionModelMissing)`, and a background listing's alert carrying the same error as `loadFailure`.
- **Strings**: no localized literal changed. The set of literals in `Apps/` and `Sources/` (non-test) lost only the
  core's own `"\(AppModelNotice.…)"` and `"\(InsertNotice.…)"` interpolations, which built `errorMessage`.
  `LocalizationCatalogTests` treats `.worded(` as the bypass `errorMessage =` was.
- **Review of #32, folded in**: `ManualAppLifecycle.send` looks each observer up as its turn comes, so one cancelled by
  another during the same `send` is not told (`ManualAppLifecycleTests.anObserverCancelledDuringASendIsNotTold`);
  `DragExportTests.aDragFromAClosedVaultWritesNothing` says the deferred second `close()` is idempotent; the app's drag
  source reads `DragExportFormat.load(from: model.services.settings)` (`NoteFileDrag.register`'s default is
  `DragExportFormat.defaultValue`; the app's `load()` on `UserDefaults.standard` is gone).
- **Also**: `SidebarDropUITests.showSidebar` taps "Show Sidebar" on the Mac too (a 1100x760 library window, 847x586 Mac
  points, can start with the sidebar collapsed). On this Mac on 2026-11-08 the tap lands but the sidebar stays
  collapsed (the main window reports itself disabled), so the suite still fails there; the cause is not found yet.
- **Tests**: `HostStepTests.theCoreDoesWhatTheHostsStepsDid` (both kinds of editor hand a saved recording to
  `finishRecordingSave`), the typed assertions above in `InsertTests`, `OpenedFilesTests`, `RecordingModelTests` and
  `VaultOpeningTests`; the app's `InsertTextTests.theAlertAndTheEditorFailureAreWordedAsBefore` checks the words.

Wave 5b, part 3, step 7b (the public surface, 2026-11-08) narrowed `SempereAppCore` to what the app uses and finished
wave 5b:

- **Counts** (lines declaring `public`, `Sources/SempereAppCore`): 2,664 before, 1,643 after (88 files); named public
  types 361 before, 317 after. The CLI links none of the module, so only the app (views, glue and its tests) counts as a
  user. Method: the members and types of the moved `AppModel`, `NoteEditor`, `QuickCapture` and settings files went
  internal, the app and its tests were built (`scripts/app.sh build-ios`, `test-mac`) and what failed became public
  again (a handful of members: `OpenedPDF`'s and `PDFImportRequest`'s `file`, `ImportDetails.isEmpty`,
  `CanvasModes.textToolEnded`, `OpenedFile.shows`, and the like). A second pass took the 40 public types the app never
  names and tried each as internal: all 40 stayed public because another public declaration's signature names them (a
  default argument of `AppModelServices.init` or `QuickCapture.init`, a property's type, an `AppModelCore` initializer).
- **What stays public, and why**: (1) `AppModelCore`'s state and steps the views read and call, with the typed values they
  show (`AppModelAlert`, `AppModelNotice`, `InsertNotice`, `EditorFailure`, `EmptyListReason`, the rows and progress
  values); (2) the seams the app implements (`AppModelServices` and the protocols and no-op defaults its initializer
  names, `QuickCapturePlatform`'s, `DeviceKeyStore`, `AppLifecycle`, `AttachmentPreparing`); (3) `NoteEditorModel` and
  `NoteCanvas`, which the app's `PencilCanvas` instantiates; (4) the types of the first three in other public
  signatures; (5) `DemoVault` and `DemoHandwriting` (`#if DEBUG`, the screenshots). Internal now: every `AppModel`
  helper the extensions call among themselves, the model's own bookkeeping (generations, gates, caches, queues, the
  list-update machinery), and the types only they name.
- **Tests and `@testable`**: `Tests/SempereAppCoreTests` use `@testable import SempereAppCore` (the target's own tests,
  which drive behavior through the internals). The app's tests do not: after the narrowing they build against the public
  surface alone, so nothing in `SempereAppTests` reaches an internal. The decision (reviewer, 2026-11-08): they may
  `@testable import SempereAppCore` to READ internals, never to drive behavior the app itself cannot reach; core behavior
  tests belong in `SempereAppCoreTests`.
- **One `AppModel.describe(_:)`** (`Insert+Text.swift`) words every thrown error: `AppModelAlert.error`,
  `EditorFailure.failed`, `EmptyListReason.failed`, and the `catch` blocks of the views that show what they caught (the
  `localizedDescription` catches for system and file errors, `InsertUI`'s photo picks, `KeyExportViews`' file save,
  `ExportSheet`'s, stay as they are). The 24 errors of the library the app worded with a retroactive
  `CustomStringConvertible` (`AppModelError`, `SyncTargetProblem`, `DeviceJoinError`, `VaultStoreProblem`,
  `DragExportError`, `QuickCaptureError`, …) now have a plain `text` and no conformance; any other error keeps its own
  description. Those conformances also applied inside the library at run time, so every text the core builds from an
  error goes through `AppModelServices.describeError` (the app passes `AppModel.describe`; headless and the editors'
  standalone default is `plainErrorDescription`, the error's own description): the export and bulk-export failures
  (`ExportJob`, `BulkExportSession`'s `fail` and `export`), the notices' reasons (`recordingUnplayable`,
  `recordingUnreadable`, `recordingNotTranscribed`, `voiceNoteUnreadable`, `deviceListUnreadable`), the attachment index's
  problems, the settings sync problem, the sync targets' `other`, thinning's skipped notes, and what each editor keeps
  (`readOnly`'s load failure, `saveFailure`, the recognition and recording failures: the model gives the editor its
  describer when it opens it). The model gives `QuickCapture.describeError` the same one (its banner and outcome).
  With that the strings are those of before; the one exception is `VoiceNoteErrorInfo` (Settings ▸ Quick Voice Notes ▸
  Recent Starts), a technical log that now shows an error's case name (`liveActivitiesOff`) where it showed the
  app's sentence: accepted, it is untranslated diagnostics. `inboxProblem` is a string no view reads. The app's tests
  assert through `AppModel.describe`; `DescribeErrorTests` (core) inject a stub describer and check that an export, a
  bulk export of an unsaved note and a notice use it, and `LocalizationCatalogTests.testEveryWordedErrorTypeIsInAppModelDescribe`
  fails when an error type with an app-side `text` has no case in `describe`.
- **`sameError`** (`AppModelAlert.swift`): equal values of one `Equatable` error type, else the same type and the same
  `String(reflecting:)`, the type's own debug text, never the app's `AppModel.describe`. The `Equatable` of
  `AppModelAlert`, `EditorFailure`, `InsertNotice` and `EmptyListReason` is for tests and for change suppression, not
  identity. `LocalizationCatalogTests.testTheLibraryBuildsNoWordedAlert` fails if `.worded` appears anywhere under
  `Sources/` outside `AppModelAlert.swift` (applied or not; the PR gate runs the package tests).
- **Review of #33, folded in**: the waits of `VaultOpeningTests` (the listing error) and `OfflineTranscriptionTests` are
  30 s (the policy); `NoteFileDrag.register` has no default `format` (the drag source and `MacCatalystTests` pass it).

**Wave 5b, part 3 (the rest of the plan).** Steps 1 to 4b, 5a to 6b, 7a and 7b are done (above): wave 5b is done. The steps:

6. App lifecycle and windows: done (step 6, above).
6b. The drag-out export (`AppModel+DragExport.swift`, split out of step 6): done (step 6b, above).
7a. `AppModelAppState`, `Host.State` and the host's steps go; the model's words become typed values: done (step 7a,
    above).
7b. Narrow the public surface of `SempereAppCore` to what the app (views, glue and its tests) uses; the CLI links
    none of it: done (step 7b, above). Wave 5b is done with it.

The words stayed in the app, next to the views that show them, so the string catalog's checks still see them
(`LocalizationCatalogTests` scans `Apps/`): `MenuCommand+Titles.swift` words `MenuCommand.titleKind(in:)`,
`DeviceSettings+Text.swift` the settings' choices and `StorageText`, `Expectations+Text.swift` the tour pages
(`TourPage.topic`), `VaultLibrary+App.swift`, `BackupSettings+Text.swift` and `QuickCapture+Text.swift` the errors (and, since wave 5b, the banner's titles and the kept-on-device line),
progress, reminder and restore name of wave 4 (a `text` per error type, worded through `AppModel.describe` since step 7b, as `CloudVault+Live.swift`). So did the glue that reads the process or the bundle for the app: `OnboardingPolicy.automatic`
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
   generators.** Checked item by item in wave 6 part 1 (2026-11-08):
   - *Thinning*: done. The stages (`loadForCompaction`, `planCompaction`, `prepare`, `execute`) and the rule
     (`ThinningRule`, `CompactionMode`) were already the library's, and the CLI's `compact` and the app's thinning both
     ran them. What each kept for itself was the cache shortcut ("the cached metadata shows nothing to delete, read
     nothing"), written twice. It is `Vault.cachedCompactionVerdict`, used by `loadForCompaction` and by the app's step.
     The app's async per-note step (`NoteWriter.thin`: the coordinated read and write, `verify`, the open-note check)
     moved from `SempereAppCore` to `Sources/Sempere/NoteThinning.swift`, next to the writer and the planner it calls.
     `NoteThinningTests` (SempereTests, Linux) pins that it plans the same deletions, snapshots and witnesses as
     `prepareCompaction`, cold and with a warm cache, and what is left on disk after a real run. What stays
     different is the platform's: the CLI runs notes on threads with a `HybridClock`, the app on tasks with the
     `DeviceClock` actor, the iCloud coordination, and the app's `ThinningReport` (titles and a progress count for
     the preview sheet) next to the CLI's `compact` JSON items.
   - *Join approval*: done. Both call `Vault.joinRequest(matching:)` and `Vault.approveDevice`. The one rule the app
     kept for itself was reading a request by a scanned code (`joinRequest(in:words:qr:)`), which is
     `Vault.joinRequest(words:qr:)` now, with the code's text `JoinRequest.qrText` (was `commitmentQRText`). The CLI
     gained what that made possible, `devices approve --qr TEXT`, and `device init --json` prints `qr`
     (`CLIDevicesTests.testApproveByTheScannedCodesText`). The wait for a request still on its way (sync every target,
     look again) stays the model's (`approveDevice`): the CLI syncs with `store sync`, a separate command.
   - *History rendering*: done. Both read `NoteHistory.restorePoints` and `NoteHistory.groups`. A group's device,
     times, saves and checkpoint name were derived in `notes history --sessions` and again in `HistoryGroupRow`; they
     are `HistoryGroup.device`, `.start`, `.end`, `.saves`, `.checkpointName` and `.isCheckpoint`, which both read
     (`VersionHistoryTests.testCheckpointsStandAloneAndSplitSessions`; the app's `HistoryTests` run on them). Words
     ("This device", "Saved version", the compaction notice) are the app's and the CLI prints ids and kinds.
   - *Notebook rename*: already one implementation. `NoteOps.renameNotebook` (the notes' ops), `NotebookRecords.rename`
     (the empty notebooks' record) and `NotebookPath.renamed` are the library's and both `notebooks rename`/`move` and
     `AppModelCore.renameNotebook` use them, in the same order (the record first, then one delta per note). What
     differs is what each reports and the app's downloads of notes not yet here. Nothing to move.
   - *Demo generators*: no duplicate to remove. `DemoVault`, `DemoHandwriting` and `DemoSearchNotes` (screenshots and
     UI-test data, `#if DEBUG`) have no CLI counterpart: the CLI's generators (`pages scribble`, `notes dense`,
     `DenseNote`) are the loop-shaped benchmarks fixtures. Their overlap is `SyntheticInk` (already shared: the demo's
     dense note, `DenseNote` and the app's device checks all use it). `DemoVault.denseOps` keeps its own paper, row
     height and ids on purpose, because the UI tests assert on that geometry; routing it through `DenseNote` would
     change what they see. Decided in review of #35: keep `denseOps`.
   - *Bulk-export driver*: not done; moved to part 2 (the largest item, below).

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

## Wave 6 plan

Surveyed on 2026-11-08 at `aaef975` (the head of wave 5b): `Apps/Sempere/SempereApp` is 175 files and 37.3k lines,
`SempereAppTests` 143 files. The 102 files that import SwiftUI or UIKit hold 29.4k of the lines and are mostly
views, UIKit controllers and platform implementations of the library's protocols (`PageCanvasView`, `NoteListView`,
`SettingsView`, `JoinViews`, `ItemSelectionController`, `TextBoxEditorController`, the Keychain, ActivityKit,
AVFoundation and CoreGraphics services), which stay; the 73 that import neither hold the other 7.9k, part of it
words (`*+Text.swift`), which stay. What is left of logic is below, found by reading each of those 73 files and the types inside
the 102. Each part is one PR with its tests; sizes are the lines that move (the ranges are line numbers at `aaef975`).

**Rules for deciding.** Moves: a type with no UIKit/SwiftUI/PencilKit/CoreGraphics/AVFoundation symbol in it, or one
whose platform part is a protocol the app can implement (`AudioCaptureBackend`, `KeyValueStore`, `FileCoordinating`).
Stays: anything that is a view, a gesture recognizer, a `UIViewRepresentable`, or words (`String(localized:)`, kept in
the `*+Text.swift` files). A file with both is split along that line, the pure half first.

**What the app does that the CLI cannot** (read against `docs/cli.md`; the CLI has a command for nearly everything
the model does: notes, notebooks, pages, items, attachments, history, export, import, sync, devices, inbox, settings):

| Capability | Where it is | CLI | Plan |
| --- | --- | --- | --- |
| Approve a join by the scanned code | `AppModelCore.approveDevice(qr:)` | words only | **Done, part 1**: `devices approve --qr TEXT`, `device init --json` `qr` |
| Add Passphrase Copy | `AppModelCore.addPassphraseCopy`, `Vault.addPassphraseCopy` | `recovery add-passphrase --kit FILE [--generate \| --new-passphrase-env VAR] --yes` (`Epochs.swift`, `CLIEpochTests`; missing from the usage list in `docs/cli.md` until part 1, which adds it) | None needed |
| Move several notes at once (ticked notes dragged onto a notebook) | `AppModelCore.moveNotes(_:toNotebook:)` (`AppModel+Drags.swift`), one commit and one `NotebookMoveRecord`; undo is `restoreNotebooks`, reached from `NoteDragSource` → `DragPayload.notes(ids)` → `move(_:to:)` | `notes move` takes one note | Part 7: `notes move ID\|TITLE... (NOTEBOOK \| --none)` (the model's other edits are one note at a time; `renameNotebook` has `notebooks rename`) |
| Recover a recording a crash left | `RecordingRecovery` | none | No command: the recording root is the app's own scratch folder, and a CLI has no such state (`attach recording` takes the file). Decided here, reviewer may overrule |
| Cache sizes, Clear Caches | `AppModelCore.cacheSizes`, `clearCaches` | none | No command: the drawing and blob caches are the app's (the CLI's only cache is the summary cache, `--no-cache`) |
| Demo vault, debug launches | `DemoVault`, `DemoLaunch`, `DebugLaunch` | none | None: `#if DEBUG`, screenshots and UI tests only |

**Part 1 (done, #35).** This inventory, duplicate 6's check (above) with its three small unifications, `devices approve
--qr`, and the two #34 folds-in (the `onLoadFailed` doc comment, `QuickCapture.app()`'s `describeError`).

**Part 2 (done, wave 6 part 2): the bulk-export driver, and the leaves with no editor edge (about 1,150 lines).**
- The driver (duplicate 6's last item): `AppModelCore.exportJobs`/`runBulkExport` (about 120 lines of
  `AppModel+BulkExport.swift`) and `ExportCommand.runBulk`'s loop (`ExportBulk.swift`, about 50) both run, per job:
  names, skip when unchanged, load, export, `fail` on an error, `finish(cancelled:)` on a `BulkExportError` or a
  cancel. The read-ahead (`LoadAhead`, `ByteBudget`) is already `SempereRender`'s. Plan: `LoadedForExport` and
  `loadNoteForExport` (`AppModel+Export.swift`, about 30 lines, which only call `Vault.loadNote` and `reconstruct`)
  move to `SempereRender`, with one async `BulkExportDriver.run(jobs:session:vault:…)` that owns the turn and the
  read-ahead; the app passes what is its own (`flushEditors`, the iCloud `ensurePDFAttachmentsLocal`/`ensureMediaLocal`
  as a `prepare` closure, `ensureCurrent(gen)`, the progress) and the CLI passes none and keeps its Ctrl-C. Tests
  (Linux): the driver's order, skips, one failed note not stopping the rest, cancel between notes, the memory budget
  (the cases of `BulkExportTests` in `SempereAppCoreTests` become its tests) and CLITests for `export --all` unchanged.
- `PageStackLayout.swift` (215, pure geometry) and `PageStackLayoutTests` (189), `ZoomDetent` (43), `PageLayoutChoice`
  (`NewNoteLayout`, `PageStrip`, 66), `PaperDraft` and `PaperPreference` (210) with `PaperPickerTests`, `TextBoxEmoji`
  (66) with `TextBoxEmojiTests`, `PickedFolderRules` (134; `Platform.isMac` becomes a parameter), `SelectionStorage`
  (`LibraryCommands.swift` 94-110), `KeyRemoval` (57), `ExistingKeyInput`'s status rules (100; its messages stay),
  `AddDeviceApproval` (99, the sheet's model; it only calls `AppModelCore`), the key halves of `ColumnLayout`
  (`stored`, `toggled`, `withoutNote`; the `NavigationSplitViewVisibility` mapping stays), `NoteTitle` (`NoteCanvasView`
  780-786, the trimming), `SearchSnippetText` and `RecognitionResultsText` (`NoteListView` 705-717, 797-817: their words
  stay), `TypedWords` (`JoinViews` 121-131), `ExportHandOffState` (`ExportSheet` 322-333).

  *Result.* `BulkExportDriver`, `LoadedForExport` and `BulkExportProgress` are in `SempereRender`
  (`BulkExportDriverTests`, Linux: order, skips without reading, a failed note not stopping the rest, stop between
  notes, a `BulkExportError` ending the run, the progress sequence, the memory budget). Only `LoadedForExport.read` (the
  blocking read; the summary only on request, for the share export) moved: `loadNoteForExport` stays in the app because
  it downloads first (`downloadNote`, the partial-copy check). The app's `runBulkExport` sets the driver's hooks (open
  notes saved first, iCloud downloads, the vault closing, progress) and the CLI's `runBulk` its event printer and
  Ctrl-C (`CLIBulkExportTests`, including a real SIGINT). The leaves moved to `SempereAppCore` with their rules and
  tests (Linux), the words staying in `*+Text.swift` files of the app: `PageStackLayout` (with `PageScrollTracker`),
  `ZoomDetent` (with `ZoomSteps`, which it needs), `NewNoteLayout` and `PageStrip`, `PaperDraft`, `PaperParameter`,
  `PaperBackground` and `PaperPreference`, `TextBoxEmoji`, `PickedFolderRules` (rules return a `Violation`),
  `SelectionStorage`, `KeyRemoval`, `ExistingKeyInput` (the status carries an `Issue`), `AddDeviceApprovalCore`
  (generic over the host as `AppModelCore`; the app's `AddDeviceApproval` is its alias), `ColumnChoice` (the stored
  string; `ColumnLayout` keeps the SwiftUI mapping), `NoteTitle.trimmed`, `SearchSnippetText`, `RecognitionPagesRead`,
  `RecognitionResults.detailParts` and `TypedWords`. Left in the app: `ExportHandOffState` (it holds the UIKit
  `PresentationAnchor.Box`; its fields are view state, not rules).

**Part 3: the editor's interaction models (done, #38).** The pure types inside the gesture files moved to
`Sources/SempereAppCore/Editor/`; the controllers keep the recognizers and call them.

Wave 6 part 3 (2026-11-09) moved:

| Core type (`SempereAppCore`) | From | The app keeps (as an extension or a caller) |
| --- | --- | --- |
| `ItemSelectionModel` (`Scope`, `Drag`, `Tap`) | `ItemSelection.swift` | `ItemSelectionView`, the recognizers, `ItemSelectionController` |
| `ItemMenu` | `ItemSelection.swift` | the menu's buttons and words |
| `FingerTapTracker` | `ItemSelection.swift` | `FingerItemTapRecognizer` |
| `MouseSmoothing` (key, default, `load(from:)`, `takesPointer`) | `MouseInk.swift` | `touchTypes`, `stroke(…)` (PencilKit) |
| `ItemPointer` (`zone`, `angle`, `identifier`) | `ItemPointer.swift` | `path`, `twoWay`, `fourWay` (`UIBezierPath`) |
| `InsertOptions` (`PDFPagesPlacement`, `pdfPagesPlacement`, `pdfImport`, `cascade`), `EditorFileImport`, `CanvasDropContent` | `InsertUI.swift`, `VideoViews.swift` | `camera`, `pdfPagesTitle` (the words), `CanvasDrop` (item providers, `UTType`) |
| `TextBoxPlacement` | `TextBoxEditor.swift` | the style bar and editor |
| `TextColourPalette` (`Standard`, `Label`, `swatches`, `label(of:)`, `opaque`) | `TextBoxEditor.swift` | `standard` (system colours on light paper), `name(of:)` (words), `swatchImage` |
| `PageExtent` (`Footer`, `scrollHeight`, `footerScreenHeight` as `Double`) | `PageCanvasView.swift` | the canvas's content size and footer button |
| `TitlePatternCheck` (`Field`, `Status`, `status(of:)`) | `SettingsView.swift` | `TitlePatternField` words the fields and problems |
| `ObjectEraseSweep` (new) | `ObjectEraserController` | the controller: canvas, `PKStroke` to `StrokeHitShape`, display link, undo |

Where the plan text above turned out different:
- `InsertState` stays in the app: it is `@Observable` state of `PhotosPickerItem`, `CameraMode` and `CropRequest`, and its one
  rule (`open`) is two lines over `InsertOptions.pdfImport`, which moved.
- The text colours are a `Standard` enum (black, blue, green, yellow, red) that the app resolves to `UIColor.system*` on light
  paper, not `Color` values in the core, so the swatches keep tracking the OS.
- `InsertTests` and `ObjectEraserTests` stay in the app: what is left in them drives a canvas host, a `PKCanvasView` and the
  editor (drops, crop with undo, the gesture against the canvas), and the pure rules they held now have core tests
  (`EditorRulesTests`, `ObjectEraseSweepTests`).

Decisions (reviewed): (1) `InsertState` stays in the app; (2) the colours resolve to `UIColor.system*` in the app;
(3) `MouseSmoothing.load(from:)` takes `any KeyValueStore` (the app makes `UserDefaults` conform), like its sibling
preferences; (4) `ObjectEraser.erasing` and the controller's touch-type helpers stay in the app (PencilKit, UIKit). The
`CGPoint` and `CGFloat` types in `InsertOptions.cascade` and `FingerTapTracker` are Foundation's on Linux; part 6 decides
whether the CoreGraphics point types give way to the library's.

**Part 4: preferences and the math models (about 800 lines).** `MathModels` (347, the installed and downloadable
recognizer models: status, download, import, remove; it calls the library's `MathModelStore` and a download seam) with `MathModelFetchTests`
and `MathSettings` (100), `RecordingPreferences` (166: `RecordingPreference`, `TranscriptionPreference` and its
engine lines; `installSettingsHooks` stays), `AppearancePreferences` (99), `EraserPreference` (60; the PencilKit
type mapping stays), `DragTestSettings`' `NoteDragTestRun` (debug), and the app's `SettingsView` rows' logic that
sits in the views (the title-pattern field's validation is part 3). Each preference moves with its key so
`SettingsSyncBridge` and the settings catalog read one definition.

**Part 4 done (wave 6).** Moved to `Sources/SempereAppCore/Preferences/`, with Linux tests (`MathModelsTests`,
`PreferencesTests`): `MathModels` (status, download, import, remove, choosing the model to read with; the
`MathModelDownload` driver; `MathModelFetching`), `MathRecognitionPreference`, `AppTheme` and `NotePagesAppearance`
(values, keys, storage), `EraserModeStorage` (the key and stored names, which the palette and settings sync both
read), `RecordingPreference`, `TranscriptionPreference` (the engine choice, the engine rows and their states as typed
values, the model status), and `NoteDragStyle`, `NoteDragDebug`, `NoteDragTestRun` and `RevealClicks` (the hidden drag
diagnostics). What stays in the app, and why: `URLSessionModelFetcher` (the `URLSession` part of the download seam;
`FoundationNetworking` is `SempereWebDAV`'s alone, and `MathModelFetchTests` stays with it), the Core ML loader and the
`SEMPERE_DEBUG_MATH_MODEL` folder (platform), the PencilKit mapping of `EraserPreference`, `installSettingsHooks`,
and every word (`*+Text`, the failure texts, the engine lines, the drag run labels). `SettingsView`'s own rows hold
only layout and bindings, apart from the eraser row's name mapping, which now calls `EraserModeStorage`.
`MathSettings` (the Handwritten Math section, listed above as moving) stays: it is the view, and its logic is `MathModels`.
`AppSettingsStorage` (`SettingsSyncBridge.swift`) stays for now and moves in part 8, once parts 2 and 3 have landed
(it reads their types).

**Part 5: the recording session (about 400 lines).** `RecordingSession` (`AudioRecorder.swift` 212-488: the state
machine of pause, resume, interruption and file layout) and `RecordingAssembly` (489-544), `RecordingError` and
`NoteEditor+RecordingSession` (89), behind the existing `AudioCaptureBackend` protocol (11-30; `AVAudioCaptureBackend`,
65-211, stays). A fake backend gives the state machine Linux tests (the cases of `RecordingTests` that do not need the
real audio engine, `RecordingRelaunchTests`); the AVFoundation cases stay. Size check first: `QuickCapture`'s
`CaptureRecorder` may already cover half of it.

**Part 6: the PencilKit and CoreGraphics boundaries (done, wave 6).** Each file was read first; what was a rule moved, what
was only drawing stayed. Moved, with Linux tests:

| Rule | To | The app keeps |
| --- | --- | --- |
| `NibSize` (the ink-size maps and the measurements behind them), `StrokePieces` (which format strokes a canvas stroke stands for: widest-point width, identity transform omitted, one piece per visible mask range), `Color(unitRed:…)` | `SempereAppCore/Canvas/StrokeConversionRules`, `Sempere` (`Color`) | `StrokeConversion` (the `PKStroke`, `PKInk`, `PKStrokePath` and `UIColor` mapping, `CGSize` wrappers of `NibSize`) |
| The fingerprint key's layout and the cheap "unchanged" test (`CanvasStrokeInfo.init(ink:color:…point:)`, `isUnchanged(id:…)`, `sampled`) | `Sempere/CanvasStrokeFingerprint.swift`, next to `CanvasStrokeInfo` and the ledger | `CanvasStrokes`: reading the numbers off a `PKStroke`, and the ledger items (`PKDrawing`, `PKInkingTool`) |
| `DrawingPreparationRules` (visible-first choice and threshold, a stroke's extent, the cached-drawing check) | `SempereAppCore/Canvas/DrawingPreparationRules` | `DrawingPreparation`: conversion, `PKDrawing(data:)`, and `CGRect.intersects` (kept as the test of "on screen" so the choice cannot drift) |
| `LassoTrace` (which moves the loop keeps, the 4,096 cap, divide by zoom) | `SempereAppCore/Canvas/LassoTrace` | `MathLassoController`: the pan, the dashed layer, the touch types |
| `PageColorInversion` (HSL arithmetic, `converts(kind:)`) | `SempereAppCore/Canvas/PageColorInversion` | `PageColorInversion+Image`: the pixel pass over a `CGImage` |
| `DrawingToolState.widthRange(for:within:)`, `clamped` | `Sempere/DrawingTools.swift`, with the width ranges | `DrawingToolbox`: `PKTool`, `UIPencilInteraction`, defaults, the notification |
| `TextBoxStyle`, `TextBoxRules` (family names, paragraph alignment and direction, language to take, run overrides, the written content, `relaid`, Markdown content, `changedRange`, decoration geometry, `extent`, `clusterTexts`) | `SempereAppCore/Editor/TextBoxRules` | `TextBoxEditing` (the attributed string and its keys), `TextBoxLayout` (TextKit breaks, CoreText runs, glyph drawing, outline fonts, emoji bitmaps) |

Already in the core or the library, so nothing to delete: the stroke order and ledger rules `CanvasStrokes` was thought to
copy (`StrokeLedger`, `NoteCanvas`'s `PreparedInk`) are used, not repeated, by `CanvasStrokes`.

Only drawing, and so left in the app: the `InkTool` ⇄ `PKInk.InkType` maps and `UIColor`, `CGAffineTransform` and
`PKStrokePoint` conversions; `CanvasStrokes`' ledger items; `PKDrawing` cache decoding; the lasso's gesture and layer;
the `PKTool` mapping, the Pencil double-tap and squeeze mapping, `PKInkingTool.convertColor`; every `NSAttributedString`
attribute and `UIFont` trait read; TextKit's line fragments, CoreText typesetting, glyph and decoration drawing, the
outline-font and emoji-bitmap builders (their per-box byte and placement budget is a cache of renders, not a rule).

Tests: the app's `PageColorInversion` colour tests, the `sampled` indices test and the Markdown content and `changedRange`
test moved to Linux (deleted in the app); the app suites that drive PencilKit (`StrokeConversionTests`,
`StrokeLedger*Tests`, `DrawingCacheTests`, `DrawingToolboxTests`, `TextBoxLayoutTests`, `MarkdownBoxTests`) stay and
now check the moved code against the real framework. `ObjectEraser.erasing`, used only by `ObjectEraserTests`, became that
suite's private reference (decision below).

Decisions (for the reviewer of the wave 6 part 6 PR): (1) `CGPoint` and `CGFloat` in `InsertOptions.cascade` and
`FingerTapTracker` stay Foundation's, which `SempereAppCore` already uses throughout (`PageStackLayout`, `NoteEditor`, the
insert calls); (2) `ObjectEraser.erasing` leaves the app target for the tests that use it.

**Part 7 (done, wave 6 part 7): `notes move` for several notes (about 120 lines).** `notes move ID|TITLE... (NOTEBOOK | --none)`: every note
is resolved first (`Vault.resolveNote`), then one all-or-none move goes through the library. The loop of
`AppModelCore.moveNotes` moves into `Sources/Sempere` if it is not there already, one implementation for the app and the
CLI; the undo step (`NotebookMoveRecord`, `restoreNotebooks`) stays the app's. With `--json`, `docs/cli.md`, `CLITests`
(several notes, one unresolvable note writes nothing, `--none`) and a changelog fragment. Nothing else is left: the
passphrase copy already has `recovery add-passphrase`, and the other model edits are one note at a time.

Result: the decision half of `AppModelCore.moveNotes` (dedupe, skip notes already there, skip deleted ones) is now
`NoteOps.notesToMove` in `Sources/Sempere/Edit.swift`, which the app's loop and the new `Vault.moveNotes` both call; the
app keeps its own write loop (it writes through the editor's `NoteWriter` and device clock) and the undo step. `notes move`
takes `ID|TITLE... (NOTEBOOK | --none)`: one note prints exactly what it did, several go through `Vault.moveNotes` after
every note resolves, and `--json` prints `{notebook, notes: [EditJSON]}` for several. Deleted notes move from the CLI, as the
one-note command always did; the app's drag leaves them alone.

**Part 8: the app's test target.** After parts 2 to 6 move the logic, `AppSettingsStorage` (`SettingsSyncBridge.swift`, the
storage half of settings sync, which reads the types parts 2 and 3 move) moves with its `SettingsSyncAppTests`, and sweep `SempereAppTests`: of its 143 files, 61
import none of UIKit, SwiftUI, PencilKit, AppKit, AVFoundation, CoreGraphics, PDFKit, Vision, ActivityKit, AppIntents,
UserNotifications, Security, LocalAuthentication, ImageIO, CoreText, QuartzCore, Speech, SwiftMath,
UniformTypeIdentifiers or Photos (the review counted 64 when UniformTypeIdentifiers, Security and
LocalAuthentication, which are Foundation-level on Linux or easily faked, are left out of the list). Those that test the words
(`*TextAppTests`, `LocalizationTests`, `ReadOnlyVaultTextTests`) need the app bundle's catalog and stay; those that
test a model or a rule (`MenuHandlerTests`, `MenuBarItemTests`, `SyncFolderPlacementTests`, `JoinThroughProviderTests`,
`DeviceWriteStoresTests`, `OfflineSyncAppTests`, `SearchTests`, `BrowserTests`, `ListAlertTests`, `NewVaultKeyTests` and
the like) are checked against `Tests/SempereAppCoreTests` for a twin and either deleted as a duplicate or moved. What
remains is the screen's: the canvas, gestures, PencilKit, the real recorder, the extension targets and the UI tests.
The "done when" list is then checked line by line, and wave 6 is closed.

**Decisions taken in the review of #35 (2026-11-09).** (1) `DemoVault.denseOps` stays as it is. (2) No CLI command for
recording recovery or cache sizes. (3) `NoteWriter.thin` stays in `Sempere`. (4) Part 2's driver is one async
`BulkExportDriver` in `SempereRender`, on condition that the CLI keeps its Ctrl-C behavior and the output of
`export --all`, both pinned by `CLITests` in part 2.

Order: 2, 3 and 4 are independent (any order, one PR each); 5 follows nothing but is the riskiest to test; 6 comes
after 3 (it reuses the types 3 creates); 7 can run any time; 8 is last.

## Done when

- `Apps/Sempere/SempereApp` holds views, glue and the platform implementations of the protocols, and
  nothing else.
- No logic exists in both the app and the CLI.
- The app's test target holds only tests that need UIKit, SwiftUI, PencilKit or the screen.
