# Continuous integration

The PR gate runs on **GitHub Actions** (`.github/workflows/ci.yml`); pull requests and merges are on GitHub
(`anthonytw/sempere`), and Gitea is a mirror ([design/local-first.md](design/local-first.md)). Gitea Actions runs nothing: `.gitea/workflows/` holds only a README, which stops Gitea from falling back to `.github/workflows/`. The same checks run on a
Mac with `scripts/local-ci.sh`, which is optional for a pull request (reproduce a failure, check before pushing) and is what
the release-bound suites use (the UI tests need a screen and a simulator). Both run the same scripts: the Linux jobs are one
script, `scripts/ci-linux.sh` (`just ci-linux test webdav static` runs them by hand in Docker), the Mac package tests are
`scripts/ci-mac-package.sh`, the app steps `scripts/app.sh`.

## The GitHub workflow

`ci.yml` runs on every pull request that is not a draft (a push to a ready PR runs it again and cancels the older run), on
pushes to `main`, and on demand (`gh workflow run CI --ref <branch>`). Its jobs run in parallel; these names are the
**required checks** of the `main` ruleset (a job's name is its check name: renaming one blocks merging until the ruleset
is updated):

| Check (job name) | Runs on | What it runs | Local equivalent |
|---|---|---|---|
| `Help and portability checks` | `swift:6.4-noble` container | the tooltip lint, the hash tool's self-test, the cross-read guard, the test-defaults and UI-test-list checks, the mirror script's test, `scripts/check-portability.sh` | `local-ci.sh` step `help` |
| `iOS build` | `xcode-27` (macOS 27.0.1, Xcode 27.1, iOS 27 SDK) | `scripts/app.sh build-ios`: the app (which embeds the Apple Watch app, so the watch targets build for the watchOS Simulator too), its unit tests and its UI tests built for an iOS simulator, nothing run; the watch's package targets for watchOS; `scripts/app.sh build-watch` (the watch app, widgets and tests for the watchOS Simulator, and the app and widgets for a watch) | steps `ios-build`, `watch` |
| `Mac package tests` | `xcode-27` | `scripts/ci-mac-package.sh`: `swift build --build-tests` and `swift test --parallel`, skipping targets whose hash passed | step `package` |
| (not required) `Mac app tests` | `xcode-27`, on demand only | `scripts/app.sh test-mac`: the Mac Catalyst unit tests, the pseudo-language layout check among them. A manual run (`gh workflow run CI --ref <branch>`) includes it. | step `mac`, the gate for these |
| `Linux package tests` | `swift:6.4-noble` container, offline (`NET_ADMIN`, `SYS_ADMIN`) | `scripts/ci-linux.sh test`: package tests with no network, portability, removable importers (the isolation grep always; the build without the module only when `CLITests`' hash has no record) | step `linux` |
| `Linux WebDAV tests` | `swift:6.4-noble` container | `scripts/ci-linux.sh webdav`: the WebDAV integration tests against wsgidav | step `webdav` |
| `Web viewer` | `ubuntu-24.04`, Node 22 | `cd web`: `npm ci`, lint, typecheck, `npm test` (which cross-checks the renderer with the committed Swift goldens), the strict-CSP build. The goldens themselves are checked against the CLI inside `Linux package tests` (`web/scripts/golden.sh`, every run, never skipped by hash). | none |
| `PR lists tests run` | `ubuntu-24.04` | `pr-description.yml`: the description has a non-empty `## Tests run` section; **a PR that changes files under `Apps/` must also name a run of `scripts/local-ci.sh` or `scripts/app.sh test-mac` with its result** (`check-tests-run.py --app-changed`), because the hosted gate does not run the Mac Catalyst tests | none |

`Pass records (...)` (three jobs) are bookkeeping and not required (the gate jobs wait for them and run even when they fail, `!cancelled()`: a failed bookkeeping job never turns a gate job into a skipped, passing check). Jobs of a draft pull request are skipped.

Wall times on the hosted runners (the first run on the branch that added the workflow, 2026-11-09). Cold: every test ran, no
cache. Warm: every test target skipped by hash, the iOS cache restored. The build always runs: `Linux package tests` builds
twice (the package, then `check-removable-importers.sh` without the importers), so skipping tests saves ~12 of its ~24 minutes.
The second build is skipped too when it already passed (job `linux-removable`, below): warm, the job is the package build, the golden diff and the checks that always run.

| Job | Cold | Warm |
|---|---|---|
| `Help and portability checks` | 1 min | 1 min |
| `iOS build` | 7 min | 3 min |
| `Mac package tests` | 21 min | 6 min |
| `Linux package tests` | 24 min | 12 min |
| `Linux WebDAV tests` | 10 min | 1 min (the whole job is skipped when both targets passed) |
| the run (jobs in parallel) | ~24 min | ~12 min |

- **The Mac runner.** GitHub's `macos-26` images have only Xcode 26. The `xcode-27` image (preview; `xcode-27-xlarge` for
  more cores; macOS 27.0.1, Xcode 27.0, 27.1 (default) and 27.2, the iOS 27 simulators) has the iOS 27 SDK, so `iOS build` and
  `Mac package tests` run there. `.github/actions/select-xcode` keeps the default Xcode and fails unless the iOS SDK is 27 or
  later: Xcode 27.2 refuses to test a Mac Catalyst target on the image's macOS 27.0.1 ("doesn't match 27.2's deployment target").
  **The Mac Catalyst app tests are not part of the gate.** On the VM (no foreground session) the suite is not reliable:
  `CanvasFocusTests` need a key window and fail on every rerun, and the pseudo-language layout check reports a sheet that is
  still moving as an overflow about once per run (`FLAKY`, which fails a step). Two runs (cold, 14 and 16 minutes) both failed
  that way. They stay on the local gate (`scripts/local-ci.sh`, step `mac`), which an author runs for a change that touches the
  app, and on demand on Actions (a manual run). Revisit when the image's macOS catches up with the Xcode.
  The two handwriting tests in `CLIRecognizeTests` that run a real Vision recognition skip themselves in a virtual machine
  (`kern.hv_vmm_present`: Vision cannot read there); a Mac runs them.
