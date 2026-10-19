# Continuous integration

CI is `.github/workflows/ci.yml`. It is gated so that scarce macOS runners are not wasted.

## Policy: what runs where

The hosted macOS runner is a 3-CPU VM that needs over an hour for the app's suites, so the app is
tested on a developer's Mac by `scripts/local-ci.sh`, in three layers. Each layer posts a commit
status for the exact commit it ran on (a clean checkout of a commit GitHub has; a status is posted
only after every step passed), and something enforces each one:

| Layer | Command | Runs | Status | Enforced by |
|---|---|---|---|---|
| PR gate | `scripts/local-ci.sh` | the tooltip lint (`scripts/check-help.py`), package tests (`swift build --build-tests && swift test --parallel`), Mac Catalyst unit tests (`scripts/app.sh test-mac`, the pseudo-language layout check `PseudoLanguageLayoutTests` among them), iOS compile check (`scripts/app.sh build-ios`: the app, its unit tests and its UI tests built for an iOS simulator, nothing run) | `local/app-tests` | the `main` ruleset (required) |
| Author's targeted tests | whatever the change calls for | e.g. `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/MacItemUITests` | the PR's `## Tests run` section | the `PR lists tests run` job (`.github/workflows/pr-description.yml`) |
| Pre-TestFlight | `scripts/local-ci.sh --testflight` | the gate, then every Mac UI test (`test-mac-ui`) and the Mac launch smoke tests (`test-mac-smoke`) | `local/testflight-suite` | the TestFlight upload script checks it on the commit it builds |
| Release sweep | `scripts/local-ci.sh --release` | all of `--testflight`, then the iPad unit suite (`test`), the iPhone suites (`test-phone`), the iPhone canvas UI tests (`test-phone-ui`: tap selects, hold menu, finger draws, reading mode), the iPad UI tests (`test-ui`) and the pseudo-language UI test on the iPad (`pseudo`) | `local/release-sweep` | `release.yml`'s `prepare` job: a `vX.Y.Z` tag fails without it (a `-rc` prerelease only warns) |

- **The gate never needs the screen** and runs no simulator, so it can run on a Mac someone is
  using. It takes about ten minutes on an Apple silicon Mac with warm build caches. The
  `--testflight` and `--release` steps after the gate are UI tests that take over the screen (a
  Mac UI test fails with "Running Background" when the app cannot come to the front): leave the
  Mac alone while they run. Both also post `local/app-tests` once their gate steps passed.
- **Targeted tests**: the gate runs no UI test and no simulator, so the author picks the tests
  the change calls for (a Mac UI test for a window or menu change, `test-ui` for an iPad drag,
  `test-phone` for an iPhone layout, …), runs them with
  `-only-testing:` where that narrows them, and lists each with its result under `## Tests run`
  in the PR description (`.github/pull_request_template.md`), or writes "None beyond the gate:
  <why>". The check fails while the section is missing or empty and re-runs when the description
  is edited.
- `scripts/local-ci.sh --list` (with any mode) prints the steps and the status a mode posts;
  `--no-status` runs without posting. Logs: `build/local-ci/<step>.log`. The script runs under
  `caffeinate -dimsu` (it re-runs itself that way) so the Mac does not sleep mid-run.
- A new push needs a new gate run. A change that cannot affect the app (docs, `web/`, CLI-only
  sources: the `app` rule of the `changes` job) gets `local/app-tests` from CI's first job instead.
- **Hosted app job on a pull request:** build only (`scripts/app.sh build-ios`, plus the tooltip,
  simulator-choice and SwiftMath checks); it runs no simulator tests. On `main` and on dispatch it
  runs the iPad and iPhone suites, the iPad UI tests, the pseudo-language check and the Mac
  Catalyst suites.
