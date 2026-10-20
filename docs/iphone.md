# iPhone (reader)

The iPhone app is the iPad app's target with the iPhone device family added
(`TARGETED_DEVICE_FAMILY = "1,2"`): one target, one bundle id, one code base. It is a
**reader**: browsing, searching, opening, exporting and unlocking work as on the iPad; writing
is possible but not emphasized. Everything phone-only is gated on `Platform.isPhone` (`UIDevice` idiom
`.phone`) or lives in `PhoneLayout.swift`. The note view's modes and toolbar are shared by every device
(`NoteModes.swift`, `NoteToolbar.swift`; "The note view on every device" below) and differ only where a
device needs it.

## Layout

`NavigationSplitView` collapses to one stack in compact width, so an iPhone shows one
column at a time:

1. the vault (`SidebarView`: All Notes, notebooks, tags, Recently Deleted; the close-vault and
   key buttons). Notebooks fold as on the iPad: a notebook with sub-notebooks has a chevron at the end
   of its row that folds or unfolds them (folded at first), and a tap on the row opens the notebook.
   The phone draws these rows itself (`PhoneNotebookRows`): an outline row's tap only folds it on the
   phone's stack and never selects it, so a notebook holding sub-notebooks could not be opened
   (PR #27 listed the whole tree unfolded for that). A notebook chosen elsewhere is listed, its parents
   unfolded,
2. the note list (`NoteListView`, search field with scopes; New Note stays in the bar, Select, Sort
   and Handwriting move into the overflow menu),
3. the note (`NoteCanvasView`).

The stack follows the selection (`CompactNavigation`): a note chosen anywhere (a row, a search hit)
shows the note, a sidebar item with no note shows its list. A `List(selection:)` pushes only when
the selection *changes*, so going back clears the selection of the column that was left (note on
back to the list; note and sidebar on back to the vault), and the same row can be tapped again.
Closing the note this way also saves and closes its editor (`AppModel.didShowCompactColumn`; a pop
removes the view whose task would have). Only the iPhone binds the stack's column
(`preferredCompactColumn`): an iPad in compact width (Slide Over, a narrow Split View) keeps the
split view's own behavior, unchanged.
A wide landscape iPhone (Pro Max) is a regular-width split view: the columns are shown by the
system and the stored column choice (`ColumnLayout`) is ignored on the phone, so a list can never
be left hidden.

## The note view

Read-first:

- **Pan and zoom.** The page fits the width; pinch zooms up to 4x, one finger pans. The fitted
  width is a detent (`ZoomDetent`, as on the iPad and the Mac): a pinch that ends within 12 % of it
  settles on it. A paged note also zooms out to half the fitted width (several pages at once); a
  pageless note stops at the fit.
  Paged notes scroll from one page to the next (`PageStackView`), with a gap and a shadow between
  pages; the counter follows the scroll. The end of the note shows "Add Page" in Annotate and Hand, never in
  Reading: a tap while reading never writes. Pageless notes scroll one screen past the ink.
- **Page navigation** in the bottom bar (previous, "n / N", next) for notes with several pages
  scrolls to the page.
- **Three modes: Reading, Hand, Annotate** (`NoteMode`, the same on every device: "The note view on every
  device"; one value per window, `WindowUI.noteMode`, so the buttons and the canvas cannot disagree). The top
  bar shows them with two buttons, the pencil ("Annotate") and the Hand (`handButton`), at most one lit:

  | Mode | Pencil | Hand | One finger | Tap / hold on an item | Palette |
  |------|--------|------|------------|-----------------------|---------|
  | Reading | off | off | scrolls; draws nothing | nothing | hidden |
  | Hand | off | on | scrolls; drags a selected item (moves, resizes) | selects / its menu | hidden |
  | Annotate | on | off | draws (two fingers scroll) | selects / its menu (below) | shown |

  A tap on the lit button goes back to Reading; a tap on the other button switches straight to its mode (Hand
  to Annotate is one tap on the pencil, never both off). A note, and the next one, opens in Reading. Everything
  follows from the mode (`NoteModeInput.of(_:on: .phone)`): `drawingSuspended` (Reading), `selectingItems`
  (Hand), the palette (Annotate only), the bottom page bar (whenever the palette is away), the drawing aids in
  the overflow menu (Annotate). There is no Select toggle: the Hand is selection mode (a Select command request
  toggles the Hand). Both buttons are hidden for read-only notes (which draw and select nothing) and notes with
  no page. The top bar is title + two buttons + the overflow menu: it fits an iPhone SE (375 pt) without
  truncating the title badly. Edits are ordinary deltas through `NoteWriter`, exactly as on the iPad.
  (TestFlight build 5: the Hand turned Annotate on too, so going back to reading took both buttons, and turning
  the pencil off with the Hand on left both buttons off while a finger still drew.)
- **The palette has no Hand** (owner, 2026-10-19: "It serves no purpose there"), on any device: the top bar's Hand
  is the only one. (Build 5's palette Hand item, `ToolPalette.handItem`, is gone, and with it the canvas keeping
  the palette's pick in step with the mode.)
- **Annotate: tap selects an item, a hold shows its menu.** A finger draws, so a tap on a placed item (a
  picture, text box, equation, clip or card) is told apart from a stroke before ink starts
  (`FingerItemTapRecognizer`, `ItemSelectionController.fingersPick`): one finger that lifts within 0.4 s and
  8 points of where it landed, on an item, selects it (outline, handles, the bar with the item menu and Delete)
  and leaves no dot. PencilKit's drawing waits for that recognizer to fail, which it does at once for a touch that
  lands off every item (ink is not delayed) and as soon as the finger moves, rests or is joined by a second one.
  A stroke that starts on an item draws (annotating a picture or PDF page is the point of Annotate); only a tap
  or a hold selects. A finger held 0.45 s on an item selects it and shows the item's menu when it lifts. The
  eraser tools keep their taps. Tap beside the selection to drop it; drawing comes back.
- **The fingers a scroll takes follow the mode**: one in Reading and Hand (and on a read-only note), two in
  Annotate in every tool (one draws, as on PencilKit's own canvas), paged or pageless. On the phone the
  canvas's drawing policy follows the mode too: `.anyInput` in Annotate, `.pencilOnly` otherwise
  (`PageCanvasHost.applyDrawingPolicy`). PencilKit sets its own scroll's `minimumNumberOfTouches`
  from that policy (2 whenever a finger may draw, `-[PKTiledView updateForAllowedDrawingInput]`) and re-runs it
  by itself: when its view moves to a window and, while PencilKit's `PKToolPicker` was the palette, when its
  visibility changed (`_updateForToolPickerVisibilityChange:`, which arrived with the palette's hide animation,
  about 0.8 s after Annotate went off). With `.anyInput` kept in Reading (builds 4 and 5), that put a pageless
  note back to two fingers a moment after leaving Annotate; with the policy matching the mode PencilKit's count is the app's
  (`PageCanvasHost.phonePanTouches`). The paged stack's scroll is the app's own scroll view, set from the
  configuration (`PageStackHost.updateGestures`), which PencilKit does not touch.
- **Page actions** are in the overflow menu's Pages submenu, with or without the pencil: Add Page
  After This One, Add Page at End, Insert PDF Pages at this page, Duplicate, Delete, Undo Delete,
  Show/Hide Pages (the thumbnails, a sheet at phone width that closes when a page is picked) and the
  Pages/Pageless switch (`PageMenu`, every device). Read-only notes get the thumbnails only.
- **Swipe to turn pages.** In Reading, on a paged note that fits the width, a swipe left goes to
  the next page and right to the previous (`PhoneReading.swipeTurnsPages`; off in Hand mode, where a
  drag may move an item, while annotating or zoomed, where a swipe draws or pans).
- **Search hits** are highlighted on the page and stepped through exactly as on the iPad (the
  same canvas code; `PhonePageSwipeStackTests`).
- **The overflow menu** is the shared one ("The note view on every device"): Text and Object Eraser Size while
  annotating, Insert, Recordings (one submenu: record, and each recording), Favorite and Tags (the bar items
  that do not fit the phone's top bar, in the shared order), then Pages, Paper, All Recordings…, Rename, Export
  (PDF, PNG, text), Save Version, Version History and Keep Screen On, as on the iPad and the Mac. Pages is the
  sixth entry while reading, so it is visible without scrolling in a long (Spanish) menu. The title in the bar
  renames the note on tap or long press.

## The note view on every device

The owner (2026-10-19): "I don't like the menu inconsistencies between the devices. Make them inconsistent only
where it makes sense." The note view's modes and toolbar are one design on the iPhone, the iPad and the Mac.

### Reading, Hand and Annotate everywhere

Every device has the iPhone's three modes (`NoteMode`), shown by the same two top-bar buttons, and every note
opens in **Reading** ("It's actually kinda nice to open a note in a more-or-less read-only mode"). What each mode
lets the canvas do per device is one table (`NoteModeInput`, `NoteModeTests`):

| Device | Reading | Hand | Annotate |
|--------|---------|------|----------|
| iPhone | one finger scrolls; nothing draws or selects | one finger scrolls; a tap selects, a hold shows the menu, a drag moves the selected item | a finger draws (two scroll); the palette |
| iPad | fingers scroll; nothing selects; **a Pencil touch switches to Annotate and draws** | fingers scroll and select (tap, hold, drag); **a Pencil touch switches to Annotate and draws** | as the system says (the Pencil draws; a finger too when no Pencil is used); the palette |
| Mac | the wheel and trackpad scroll; a click or drag draws and selects nothing | a click selects, a drag moves or resizes | the mouse draws; the palette (and Drawing Tools, the Tools menu) |

The iPad's Pencil: in Reading and Hand the canvas keeps PencilKit's drawing on with the policy `.pencilOnly`
(`NoteModeInput.pencilAnnotates`, `PageCanvasHost.drawingPolicy`), so a Pencil stroke is drawn whole, and its
start (`canvasViewDidBeginUsingTool`, or the object eraser's first touch) switches the note to Annotate
(`NoteMode.pencilTouched`); the policy change waits for the stroke to end (`PageCanvasHost.inkInProgress`).
Hand mode's selection takes fingers and the pointer only there (`ItemSelectionController.pencilDraws`), so the
Pencil reaches PencilKit. Fingers follow the mode. Text and a tool picked from a menu (the Mac's Tools menu)
switch to Annotate too. The palette shows only in Annotate: the iPad's Show/Hide Tool Palette button is now
the Annotate button (one control per mode), whose press-and-hold menu keeps Compact Palette; the Mac's (which
fix/palette-button had turned into Drawing Tools, since PencilKit shows no palette there) is the Annotate
button too, with Drawing Tools beside it while annotating. The palette itself is Sempere's own on every device
("The drawing palette" below). The Mac's Tools menu has Annotate (⇧⌘P) and Hand (⌥⌘7), docs/mac.md
"Reading, Hand and Annotate". Debug launches can open notes in another mode (`SEMPERE_DEBUG_NOTE_MODE`:
`annotate`, `hand`), which the drawing UI tests use.

### The toolbar: before

As of PR #34 (`main` at 5097395). "⋯" is the overflow menu ("More"); "bar" the top bar's trailing items.

| Item | iPhone | iPad | Mac (library window) | Mac note window |
|------|--------|------|----------------------|-----------------|
| Annotate / Hand | bar (modes) | no modes: a note opened drawing | as the iPad | as the iPad |
| Show/Hide Tool Palette (hold: Compact) | none (palette = Annotate) | bar, 1st | bar, 1st | bar, 1st |
| Favorite | ⋯ 2nd | bar | bar | bar |
| Text | ⋯ (Annotate only) | bar (always) | bar | bar |
| Insert | ⋯ 3rd | bar | bar | bar |
| Recordings (record; per-recording submenu) | ⋯ | bar (tap records; hold: submenu) | bar | bar |
| All Recordings… | in the Recordings submenu, only once the note had recordings | only by holding Recordings, only with recordings (**the iPad's list button was gone**, PR #31) | as the iPad, plus Note > Recordings… | as the iPad |
| Select | none (the Hand) | bar toggle | bar toggle | bar toggle |
| Object Eraser Size | ⋯ (Annotate only) | bar (always) | bar | bar |
| Page navigation | bottom bar (not while annotating) | bar | bar | bar |
| Add Page (hold: page actions), Show Pages | in ⋯ Pages | bar | bar | bar |
| Pages submenu (actions, thumbnails, layout) | ⋯ 4th | none | none | none |
| Page Layout picker | in Pages | ⋯ 2nd | ⋯ | ⋯ |
| Paper… | ⋯ 1st | ⋯ 1st | ⋯ 1st | ⋯ 1st |
| Tags | ⋯ last | bar (from the outer view) | bar | bar |
| Rename…, Export, Save Version…, Version History… | ⋯ after the editor's items | ⋯ | ⋯ | ⋯ |
| Keep Screen On | ⋯ | ⋯ | ⋯ | none |
| Palette's Hand | last palette item | none | none | none |

Orders differed (the phone's overflow started with Paper, Favorite, Insert; the iPad's with Paper, Layout), the
same action had different homes (layout, page actions, Favorite, Tags), Text and the eraser size were always on
the iPad but Annotate-only on the phone, and the iPad and the Mac could reach a note's recordings list only by
holding Recordings once the note had some.

### The toolbar: after (one order, one set)

`NoteToolbar` lists every item once, in one order (`NoteToolbar.order`), with one availability rule
(`isAvailable`) and a placement per device (`placement(of:on:)`); `EditorView.noteToolbar` draws exactly what
`NoteToolbar.items(in:)` returns, in the library window and the Mac's note windows alike. The bar items come
first, then the overflow menu's.

| # | Item | iPhone | iPad | Mac | Offered when |
|---|------|--------|------|-----|--------------|
| 1 | Annotate (pencil) | bar | bar (hold: Compact Palette) | bar | writable note with a page |
| 2 | Hand | bar | bar | bar | writable note with a page |
| 2a | Drawing Tools (pen, marker, pencil, eraser, lasso, ruler; the same tool state as the palette) | — | — | bar | annotating |
| 3 | Text | ⋯ | bar | bar | annotating |
| 4 | Object Eraser Size | ⋯ | bar | bar | annotating |
| 5 | Insert | ⋯ | bar | bar | writable |
| 6 | Recordings (record or stop; each recording) | ⋯ | bar (tap records) | bar (tap records) | writable, or has recordings |
| 7 | Favorite | ⋯ | bar | bar | always |
| 8 | Tags | ⋯ | bar | bar | always |
| 9 | Previous, n / N, Next | bottom bar, not while annotating | bar | bar | several pages, or a writable paged note |
| 10 | Add Page (hold: page actions) | in Pages | bar | bar | writable, paged |
| 11 | Show / Hide Pages | in Pages | bar | bar | paged |
| 12 | Pages (go to, add, insert PDF, duplicate, delete, undo, thumbnails, layout) | ⋯ | ⋯ | ⋯ | it has entries, or several pages |
| 13 | Paper… | ⋯ | ⋯ | ⋯ | writable |
| 14 | All Recordings… | ⋯ | ⋯ | ⋯ | always (read-only notes too) |
| 15 | Rename… | ⋯ | ⋯ | ⋯ | always |
| 16 | Export | ⋯ | ⋯ | ⋯ | always |
| 17 | Save Version… | ⋯ | ⋯ | ⋯ | always (off for a deleted note) |
| 18 | Version History… | ⋯ | ⋯ | ⋯ | always |
| 19 | Keep Screen On | ⋯ | ⋯ | ⋯ (not in a note window) | always |

Left of the title, the iPad and the Mac keep Show / Hide Note List (the iPhone's back button is its way to the
list); the title renames the note on every device. The palette has no Hand anywhere.

Where a device differs, and why:

- **iPhone, items 3–8 in ⋯**: its top bar must fit the title, the two mode buttons and ⋯ on an iPhone SE (375 pt).
- **iPhone, page navigation in the bottom bar, away while annotating**: the top bar has no room, and the palette
  sits at the bottom while annotating (Pages turns pages then).
- **iPhone, no Add Page or Show Pages button**: no room; the same actions are in Pages.
- **iPad, Compact Palette in the pencil's menu**: the iPhone's palette is always the compact one; a Mac picks it
  in the Tools menu (Use Compact Palette) and every device in Settings.
- **Mac, Drawing Tools**: the tools as a menu beside the palette, for the pointer and the keyboard (it came first,
  when PencilKit's palette showed nothing on a Mac).
- **Mac note windows, no Keep Screen On**: the idle timer follows the library window's note (`RootView.applyIdleTimer`).
- **Mac, its menu bar too**: Tools > Annotate, Hand, Text; Note > Recordings… (⌃⌘R) — the same actions by keyboard.

### The drawing palette

PencilKit's `PKToolPicker` never shows in a Mac Catalyst app (Apple's documentation; `isVisible` stays false on
macOS 27), so the Mac had no ink color or width. The owner (2026-10-19): "If we're going to make a palette for Mac,
why not share the palette across all devices for consistency?" So every device draws with Sempere's own palette
(`DrawingPaletteView`), and no `PKToolPicker` is made anywhere.

- **One tool state** (`DrawingToolbox.shared`, the pure `DrawingToolState` in `Sources/Sempere/DrawingTools.swift`,
  tested on Linux): the tool, the tool before it, each ink's color, width and opacity, the eraser's mode and the
  pixel eraser's width, the ruler. Every canvas (the one-page canvas and each page of the stack) sets
  `PKCanvasView.tool` from it and follows its changes (`DrawingToolbox.didChange`); the palette, the Mac's Tools
  menu (⌥⌘1–5, Ruler ⌥⌘R) and Drawing Tools, and the Apple Pencil all change it. Picking a tool goes through the
  note's canvas (`CanvasCommandTarget.select(drawingTool:)`), which ends the Hand, the text tool and the math
  lasso there. The ruler shows on one canvas: the one-page canvas, or the stack's page with the focus.
- **Tools**: pen, monoline, fountain pen, marker, pencil, watercolor, crayon (PencilKit's inks, as the system
  palette offered them), the eraser (the app's sized object eraser or PencilKit's pixel eraser:
  `EraserPreference`, `ObjectEraserSize`), the lasso and the ruler. No Hand (the top bar's is the only one) and no
  text tool (Text stays in the toolbar).
- **Per tool**: eight swatches (black, gray, blue, red, green, orange, purple, yellow) and any color (the system
  color picker, `ColorPicker`), any width (a slider over the ink's range, PencilKit's `validWidthRange`, kept exactly)
  with five presets as quick picks, the opacity (every ink, as the
  system palette had it); the eraser's mode (object or pixel) and its sizes. A tap on the selected tool shows its
  choices, as PencilKit's did. Every tool keeps its own last settings, exactly, through tool switches, the modes, other
  notes, other Mac windows and relaunches (owner, PR #51: "Every tool should remember its last settings"; the ruler too).
  The width goes to `PKInkingTool` unchanged; the drawn point sizes are PencilKit's, mapped by `NibSize` when strokes are
  stored. Remembered across launches: `Sempere.drawingTools` (JSON, damaged values start
  fresh), the eraser mode under `Sempere.eraserType` and the object eraser's size under
  `Sempere.objectEraserRadius`, as before (settings sync writes those two). PencilKit's own saved palette
  (`PKPaletteNamedDefaults`) is no longer read.
- **Colors** are stored as drawn on light paper (`PageCanvasHost+Appearance`): with Note Pages ▸ Dark the
  swatches, the tools' color marks and the color picker show each color as the page shows the ink
  (`PKInkingTool.convertColor` light → dark), and a color picked there is stored back as the light one.
- **Layout**: docked at the bottom of the note, over the canvas, only while annotating (Reading and Hand have
  none). Full (iPad, Mac): every tool, the choices inline where the window is wide enough, else behind the color
  button, and the ruler; a window too narrow for every tool gets the compact one. Compact (always on an iPhone;
  Compact Palette elsewhere): pen, marker, eraser and lasso (plus a tool picked elsewhere, so the tool in use always
  shows), the choices in a popover; the iPhone's also has Undo and Redo. Pointer-friendly on a Mac: 36-point
  targets, hover highlights and a tooltip on every control.
- **Apple Pencil**: double-tap and squeeze (`UIPencilInteraction`, while annotating) do what the user set in
  Settings ▸ Apple Pencil: switch to the eraser and back, switch to the previous tool, or show the color and width
  choices (`PencilPreferredAction`). PencilKit draws the tool's hover preview on the canvas by itself.
- **Focus**: the palette is a view of the note and needs no first responder, so Annotate no longer gives the canvas
  the focus (PR #41's "the palette takes the focus" is gone); the `CanvasFocus` rules for the keyboard stay, and a
  touch on the canvas still takes the focus back for undo and the keys.
- **Draw with Finger** (iPad, as PencilKit's palette had it, `showsDrawingPolicyControls`): on, a finger draws too
  while annotating (`.anyInput`); off, only the Pencil (`.pencilOnly`). Until the user sets it
  (`Sempere.fingerDrawing`) the system's Settings ▸ Apple Pencil ▸ Only Draw with Apple Pencil decides (`.default`).
  Without a picker, PencilKit's `.default` follows only that system setting.
- **Not reproduced from PencilKit's palette**: dragging it to any edge or corner and minimizing it (it docks at the
  bottom); the reed ink (stored as the
  fountain pen anyway); the squeeze's palette at the Pencil's hover position (it toggles the docked palette's choices).

Tests: `DrawingToolsTests` (Linux: per-tool settings, storage, the Pencil's actions), `DrawingToolboxTests`,
`EraserPreferenceTests` (PencilKit tools, the canvases following the state), `DrawingPaletteUITests` (iPad,
iPhone, Mac: the palette with the modes, a color and a width reaching the stroke, the erasers and the lasso,
compact and full).

## Quick voice notes

The iPhone records voice notes without opening the app: from the Lock Screen and Home Screen
widgets, Control Center, the Action button and Siri, with a Live Activity while recording
(`docs/quick-capture.md`). Settings ▸ Quick Voice Notes turns it on and says when Live
Activities or the microphone are off for Sempere.

## Search, export, history, keys

All of them are the shared views and model code: handwriting search over the recognized text
(Vision recognition also runs on the iPhone if switched on; the text is stored in the vault so
the iPad's recognition is searchable here), share/export sheets, the history browser and its
restore, and key unlock. Status texts say "this device". Remembered keys use the Keychain with Face ID exactly as on the iPad
(`RememberedKeys`, "Remember on this iPhone"); the unlock screen is a sheet.

## iCloud Drive in the folder picker

The folder picker shows whatever locations Files shows; the app cannot hide iCloud Drive:

- The picker is SwiftUI's `fileImporter` (`UIDocumentPickerViewController` in open mode) with the
  content types `.sempere` and `.folder` (`UTType.vaultPickerTypes`; New Vault picks `.folder`).
  Open mode lists every location Files shows; the types only filter items, never locations. It is
  the same view at compact width.
- Opening documents from iCloud Drive through the picker needs no entitlement: the iCloud container
  entitlements (`com.apple.developer.icloud-container-identifiers`, ubiquity containers) are only for
  an app's own container, which Sempere does not use (`docs/io.md` "iCloud Drive"). The iOS build has
  no entitlements file; the Mac one has the sandbox's user-selected read-write.
- `LSSupportsOpeningDocumentsInPlace` is YES (`SempereInfo.plist`), so picked items are opened in
  place, not copied. `UIFileSharingEnabled` is not set: it would only show the app's own Documents
  folder ("On My iPhone › Sempere") in Files, and has no effect on iCloud Drive.

A vault in iCloud Drive is a plain folder (not a package), so iCloud syncs its files one by one and
the app merges iCloud's conflict versions of the vault's own files itself.

When iCloud Drive is missing, the device hides it: iCloud Drive syncs per device (Settings ▸ your
name ▸ iCloud ▸ iCloud Drive ▸ "Sync this iPhone", which can be off even with iCloud on), and Files
can hide a location (Browse › ⋯ › Edit). The welcome screen and New Vault show "Don't see iCloud
Drive?" (`ICloudDriveHelp`, iPhone and iPad) with those steps. The app does not try to detect this
with `FileManager.ubiquityIdentityToken`: without an iCloud container entitlement its answer is not
documented to reflect iCloud Drive. If Files › Browse lists iCloud Drive and the picker does not,
that is a bug.

## Tests

- `PhoneLayoutTests.swift` (app tests): `CompactNavigationTests`, `CompactBackTests` (a back swipe on
  the model: selections dropped, the note's pending ink saved), `PhoneReadingTests`, `PhoneCanvasTests`
  (a `PageCanvasHost` in windows of iPhone sizes: the page fits the width, reading mode disables
  drawing and keeps scrolling and zooming, annotating enables it, the iPad's canvas is not suspended) and
  `PhoneRootTests` (the root view hosted at an iPhone width, on the welcome screen and with an
  unlocked vault and a note open). They run on the iPad destination
  as well (the idiom-dependent expectations follow the destination).
- `PhoneCanvasInteractionTests` (app tests, any destination): the tap/stroke decision
  (`FingerTapTracker`), where a finger tap may start, that only PencilKit's drawing waits for it,
  selection and drawing coming back, the bar at phone width, two-finger scrolling.
- `PhoneToolbarTests` cover the phone's side of the toolbar (`NoteToolbar` with `.phone`: the two buttons, the
  bottom page bar only while the palette is away, the drawing aids only while annotating). `PhoneCanvasTests` check
  the one-page canvas's finger count and drawing policy per state, and that they survive PencilKit's own
  recount (`pencilKitsOwnRecountKeepsReadingAtOneFinger`, after each palette tool, and a move to a window).
- `NoteModeTests` and `NoteToolbarTests` (app tests, any destination): every button tap from every mode, what each
  mode lets the canvas do on each device, the drawing policy per device and mode, the Mac's Tools commands; the
  toolbar's one order on every device in every state, the same set (besides the listed differences), the same
  overflow menu, All Recordings… reachable on every device. `PencilAnnotatesTests`: an iPad's Pencil in Reading
  or Hand draws with PencilKit's own gesture, a stroke's start asks for Annotate, Hand's selection leaves the
  Pencil alone, a read-only note never switches; no palette has a Hand. (XCUITest cannot touch with a Pencil.)
- `PhoneSidebarTests`: the notebook rows, folded and unfolded, and a chosen notebook's parents unfolded.
- `PhoneCanvasModeUITests` (iPhone simulator, `scripts/app.sh test-phone-ui`; the iPad too, `scripts/app.sh
  test-ui`): every transition between the three modes, in each order, on a pageless note, checked by what the canvas does (a slow
  one-finger drag scrolls or draws one stroke, a tap on the picture selects it or not, the palette is up or not,
  which button is lit); leaving Annotate from each tool (pen, marker, object eraser, lasso) and waiting 3 s still
  scrolls with one finger; the same on a paged note. The phone's collapsed palette opens with a tap, after which
  its items (Pen, Marker, Object Eraser, Lasso; no Hand: `testThePaletteHasNoHand`) can be tapped by label.
- `NoteToolbarUITests` (iPhone, iPad and Mac: `test-phone-ui`, `test-ui`, `test-mac-ui`): All Recordings… in the
  overflow menu opens the recordings list; a note opens in Reading with both mode buttons off.
  `MacNoteModeUITests` (`test-mac-ui`): Reading, Hand and Annotate with the mouse, by the buttons and the Tools keys.
- `PhoneParityUITests.testNotebooksFoldAndUnfold`: the sidebar's chevron folds and unfolds a notebook's
  sub-notebooks without opening it.
- `PhoneCanvasUITests` (iPhone simulator UI tests, `scripts/app.sh test-phone-ui`, in
  `scripts/local-ci.sh --release`): a tap selects a picture and the other kinds without a dot, a
  hold shows the item's menu, strokes from the empty page and from an item still draw, a tap on the
  empty page draws its dot, reading mode draws and selects nothing. `PhoneReadingScrollUITests` (same
  command): a slow one-finger drag scrolls a paged note at the fitted width and zoomed in and a pageless
  note in reading mode, and a quick sideways swipe still turns the page. They need the simulator's UI
  automation (macOS Automation Mode). XCTest cannot synthesize a two-finger drag, so two-finger
  scrolling is checked on the stack.
- CI runs them on an iPhone simulator after the iPad run on `main` (`scripts/app.sh test-phone`;
  the build products are shared, so it adds a boot and a few seconds), and so does
  `scripts/local-ci.sh --release`. A PR that changes an iPhone layout runs it and lists it under
  `## Tests run`. Run it locally the same way;
  `SEMPERE_SIM_ID` picks a simulator.
- Screenshots: `scripts/screenshots.sh iphone` (6.9", `docs/appstore/screenshots.md`).

## Not done

- Not tried on a physical iPhone: the layouts, the Face ID prompt, finger annotation and tap/hold item selection are
  covered by simulator tests and by reading the code only. The mode fix (Reading, Hand, Annotate and the scroll's
  finger count) was traced and tested on the iOS 27 simulator; a real finger has not checked it yet.
- Swipe-to-turn on a pageless note that has several pages (rare); the one-page canvas has no swipe.
- Not tried on a physical iPhone either: the swipe against the system back gesture, the thumbnails sheet, the paper
  picker at half height (`PaperPickerLayout`: one strip of kinds, a capped preview, "Use as Default"
  scrolls with the controls).
