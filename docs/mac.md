# The Mac app (Mac Catalyst)

The Mac app is the iPad target built for Mac Catalyst: same sources, same
vault code. Phase 2 (`docs/ROADMAP.md`, "macOS app") adds what a Mac expects.
Everything Mac-only is gated on `targetEnvironment(macCatalyst)` or on
`Platform.isMac` (`MacSupport.swift`), so the iPad build is unchanged: no
menu bar entries, one window, the same pointer behaviour.

**Verification status.** The logic (command list, enabling, zoom steps,
window editors, key changes, PDF export, selection restore, folder-access
check) is covered by tests that run in the `app` CI job on the iPad simulator
and, as plain Swift, on Linux. Since TestFlight build 6 the app's tests also
run **on Mac Catalyst** (ad-hoc signed and sandboxed like the shipped app):
`scripts/app.sh test-mac` runs the app suites there and `scripts/app.sh
test-mac-ui` runs `MacWindowUITests` (menus, note windows, the new-note sheet)
against the synthetic demo vault. CI runs both on `main` and on a dispatch
(`gh workflow run CI --ref <branch>`), not on pull requests. The launch smoke
tests (`scripts/app.sh test-mac-smoke`, `LaunchSmokeUITests`) run on every CI
run, pull requests included: a first launch (no preferences, caches or saved
windows) unlocks the demo vault through the unlock sheet, shows the library
in each column layout (`all`, `doubleColumn`, `detailOnly`), and opens
Settings, Vault Keys, a note window, Export…, Export Notes… and Restore from
Backup…. A Linux test (`AppSceneEnvironmentTests`) checks that every scene
injects `AppModel`, `VaultLibrary` and `RememberedKeys`. What still needs
a hand test on a real Mac is listed at the end.

## Menus and shortcuts

One type, `MenuCommand` (`MenuCommand.swift`), lists every command with its
title, shortcut and enabling rule; `MenuLayout` orders them into menus and
`AppCommands` (`AppCommands.swift`) turns that into SwiftUI. A feature that
adds a menu entry adds a case there (and a handler in `RootView.perform` or
`EditorCommands.perform`); `MenuCommandTests` fails when two commands share a
shortcut, a command is in no menu, or a plain key (one that would take typing
from a text field) is used.

Each window publishes a `CommandRouter` (its state for enabling, and what to
do for a command) as a focused scene value; the menu bar acts on the focused
window.

