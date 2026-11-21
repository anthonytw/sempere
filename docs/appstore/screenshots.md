# App Store screenshots

The screenshots are generated, not taken by hand: a UI test launches the debug app on a **synthetic
demo vault** built in code and saves what it sees. Nothing is uploaded to App Store Connect; the
maintainer does that with the PNGs.

```bash
scripts/screenshots.sh ipad    # iPad Pro 13-inch simulator -> build/screenshots/ipad/*.png
scripts/screenshots.sh iphone  # newest iPhone Pro Max simulator -> build/screenshots/iphone/*.png
scripts/screenshots.sh mac     # Mac Catalyst (best effort)   -> build/screenshots/mac/*.png
scripts/screenshots.sh         # all three
scripts/screenshots.sh docs-ipad|docs-iphone|docs-watch   # the website's guide shots (below)
SEMPERE_SHOTS_APPEARANCE=dark scripts/screenshots.sh docs-ipad   # their dark twins -> build/screenshots/docs-ipad-dark/
```

It needs Xcode with an iOS 27+ runtime and an "iPad Pro 13-inch" simulator (`SEMPERE_SIM_ID` picks
another; `SEMPERE_SHOTS_OUT` changes the output folder). It is a tool run by hand, never part of CI.

## Sizes

| Set | Size | How |
| --- | --- | --- |
| iPad 13" | 2064 × 2752, portrait | `XCUIScreen` screenshot on the iPad Pro 13-inch simulator (2x of 1032 × 1376 pt). App Store Connect takes the 13" size for every iPad. The script fails if a PNG has another size. |
| iPhone 6.9" | 1320 × 2868 (or 1290 × 2796), portrait | `XCUIScreen` screenshot on the newest "iPhone … Pro Max" simulator (iOS 27+). App Store Connect scales the 6.9" set to the other iPhone sizes. The script fails if a PNG has another size. The status bar shows full cellular bars. |
| Mac | 2880 × 1800 | The Catalyst window (pinned to 1280 × 800 pt) is scaled to fit and centered on a plain 2880 × 1800 canvas with `sips`. A window on a plain background is how Mac shots are usually shown; it avoids depending on the runner's display size. |