- **Layouts in other languages** need no UI test on the Mac: `PseudoLanguageLayoutTests`, a hosted
  unit test, lays out the main screens in the double-length, right-to-left and Spanish
  pseudo-languages in every gate run, so `--testflight` no longer runs `pseudo-mac`
  (docs/localization.md "Checking layouts"). The iPad's layouts are still checked by the UI test
  (`pseudo`, in `--release` and CI's `app` job on `main`): the in-process check is Mac-only for now.
- Off CI, `scripts/app.sh` stops an `xcodebuild` that sits idle after printing its test
  summary (`SEMPERE_STALL_SECS`, default 180 s).

## Changelog fragments

PRs never edit `CHANGELOG.md` (every PR conflicted there). Each adds `changelog.d/<topic>.md`
([format](../changelog.d/README.md)). `python3 -I scripts/changelog-collect.py` folds them into
`[Unreleased]` and deletes them: run it on `main` before a TestFlight build and in the release PR
([releasing.md](releasing.md)). Tested by `scripts/test-changelog-collect.sh` (CI `release` job).

## Real-mouse UI tests

`MacRealMouseUITests` (in `test-mac-ui`) posts HID-level mouse events (`HIDMouse`, `CGEventPost` to
`.cghidEventTap`) instead of XCUITest's synthesized ones: an item dragged and resized with the lasso as the
palette's last tool, a click into a new text box followed by typing, and the New Notebook sheet's Create button
clicked for real. It skips itself (with the reason) when the test runner may not post events
(`CGPreflightPostEventAccess()`: Accessibility for the runner's responsible process). Every Mac UI test also
needs Automation Mode, which on a Mac that "requires user authentication" (`automationmodetool`) is enabled by a
person approving the prompt once in the desktop session that owns the screen. AutoFill's Strong Password in the
New Vault sheet stays a hand check: it needs the signed app and a signed-in Passwords/iCloud Keychain, and its
popover belongs to another process that XCUITest cannot see.

## What runs when

- **Draft pull requests run nothing.** Mark a pull request ready (`gh pr ready`) to run CI;
  later pushes run it again, and a newer push cancels the older run.
- **Only affected jobs run.** Docs-only changes run nothing. CLI-only changes skip the app
  job; a change to any `Sources/` target the app links (`scripts/release-check.sh
  --app-sources`) runs the app and release jobs. App-only changes skip Linux and macOS.
  `main` always runs everything. `gh workflow run CI --ref <branch>` runs everything on any
  branch.
- **Web viewer:** `web/` changes run the `web` job (lint, typecheck, tests, build) and
  `web-golden` (the Swift CLI's exports of the fixture vaults compared with
  `web/test/golden`). A Swift change that moves the goldens shows up on `main`; regenerate
  them with `web/scripts/golden.sh` ([web-viewer.md](web-viewer.md)).
- **Shipping-only steps** run on `main`: the static Linux release build, the app's simulator
  suites and the Mac Catalyst suites (`scripts/app.sh test-mac`, `test-mac-ui`, ad-hoc signed
  and sandboxed). When the app job fails, its "Summary of failures" step prints the failing tests and UI-test window
  dumps.
- **Extra jobs:** changes to the package run `webdav` (`scripts/test-webdav.sh` against
  wsgidav, pinned in `scripts/webdav-server-requirements.txt`, and the fault proxy in front of it
  for `SyncFaultProxyTests` ([Sync stress](#sync-stress)); a skip fails it); changes the
  web viewer reads run `web-smoke` (`web/scripts/smoke-all.sh`, browser smoke tests in
  Chromium, including the large-note stress run, the scroll-anchor check and the pixel diff against
  the CLI's SVG export; the heavy sizes and WebKit are run by hand, `web-viewer.md` "Stress tests").

## Sync stress

WebDAV sync is stressed at three levels (and timed at a fourth); all three share a two-device harness
(`Tests/SempereWebDAVTests/SyncDevices.swift`: `SyncDevice` is one device with its own vault
folder, key, device clock (`device.json`, with an optional wall-clock skew) and sync state;
`SyncDevices` makes two or more on one remote, the first creating the vault with every device's
key, and checks convergence: every device and the server hold the same note files, nothing written
was lost, nothing is left in flight, every device reads the same notes).

| Level | Runs in | What |
| --- | --- | --- |
| `TwoDeviceStressTests` | every `swift test` (6 seeds; `SEMPERE_STRESS_SEEDS=N` for more) | devices on the in-memory `MockDAV`, each through a `FaultyTransport` (seeded: requests dropped, answered 503, applied with the answer lost, downloads cut midway), interleaving notes, renames, tags, blobs, shared settings, two-way runs, pushes and simultaneous runs; request counts of idle and catching-up runs; label-only `vault.json` changes; per-device summaries; merge-copy round trips |
| `SyncFaultProxyTests` | `scripts/test-webdav.sh` (CI's `webdav` job) | real sockets: wsgidav behind `scripts/dav-fault-proxy.py`; a reset mid-download resumes with `Range`, a reset mid-upload leaves no partial blob, random 5xx and resets converge, a stalled request ends at the idle timeout, a dripping download ends at the run's time bound, request counts over latency and a bandwidth cap |
| `SyncStressTests` | `scripts/sync-stress.sh` only (about five minutes) | the seeded 640-note vault the CLI builds (`scripts/make-stress-vault.sh`: notebooks, tags, text boxes, edits from a second device, small and 3 MB images), uploaded and pulled through faults, 240 concurrent edits from both devices, idle request counts, a fresh pull canceled at random points, a merge-copy round trip; prints `STRESS` lines (times, requests by method, faults) |
| `SyncTimingTests` | `scripts/sync-stress.sh` only | the same vault without faults at `SEMPERE_STRESS_LATENCIES` ms per request (default `0,20`): first upload, first pull, two idle runs (the first checks the deep listing, the second uses it), the app's push after one edit; prints `TIMING` lines (wall time, requests by method, client connections) for before/after numbers in performance PRs |

`scripts/sync-stress.sh` runs all four (60 seeds) against a local wsgidav and the proxy, building
the vault once per seed and size in `build/sync-stress/` (`SEMPERE_STRESS_SEED`,
`SEMPERE_STRESS_NOTES`). Run it after a change to `Sources/SempereWebDAV`; it is not part of CI or
the PR gate, so list it under `## Tests run`.

**The fault proxy** (`scripts/dav-fault-proxy.py`, standard library only) forwards to the server
and, as each test configures it (`POST /__proxy__/config`, Swift: `FaultProxy`), adds latency,
caps bandwidth, resets the connection (TCP RST) after N bytes of a request or response body,
answers 5xx at random or by rule, stalls, or drips a response; rules match a method and a path
pattern, can skip the first matches and fire a number of times with a probability, all from a
seeded generator. `GET /__proxy__/stats` is the request log (method, path, status, fault, `Range`)
and the number of client connections that carried a request (keep-alive reuse shows as fewer).
Its configuration is global, so tests that use it never run in parallel.

## Launch smoke tests

`LaunchSmokeUITests` launches the app with no preferences, caches or saved windows
(`SEMPERE_DEBUG_FRESH`), unlocks the demo vault through the unlock sheet
(`SEMPERE_DEMO_PASSPHRASE`), checks the library in each column layout and opens Settings,
Vault Keys, a note window, the export sheets and Restore from Backup. On the Mac it is
`scripts/app.sh test-mac-smoke` (on `main`, and locally in `local-ci.sh --testflight` and
`--release`); the iPad's sidebar and list layouts run inside `scripts/app.sh test-ui` (on `main`
and in `local-ci.sh --release`). Failures print `SMOKEDEBUG` window dumps, the newest Mac crash report's
crashing thread and, on the iPad, the simulator's log of the app's faults and hangs.

## Other checks

- **Tools tests need are required in CI.** `SEMPERE_REQUIRE_TOOLS` (a comma list of `zbar`,
  `zip`, `pdftotext`, `bidi`, or `all`; `Tests/FuzzSupport/RequiredTools.swift`) turns a
  missing tool into a failure, and `SEMPERE_REQUIRE_POPPLER` does the same for `pdftoppm`.
  Locally those tests skip.
- **Every scene injects the app environment.** `AppSceneEnvironmentTests` (plain
  `swift test`, also on Linux) fails when a scene does not put `AppModel`, `VaultLibrary`
  and `RememberedKeys` into its root view's environment, or when a view reads one of them
  with a plain `@Environment(X.self)` instead of the non-trapping wrappers
  (`AppModelEnvironment.swift`).
- **Age is compiled with `-O` even in debug builds** (`Package.swift`): unoptimized scrypt
  makes the passphrase tests take minutes.
- **Build caches:** each job restores `.build` (`.build/xcode` for the app) from the newest
  cache a `main` run saved; pull requests never save. The key is the checkout path, the
  toolchain version and `Package.resolved`, so changing any of them starts a fresh cache. If a
  build fails in a way a clean build would not, run `gh cache delete --all` and re-run.

## Device checks in process

The owner's device checks that only need the app's own paths run as Mac Catalyst unit tests
in the gate (`test-mac`), named after their check (`c4…`, `c54…`):

| Suite | Checks |
| --- | --- |
| `InkDeviceCheckTests` (and `EraserPreferenceTests.c5…`) | c4 edited strokes on two vault copies, c5 eraser mode across notes, c11 pen-up and edits on a 20 000-stroke page, c12 and c50 the object eraser, c52 the ink's extent |
| `LoadDeviceCheckTests` | c14 playback highlights and Tap Ink to Play, c20 summary-cache saves while recognizing, c21 a 120-page note to PDF on every path, c42 PDF export right after drawing, c54 browser actions and Version History on 400 revisions |
| `SearchDeviceCheckTests` (and `TranscriptSearchAppTests.c15…`) | c15 stepping on a large note, typing during Recognize All and sync, 600 transcripts |
| `ViewDeviceCheckTests` (and `AttachmentPersistenceTests.c16…`) | c13 page-strip thumbnails, c16 many items and text after a font or OS change, c40 and c41 pages loading while another device writes |

They drive ink through `InkInjector` (`Apps/Sempere/SempereAppTests/InkInjector.swift`): a
`PageCanvasHost` in a window with its real coordinator as the canvas delegate, each edit set as
PencilKit leaves the drawing (pen-up, lasso move, resize, recolor, pixel erase) with its undo
step, and the app's own object-eraser controller. Fixtures come from `SyntheticInk`, the
generator behind `sempere pages scribble` (`InkFixture`). Timing bounds are generous (they
catch a return to the whole-drawing paths, not device speed) and the measured numbers print as
`PERF-REPORT` lines; the `ink.change` and `index.save` signposts give the same phases on a
device.