**UIKit's own items (fixed after build 6).** Before SwiftUI adds the app's
commands, UIKit builds a default menu bar: File > New Window (⌘N), Open… (⌘O),
Open Recent and the document commands (Duplicate, Move, Rename…, Export As…),
and Edit > Find (⌘F, ⌘G, …). UIKit refuses a SwiftUI command group holding a
shortcut it already has ("Replacement elements conflict" in the log), and with
it the whole group: in build 6 the File and Edit menus had none of the app's
commands, and ⌘N was UIKit's New Window, which opened a second library window.
So the two commands whose shortcut UIKit takes, Open Vault… and Find Notes
(`MenuCommand.nativeOnMac`), are not SwiftUI commands: `MacMenus`
(`MacMenus.swift`, run by the app delegate's `buildMenu`) turns UIKit's ⌘O and
⌘F items into them and drops UIKit's document and text-find commands and New
Window. Those two items reach the focused window through the responder chain
(`UIWindow.sempereMenuCommand`) and run its router, which each window also
publishes to `MenuRouting` (`menuRouter(_:)`); they run only when the router
enables them, but the menu shows them enabled. `MacMenuBarTests` checks the
built menu bar on Catalyst (the app's File and Edit commands are there,
UIKit's duplicates are not, no shortcut twice), and `MacWindowUITests` checks
it in the running app.

**About and Help (#142).** UIKit's Sempere ▸ About Sempere (the standard panel) and Help ▸
Sempere Help (no help book) are replaced by the app's own items (`MenuCommand.showAbout`,
`showTour`, `showKeyNotice`; `MacMenus.nativeCommand`, menu items with no key equivalent): About
Sempere, Quick Tour and About Your Key open as sheets in the focused window
(`WindowUI.expectations`, `ExpectationsSheets`). `LaunchSmokeUITests.testFirstUnlockShowsKeyNoticeThenTour`
opens them from the menu bar.

File > Export… (⇧⌘E) acts on the focused window's notes (`CommandRouter.exportIDs`:
the list's selection in a library window, its note in a note window), and its
sheet opens in that window (`ExportRequest.window`) with PDF chosen; the sheet
picks the format. (The iPad keeps the Export submenu, `ExportMenuCommands`, in
its keyboard menu.)

The File menu's import and insert commands (TestFlight build 7) open the same
pickers as the toolbars: Import PDF as New Note… sets the flag the note list's
Import PDF… button sets (`WindowUI.importingPDF`), Import from Notability… the
flag of the note list's Import from Notability… button (`importingNotability`;
the iPad, which has no File menu, uses that button); both importers live in
`WindowSheets`, so they work with the note list hidden and in note windows.
Insert Photo… and Insert PDF Pages… send `WindowUI.insertRequest` to the
window's editor, which opens its Insert menu's picker (`InsertState.open`);
they follow the Insert menu's enabling (an editable note with a page); on a
pageless note Insert PDF Pages… switches it to pages once a PDF is picked, as
the Insert menu's entry does (#104). Imports file new notes under the sidebar's notebook. With no window, only View > Library is enabled (`CommandGroupPlacement.windowList`, the natural home, is macOS-only).

| Menu | Command | Shortcut |
| --- | --- | --- |
| File | New Note… | ⌘N |
| File | Open Note in New Window | ⌥⌘N |
| File | New Vault… | ⇧⌘N |
| File | Open Vault… | ⌘O |
| File | Open Recent | submenu of the recent vaults |
| File | Reopen Last Vault | ⇧⌘T |
| File | Close Vault | ⇧⌘W |
| File | Import PDF as New Note… | ⇧⌘I |
| File | Import from Notability… | (none) |
| File | Insert PDF Pages… | (none) |
| File | Insert Photo… | ⌥⌘I |
| File | Export… | ⇧⌘E |
| File | Reload Vault | ⌘R |
| File | Export Notes… (the ticked notes, else the sidebar's notebook, else the vault, into a chosen folder or a zip; docs/io.md "Bulk export") | (none) |
| Edit | Undo, Redo | ⌘Z, ⇧⌘Z (the system's: the canvas's undo manager, or the text field being edited) |
| Edit | Find Notes (focuses the title search) | ⌘F |
| Note | Rename Note… | ⇧⌘R |
| Note | Edit Tags… | ⌥⌘T |
| Note | Paper… | ⌥⌘P |
| Note | Save Version… | ⌥⌘S |
| Note | Version History… | ⇧⌘Y |
| Note | Recordings… | ⌃⌘R |
| Note | Start Recording / Stop Recording (starts in the open note, asking for the microphone the first time; "Stop" while one runs) | ⌃⌘M |
| Note | Previous Page, Next Page | ⌘[, ⌘] |
| Note | Add Page After This One (the toolbar's Add Page) | ⇧⌘A |
| Note | Add Page at End | ⌥⇧⌘A |
| Note | Duplicate Page | ⇧⌘D |
| Note | Delete Page (never the last) | ⌥⌘⌫ |
| Note | Undo Delete Page | ⌃⌘Z |
| Note | Switch to Pageless / Paged Layout | ⌃⌘L |
| Note | Duplicate Item, Bring Item to Front, Delete Item (the item selected on the canvas; off while nothing is selected, the note is read-only, and Delete Item also while a text field may have focus) | ⌘D, ⌥⇧⌘F, ⌃⌘⌫ |
| Note | Move to Recently Deleted | ⌘⌫ |
| Note | Restore Note | (none) |
| Tools | Pen, Marker, Pencil, Eraser, Lasso | ⌥⌘1 … ⌥⌘5 |
| Tools | Text, Select (flip the toolbar toggles) | ⌥⌘6, ⌥⌘7 |
| Tools | Smaller / Larger Object Eraser (steps through the presets) | ⌥⌘[, ⌥⌘] |
| Tools | Ruler (straight lines with a mouse) | ⌥⌘R |
| Tools | Use Compact / Full Palette | ⌥⇧⌘P |
| Tools | Show or Hide Tool Palette | ⇧⌘P |
| View | Show or Hide Pages (thumbnails) | ⌃⌘T |
| File | Start / Stop Voice Note | ⇧⌘M |
| View | Zoom In, Zoom Out | ⌘=, ⌘- |
| View | Fit Page Width, Actual Size | ⌘0, ⌘1 |
| View | Hide or Show Note List | ⌥⌘L |
| View | Library (opens a library window when none is open) | ⌥⌘0 |
| View | Vault Keys (the key window) | ⌥⌘K |
| Sempere (app menu) | Settings… (the app's settings window; UIKit's own item, which opened Catalyst's generated pane, is replaced) | ⌘, |

⌘W closes a window as usual; it never closes the vault (⇧⌘W does). Zoom
steps are 1, 1.25, 1.5, 2, 2.5, 3 and 4 times the fitted page width
(`ZoomSteps`); Actual Size is one page point per screen point, within the
canvas's range. Tool commands select the tool in the system palette
(`PageCanvasHost.select(tool:)`); the compact palette has no pencil, so that
command does nothing there.

**Settings… (fixed after build 7).** UIKit also builds the app menu's
Settings… (⌘,), which opens a pane Catalyst generates (touch alternatives and
system items only), while the sidebar's gear opened the app's settings. Settings…
is now one of the `nativeOnMac` commands: `MacMenus` replaces UIKit's
preferences item with the app's, so it sits where a Mac user looks for it, and it
is no longer at the end of the View menu. It needs no window: `MenuRouting`
opens the settings window through the `openWindow` of the last window that
appeared (`openScene`), and the app delegate takes the command when no window
is in the responder chain. `MacCatalystTests.settingsInTheAppMenuAreTheApps`
checks the built menu bar (one Settings… on ⌘,, no `orderFrontPreferencesPanel:`)
and `MacWindowUITests.testCommandCommaOpensTheAppsSettings` presses ⌘, in the
running app.

Placed items (images, text boxes, PDF pages, videos, recordings' cards): the mouse always draws,
so a right-click (or two-finger click) on an item selects it and shows its
menu (Crop…, Replace Image, Delete…) without leaving the drawing tool; a click
with the lasso does the same, and Select in the toolbar turns selection mode
on (`docs/attachments.md` §13 "Selecting items").

## Recordings and export (TestFlight build 7)

Recordings were reachable only from the Recordings toolbar menu, whose list
is behind a press and hold (a split button on the Mac): users did not find
them. Now a recording that stops is placed on the page as a card
(`format.md` §8.2.9) whose play/pause button is a real `UIButton` in the
canvas (`AudioCardControls`), like the page footer's, so a mouse click plays
it without drawing; and the note's recordings are listed by Note >
Recordings… (⌃⌘R), the note's "…" menu and the Recordings menu
(`RecordingsListView`): play or pause, place on this page, transcript,
transcribe, rename, delete.

Exporting a note with a recording crashed on the Mac. Without a crash report,
the code points at the hand-off to the system after the export, not the
export itself (the renderers range-check everything and are tested with
audio): the share sheet (`UIActivityViewController`) and the save picker
(`UIDocumentPickerViewController`) were hosted inside a SwiftUI sheet, where
on Catalyst they become the share picker and save panel with no anchor, and
the share sheet's completion handler was a closure written in a main-actor
view, which Swift 6 checks at run time: called from the sharing service's
queue it stops the app. Now, on a Mac, both are presented by UIKit from the
export sheet's Share button (a popover anchored to it; the picker modally)
(`ExportHandOff`), every callback is `@Sendable` and hops to the main actor,
and recordings over 16 MiB are streamed into "PDF + attachments" instead of
being read whole. `AudioItemAppTests` exports a note with a recording and
calls the callbacks off the main thread.

## Windows and state restoration

* **Library window** (`WindowGroup` id `library`): the sidebar, the note list
  and one note on the canvas, as on the iPad.
* **Note windows** (`WindowGroup(for: NoteWindowValue.self)`): one note each,
  opened from the note's context menu or File > Open Note in New Window (⌥⌘N).
  In build 6, File had none of the app's commands (see "UIKit's own items")
  and File > New Window (⌘N) was UIKit's, which opens another library window,
  never a note; UIKit's New Window is gone now. `MacWindowUITests` opens a note
  window both ways on Catalyst and checks that no second library window
  appears.
  `NoteWindowValue` is `Codable` (vault id and note id, no path), so SwiftUI
  restores the windows that were open. A note window restored without a library
  window brings the library window up (after a second, if none appeared) to
  open and unlock the vault; the note then opens by itself. A window whose note
  belongs to another vault than the open one says so and offers to close.
* **Key window** (`WindowGroup` id `keys`; SwiftUI's single-instance `Window` scene is not available in the iOS SDK that the simulator CI builds, so repeating the command may open a second, identical window): see below.
* The library window saves its selection (sidebar item, note, vault id) with
  `@SceneStorage` and applies it once the same vault is unlocked again
  (`AppModel.restore`; a notebook, tag or note that is gone falls back to All
  Notes or no note).
* Multiple scenes are switched on for Mac Catalyst only
  (`INFOPLIST_KEY_UIApplicationSupportsMultipleScenes[sdk=macosx*]`); the iPad
  keeps its single scene.
* Every `WindowGroup` gets the model, the vault library and the remembered
  keys through one modifier (`appEnvironment`, `SceneRestoration.swift`), even
  when its own views read fewer: a view that reads an environment object its
  window lacks traps in `EnvironmentValues`.

**Windows restored from another build.** The Catalyst build and the iPad
build ("Designed for iPad" on an Apple silicon Mac, e.g. from TestFlight) share
one container, so either build may be handed the scenes the other saved. The
iPad build once crashed at launch that way: SwiftUI restored the Catalyst
build's Settings window, whose views read an object that window was not given.
So every non-library window's root is a `RestoredScene`
(`SceneRestoration.shows`): in a single-scene build (the iPad build, wherever it
runs) a restored note, Settings or key window shows the library instead, since
it is the only window and must lead back to the notes; on the Mac a note window
restored without its `NoteWindowValue` brings the library window up (unless one
is open) and closes. The library window has the id `library` in both builds.
`SceneRestorationTests` checks the rules and lays out each window's root with
only the shared environment.

Keeping the iPad build off Macs altogether is an App Store Connect setting,
not a build setting: Pricing and Availability → "iPhone and iPad Apps on Apple
Silicon Macs" (`docs/release/app-store.md`, item 4). `LSRequiresIPhoneOS` does
not do it (every iOS app has it, and Macs run such apps anyway), and
`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO` only removes the "My Mac
(Designed for iPad)" run destination in Xcode. The app stays safe either way.

**One editor per note.** All windows share one `AppModel`, one vault, one
`DeviceClock` and one edit gate, so every delta ticks the same clock. A note
has at most one `NoteEditor` (two would keep separate stroke ledgers and write
diverging deltas): while a window shows a note (`claimNote`), the library
window's detail pane shows "Open in Its Own Window" instead of opening it, and
takes it back when the window closes (`releaseNote`, once the window's last
save is written). An open that finishes after a window took its note, or after
its window closed, is dropped. Closing the vault, or changing the vault's keys,
saves and closes every editor first; a closed editor takes no more changes and
writes nothing (`NoteEditor.isShutDown`), and a note window always shows the
model's editor for its note (`windowEditors`), never a copy of its own. Only one
library window shows the canvas (`AppModel.canvasWindow`, "Show Here" in the
others): two canvases on one editor would each report a drawing without the
other's new strokes, which the ledger takes as erasures. A window's editor reads
handwriting like the pane's (the model's `recognizer` reaches it), and notes
open in a window are left out of "Recognize N Notes Now". Restored note windows
ask for at most one library window (`shouldOpenLibraryWindow`). A double-click
on a row of the note list opens the note's window too (`OpenOnDoubleClick`, Mac
only). A SwiftUI tap gesture on the row never fires there, because the list's
collection view takes the clicks for selection, and `primaryAction` is a
single click in the iPad idiom. So a `DoubleClickRecognizer` sits on the row's
cell (`DoubleClick.swift`, one per cell, its handler following the row shown).
It fires when a touch ends with `tapCount` ≥ 2, so the work the first click
starts (selecting the note, opening it) cannot break the pair, and it never
delays or cancels touches. It acts for
the same notes as the menu (`AppModel.noteWindowValue`: listed, downloaded,
not in Recently Deleted). Note > Move to
Recently Deleted (⌘⌫) is off while a search, rename or tag field may have focus.

## Tooltips

Toolbar buttons show no title on a Mac, so every icon-only control has a
`.help("…")` tooltip (TestFlight build 7). `scripts/check-help.py` (run by the
`app` CI job, with `--self-test` for its own cases) fails on a `Button`,
`Menu`, `Toggle`, `ShareLink` or `PhotosPicker` that shows an icon outside a
menu, list, form, picker or dialog and has no `.help`. A view builder whose
controls only appear in menus is marked `// help-lint: titled`; a deliberate
exception carries `// help-lint: ignore (why)`. The scan cannot see a
`.labelStyle(.iconOnly)` set on a container, so give those buttons `.help` by
hand (the recording bar's do).

## Opening PDFs from the Finder

Sempere declares PDFs (`com.adobe.pdf`) as a document type it can view, at rank
Alternate (`SempereInfo.plist`): it is offered under Open With (and on an
iPad in the share sheet and Files' Open In), never made the default PDF app.
An opened PDF is not a vault (before build 8 it was opened as one): `onOpenURL`
(library and note windows, `AppModel.handleOpened`) copies it into the work
folder at once, since its security scope ends with the call, and queues it
(`openedPDFs`, app state, not the vault's). Then (`OpenedFile.stage`):

* no vault open: a bar under the welcome screen says the PDFs wait for one
  (Discard drops them);
* a vault opening, locked or migrating: the same bar, until it is unlocked;
* unlocked: a sheet in the window with the canvas, "Import PDF" into the
  named vault, with the notebook (the sidebar's by default). Import makes one
  note per PDF through `importPDF(copy:to:password:)`, the Import PDF path
  (a protected PDF asks for its password); Choose Another Vault… closes the
  vault and the PDFs wait for the next one; Cancel discards them;
* a read-only vault (`format.md` §7.3): the sheet says so and offers only
  another vault or Cancel.

Work copies are plaintext: they are removed after the import, on Discard or
Cancel, and at launch (`PDFPreparation.purge`).

## Drag a note out as PDF

Dragging a row of the note list to the Finder (or any app that takes files)
gives a PDF named after the title (`ExportFileName.pdf`: no path separators,
colons or control characters, at most 120 bytes, "Untitled" when empty). The
item provider offers the PDF first, before the in-app note payload, with that
name as its suggested name (`NoteFileDrag`).

On a Mac the drop is a file promise, and the system may ask for the file while
the main thread waits for it. In build 6 the request ran the whole export on
the main actor, so the drop never got its file. Now the main-actor part (the
open note's pending ink is saved and, in iCloud Drive, the note downloaded:
`AppModel.prepareExport`) starts when the drag begins, and the request only
waits for it, then renders and writes off the main actor
(`PreparedExport.write`) with `SempereRender.PDFWriter`, the same renderer as
`sempere export`. `MacDragOutTests` checks that the file arrives while the main
thread is blocked. A note with unreadable revisions is refused rather than
exported with pages missing; a drag prepared before the vault closed writes
nothing (`ExportEpoch`). The file is plaintext, written under
`$TMPDIR/SempereExport/<model id>/<random id>/<title>.pdf`; the folder is
emptied when the vault closes and at launch, and files older than ten minutes
are removed on the next export. Many notes at once go through File ▸ Export
Notes… (`MenuCommand.bulkExport`, `BulkExportSheet`): on a Mac it writes into
a folder chosen in the open panel (security-scoped for the run, resumable: a
re-run skips notes already there unchanged), or a zip saved with the save
panel. It is enabled in a library window with an unlocked vault.

## PDF pages on the canvas

PDF page items are `PDFTileLayer`s (a `CATiledLayer` drawn by Core Graphics,
`docs/attachments.md` §13). In build 6 they stayed blank on the Mac. What the
Catalyst runs in CI show:

* The whole path works on Catalyst for a local vault: the blob cache (file
  protection attributes, the sandboxed temporary folder), Core Graphics, the
  tile drawing in both context orientations, Core Animation asking for tiles
  and the pixels in a window (`MacCatalystPDFTests`), and a PDF imported into
  the demo vault and opened in the running app's canvas
  (`MacWindowUITests.testPDFPagesAreDrawnOnTheCanvas`).
* One Mac difference was fixed: a tile layer redrew only when its content
  changed. An iPad redraws tiles for a new `contentsScale` by itself, a Mac
  does not, and the canvas can show a page's items before its view is in a
  window (when the display scale may not be the window's yet). Now a tile layer
  never takes a scale of 0, redraws when its scale changes, and the item layer
  lays out again when the display scale changes (a window moved to another
  display). The runner's display is 1×, so this could not be shown failing
  before the fix there.
* Not covered: the maintainer's vault is in iCloud Drive, whose attachments are
  downloaded lazily (`CloudVault`, the same code as the iPad; the runner has no
  iCloud). If pages stay blank on a Mac after this PR, that path, on a Retina
  display, is the next suspect: the DEBUG log (`SemperePerf`, `SempereProbe`)
  and the item's placeholder (a cloud symbol while downloading, a triangle with
  the error otherwise) tell which.

## Notebook combo box

The notebook field of New Note, Move to Notebook and Move Notebook (#72) is
the same view on the Mac. A Mac shows these sheets in a small window without
visible scroll bars, where the list opened below the window's edge; the field
now scrolls to the top of the form when its list opens (`NotebookField.reveal`).
`MacWindowUITests` types into it and opens the list with the chevron on
Catalyst. Typing suggestions and the chevron worked on Catalyst in CI before
this change too, so if build 6 showed neither, check that it was built after
#72.

## Key window

View > Vault Keys (⌥⌘K) shows the keys the unlocked vault is encrypted to:
label, abbreviated public key with its SHA-256 fingerprint, the date added, a
mark on the key that unlocked the vault. From it:

* **Add Device Key…** pastes another device's public key (`age1pq1…`) with a
  label, or generates a post-quantum key for it, adds it, and shows the secret
  once (copy: local only, cleared after three minutes; the text is not
  selectable, so ⌘C cannot bypass that). The secret is shown whenever the
  vault already lists the key, even if the rest of the change failed or the
  vault was closed meanwhile. Classic X25519 keys are refused
  (`docs/post-quantum.md`). The sheet and the Remove dialog act only on the
  vault they were opened for (`KeyError.vaultChanged`). A generated key can
  also be saved to a file, shared or printed as a kit there (`KeyFileActions`,
  as in Settings → Device Keys → New Key…). Adding or generating a key first
  asks the owner (Touch ID, or the password on a Mac without it), as Save
  Key… does (`AppModel.requireOwner`, security review 2026-10, P1); so does
  Recovery Kit…, which prints the secret key.
* **Remove…** drops a key. The key that unlocked the vault, and the last key,
  cannot be removed. Removal rotates the vault secret and re-encrypts every
  note (`Vault.removeRecipient`, `docs/io.md` "Recipient changes").
* **Replace…** swaps another device's key for a pasted public key or a
  generated one (shown once, as for Add) in one change: the vault secret
  rotates and every note is re-encrypted once (`Vault.replaceRecipient`, the
  CLI's `vault recipients replace`); an empty label keeps the old one. It
  asks for confirmation and then the owner check, as Add does. The key that
  unlocked the vault cannot be replaced here (`KeyError.replaceInUse`): add a
  key for this device, unlock with it, then remove the old one.
* **Recovery Kit…** is the paper kit (`sempere keys paper`): the unlocked key as
  a QR code and checked text, to print (system print panel) or save as PDF. The
  PDF holds the secret key, and the dialog says so.

Adding and removing re-encrypt every file, which takes as long as the vault is
large and needs every note local in iCloud Drive (`downloadEverything`).
Open editors hold a copy of the vault with the old secret, so all of them are
saved and closed first, the vault is replaced (`adoptRewrapped`), and
`keyEpoch` makes every view open its note again. No editor opens while the
change runs (`isChangingKeys`), and one whose open began before it is dropped.
Edits from the note list wait on the edit gate meanwhile. If some files cannot be re-encrypted the change
stays pending (`KeyError.incomplete`) and the next try finishes it.

## Mouse and trackpad

There is no Pencil, so on a Mac:

* The canvas draws with any input (`drawingPolicy = .anyInput`), not "the
  Pencil if one is paired".
* The **object eraser takes the pointer** (`ObjectEraserController.pressTouchTypes`).
  It replaces PencilKit's gesture, and used to listen for the Pencil and
  fingers only, so on a Mac the default eraser did nothing.
* **The remembered eraser mode** (object or pixel, `EraserPreference`) holds
  on the Mac too. macOS 27's Catalyst picker does not keep a
  `.fixedWidthBitmap` eraser item, the pixel eraser iPadOS 26 kept, so the
  picker gets whichever pixel type this platform keeps (`pixelPickerType`,
  probed once per launch; `EraserPreferenceTests` print what each type comes
  back as, `ERASER-PROBE`). Where none is kept, a canvas starts with the
  object eraser.
* The pointer over the canvas is a circle the size of the ink tool's stroke at
  the current zoom (`PointerCursor.diameter`, 6 to 64 pt); the object eraser
  keeps its own cursor, the lasso and the pixel eraser the system arrow.
* **Ruler** (⌥⌘R) toggles PencilKit's ruler for straight lines.
* **Smoothed strokes** (below): Settings → General → Smooth Mouse Strokes,
  Off, Light (the default) or Strong.
* Two-finger scroll and pinch scroll and zoom the canvas, as PencilKit's
  scroll view does; click-drag draws. In a paged note the pages scroll as one
  (`PageStackView`); the pointer does not drag the pages while they can be
  drawn on, and the zoom commands apply to all pages.

Not done: smoothing or simulated pressure for mouse strokes (PencilKit
produces the strokes and gives a mouse constant force, so mouse ink has a
uniform width). Post-processing strokes would change what the format stores
for them; it is left until it has been tried by hand.

### Smoothing mouse and trackpad strokes

A mouse is sampled at the event rate in whole device pixels, and a hand on
a mouse or trackpad shakes more than one holding a pen, so mouse strokes
came out jagged. With Smooth Mouse Strokes at Light or Strong, the app draws
pointer strokes itself (`MouseInk.swift`); the filter is plain Swift in the
core (`Sources/Sempere/StrokeSmoothing.swift`, tested on Linux by
`StrokeSmoothingTests`).

**When.** Only on a Mac, only for `indirectPointer` touches (the mouse and
trackpad), only with an ink tool, and not while the ruler shows: PencilKit's
ruler snaps its own strokes, so with the ruler PencilKit draws as before
(`MouseSmoothing.takesPointer`). Then `PageCanvasHost` turns PencilKit's
drawing gesture off (as for the object eraser) and `MouseInkController`'s
gesture takes the pointer; the pointer no longer drags the canvas (two-finger
scroll and pinch still work). With Off, eraser or lasso, PencilKit draws
exactly as before. The Pencil and fingers never reach this code (a Mac has
neither; on an iPad it is never active), and strokes already on the page are
never changed: a smoothed stroke is appended to `canvas.drawing`, which the
`StrokeLedger` turns into one `addStroke`, and is one undo step.

**While drawing: a 1€ filter** (Casiez, Roussel and Vogel, CHI 2012) on the
pointer, shown as a line in the tool's colour and width over the ink. It is
an exponential smoother whose cutoff rises with the pointer's speed,
`fc = fmin + β·|v|`: slow movement, where jitter shows, is averaged hard; fast
movement, where lag would show, hardly at all. At constant speed `v` the
line trails the pointer by `v / (2π(fmin + β v))`, which never exceeds
`1 / (2π β)`: 4 screen points for Light (`fmin` 4 Hz, `β` 0.04 s/pt) and
8 for Strong (1.5 Hz, 0.02 s/pt). It works in screen points (the canvas's
zoomed coordinates), since the shake is the hand's, not the page's.

**When the stroke ends: a Gaussian along the arc length**, recomputed from
the raw samples (not from the live line, so no lag survives). The samples
are resampled every screen point of arc length, convolved with a Gaussian of
σ = 2 (Light) or 5 (Strong) screen points cut at 3σ, and every second point
is kept. Why this rather than the alternatives:

* Catmull-Rom splines pass *through* every sample, so they keep the jitter
  (they only fill between samples), and PencilKit already draws a stroke's
  points as a B-spline.
* Chaikin corner cutting shrinks every corner, including the hand's real
  ones, and moves the ends unless they are pinned by hand.
* A causal filter (the 1€ filter itself) lags: the stroke would end short of
  where the pointer let go.
* The Gaussian is symmetric (zero phase: no lag, no drift), its window shrinks
  symmetrically near the ends, so the first and last samples are kept
  exactly and the ends are not pulled in, and it has a hard bound: each point
  is a weighted mean of samples within `⌈3σ/h⌉·h < 3σ + h` of arc length of
  its own, so no point moves further than that (7 pt for Light, 16 for
  Strong, at spacing h = 1) from the path the pointer took, and a real corner
  is rounded by at most that much. A curve of curvature κ shrinks by about
  κσ²/2 (0.02 pt on a 100 pt circle at Light).

Bounds: a gesture keeps at most 100,000 raw samples and the final pass at
most 16,384 resampled points (a longer stroke is resampled more coarsely),
so its work is O(n + 16,384 · 3σ) whatever the input; non-finite samples are
dropped and timestamps that run backwards are clamped. Each stored point has
the tool's width (`NibSize`, as a loaded stroke of that width), force 1,
altitude π/2 and the time of the raw sample it came from, and the stroke's
creation date is when the drag began, so recordings sync (`rec`) as before.

Tests: `StrokeSmoothingTests` (jagged line in, bounded deviation, endpoints
kept, bounded work, lag bound), `MouseSmoothingTests` (when it applies, the
stroke's width and endpoints, other strokes byte for byte, undo, one
`addStroke`), and `MacWindowUITests.testAMouseDragDrawsASmoothedStroke`
(a mouse drag in the running Catalyst app draws ink). The CLI has nothing to
add: smoothing changes only how pointer input becomes a stroke, and the
stroke is stored like any other. What needs a hand test on a Mac: how Light
and Strong feel with a mouse and with a trackpad.

## Sandbox and saved folder access

See `docs/io.md` "Saved folder access (sandboxed Mac)". The entitlements for
Mac builds are `Apps/Sempere/Sempere.entitlements` (App Sandbox, user-selected
files read/write, app-scope bookmarks), applied to Catalyst builds only
(`CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`).

## To try by hand on a Mac

1. Open a vault from the open panel, quit, relaunch: does it reopen (sandboxed
   build: `scripts/app.sh catalyst` with signing, or Xcode)? A DEBUG build logs
   `SempereDebug folderAccess scoped=… listable=…` for every open.
2. Every menu entry and shortcut above, in the library window and a note window;
   File and Edit hold no UIKit New Window, Open…, Duplicate or Find… items.
3. Open two notes in two windows (⌥⌘N and the context menu), draw in both, quit
   and relaunch: both windows come back, the vault asks for its key (or Touch
   ID) once.
4. Drag a note to the Desktop; open the PDF in Preview. Drag one that is open
   with unsaved ink, and one from an iCloud vault that is not downloaded yet.
5. Open a note with PDF pages from the iCloud test vault (attachments not yet
   downloaded on the Mac): the pages appear after the download; zoom in, move
   the window to another display.
6. New Note: type part of a notebook name; open the list with the chevron.
7. Add a key (paste and generate), remove it, print the recovery kit.
8. Draw with the mouse and trackpad, with each tool; erase with the object eraser.
   Settings → General → Smooth Mouse Strokes at Off, Light and Strong: write a
   word and a circle with each (Light should feel direct, Strong round but
   laggier); undo and redo a stroke; with the ruler shown, lines stay straight.
9. Double-click a note in the list: its window opens. Hover over every toolbar
   button: each shows a tooltip.
10. File > Import PDF as New Note…, Import from Notability… (a `.note` and a
    backup zip), Insert Photo…, Insert PDF Pages… (on a pageless note it
    switches to pages), Export…, with and without an open note.
11. In the Finder, right-click a PDF > Open With > Sempere: with the app quit,
    with no vault open, with the vault locked, and unlocked. Sempere must not
    become the default app for PDFs.
12. ⌘, and Sempere > Settings… open the app's Settings window, with and without
    a window open; there is no other Settings window.
13. Record (Recordings menu), stop: the card appears where you were looking;
    click its play button (no ink is drawn), move and resize it in selection
    mode, delete it; Note > Recordings… lists the recording, Place on This Page
    puts it back. Export the note as "PDF + attachments", then Share… and
    Save…: no crash, the PDF lists the audio in Preview's attachments.

## Menu parity and the voice note item (gap audit GA-14, GA-23)

Every toolbar-only note command has a menu entry (the table above); page commands act on paged
notes (a pageless note is one page), enable like the toolbar (a note keeps its last page; ⌥⌘⌫ and ⌘⌫ are off
while a text field or a text box on the canvas is being typed in, `NoteEditor.typingInTextBox`: a
menu key equivalent wins over the text view, where both keys delete text) and the switches say what they do next ("Hide Pages", "Use Full
Palette", "Switch to Paged Layout"). Version History opens from `WindowUI.historyNoteID`, so the
library and note windows share one sheet. There is no Edit-menu entry: the Edit menu is UIKit's,
and a group with a clashing shortcut is dropped whole, so the commands sit in Note, Tools and View.

**Voice notes from the menu bar.** File > Start Voice Note (⇧⌘M) records through the same
`QuickCapture` as Siri, Shortcuts and the widgets and seals into the vault's inbox without the
vault being unlocked; the item then reads Stop Voice Note, and the library and note windows show the usual banner
(`VoiceNoteBannerRule`, the same on every platform). Without a setup it opens the Settings window,
where Quick Voice Notes is. The system
menu-bar icon is the next section.

## Menu-bar item (GA-23)

A Sempere icon in the system menu bar (an `NSStatusItem`), on by default while the app runs
(Settings → General → Show in Menu Bar turns it off). Entries:

- **Quick Voice Note** starts a voice note; the entry then reads **Stop Voice Note** and the icon
  turns red. The same encrypted-inbox path as the iPad and iPhone (`QuickCapture`,
  docs/quick-capture.md): it works while the vault is locked, needs no window and no Face ID or
  Touch ID, and the note appears in the inbox notebook when the vault is next unlocked. Not set
  up yet: the app comes forward on Settings → Quick Voice Notes.
- **New Note** brings the app forward and creates a note in the notebook the sidebar shows (the
  New Note sheet's defaults for paper and layout), unlocking first if the vault is locked: the
  unlock sheet appears and the note is created when it closes. A request older than two minutes,
  or with no vault open, is dropped (`AppModel+MenuBar`).
- **Open Sempere** brings the app forward on a library window, opening one if all are closed.

How it works. Mac Catalyst has no `NSStatusItem` (SwiftUI's `MenuBarExtra` is macOS-only too), so
the item is a small AppKit bundle, `SempereStatusItem.bundle`, built for macOS (target
`SempereStatusItem`, `Apps/Sempere/SempereStatusItem/`) and embedded in the app's `PlugIns`
folder for the Catalyst build only (the dependency and the embed carry `platformFilter =
maccatalyst`). `StatusItemHost` loads it at launch and instantiates its principal class. The two
share a process but no types, so they only post notifications on the default center
(`StatusItemProtocol`, compiled into both): the app sends the state and the localized titles
(the bundle has no strings), the bundle sends back which entry was chosen. Missing bundle, or the
setting off: no item, nothing else changes. The item exists only while the app runs; it is not a
login item. The bundle holds no logic, no keys and no network code.

To try by hand: the icon appears at launch; Quick Voice Note with the vault locked (quit and
reopen the app, do not unlock) and then unlock: the note appears; New Note with the app in the
background and with the vault locked; the setting off and on; Open Sempere with every window
closed; the entries when the app was started from Spotlight or the Dock. Not yet tried on a Mac.
