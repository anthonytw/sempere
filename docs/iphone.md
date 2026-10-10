# iPhone (reader)

The iPhone app is the iPad app's target with the iPhone device family added
(`TARGETED_DEVICE_FAMILY = "1,2"`): one target, one bundle id, one code base. It is a
**reader**: browsing, searching, opening, exporting and unlocking work as on the iPad; writing
is possible but not emphasised. iPad and Mac behaviour does not change: everything phone-only
is gated on `Platform.isPhone` (`UIDevice` idiom `.phone`) or lives in `PhoneLayout.swift`.

## Layout

`NavigationSplitView` collapses to one stack in compact width, so an iPhone shows one
column at a time:

1. the vault (`SidebarView`: All Notes, notebooks, tags, Recently Deleted; the close-vault and
   key buttons),
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
split view's own behaviour, unchanged.
A wide landscape iPhone (Pro Max) is a regular-width split view: the columns are shown by the
system and the stored column choice (`ColumnLayout`) is ignored on the phone, so a list can never
be left hidden.

## The note view

Read-first:

- **Pan and zoom.** The page fits the width; pinch zooms up to 4x, one finger pans.
  Paged notes scroll from one page to the next (`PageStackView`), with a gap and a shadow between
  pages; the counter follows the scroll. The end of the note shows "Add Page" only while annotating:
  a tap while reading never writes. Pageless notes scroll one screen past the ink.
- **Page navigation** in the bottom bar (previous, "n / N", next) for notes with several pages
  scrolls to the page.
- **Light annotation.** The pencil button ("Annotate") switches finger drawing on. Until then the
  canvas draws nothing and the palette is hidden (`PhoneReading.drawingSuspended`,
  `PageCanvasHost.drawingSuspended`), so a stray finger only scrolls. Annotating shows the short
  palette (pen, marker, eraser, lasso; `PhoneReading.paletteCompact`), fingers draw
  (`drawingPolicy = .anyInput`), and the bottom bar gives way to a Pages menu so it does not sit on
  the palette. Annotation turns off again on the next note. Edits are ordinary deltas through
  `NoteWriter`, exactly as on the iPad. Read-only notes (deleted, legacy) never draw.
- **Page actions** are in the overflow menu's Pages submenu, with or without the pencil: Add Page
  After This One, Add Page at End, Insert PDF Pages at this page, Duplicate, Delete, Undo Delete,
  Show/Hide Pages (the thumbnails, a sheet at phone width that closes when a page is picked) and the
  Pages/Pageless switch (`PhonePageMenu`). Read-only notes get the thumbnails only.
- **Swipe to turn pages.** In reading mode, on a paged note that fits the width, a swipe left goes to
  the next page and right to the previous (`PhoneReading.swipeTurnsPages`; off while annotating or
  zoomed, where a swipe draws or pans).
- **Search hits** are highlighted on the page and stepped through exactly as on the iPad (the
  same canvas code; `PhonePageSwipeStackTests`).
- **The rest** is in the overflow menu: Rename, Export (PDF, PNG, text), Version History, Keep Screen
  On, Tags, Paper, and the object-eraser size while annotating. The title in the bar renames the
  note on tap or long press.

## Search, export, history, keys

All of them are the shared views and model code: handwriting search over the recognised text
(Vision recognition also runs on the iPhone if switched on; the text is stored in the vault so
the iPad's recognition is searchable here), share/export sheets, the history browser and its
restore, and key unlock. Status texts name "this device" where they meant the iPad. Remembered keys use the Keychain with Face ID exactly as on the iPad
(`RememberedKeys`, "Remember on this iPhone"); the unlock screen is a sheet.

## iCloud Drive in the folder picker

TestFlight build 6: on the maintainer's iPhone the folder picker showed no iCloud Drive, though
the iPad's did and iCloud was on. Findings (code and configuration, no device to try):

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

So the app cannot hide iCloud Drive; the device does: since iOS 18 iCloud Drive syncs per device
(Settings ▸ your name ▸ iCloud ▸ iCloud Drive ▸ "Sync this iPhone", off on some devices even with
iCloud on), and Files can hide a location (Browse › ⋯ › Edit). The welcome screen and New Vault show
"Don't see iCloud Drive?" (`ICloudDriveHelp`, iPhone and iPad) with those steps. Detecting it in the
app (`FileManager.ubiquityIdentityToken`) is not used: without an iCloud container entitlement its
answer is not documented to reflect iCloud Drive. To confirm on the iPhone: Files › Browse must list
iCloud Drive; if it does and the picker still does not, that is a new finding.

## Tests

- `PhoneLayoutTests.swift` (app tests): `CompactNavigationTests`, `CompactBackTests` (a back swipe on
  the model: selections dropped, the note's pending ink saved), `PhoneReadingTests`, `PhoneCanvasTests`
  (a `PageCanvasHost` in windows of iPhone sizes: the page fits the width, reading mode disables
  drawing and keeps scrolling and zooming, annotating enables it, the iPad's canvas is not suspended) and
  `PhoneRootTests` (the root view hosted at an iPhone width, on the welcome screen and with an
  unlocked vault and a note open). They run on the iPad destination
  as well (the idiom-dependent expectations follow the destination).
- CI runs them on an iPhone simulator after the iPad run (`scripts/app.sh test-phone`; the
  build products are shared, so it adds a boot and a few seconds). Run it locally the same way;
  `SEMPERE_SIM_ID` picks a simulator.
- Screenshots: `scripts/screenshots.sh iphone` (6.9", `docs/appstore/screenshots.md`).

## Not done

- Not tried on a physical iPhone: the layouts, the Face ID prompt and finger annotation are
  covered by simulator tests and by reading the code only.
- Swipe-to-turn on a pageless note that has several pages (rare, older notes); the one-page canvas
  has no swipe.
- Not tried on the device: the swipe against the system back gesture, the thumbnails sheet, the paper
  picker at half height (`PaperPickerLayout`: one strip of kinds, a capped preview, "Use as Default"
  scrolls with the controls).