The app runs on iPhone and iPad (`TARGETED_DEVICE_FAMILY = "1,2"`). The simulator is
set to light mode and `simctl status_bar override` gives 9:41, full battery and full Wi-Fi (no clutter).
The status bar's date is the day of the run (`simctl` refused an ISO date with an offset): check it
before uploading.
The app runs with `TZ=UTC` and an `en_US` locale, so the note dates in the list are the same
on every machine. The simulator is set to English before a run (the status bar's date follows the simulator's language,
not the app's: a Spanish simulator showed "Sáb nov 14"; the script writes the language and reboots it once). The demo forces
its windows to light (`DemoLaunch.forceAppearance`, `SEMPERE_DEMO_APPEARANCE`, default `light`), so the Mac shots are light
whatever the runner's appearance; the canvas is always light anyway. The store sets are light only; the website's dark
twins (`SEMPERE_SHOTS_APPEARANCE=dark`, guide targets only) set the simulator and the demo to dark and keep the paper
light inside dark chrome, what a user sees by default (docs/design/1.2-screenshots.md §3.3).

**Mac is best effort.** A Mac UI test needs automation (Accessibility) permission for the test runner
and a window server, so the CI step runs with `continue-on-error`. The Mac test runner is sandboxed and
cannot write into the checkout, so the script reads the shots from the result bundle's attachments
(`xcresulttool export attachments`). On a GitHub `macos-26` runner this produced all six shots; they have not
been checked on a physical Mac, so look at the Mac PNGs before uploading them: a macOS notification banner of the machine that ran it can overlap the window's
top-right corner. `ScreenshotTests` therefore closes it before each Mac shot (it finds Notification Center's banner window by its place near the corner and sends it away with a hover-and-click and a swipe, as a person would; the log says `SHOTDEBUG banners`). Off CI the script builds the Mac runner without the hardened runtime, as
`scripts/app.sh` does, or a Mac with a developer identity refuses its test bundle. The Catalyst window
has a title bar and the Mac layout differs from the iPad's (three columns side by side).

## The shots

| File | Shows |
| --- | --- |
| `01-write` | A lecture note on ruled paper with a margin: headings, a diagram, a highlight; the system tool palette. Full width. Undo and Redo in the bar are both enabled: two finger strokes were drawn under the last line and Undo tapped once, so one underline is left. |
| `02-sketch` | A design sketch on cream dot paper. Full width. Same Undo and Redo state, one underline under the last bullet. |
| `03-insights` | Note Insights (1.2): the lecture note's Note Insights sheet over the note: a summary, keywords, three related notes with their shared terms, and the note's group. |
| `04-notes` | The note list (all twelve notes: dates, pages, notebook, tag chips) next to the open note. |
| `05-tags` | Sidebar (notebooks, tags) with the `lecture` tag selected, its notes, the open note. |
| `06-paper` | The paper picker over the dot-paper note. |
| `07-unlock` | The key / unlock screen of a locked vault (passphrase or pasted key). |

On the Mac the full-width shots show all three columns instead, and `01-write` and `02-sketch` draw no strokes (Undo and
Redo are in its Edit menu, which a window shot does not show). Captions are not drawn into the images;
add them in App Store Connect or a design tool. Each shot is a fresh launch whose state comes from launch
variables (below), so a layout change cannot break a shot's navigation. The exceptions are `01-write` and `02-sketch`
(two finger strokes and Undo; the iPad launch sets `SEMPERE_DEBUG_FINGERS_DRAW`, the simulator has no Pencil), which log
`SHOTDEBUG` when Undo or Redo never enabled. After Undo PencilKit redraws its tiles on the simulator, and now and then a
screenshot shows a tile of the page missing (a vertical slice of the diagram gone, though the canvas's stroke count is right
and the next screenshot is whole), so the shot is the one with the most ink of fourteen taken over 20 s; `SEMPERE_SHOTS_DIAG=1`
(`TEST_RUNNER_…`) reports the stroke count at each step and keeps a PNG of each.

**Note Insights shots.** The simulator has no Apple model, so the demo never calls one: `SEMPERE_DEMO_INSIGHTS=note|map` (below)
gives the demo's notes made-up recognized text (`DemoVault.insightsTexts`, `DemoInsightsText.swift`: three groups with words
of their own, the science notes tied by energy, electrons and light), turns Note Insights on with the package's fake
providers (a 512-dimension hashed embedder, fewer collisions than the default's 64) and runs the passes with them, so the
sheet shows real stored insights in the real format. The fake summary is the text's first sentences. The map (`map`) opens the same way and fits all its circles and labels in the sheet, but it is not a store shot: three groups of a few notes read as three circles in an empty sheet.
Set `TEST_RUNNER_SEMPERE_SHOTS_ONLY=03-insights,01-write` to take only some shots.

### iPhone shots

The iPhone is a stack, so each shot is one screen (`ScreenshotTests.phoneShots`): `01-write` and
`02-sketch` the note view (reading mode, the "Annotate" pencil in the bar; the phone draws the two strokes and taps Undo
in the compact palette, which has its own Undo and Redo), `03-insights` the Note Insights sheet, `04-notes` the note list,
`05-tags` the list for the `lecture` tag, `06-library` the vault's notebooks and tags, `07-unlock` the
unlock sheet. There is no paper-picker shot on the phone.

### Website user-guide shots

`scripts/screenshots.sh docs-ipad` and `docs-iphone` run `DocsScreenshotTests` instead: the shots the project
website's user guide (/docs) shows, into `build/screenshots/docs-ipad/` and `docs-iphone/`. Same demo vault and
simulators; the website's `scripts/media.mjs` turns them into its images.

| File | Shows |
| --- | --- |
| `docs-welcome`, `docs-new-vault` | The welcome screen of a first launch, then the New Vault sheet. |
| `docs-palette`, `docs-palette-choices` | A note being annotated, then the selected pen's choices (colors, width, opacity). |
| `docs-settings`, `docs-settings-general`, `docs-settings-sync`, `docs-settings-backups` | Settings' groups, then three of its pages. |
| `docs-search`, `docs-search-highlight` | The results for a handwritten word (the demo's search notes, stored recognition), then a hit with its words highlighted. |
| `docs-nearby-join` | Add Device on the home device with one request that came nearby ("Demo iPhone", throwaway keys, asked at a fixed 5 Oct 2026, 09:41): its six words, Nearby, They Match and Decline (`SEMPERE_DEMO_NEARBY_JOIN`, through Settings ▸ Sync & Devices ▸ Devices ▸ Add Device). |
| `docs-join-waiting`, `docs-join-waiting-nearby` | The new device's Join This Device screen waiting for its approval: six words, QR code, the delivery line and "A device nearby has this request" (`SEMPERE_DEMO_NEARBY_JOIN` on the locked demo with `SEMPERE_DEBUG_MEMORY_KEYS`, since an unsigned build has no Keychain). |
| `docs-pages-dark` | A note with Settings ▸ General ▸ Appearance ▸ Note Pages ▸ Dark (`-Sempere.notePages dark`): dark paper, ink lightness inverted. The one dark-pages shot of docs/design/1.2-screenshots.md question 1. |

`docs-watch` runs `WatchScreenshotTests` (`SempereWatchUITests`, the debug state of `WatchDebugLaunch`: a fake recorder, the debug vault's made-up name) on the newest watchOS simulator, at that watch's native size (the script takes it from the first PNG and requires it of the rest), into `build/screenshots/docs-watch/`: `01-ready`, `02-recording`, `03-saved`, `04-unsent`. Run it under the build lock with `XC_KIND=sim XC_NO_CLONE=1` (its clones are iPads). The watch shows the real time (`simctl status_bar` does not reach a watch); the language is set to English like the others. Where the watch test runner cannot write into the checkout, the script takes the shots from the result bundle's attachments.

Unlike the store shots, these tap their way to a screen, so a UI change can break one: the test keeps going,
writes whatever was on screen, and logs `SHOTDEBUG` for the shot that missed. Look at every PNG. The status bar
date follows the simulator's language, not the app's: set the simulator to English first
(`xcrun simctl spawn SIM defaults write -g AppleLanguages -array en`, the same for `AppleLocale en_US`, then reboot it).

## The demo vault

`DemoVault.swift` (`Sources/SempereAppCore`) builds `My Notes.sempere` in the app's temporary directory on every launch, with a
throwaway post-quantum key, then opens (and unlocks) it. Twelve notes in seven notebooks
(`School/Biology`, `School/Physics`, `School/Spanish`, `Work/Atlas`, `Work/Meetings`, `Personal/Books`,
`Personal/Travel`, plus two outside any notebook), seven tags, six paper styles, one two-page note.
Notes are written through `NoteWriter` like the app's own edits, at fixed dates (the newest is
5 Oct 2026), so the list is the same on every run. The ink is generated: `DemoHandwriting.swift`
lays words out letter by letter from parametric curves (cursive-looking, not legible text), plus ellipses,
boxes, arrows, a star and a padlock, all from a seeded generator (`DemoRandom`, SplitMix64). Nothing comes
from real notes. `DemoVaultTests` pins the structure, the fixed dates and the determinism
(including the random generator's values, which use their own mapping to doubles so an Xcode
update cannot move the demo ink).

All of it is `#if DEBUG` (the package's files and the app's `DemoLaunch` alike); release builds contain none of it.
`DemoVaultTests` runs in SempereAppCoreTests, on Linux too.

## Launch variables (debug builds)

| Variable | Meaning |
| --- | --- |
| `SEMPERE_DEMO` | Build the demo vault and open it. |
| `SEMPERE_DEMO_LOCKED` | Leave it locked (the unlock screen). |
| `SEMPERE_DEMO_PASSPHRASE` | Store the key in the vault's `keys/` under this passphrase and leave it locked; the sidebar and note choices apply after the unlock (launch smoke tests). |
| `SEMPERE_DEBUG_FRESH` | Start as a first launch: the preferences, the app's own `Sempere…` folders in Application Support, Caches and tmp, and the saved windows are deleted first (`DebugLaunch.resetForFreshLaunch`; files only inside an app container). |
| `SEMPERE_DEMO_NOTE` | Open the note with this key: `atlas`, `respiration`, `sprint`, `weekly`, `optics`, `quantum`, `photosynthesis`, `lisbon`, `vocabulario`, `books`, `groceries`, `thoughts`. |
| `SEMPERE_DEMO_SIDEBAR` | `all`, `notebook:School/Physics` or `tag:lecture`. |
| `SEMPERE_DEMO_PAPER_PICKER` | Open the paper picker over the note. |
| `SEMPERE_DEMO_APPEARANCE` | `light` (default) or `dark`: what the demo's windows are forced to (`DemoLaunch.forceAppearance`; an unknown value is light). |
| `SEMPERE_DEMO_INSIGHTS` | `note` or `map`: Note Insights on with fake providers, recognized demo text, passes run, then the note's sheet or the map opens (DEBUG, never an Apple model). `on`: only the fake providers and the text, Note Insights stays off until Settings turns it on (`LaunchSmokeUITests.testNoteInsightsSheetOpensFromTheNoteListMenu`). |
| `SEMPERE_DEMO_RECORDING` | The "thoughts" note also gets one recording ("Demo Recording", stand-in bytes, no transcript), and the app transcribes with a fake that writes "Demo transcript" and the language asked for (`RecordingsTranscribeUITests`). |
| `SEMPERE_DEMO_NEARBY_JOIN` | List one synthetic join request as nearby for Add Device; on the locked demo the join screen shows the nearby link connected. |
| `SEMPERE_DEMO_MAC_WINDOW` | `WIDTHxHEIGHT` in points (Mac Catalyst). |
| `SEMPERE_DEBUG_COLUMNS` | `all`, `doubleColumn`, `detailOnly`, or `stored` to keep the stored layout (see `DebugLaunch.swift`). |

## Before uploading

- Look at every PNG. The ink is deliberately not real writing; check nothing reads as a word it should not.
- 1 to 10 screenshots per size; the first three show in search results, so `01-write`, `02-sketch`
  and `03-notes` lead.
- Only features present in the submitted build; no competitor logos, no device bezels.
- If the first shot should be landscape, set `XCUIDevice.shared.orientation` in
  `Apps/Sempere/SempereAppUITests/ScreenshotTests.swift` and expect 2752 × 2064 (change the size check in
  the script).
