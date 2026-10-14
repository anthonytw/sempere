# Continuous integration

CI is `.github/workflows/ci.yml`. It is gated so that scarce macOS runners are not wasted.

## App suites run on a Mac

The hosted macOS runner is a 3-CPU VM that needs over an hour for the app job, so a pull
request's app suites run on a developer's Mac instead:

- `scripts/local-ci.sh` runs the package, iPad, iPhone, iPad UI, pseudo-language and Mac
  Catalyst suites on a clean checkout of a pushed commit and posts the commit status
  `local/app-tests` for it. `--quick` runs the package, iPad and iPhone suites only;
  `--mac-ui` adds the Mac UI and launch smoke tests (they need the app in front, so they fail
  on a Mac someone is using); `--no-status` posts nothing. Logs: `build/local-ci/`.
- The `main` ruleset requires `local/app-tests`, so a pull request merges only once its head
  commit passed on a Mac; a new push needs a new run. A change that cannot affect the app
  (docs, `web/`, CLI-only sources) gets the status from CI's first job instead.
- On a pull request the hosted app job runs only the iPad and iPhone suites, for feedback; its
  UI, pseudo-language and Mac Catalyst steps run on `main` and on dispatch.
- Off CI, `scripts/app.sh` stops an `xcodebuild` that sits idle after printing its test
  summary (`SEMPERE_STALL_SECS`, default 180 s).

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
- **Shipping-only steps** run on `main`: the static Linux release build and the Mac Catalyst
  suites (`scripts/app.sh test-mac`, `test-mac-ui`, ad-hoc signed and sandboxed). When the
  app job fails, its "Summary of failures" step prints the failing tests and UI-test window
  dumps.
- **Extra jobs:** changes to the package run `webdav` (`scripts/test-webdav.sh` against
  wsgidav, pinned in `scripts/webdav-server-requirements.txt`; a skip fails it); changes the
  web viewer reads run `web-smoke` (`web/scripts/smoke-all.sh`, browser smoke tests in
  Chromium).

## Launch smoke tests

`LaunchSmokeUITests` launches the app with no preferences, caches or saved windows
(`SEMPERE_DEBUG_FRESH`), unlocks the demo vault through the unlock sheet
(`SEMPERE_DEMO_PASSPHRASE`), checks the library in each column layout and opens Settings,
Vault Keys, a note window, the export sheets and Restore from Backup. On the Mac it is
`scripts/app.sh test-mac-smoke` (on `main`, and locally with `local-ci.sh --mac-ui`); the
iPad's sidebar and list layouts run inside `scripts/app.sh test-ui` in every
`local-ci.sh` run. Failures print `SMOKEDEBUG` window dumps, the newest Mac crash report's
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
