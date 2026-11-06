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
  because the system reads them from the app bundle. Before relying on this target, check how a Linux
  `swift build` treats an `.xcstrings` resource. If it can't, make the target Apple-only, with its
  sources behind `#if canImport(Darwin)`.
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

## Duplicates to remove first

These are cases where the app and the CLI each implement the same logic, and the two can disagree.
Each one becomes a single implementation in the library that both call.

1. **The revision writer.** `NoteWriter`/`DeviceClock` in the app and `Vault.apply`/`writeDelta` in
   the CLI handle the clock and `seq` differently. Make one writer in `Sempere`. It keeps the app's
   rule of one `DeviceClock` per state file, which CLAUDE.md requires.
2. **Where a sync folder's vault copy goes.** `folderTargetLocation` exists only in the app, so the
   CLI places the same copy somewhere else. Move it to `SempereSync`.
3. **The importers.** `AppImporters` and the CLI's `ImportRegistry` are line-for-line twins. The CLI
   also has its own `enum DeviceKeyStore`, which shares a name with the app's protocol.
4. **Sync problem classification** (`SyncStatus.problem(from:)` and `WebDAVSyncProblem.from`), the
   WebDAV connection check, how `SyncOptions` limits are filled in, the settings catalog accessors, and
   vault creation (`VaultLibrary.create` and `vault init`).
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
