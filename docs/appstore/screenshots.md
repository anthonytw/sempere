# App Store screenshots

The screenshots are generated, not taken by hand: a UI test launches the debug app on a **synthetic
demo vault** built in code and saves what it sees. Nothing is uploaded to App Store Connect; the
maintainer does that with the PNGs.

```bash
scripts/screenshots.sh ipad    # iPad Pro 13-inch simulator -> build/screenshots/ipad/*.png
scripts/screenshots.sh iphone  # newest iPhone Pro Max simulator -> build/screenshots/iphone/*.png
scripts/screenshots.sh mac     # Mac Catalyst (best effort)   -> build/screenshots/mac/*.png
scripts/screenshots.sh         # all three
```

It needs Xcode with an iOS 27+ runtime and an "iPad Pro 13-inch" simulator (`SEMPERE_SIM_ID` picks
another; `SEMPERE_SHOTS_OUT` changes the output folder). In CI, run the **CI** workflow by hand with
`screenshots` ticked (`gh workflow run CI --ref <branch> -f screenshots=true`) and download the
`appstore-screenshots` artifact. That run builds only the screenshots job.

## Sizes

| Set | Size | How |
| --- | --- | --- |
| iPad 13" | 2064 × 2752, portrait | `XCUIScreen` screenshot on the iPad Pro 13-inch simulator (2x of 1032 × 1376 pt). App Store Connect takes the 13" size for every iPad. The script fails if a PNG has another size. |
| iPhone 6.9" | 1320 × 2868 (or 1290 × 2796), portrait | `XCUIScreen` screenshot on the newest "iPhone … Pro Max" simulator (iOS 27+). App Store Connect scales the 6.9" set to the other iPhone sizes. The script fails if a PNG has another size. The status bar shows full cellular bars. |
| Mac | 2880 × 1800 | The Catalyst window (pinned to 1280 × 800 pt) is scaled to fit and centred on a plain 2880 × 1800 canvas with `sips`. A window on a plain background is how Mac shots are usually shown; it avoids depending on the runner's display size. |

The app runs on iPhone and iPad (`TARGETED_DEVICE_FAMILY = "1,2"`). The simulator is
set to light mode and `simctl status_bar override` gives 9:41, full battery and full Wi-Fi (no clutter).
The status bar's date is the day of the run (`simctl` refused an ISO date with an offset): check it
before uploading.
The app runs with `TZ=UTC` and an `en_US` locale, so the note dates in the list are the same
on every machine. The demo forces light mode on its windows (`DemoLaunch.forceLight`), so the Mac
shots are light whatever the runner's appearance; the canvas is always light anyway.

**Mac is best effort.** A Mac UI test needs automation (Accessibility) permission for the test runner
and a window server, so the CI step runs with `continue-on-error`. The Mac test runner is sandboxed and
cannot write into the checkout, so the script reads the shots from the result bundle's attachments
(`xcresulttool export attachments`). On a GitHub `macos-26` runner this produced all six shots; they have not
been checked on a physical Mac, so look at the Mac PNGs before uploading them. The Catalyst window
has a title bar and the Mac layout differs from the iPad's (three columns side by side).

## The shots

| File | Shows |
| --- | --- |
| `01-write` | A lecture note on ruled paper with a margin: headings, a diagram, a highlight; the system tool palette. Full width. |
| `02-sketch` | A design sketch on cream dot paper. Full width. |
| `03-notes` | The note list (all twelve notes: dates, pages, notebook, tag chips) next to the open note. |
| `04-tags` | Sidebar (notebooks, tags) with the `lecture` tag selected, its notes, the open note. |
| `05-paper` | The paper picker over the dot-paper note. |
| `06-unlock` | The key / unlock screen of a locked vault (passphrase or pasted key). |

On the Mac the full-width shots show all three columns instead. Captions are not drawn into the images;
add them in App Store Connect or a design tool. Each shot is a fresh launch whose state comes from launch
variables (below), so the test taps nothing and a layout change cannot break a shot's navigation.

### iPhone shots

The iPhone is a stack, so each shot is one screen (`ScreenshotTests.phoneShots`): `01-write` and
`02-sketch` the note view (reading mode, the "Annotate" pencil in the bar), `03-notes` the note list,
`04-tags` the list for the `lecture` tag, `05-library` the vault's notebooks and tags, `06-unlock` the
unlock sheet. There is no paper-picker shot on the phone. Look at the PNGs before uploading: they have
not been seen on a real run yet.

## The demo vault

`DemoVault.swift` builds `My Notes.sempere` in the app's temporary directory on every launch, with a
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

All of it is `#if DEBUG`; release builds contain none of it.

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