- **watchOS compile.** `iOS build` also runs `scripts/build-watchos-package.sh`: `Age`, `Sempere` and `SempereCapture`, built with
  the watchOS device SDK (`-destination 'generic/platform=watchOS'`, unsigned, so arm64 and arm64_32; no simulator runtime), about
  2 minutes. The `xcode-27` image has the SDK (watchOS 27.0 on 2026-11-09, probed in the run of the watch core PR). Apple Watches
  with arm64_32 have a 32-bit `Int`: code in `Sources/` that the watch links must not use an integer literal or a product
  that needs more (`Revision.maxSeq` was the one that failed). The compile check does not catch a runtime trap: an `Int(someInt64)` or `Int(someDouble)` of a value over 2^31, or an
  arithmetic overflow, compiles and then traps on the watch. A grep audit of the seal path (2026-11-09) found and fixed
  `RFC3339.string(from:)` and `parse` (milliseconds since 1970 in an `Int`: every capture's manifest dates went through it),
  `Int(UInt32.max)` in `Gzip` and `PublishedSummaries`, and sums in `ADTSToMP4` and `WatchOutbox`; use `Int64` or `Int(clamping:)`. Locally: `xc-lock scripts/build-watchos-package.sh [TARGET]`.
- **The watch app's build and tests.** The iPhone app embeds `SempereWatch` (with `SempereWatchWidgets`; `Apps/Sempere/Sempere.xcodeproj`), so `build-ios` needs the watchOS **simulator SDK** (Xcode's watchOS platform, which carries the device SDK the step above uses) and builds the watch app on every run. `scripts/app.sh build-watch` builds the scheme `SempereWatch` for `generic/platform=watchOS Simulator` (app, widgets, unit and UI test bundles) and the app and widgets for `generic/platform=watchOS` unsigned, which is the only build that compiles the Control (the watchOS Simulator has no Shortcuts services behind a Control's intent and the extension dies rendering it, so simulator builds leave it out). Neither needs a simulator runtime. The unit and UI tests (`test-watch`, `test-watch-ui`: `SempereWatchTests`, `SempereWatchUITests`, a fake recorder that writes real ADTS frames) need the watchOS runtime, which GitHub's image is not known to have (the `iOS build` step prints `xcrun simctl list runtimes`), so they run on a Mac: `local-ci.sh`'s step `watch-test`, in `--testflight` and `--release`, or by hand: `XC_KIND=sim XC_NO_CLONE=1 xc-lock scripts/app.sh test-watch-ui` (xc-lock's simulator clones are iPads and iPhones). A Keychain test skips itself in an unsigned test host.
- **The Linux images** are pinned by digest: the test image (`env.SEMPERE_CI_IMAGE_ID` and the `container:` lines of `ci.yml`),
  and the static-build, packaging and smoke-test images (`STATIC_IMAGE` in `ci-linux.sh`, `release-build.sh`). The digest goes into every
  Linux hash, so a moved tag cannot reuse a record. To update: `docker buildx imagetools inspect swift:6.4-noble`, change the
  digest in every place (the `ci.yml` lines, `STATIC_IMAGE` in `ci-linux.sh`, the images at the top of `release-build.sh`), and the next run runs every Linux target once.
- **Pass records** (hash skipping, [design/ci-lean.md](design/ci-lean.md)) live in `actions/cache` (`ci-pass-<job>-<run>`,
  restored by prefix, so the newest wins, saved after the job passed) and as an artifact of each pull request run. A
  cache saved by a pull request is readable only by that PR, so a later push to the same PR skips what already passed. The
  push to `main` of the squash starts with the merged PR's artifact (the `Pass records` jobs) and saves it in main's scope, where every
  later PR restores it: the squash reruns no test whose hash the PR passed. The honesty rules are the script's, not the
  workflow's: a record is written only for a clean tree equal to the planned commit, and never when a `SEMPERE_*` variable
  outside the allow-list is set (the workflow sets only allowed ones).
- **Removable importers** (`check-removable-importers.sh`: a second, full build of a copy without the Notability module, then
  `CLITests`) is hash-skipped under its own job name, `linux-removable`: the record is keyed on the `CLITests` closure and the built
  CLI (as for any target), `Package.swift`/`Package.resolved`, both scripts (`check-removable-importers.sh`,
  `check-importer-isolation.sh`) and the Docker image id. `check-importer-isolation.sh` (a grep of every Swift file for the
  module's names) is cheap and always runs, so the build can be skipped for a change outside `CLITests`' closure: only code that
  names the module can break a build without it. The honesty rules are those of every record (clean tree, no `SEMPERE_*` mode
  variable, hashes unmoved during the run, `SEMPERE_CI_FORCE_ALL=1` runs it). A failed golden diff prints a bounded real diff
  (80 lines), not only the file names.
- **Build cache**: only the iOS build's derived data (`.build/xcode.noindex`): pushes to `main` save it, pull requests restore
  it (`.github/actions/build-cache`; 7 minutes cold, 4 warm). The SwiftPM `.build` folders are not cached: a fresh checkout's
  file times make SwiftPM rebuild everything, and the Linux job took as long with a restored cache as without.
- `SEMPERE_FAIL_FAST=1` is set, so a test step stops at the first failed test and reruns it twice ([Fail fast](#fail-fast)).
- The App Store screenshots job and the web viewer's browser smoke tests of the old workflow are not part of this gate.
- `release.yml` is gone: releases are local builds ([releasing.md](releasing.md)).
- The old `PR description` check stays: the gate runs no UI test, so `## Tests run` is how a reviewer sees which targeted
  tests the author ran; it costs a few seconds.

## Policy: what runs where

The layers beyond the GitHub gate run on a developer's Mac by `scripts/local-ci.sh`. Each posts a commit status on
Gitea for the exact commit it ran on (a clean checkout of a commit the mirror has copied; a status is posted only after every
step passed; `scripts/forge.sh`), and something enforces each one. The gate's own status (`local/app-tests`) is posted only with
`--status` and nothing requires it:

| Layer | Command | Runs | Status | Enforced by |
|---|---|---|---|---|
| PR gate (GitHub: the checks above; here: its local twin, optional) | `scripts/local-ci.sh` | the tooltip lint (`scripts/check-help.py`), iOS compile check (`scripts/app.sh build-ios`: the app, its unit tests and its UI tests built for an iOS simulator, nothing run), Mac Catalyst unit tests (`scripts/app.sh test-mac`, the pseudo-language layout check `PseudoLanguageLayoutTests` among them), package tests (`swift build --build-tests && swift test --parallel`), then in Docker the Linux package tests (offline, portability, removable importers: `scripts/ci-linux.sh docker test`) and the WebDAV tests (`docker webdav`), each skipping targets whose hash already passed | `local/app-tests` (with `--status`) | nothing: GitHub's checks gate merging |
| Author's targeted tests | whatever the change calls for | e.g. `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/MacItemUITests` | the PR's `## Tests run` section | review (the PR template has the section) |
| Pre-TestFlight | `scripts/local-ci.sh --testflight` | the gate, then the dense-note performance suite (`test-mac-perf`, [Performance tests](#performance-tests)), the Mac unit tests with no network ([Offline mode](#offline-mode)), the Mac launch smoke tests (`test-mac-smoke`) and every Mac UI test (`test-mac-ui`) | `local/testflight-suite` | `scripts/testflight.sh` (`just testflight`) checks it on the commit it builds (`local/release-sweep` also counts) |
| Release sweep | `scripts/local-ci.sh --release` | all of `--testflight`, with the iPad unit suite (`test`), the iPhone suites (`test-phone`) and the pseudo-language UI test on the iPad (`pseudo`) before the Mac UI tests, then the iPad UI tests (`test-ui`) and the iPhone canvas UI tests (`test-phone-ui`: tap selects, hold menu, finger draws, reading mode) | `local/release-sweep` | the App Store submission; then the release checks (`release-tag.sh`, `release-build.sh`): a `vX.Y.Z` tag needs it on the commit or on a swept ancestor with only release-neutral changes since (`scripts/release-sweep-check.sh`; a `-rc` prerelease only warns) |
| CLI-only release | `scripts/local-ci.sh --cli` | the package tests on the Mac, then in Docker the Linux tests (`scripts/ci-linux.sh test`), the WebDAV integration tests (`webdav`) and the static release build (`static`) | `local/cli-suite` | the release checks for a tag whose `Version.swift` differs from the app's `MARKETING_VERSION` |

- **The gate never needs the screen** and runs no simulator, so it can run on a Mac someone is
  using. It takes about ten minutes on an Apple silicon Mac with warm build caches. The
  `--testflight` and `--release` steps after the gate are UI tests that take over the screen (a
  Mac UI test fails with "Running Background" when the app cannot come to the front): leave the
  Mac alone while they run. Both also post `local/app-tests` once their gate steps passed.
- **A sweep for a commit with the same tree.** A passing `--release` run on a clean checkout records the commit's tree id
  (`data/local-ci/release-sweep-trees`, git-ignored; `scripts/release-sweep-tree.sh`), also with `--no-status`.
  `scripts/local-ci.sh --post-sweep SHA` runs nothing: it posts `local/release-sweep` for SHA when its tree is one that
  passed. A release built from a local commit and merged later as a squash is another commit with the same tree, so it
  needs no second sweep (docs/audits/README.md "Embargoed fixes"). Any other tree is refused.
- **Targeted tests**: the gate runs no UI test and no simulator, so the author picks the tests
  the change calls for (a Mac UI test for a window or menu change, `test-ui` for an iPad drag,
  `test-phone` for an iPhone layout, …), runs them with
  `-only-testing:` where that narrows them, and lists each with its result under `## Tests run`
  in the PR description (`.github/pull_request_template.md`), or writes "None beyond the gate:
  <why>".
- `just ci`, `just ci-testflight`, `just ci-release` and `just ci-cli` run the layers (extra arguments pass through,
  e.g. `just ci --list`); [releasing.md](releasing.md) is the runbook around them.
- `scripts/local-ci.sh --list` (with any mode) prints the steps and the status a mode posts;
  `--no-status` runs without posting. Logs: `build/local-ci/<step>.log`. The script runs under
  `caffeinate -dimsu` (it re-runs itself that way) so the Mac does not sleep mid-run.
- A new push needs a new gate run.
- **Layouts in other languages** need no UI test on the Mac: `PseudoLanguageLayoutTests`, a hosted
  unit test, lays out the main screens in the double-length, right-to-left and Spanish
  pseudo-languages in every gate run, so `--testflight` no longer runs `pseudo-mac`
  (docs/localization.md "Checking layouts"). The iPad's layouts are still checked by the UI test
  (`pseudo`, in `--release`): the in-process check is Mac-only for now.
- **Fail fast, then rerun** ([Fail fast](#fail-fast)): steps run cheapest first and the run stops at the first
  failed step; inside a step the tests stop at the first failed test, which then runs twice on its own and is
  reported as `FAILING` or `FLAKY`. A flaky test fails the step too: nothing retries silently.
- **Quarantine**: a test known to be flaky leaves the main suites and runs only on its own, outside every gate and sweep.
  Rule (owner, 2026-11-12): a known flaky test is quarantined, never rerun around; a reviewer then decides keep-or-delete
  per test, and only a kept one is made reliable and moved back. Each runner has one list, skipped by its normal steps and run
  alone by one command:

  | List | Runner | Skipped by | Run alone by |
  |---|---|---|---|
  | `ui_quarantine` (`scripts/app.sh`) | iPhone simulator UI tests | every `ui_suites` step | `scripts/app.sh test-quarantine` (group `ui`) |
  | `unit_quarantine_mac` (`scripts/app.sh`) | Mac Catalyst app unit tests | `test`, `test-mac`, `test-mac-offline` | `scripts/app.sh test-quarantine` (group `mac`) |
  | `unit_quarantine_watch` (`scripts/app.sh`) | watchOS simulator unit tests | `test-watch` | `scripts/app.sh test-quarantine` (group `watch`) |
  | `swiftpm_quarantine` (`scripts/swiftpm-quarantine.sh`) | SwiftPM: the Mac package step and the Linux `test` job | `ci-mac-package.sh`, `ci-linux.sh test`, `test-linux.sh` | `scripts/ci-linux.sh docker quarantine`, or `scripts/swiftpm-quarantine.sh` on a Mac |

  `SEMPERE_QUARANTINE_GROUP=ui|mac|watch` makes `test-quarantine` run one group (the default runs all three; each non-empty
  group runs, and the step fails if any did). Under xc-lock run it per group: `XC_KIND=mac` for `mac` (Catalyst jobs are
  exclusive), `XC_KIND=build` for `watch` (a clone would be an iPhone), `XC_KIND=sim` for `ui`. A list may be empty; every
  expansion of one uses `${a[@]+"${a[@]}"}`, because macOS bash 3.2 with `set -u` fails on a bare `"${a[@]}"`.

  Deleted after review (their behavior is guarded elsewhere, so their lists are empty now: `ui_quarantine`, `swiftpm_quarantine`):
  - `NoteToolbarUITests/testANoteOpensInReadingAndTheOverflowMenuListsItsRecordings`: every assertion is a model-level test
    (`NoteModeTests.everyNoteOpensInReadingMode`, `everyDeviceReachesTheRecordingsList`, `theOverflowMenuIsTheSameOnEveryDevice`,
    `AudioItemAppTests.recordingsListIsANoteMenuCommand`); what was left was a 60 s cold launch on three devices.
  - `ConcurrentTransferTests/testCancelledMidwayWithSeveralInFlightResumes`: covered by `testReviewProgressMonotoneWhenResumeGets200`
    (the same cancel-in-flight harness), `BlobResumeTests` and `PartialCopyTests` (Range at the kept offset) and
    `testACutDownloadAmongConcurrentOnesResumes`. If a sister test flakes, the shared `cancelWhenBlobsAreInFlight` / `SegmentGate`
    harness is the cause and gets fixed there.

  Kept in quarantine, with the reviewer's plan to make each deterministic (a follow-up PR; none is fixed yet). Until then none gates:
  - `SempereAppTests/PseudoLanguageLayoutTests/screenFits(_:in:)` (`unit_quarantine_mac`): a sheet is still animating when the
    layout is measured. It is the only per-PR layout check for localization (`pseudo` and `pseudo-mac` are release-only), so the
    layouts are not gated meanwhile (docs/localization.md "Checking layouts"). Plan: in `LayoutHost.settle(sheet:)`
    (`PseudoLanguageHarness.swift`) replace "3 equal snapshots 50 ms apart" with the end of the presentation as an event: present
    with animations disabled (`Transaction(disablesAnimations: true)`); for a sheet, await the presenting controller's
    `transitionCoordinator` completion (resume at once when it is nil), then require `isBeingPresented == false` and the presented
    view's frame equal to `presentationController.frameOfPresentedViewInContainerView`; then `layoutIfNeeded()` and one snapshot.
  - `SempereAppTests/LoadDeviceCheckTests/c20RecognitionWhileWritingSavesTheSummaryCacheRarely()` (`unit_quarantine_mac`): timing
    under load. The only test of the `summaryCacheSaveInterval` throttle. Plan: inject the clock (`saveSummaryCacheIfDue` reads
    `ContinuousClock.now`; give `AppModel` a `now` closure or a `Clock`, and make the recognition delay and editor debounce use it);
    draw N strokes in a loop with no sleeps, wait on events (`editor.deltasWritten == n`, the `FakeRecognizer` call count),
    advance a manual clock 0.45 s each, and assert the exact save count, `deltasWritten == N` and `calls == N`; drop the 6 s window
    and the load-relative bounds.
  - `SempereWatchTests/WatchModelTests/testRecordStopSealsIntoTheOutboxAndHandsItOver` (`unit_quarantine_watch`): the test host
    crashed once. The only end-to-end happy-path test of the watch model. Plan: first pull the crash report from that run's
    xcresult or DiagnosticReports and treat it as a bug; then remove the incidental timing: delete the
    `Task.sleep(for: .milliseconds(300))` (`FakeWatchRecording.stop()` writes at least 8 frames whatever the elapsed time) and
    replace the wall-clock `eventually("saved to go")` with an injected saved-to-ready timer, or await the model's saved-dismiss task.

  Adding one is a line in the runner's list and a line here with its reason; a reviewer then decides keep-or-delete.
- Off CI, `scripts/app.sh` stops an `xcodebuild` that sits idle after the end of its whole run
  (`SEMPERE_STALL_SECS`, default 180 s): `Test Suite 'All tests'` or `'Selected tests'` passed or failed, or
  `Test run with N tests`, never a class's `Executed N tests`; a `◇ Test run started` after it (Swift Testing
  after XCTest) disarms it. A stopped run passes only when a run ended passed and none started after it.
- **UI tests capture screenshots, not screen recordings** (`preferredScreenCaptureFormat =
  "screenshots"` in the `SempereScreenshots` scheme). On the iOS 27 simulator (Xcode 27.1) XCTest's
  per-test recording hung on stop about every other test (30 s each). Now and then the stop took
  `testmanagerd` and the simulator down with it, and a passing test was reported as "Test crashed
  with signal term" (the 1.0 release sweep, `PhoneCanvasUITests`). Keep the setting unless a newer
  Xcode fixes that.

## Fail fast

Every test step (`scripts/app.sh`'s `xcodebuild` runs and the gate's `swift test --parallel --skip 'Benchmarks\.'`) goes through
`scripts/test-runner.py`, which passes the output through and watches it (`--self-test` checks its parsing; the
gate's `help` step runs it):

- **Stop at the first failed test** (off CI; `SEMPERE_FAIL_FAST=0` runs every test of the step, `=1` turns it on
  under CI). Xcode 27 has no option for it (`xcodebuild -help`: `-run-tests-until-failure` repeats tests,
  `-retry-tests-on-failure` retries them), so the runner stops the run itself when a test ends failed (XCTest's
  `Test Case '-[M.C t]' failed`, Swift Testing's `✘ Test t() failed`, a runner that crashed in a test, named by
  xcodebuild's crash line when it says which): the command runs in a process group of its own, which gets SIGINT
  (xcodebuild cancels the run and quits the app under test), then SIGTERM and SIGKILL (`os.killpg`: never a PID
  that may have been reused, never anything else on the Mac). The runner's own SIGINT and SIGTERM stop the group
  too, and once the command exits its output is read for a few seconds more, not until every process that
  inherited it closes it.
  `swift test --parallel` prints a failed test's output only once every test has run (checked on a toy package),
  so the package step cannot stop early; it still gets the reruns and the `TEST-RESULT` lines. Its floor is its
  longest test, which is why the epoch mutation tests are one test per mutation.
- **Rerun to tell flaky from real**: each failed test (at most `SEMPERE_RERUN_LIMIT`, default 3) runs again on its
  own, `SEMPERE_RERUNS` times (default 2): `-only-testing:<target>/<class>/<test>` with the step's other
  arguments, or `swift test --skip-build --filter`. A Swift Testing test's suite comes from its source (the issue's
  file, else the one file declaring the function). Passing every rerun makes it `FLAKY` (each rerun must show that
  very test ending passed), failing one, or one that ran no test, `FAILING`; both fail the step. The UI tests no longer use `-retry-tests-on-failure` (CI retried them once, which hid
  flaky tests).
- **One line per failed test** ends the step's log, `TEST-RESULT FAILING|FLAKY <id> (…)`, and
  `scripts/local-ci.sh` prints them under the failed step (`local-ci: iphone-ui: FLAKY …`). The statuses it posts
  are unchanged.

On CI the run is not stopped (the job's "Summary of failures" wants every failure), but failed tests are rerun
and reported the same way.

### Where UI-test time goes

Measured from the per-step `t = …s` timestamps of the 1.0 release sweep's logs (Mac UI: 46 tests, 1491 s;
iPhone UI: 27 tests, 1732 s; Mac smoke: 5 tests, 261 s):

| Stage | Launch | Demo vault ready (and unlock) | Terminate | Waits that ran to their timeout | Test body |
| --- | --- | --- | --- | --- | --- |
| `test-mac-ui` | 57 s (4 %) | 218 s (15 %) | 56 s (4 %) | 172 s (12 %) | 974 s (65 %) |
| `test-phone-ui` | 114 s (7 %) | 284 s (16 %) | 28 s (2 %) | 5 s | 1288 s (74 %, of which 300 s were five 60 s "wait for the app to idle" in one test) |
| `test-mac-smoke` | 6 s | 17 s | 6 s | 42 s | 190 s |

A launch is 1 s on the Mac and about 4 s on the iPhone simulator; the vault's readiness is mostly building the
demo vault (on the Mac 2 to 8 s) and, on the phone, pasting the device key into the unlock sheet (about 10 s). A
shared app across tests, reset between them by a debug hook, would still have to rebuild the demo vault (the
tests write to it: drags move notebooks, notes are created) and redo the per-test choices (note, columns, window
size, items, a fresh state), so it could save the launch and the terminate, about 2 s a test on the Mac and 5 s
on the phone (6 to 8 % of each stage), at the price of a reset that must be complete for every test. Tests that
open the same note were merged into one launch instead, and the waits that always ran out were removed
(the PR that added this section lists them).



PRs never edit `CHANGELOG.md` (every PR conflicted there). Each adds `changelog.d/<topic>.md`
([format](../changelog.d/README.md)). `python3 -I scripts/changelog-collect.py` folds them into
`[Unreleased]` and deletes them: run it (`just changelog`) on `main` before a TestFlight build; in the release PR
`just release-prep X.Y.Z` runs it ([releasing.md](releasing.md)). Tested by `scripts/test-changelog-collect.sh` and `scripts/test-release-prep.sh` (CI `release` job).

## Offline mode

`scripts/app.sh test-mac-offline` runs every app suite as `test-mac` does, on a device that is never online: the
Catalyst test host is signed with `Apps/Sempere/SempereOfflineTests.entitlements` (the app's Mac entitlements
without `com.apple.security.network.client`; tests only, never shipped), so the sandbox refuses every outbound
connection, and `SEMPERE_OFFLINE_TEST=1` turns on `OfflineModeTests`. Those fail when a raw connection or a
`URLSession` request gets through, so a run without the entitlements cannot pass silently, and the step fails
unless `outboundConnectionsAreRefused` ran and passed (a variable that no longer reaches the runner would skip it).
They then walk the journeys
that must work offline (a vault copied in and unlocked, a folder target, transcription's availability).
The join of two devices through a plain folder, which needs no network either, is the model's
(`JoinThroughProviderTests.aDeviceJoinsThroughAFolderOnADrive` in SempereAppCoreTests, with the package tests, on Linux
too; wave 5b part 3, step 5a). `test-mac-offline` is a step
of `local-ci.sh --testflight` and `--release` (`mac-offline`, no screen needed), not of the gate. It is a Mac job
for the build lock (`xc-lock.sh scripts/app.sh test-mac-offline`).

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

The tests that drive AppKit's open and save panels (`FolderPickerUITests`, `MacExportUITests`, `MacImportUITests`)
need the test user's desktop on the console. With it in the background (Fast User Switching, another user in
front), the panels' Save, New Folder and Choose stayed disabled in every folder in every run since 2026-10-26, on
commits that had passed with the desktop in front. `scripts/app.sh test-mac-ui` warns when the console belongs to
another user and passes `SEMPERE_SESSION_OFF_CONSOLE` to the tests (`PanelSession.swift`), whose failure messages
then say so.

## What runs when

- **Every pull request** needs the GitHub checks above. Locally the same steps are `just ci` (the Linux jobs in Docker on the
  Mac, beside the Mac steps: about 10 minutes cold, 5-9 warm: [design/ci-lean.md](design/ci-lean.md)); nothing
  runs on Gitea. The web viewer's checks are the `Web viewer` job and the golden diff in `Linux package tests`. **Unchanged test targets are skipped** ([design/ci-lean.md](design/ci-lean.md)): `scripts/ci-hash.py`
  hashes each target's inputs (the whole folders of the target and its dependencies, the docs, sources and other targets' fixtures its tests read (`check-reads` fails for an undeclared read), `Package.swift`, `Package.resolved`, the
  toolchain, the scripts that run the tests) and the gate's `package`, `linux` and `webdav` steps skip a target whose
  hash already passed, logging the hash and the commit that passed it (`ci-hash: SKIP ...`). The records are
  files in `~/.cache/sempere-ci-pass` on a Mac (the Docker jobs mount it; on GitHub, `actions/cache`, above), keyed by job, target and hash, not by commit: a pass
  recorded on a pull request's head is honored by any later commit with the same hashes, so the push to `main` of a squash
  whose files the pull request already passed runs nothing. There is no weekly or post-merge full run; only the release
  modes force one. `SEMPERE_CI_FORCE_ALL=1` runs everything; `--testflight`,
  `--release` and `--cli` set it. `scripts/ci-targets.json` classifies targets as logic or OS-dependent (the Mac gate
  skips the logic ones with `SEMPERE_CI_MAC_PACKAGE=os-dependent`; off for now).
- **The static (musl) Linux release build** is `scripts/ci-linux.sh static`; `release-build.sh` builds both
  architectures from the tag.
- **WebDAV integration tests:** `scripts/ci-linux.sh webdav` runs `scripts/test-webdav.sh` against wsgidav
  (pinned in `scripts/webdav-server-requirements.txt`) with the fault proxy in front of it for
  `WsgidavFaultProxyTests` ([Sync stress](#sync-stress)); a skip fails it. **The selection is by name:** the job runs
  every test whose identifier (`Target.Class/testName`) contains `Wsgidav` (`WsgidavIntegrationTests`,
  `EngineOverWsgidavTests`, `testInvariantsHoldOverWsgidav`, `CLIWebDAVTests.testSyncAgainstWsgidav`, …), and a plain
  `swift test` skips them for want of the server. A test that reaches the server without the word would run nowhere:
  `WebDAVJobSelectionTests`, in every plain `swift test`, reads the test sources of `SempereWebDAVTests` and `CLITests`
  and fails for it, so a new server test is picked up by being named for the job, with no regex to update.
- **Web viewer smoke tests** (`web/scripts/smoke-all.sh`, browser smoke tests in Chromium, including the
  large-note stress run, the scroll-anchor check and the pixel diff against the CLI's SVG export; the heavy
  sizes and WebKit are run by hand, `web-viewer.md` "Stress tests").

## Offline guard

Sempere works with no network at all (the offline audit: every journey's data path is local; the only connections
are to a WebDAV server the user sets up). The Linux job runs the package tests through `scripts/test-offline.sh`: in
a network namespace of their own with only `lo` up (`unshare -n`; the job's container gets `CAP_SYS_ADMIN` and
`CAP_NET_ADMIN` for it), so a test, or code under test, that reaches anything but this machine fails. The WebDAV
tests use servers on loopback (the in-process mock; wsgidav in the `webdav` job, which runs without the guard). On a
Mac the same script runs the tests under `sandbox-exec`, refusing every connection except to localhost (it first
checks that the sandbox does refuse): `scripts/test-offline.sh --skip-build --parallel`.

## Sync stress

Sync is stressed at four levels (and timed at a fifth); all share a multi-device harness
(`Tests/SempereWebDAVTests/SyncDevices.swift`: `SyncDevice` is one device with its own vault
folder, key, device clock (`device.json`, with an optional wall-clock skew or a virtual clock) and
sync state, on any `SyncRemote`, or on several with a state each; `SyncDevices` makes two or more
on one remote, the first creating the vault with every device's key, and checks convergence: every
device and the server hold the same note files, nothing written was lost, nothing is left in
flight, every device reads the same notes).

| Level | Runs in | What |
| --- | --- | --- |
| `TwoDeviceStressTests` | every `swift test` (6 seeds; `SEMPERE_STRESS_SEEDS=N` for more) | devices on the in-memory `MockDAV`, each through a `FaultyTransport` (seeded: requests dropped, answered 503, applied with the answer lost, downloads cut midway), interleaving notes, renames, tags, blobs, shared settings, two-way runs, pushes and simultaneous runs; request counts of idle and catching-up runs; label-only `vault.json` changes; per-device summaries; merge-copy round trips |
| `NDeviceStressTests` | every `swift test` (quick: 3 seeds of 90 steps, 3 devices, a few seconds); `SEMPERE_SYNC_STRESS_LONG=1` (60 seeds of 300 steps, 3 to 5 devices, simultaneous runs; `SEMPERE_SYNC_STRESS_SEEDS=N`; `scripts/sync-stress.sh`) | devices on one or two remotes (a `MemoryRemote`, or every fourth seed a `FolderRemote` on a plain folder through `FaultyRemote`, plus a second in-memory one or the WebDAV mock, by seed), the first bridging both, each other one a random non-empty subset, so two or more devices often bridge the same two remotes (`SEMPERE_SYNC_STRESS_BRIDGES=one`: one remote each); new notes, renames, tags, attachments, deletes, thinning, shared settings, voice notes recorded into the inbox, adoptions of the inbox and each device's published summaries, synced in random order through transport faults and, on in-memory remotes, a hostile server on note files, `vault.json`, `inbox/` and `summaries/` (wrong bytes, listings that drop or invent entries or misreport sizes, version tokens changing underneath). Checks as it goes and at the end: no note file on any device or remote differs from what its writer wrote or appears unwritten; every attachment and revision is everywhere, or (thinned) the note reads the same with all of them put back; every file that appeared in a quarantine folder is still there with the same bytes; with faults off, a few rounds (retrying quarantined files, as Repair does) converge every device and remote with no conflict copy and nothing in flight, the same inbox and the same per-device summaries everywhere (each device's own file the one it wrote), and every voice note still in the inbox or adopted. `SEMPERE_SYNC_STRESS_SEED=N` replays one seed; prints `NDEVICE` lines |
| `EpochInterleavingTests` | every `swift test` (quick: 2 seeds of 36 steps, 4 devices, over memory targets and the WebDAV mock, and the mutation tests: each `EpochMutation`, `SyncEpochMutation` or `PrecedenceMutation` must break its own invariant on a seed whose unmutated run is clean, one test per mutation (`testMutation…`, so `swift test --parallel` runs them side by side: as one test they took four and a half minutes, the gate's longest; `testEveryMutationHasItsTest` fails when one is missing), as `EpochInvariantTests` does for its mutations; the scan starts at the seed each mutation first broke its invariant on, `Mutation.knownSeed`, and goes through the others only if that one stops breaking, so a mutation costs two runs, not a dozen); the wsgidav run in the CI `webdav` job; `SEMPERE_SYNC_STRESS_LONG=1` (60 seeds of 120 steps, 5 devices, each transport; `scripts/sync-stress.sh`) | key hierarchy design §11.2: devices on two targets (two bridges), transport faults, writes, two-way runs, removals by home after its best-effort pull, one or two takeovers at once, lost epoch records, removed devices that keep writing and plant files, or forge an epoch; checks J5a, J5b, J6 and J8 after every write and run, and J1–J4, J8–J10 at quiescence. `SEMPERE_EPOCH_SEED=N` replays one seed, `SEMPERE_EPOCH_EMPHASIS=OP` leans on one op, `SEMPERE_EPOCH_MUTATION=NAME` runs one mutation, `SEMPERE_EPOCH_TRACE=1` prints a failing run's ops; prints `EPOCH-INTERLEAVING` lines. Two ops are chosen only when leaned on (so other seeds replay unchanged): `away` (a device skips its syncs for 5 to 20 steps while it writes, and the clock jumps 7 to 200 days) and `window` (a run over a short connection window, `WindowRemote`); `testInvariantsHoldWithDevicesAway` and `testInvariantsHoldOverShortWindows` lean on them in every `swift test`, and `scripts/sync-stress.sh` runs the long mode again with `SEMPERE_EPOCH_EMPHASIS=remove`, `=away` and `=window`, over memory targets, the mock and wsgidav. Over wsgidav those leaning runs once failed J1 on a few seeds in 60: its whole-second version tags hid an accepted copy that replaced a refused one within the second (key-hierarchy design §16.13 "Whole-second version tags"; `SecondStampTests` pins it on the mock with `MockDAV.secondETagClock`) |
| `ShortWindowTests`, `LongOfflineTests` | every `swift test` | offline audit (infrequent connectivity): uploads and pulls over windows of K requests converge with progress in every window; a dead link stops the run after three network failures in a row (`LinkBreaker`); a cut run that moved something is a success, not a failure with backoff (`SyncReport.outcome`); the inbox and this device's own summaries go before the notes backlog, and its newest writing first. A device back after six months across five epochs converges; a join request waits for an offline home and a joiner's clock 8 days behind; summaries signed ahead of a clock are left in place; a removal a takeover undid is named. Big-blob starvation (P3) and resumable listings (P7) are skipped `TODO`s pending the owner; prints `WINDOW` lines |
| `WsgidavFaultProxyTests` | `scripts/test-webdav.sh` (CI's `webdav` job) | real sockets: wsgidav behind `scripts/dav-fault-proxy.py`; a reset mid-download resumes with `Range`, a reset mid-upload leaves no partial blob, random 5xx and resets converge, a stalled request ends at the idle timeout, a dripping download ends at the run's time bound, request counts over latency and a bandwidth cap |
| `SyncStressTests` | `scripts/sync-stress.sh` only (about five minutes) | the seeded 640-note vault the CLI builds (`scripts/make-stress-vault.sh`: notebooks, tags, text boxes, edits from a second device, small and 3 MB images), uploaded and pulled through faults, 240 concurrent edits from both devices, idle request counts, a fresh pull canceled at random points, a merge-copy round trip; prints `STRESS` lines (times, requests by method, faults) |
| `SyncTimingBenchmarks` | `scripts/sync-stress.sh` only | the same vault without faults at `SEMPERE_STRESS_LATENCIES` ms per request (default `0,20`): first upload, first pull, two idle runs (the first checks the deep listing, the second uses it), the app's push after one edit; prints `TIMING` lines (wall time, requests by method, client connections) for before/after numbers in performance PRs |

**Two bridges.** With two devices that both sync the same two remotes, a delta that thinning made
deletable used to circle for ever: one bridge deleted it from a remote (explained by the snapshot
there) while the other uploaded it there again from the other remote, and a round later the
reverse. Each (device, remote) pair now remembers the deletions it settled (`SyncState.thinned`), so
a copy that comes back is judged as a deletion again instead of copied
(docs/design/device-first-sync.md §5.4; `testTwoBridgesSettleAThinnedDelta`), and
`NDeviceStressTests` uses several bridges by default.

`scripts/sync-stress.sh` runs all five (60 seeds each), and the transport suites below over wsgidav, against a local wsgidav and the proxy, building
the vault once per seed and size in `build/sync-stress/` (`SEMPERE_STRESS_SEED`,
`SEMPERE_STRESS_NOTES`). Run it after a change to `Sources/SempereSync` or `Sources/SempereWebDAV`; it is not part of CI or
the PR gate, so list it under `## Tests run`.

### Transports

Every `SyncRemote` (docs/io.md "Sync engine and transports") is held to one contract and runs the
engine's core rules, over each transport (`Tests/SempereWebDAVTests/TransportFixtures.swift`:
`TransportUnderTest.memory()`, `.mockDAV()`, `.wsgidav()`, `.folder()`, `.evictingFolder()` and
`.evictedMemory()`, each a fresh base plus an unfaulted inspector, seeded fault injection and an
unreachable remote; the folder transport has no faults of its own, so `FaultyRemote` wraps it):

| Suite | Transports | What |
| --- | --- | --- |
| `SyncRemoteConformanceCase` (`MemoryRemoteConformanceTests`, `WebDAVMockConformanceTests`, `WsgidavConformanceTests`, `FolderRemoteConformanceTests`, `EvictingFolderConformanceTests`) | `MemoryRemote`; `WebDAVSyncRemote` on `MockDAV`; on wsgidav (`scripts/test-webdav.sh`); `FolderRemote` on a plain folder and on one `EvictingFolderProvider` holds | listings and stat, bounded reads, create-only and conditional writes, a write needing its parent, a create-only race of 8 writers, moves that never overwrite, collections and the base, deletes with version tokens, downloads in pieces, resumed and restarted, deep listings matching per-collection ones, error classification (unreachable, dropped and lost answers transient; bounds, missing files and refusals not), capability flags held where observable, unusable path components refused. Known server deviations are pinned per fixture (`TransportUnderTest.Deviation`: wsgidav's whole-second ETags, `If-Match` creating a missing file, unquoted `getetag`) |
| `EngineScenarioCase` (`EngineOverMemoryTests`, `EngineOverWebDAVMockTests`, `EngineOverWsgidavTests`, `EngineOverFolderTests`, `EngineOverEvictingFolderTests`, `EngineOverEvictedMemoryTests`) | the same, plus `MemoryRemote` in evicted mode (every file evicted as it is written, so every read goes through the arrival rules) | first upload, pull and idle runs; concurrent deltas; never overwriting write-once files; quarantine (every distinct copy of a path kept, bounded); compaction deletes; unexplained and wiped remote deletions put back; another vault refused; `vault.json` conflict copies, and none when only its version token moved; settings merged per key; a cut blob download finished next run; random transport faults converging; `skipUnchangedNotes` |
| `MemoryRemoteTests` | `MemoryRemote` | each injected fault does what it says; faults replay from the seed whatever the call order; an evicted file is listed, unreadable (transient) and arrives after `requestDownload`; an arriving folder lists empty; latency is interruptible |
| `FolderRemoteTests` | `FolderRemote` | version tokens follow the bytes (a same-size rewrite in place; folder tokens follow children); the lock file is hidden; a conditional-replace race has one winner; symbolic links never followed or listed; FIFOs and names that are not UTF-8 not listed; huge files and listings bounded; a provider's stand-ins and dataless files listed, unreadable (transient, `isUnavailable`) and arriving after `requestDownload`; folders listed before their files (and the base); conflict versions and change hints; on macOS `UbiquitousFolderHooks` on a local folder (real `NSFileCoordinator`, an `NSFilePresenter` hearing a coordinated write) |
| `FolderHazardTests` | `FolderRemote` + `EvictingFolderProvider`, `MemoryRemote` evicted | the design's §3.3 hazards through the engine: evicted files arriving within the run's wait, or left for later (never quarantined, never taken as missing, nothing uploaded over them); download failures, then stalls as errors; an evicted `vault.json` or base stopping the run; note and `att/` folders listed before their files (nothing judged until `unlistedTimeout`, then taken as listed); `att/`-only folders; conflict versions of `vault.json` (label-only dropped, others kept as conflict copies), `settings.age` (merged, waiting for the key when locked) and the summaries (dropped) |
| `CLIFolderSyncTests` | `sempere sync folder` | two devices through a folder, usage errors (overlap, a file, flags), `--push-only` and `--dry-run`, quarantine (exit 1), and on macOS a real FAT volume (no hard links, a 2 s clock) |

A new transport gets a fixture and a subclass of each case with the same test methods.

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
- **Build caches:** `scripts/ci-linux.sh docker` keeps the Linux `.build` in a Docker volume per image
  (`sempere-linux-build-…`). The test and webdav jobs never mount the Static Linux SDK. A `static` job (the
  release binaries, `release-build.sh`) uses a fresh `.build` volume and a fresh `~/.swiftpm` volume on every
  run and removes both afterwards, so its SDK is downloaded and checked against its checksum each time and
  nothing a test job wrote can reach a release binary. If a Linux build fails in a way a clean build would
  not, `docker volume rm` the volume and re-run.

## Temp-folder guard

Tests put every scratch file under `TestTemp.root`, one folder per test process
(`sempere-test-<pid>-<uuid>`) that is removed when the process exits; the first use in a later
process also removes the roots of processes that are gone. The app tests use
`Apps/Sempere/SempereAppTests/TestTemp.swift`, the SwiftPM tests `Tests/TempDirSupport/TestTemp.swift`
(same API: `root`, `url(_:)`, `directory(_:)`, `with(_:_:)`). Never build a path from
`FileManager.default.temporaryDirectory` or `NSTemporaryDirectory()` in a test; for XCTest, `makeScratch`
and `TempDirTestCase` already do the right thing. Production code that makes a temp folder removes it
itself (an `AppModel` built without explicit roots owns one scratch folder, removed in `deinit`).

Why: leaked folders once piled up to about 195,000 entries in the sandboxed app container's tmp
(`~/Library/Containers/io.github.anthonytw.sempere/Data/tmp`), hit APFS's 65,535-subfolder limit, and
failed every Mac Catalyst test that wrote there with Cocoa error 512.

`scripts/app.sh test-mac`, `test-mac-ui` and `test-mac-smoke` count that folder's entries before and
after and print `tmp-guard: ... before=N after=M`. More than `SEMPERE_TMP_LEAK_MAX` (default 20) new
entries is a warning; `scripts/local-ci.sh` sets `SEMPERE_TMP_GUARD_FAIL=1`, which makes it a failure.
`SEMPERE_CONTAINER_TMP` points the guard at another folder. The iOS simulator runs are not covered:
their tmp lives in a throwaway simulator clone.

The same line also counts the container's `Library/Preferences` (`SEMPERE_PREFS_LEAK_MAX`, default 20;
`SEMPERE_CONTAINER_PREFS` moves it). A test that calls `UserDefaults(suiteName:)` leaves a `<suite>.plist` there for
ever (about 21,000 piled up in four days and made the Mac choppy), so tests make suites with
`TestDefaults.suite(_:)` (`Apps/Sempere/SempereAppTests/TestDefaults.swift`), which removes the domain and the plist at
process exit (the hosted runner ends the host before cfprefsd settles, so each suite is also recorded in a per-process
ledger under the container's `Library/Caches/TestDefaultsLedger`; suites idle for two minutes are removed as new ones
are made, and `app.sh` and the next host remove the files of a gone host's ledger), and `scripts/check-test-defaults.sh` (in the `help` step of `local-ci.sh` and in CI) fails on a raw
`UserDefaults(suiteName:`.

`swift build`, `swift test` and `xcodebuild` leave empty `TemporaryDirectory.XXXXXX` folders (each holding only
`.keep-directory`), `ResultBundle_*` and `SempereApp_*` entries in `$TMPDIR` (about 18,000 in four days); they are
Apple's tooling, not ours. `app.sh`, `local-ci.sh`, `screenshots.sh` and `testflight.sh` therefore source
`scripts/run-tmp.sh`, which gives the run a `TMPDIR` of its own (`sempere-run.XXXXXX`) and removes it at exit, so only
what the run made goes, never another agent's files (a run killed with SIGKILL leaves its `sempere-run.*` folder; remove it by hand) (`SEMPERE_RUN_TMP_KEEP=1` keeps it). Plain `swift build` from a
shell is unchanged and still leaves them. Derived data lives in `.build/xcode.noindex` (and testflight's
`dd-<platform>.noindex`): Spotlight skips `.noindex` folders, so `mds` does not index build output; `.build` itself
is a dot folder, which Spotlight skips too.

## Device checks in process

The owner's device checks that only need the app's own paths run as Mac Catalyst unit tests
in the gate (`test-mac`), named after their check (`c4…`, `c54…`):

| Suite | Checks |
| --- | --- |
| `InkRoundTripTests` | synthetic Pencil strokes (`PencilTrace`: pressure ramp, azimuth sweep, tilt, 120 Hz timing; all seven inks, each at its own width and color) through the canvas, saved, read back from the vault and reloaded: every point's force, azimuth, altitude, opacity, size and time, the ink, color and the tool's width; two reloads draw the same pixels, a reload draws what the pen drew |
| `RecordingRelaunchTests` | a recording on an audio file (no microphone) while strokes are written through the canvas, with a call in the middle; stop, save, relaunch (a second `AppModel` on the vault): each stroke still linked to the recording at its second, Tap Ink to Play seeks to it, playback highlights exactly the ink around the position |
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

## Benchmarks

The print-only timing tests (how long a vault listing, a thinning pass, a PDF export, a sync run takes, with the
old way next to the new one) are **benchmarks**, and a benchmark never gates anything. Each module measured has a
test target of its own, named `<Module>Benchmarks`, so it is obvious what a test is and what it measures:

| Target | Measures |
| --- | --- |
| `SempereBenchmarks` | vault reads and scans (summaries, history, thinning, blob GC, backup index, search, lasso, digests) |
| `SempereRenderBenchmarks` | PDF, SVG and PNG writers, the rasterizer, text shaping, bulk export |
| `SempereWebDAVBenchmarks` | a sync run at a realistic size (`SyncPerfBenchmarks`; `SyncTimingBenchmarks` is `scripts/sync-stress.sh`'s) |
| `SemperePDFBenchmarks` | text extraction from a long PDF |
| `AgeBenchmarks` | scrypt at the default work factor |

- **Never in the gate.** The PR gate (`scripts/local-ci.sh`'s `package` step), the Linux jobs (`scripts/ci-linux.sh test`),
  `just test` and `scripts/test-linux.sh` all pass `--skip 'Benchmarks\.'`: `swift test --list-tests` names a test
  `Target.Class/testName`, and the regex matches the target part only. A plain `swift test` runs them (they are quick
  at their default sizes), so use the same `--skip` for a package run without them.
  A serial `swift test` with `--skip` or `--filter` on Linux hands the runner every selected test as one comma-joined
  argument and dies with `posix_spawn error: Argument list too long` once the names pass 128 KB (Linux's
  `MAX_ARG_STRLEN`; the suite is ~265 KB): pass `--parallel`, as the CI jobs and `scripts/test-linux.sh` do.
- **`scripts/bench.sh [sempere|render|webdav|pdf|age ...]`** (`just bench`) builds in release mode
  (`-c release -Xswiftc -enable-testing`, which the tests' `@testable` imports need) and runs each module in a
  process of its own, so a run's peak memory is its own. `SEMPERE_BENCH_DEBUG=1` runs unoptimized; arguments after
  `--` go to `swift test` (`just bench sempere -- --filter SummaryBenchmarks`). Sizes grow with environment variables
  named in each test's doc comment (`SEMPERE_BENCH_NOTES=600`, `SEMPERE_BENCH_STROKES`, `SEMPERE_BENCH_REVISIONS`, …).
- **When:** on a schedule and before a release, never to decide a merge. They assert only what must stay true (the
  results of the old and the new way agree); the work-counting guards that fail on a regression (decrypt counts, read
  counts, save cadence) are ordinary tests in the module's own target (`HistoryReadPerfTests`, `IncrementalSummaryTests`,
  `BackupTests.testIndexSavesGrowLogarithmically`).
- Helpers a benchmark shares with its module's tests (`SyntheticVault`, `VaultTestCase`, `DenseNote`, `PDFBuild`, the sync
  test cases) are symlinks to the test target's own files (the internal types they use are reached through
  `@testable`, which a separate support library could not do in a release build).
- **Fixture tools** are in the same place: `FixtureRegeneration` (`SempereBenchmarks`) rewrites the committed fixture
  vaults when `SEMPERE_REGENERATE_FIXTURE=1` (and the variants named in `Tests/SempereTests/Fixtures/README.md`) is set,
  and `ExportBenchVault` (`SempereRenderBenchmarks`) writes a large vault for measuring `sempere export` by hand
  (`SEMPERE_BENCH_VAULT=DIR`). Neither shows as a skipped test in the gate any more.

## Performance tests

The owner's complaint on dense notes was jerky scroll and zoom next to Notability's, and slow opens; PR #38 drew
the ruling of a long page only near the screen. `DensePerformanceTests` (`scripts/app.sh test-mac-perf`, in
`local-ci.sh --testflight` and `--release`, not in the gate: about two minutes) keeps it that way. It writes
dense notes with `DenseNote` (what `sempere notes dense` writes, [cli.md](cli.md): a paged note of 40 pages,
30 000 strokes and 16 pictures; a pageless one of 20 000 strokes, ruled, with pictures; a tenth of the strokes on
the simulator) and measures, through the app's real paths:

| Metric | How |
| --- | --- |
| `open.*.read_ms`, `open.*.firstScreen_ms` | `NoteEditor.open` (read, decrypt, reduce), then the first screen of the stack (paged: the visible pages' canvases ready) or of the one-page canvas; median of three. The `note.open` and `note.firstRender` signposts (`Perf`) show the same phases in Instruments |
| `scroll.*.hitch*_ms`, `framesOver` | a scripted scroll of the whole note and back, one 80-point step per 60 Hz frame (layout, Core Animation commit, then the run loop turns until the frame budget ends, so background loads and callbacks count). A hitch is a frame's time beyond 16.7 ms; p95 and worst are compared, and the frames that cost more than a whole frame extra |
| `zoom.*.hitch*_ms`, `zoom.paged.*framesOver` | a pinch out to 2x and back below the fit, one step a frame (the paged stack bakes the scale at its end). The paged note is pinched twice: `zoom.paged.first.*` is the first pinch, which meets pages whose canvases were never made (the spare canvases are built and laid out while the stack is quiet, a few tenths of a second apart, `PageStackHost.scheduleWarming`; the test waits for them as a person pauses before pinching), `zoom.paged.*` the second. A frame that costs more than a whole frame extra prints a `PERF-DIAG` line with the frame's phases |
| `scroll.pageless.paperLayers` | the most ruling layers any screen held (deterministic: a regression of PR #38 holds a layer per band of the whole note, 28 instead of 5) |
| `memory.*_mb` | the process footprint a scenario added (open, then a full scroll); a second pass over the same pages must not grow it (recycled canvases, bounded caches) |

Baselines are in `PerfBaselines.mac` (`DensePerformanceTests.swift`), the worst of two runs on an Apple silicon
Mac. A value fails when it exceeds `baseline * 3 + slack` (`SEMPERE_PERF_FACTOR` changes the factor; the slack is a few
milliseconds for hitches, 200 ms for opens, 60 MB for memory), so a slower or busier Mac does not trip it and
a per-frame cost that grows with the note does. Only Mac Catalyst enforces them: the simulator draws ink without the
GPU, so there the numbers print as `PERF-REPORT dense` lines and nothing fails. Re-record after an intended change
(or on another Mac) with `TEST_RUNNER_SEMPERE_PERF_RECORD=1 scripts/app.sh test-mac-perf`, which prints a
`PERF-BASELINE "key": value,` line per metric to paste into `PerfBaselines`, and say so in the PR.
The headless window records no Core Animation rendering, so frame hitches there catch main-thread work (layout,
layer creation, ink preparation), not GPU time. The structural `paperLayers` metric is what catches a return of
the paper regression (checked by reverting the banding: 28 layers against 5; the hitches and the footprint did not
move); the pinch and scroll feel on a device stays the owner's.
