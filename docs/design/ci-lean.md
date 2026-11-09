# A lean CI (thin-app wave 7)

Status: part 1 is built (the hash tool, skipping on Linux and on the Mac, the classification); the rest is
planned in "Migration order". The policy tables in [ci.md](../ci.md) describe what runs today.

## Why

A pull request's Gitea run takes 45–60 minutes on the Orin runner (aarch64, one job at a time), and stacked
pull requests each need a fresh run although most of their targets did not change. The owner's goals (2026-11-06
sweep): a small, fast PR gate; the full suite only for releases, run locally; agents run precise targeted tests;
the package tests run on Linux on pull requests, except the OS-dependent ones, which run on both the Mac and Linux;
no simulator suite in PR CI; and Bazel-like caching at the level of a test target.

## Logic and OS-dependent test targets

A package test target is **OS-dependent** when what its tests prove can differ between Darwin and Linux, so a
pass on one says little about the other. Mechanical evidence, from `#if` in the target's tests and in the code
they exercise (`grep -rE '#(if|elseif) .*(os\(|canImport)'`): a choice between `Glibc`/`Musl`/`Darwin` calls
(file locks, atomic replace, ledgers), `FoundationNetworking` against `URLSession`, an Apple framework with a
Linux stand-in (Vision, CoreML, PDFKit, PencilKit, AVFoundation, Speech), or a test that runs the built binary.
Everything else is **logic**: it runs the same Swift on both, so Linux is enough on a pull request.

The decision is `scripts/ci-targets.json` (`logic` and `os_dependent`, each with its reason); a target in neither
list is treated as OS-dependent, so a new target is checked everywhere until someone classifies it.

| Target | Class | Why |
| --- | --- | --- |
| `AgeTests`, `SempereCaptureSharedTests`, `SempereImportTests`, `SemperePDFTests` | logic | no platform branch in the tests or the code under test |
| `SempereTests` | OS-dependent | `FileIO`, `VaultFileLock`, `WriteLedger`, `VaultTrust`, `BlobCache`, `FinderBundleBit` |
| `SempereWebDAVTests` | OS-dependent | the transport, `FolderRemote`, the slow HTTP server |
| `SempereRenderTests` | OS-dependent | Vision/CoreML/PDFKit/PencilKit parity, fonts, FoundationXML, JavaScriptCore |
| `SempereAppCoreTests` | OS-dependent | `VaultLibrary` and lifecycle file locking |
| `CLITests`, `SempereNotabilityTests` | OS-dependent | run the built `sempere`; Vision, Speech, AVFoundation, macOS-only cases |
| `SempereLocalizationTests` | OS-dependent | Apple only: Linux never builds it |
| `*Benchmarks` | none | never gate anything ([ci.md](../ci.md) "Benchmarks") |

The honest finding is that the split saves little by itself: the four logic targets hold about 180 of the ~3,600
tests, and the big ones (`SempereTests` 1,127, `SempereWebDAVTests` 717, `SempereAppCoreTests` 617) are
OS-dependent as targets although most of their tests are not. Hash skipping (below) is where the time goes. Part 2
can cut the large targets along the same line (the platform-neutral suites into a logic target), once the hashes
show which targets still run too often.

What the split changes, when switched on (`SEMPERE_CI_MAC_PACKAGE=os-dependent`): the Mac gate's `package` step
runs only the OS-dependent targets, and logs the logic ones as left to the Linux job. Linux runs every target. It
is off in part 1 (see "Decisions for the reviewer" in the pull request).

## Target hashes and skipping

`scripts/ci-hash.py` computes, for each test target, one SHA-256 over:

- every file (path and content, symlinks followed and their link text included) of the **whole folder** of the target and
  of every target in its dependency closure (from `swift package dump-package`), whatever `Package.swift` excludes:
  tests read their excluded fixtures (`SempereNotabilityTests`);
- targets the tests run without linking (`implicit_dependencies` in `scripts/ci-targets.json`: the CLI tests run the built
  `sempere`);
- the files and folders the tests **read from outside their own folders** (`extra_inputs`): docs
  (`SempereTests` reads `docs/format.md`, `key-hierarchy.md`, `settings-sync.md`, `settings.schema.json`, `security.md`),
  the app's and the package's sources (`LocalizationCatalogTests` and `SharedSettingsTests` read all of `Sources/` and
  `Apps/`), `web/test/fixtures` and `web/test/golden`, and other targets' fixtures (`Tests/SempereTests/Fixtures` is read
  by five other targets, `Tests/SemperePDFTests/Fixtures` and `Tests/SempereRenderTests/Fixtures` by the CLI and render
  tests). `SempereTests` therefore reruns on any change under `Sources/` or `Apps/`; moving the catalog tests into a
  target of their own (part 2) is what would let it skip again;
- `Package.swift`, `Package.resolved`, `scripts/ci-targets.json`;
- the toolchain: `swift --version`, OS, kernel release, architecture; on macOS the OS build and SDK version; on Linux
  `/etc/os-release` and the Docker image id (`ci-linux.sh docker` passes it; the runner's image is pinned by digest in
  the workflow file, which the Linux hashes include);
- the files the job runs the tests with (`scripts/ci-linux.sh`, `test-offline.sh`, `test-webdav.sh`,
  `dav-fault-proxy.py`, `webdav-server-requirements.txt`, `local-ci.sh`, `test-runner.py`, `ci-hash.py`, the workflow), so
  changing how tests run reruns them all; the self-test fails if a script those test scripts invoke is not listed;
- the job's name, so the Mac's and Linux's results never stand in for each other.

**The cross-read guard.** Package.swift cannot say what a test reads at run time, so `ci-hash.py check-reads` scans
`Tests/**/*.swift` for it and fails, naming file and line, for every read that is not in the hash of a target that runs
that code: `#filePath` chains (parent folders walked, literals appended), every literal of such a file that names an
existing path under the escaped base, and literals that start with `docs/`, `Apps/`, `Sources/`, `web/`, `scripts/`,
`Tests/`. It over-approximates (a literal that happens to name a path counts), which only costs a declaration.
`scripts/test-ci-hash-guard.sh` is its test: with `extra_inputs` ignored the guard must itself find every known read
listed above, and with them it must find none. It runs in the gate's `help` step and in the Linux `test` job. A new
cross-folder read therefore fails CI until declared, instead of silently escaping the hash.

**Residual risk, bounded.** Not covered: tools installed from apt on Linux (poppler, zbar, zip) under the pinned image,
the clock, the network, and a path assembled at run time from data the scan cannot see. The forced full runs bound how
long any of that can hide: `--testflight`, `--release` and `--cli` run every test (`SEMPERE_CI_FORCE_ALL=1`), and the
weekly full run planned in part 2.

**The record.** When a run passed, every target it ran gets a small file `STORE/JOB/TARGET/HASH` with the commit,
the date and the host. The store is `.build/ci-pass` on Linux (the build volume, so a record lives as long as the
build cache; `fil-ci-sempere-build` on the runner) and `~/.cache/sempere-ci-pass` on the Mac;
`SEMPERE_CI_PASS_DIR` moves it. The files are content addressed, so a stacked or rebased pull request with the same
content as an earlier one hits the earlier record, whichever branch it was on.

**A skip stays honest.**
- A target is recorded only after the whole `swift test` run exited 0, by the script, never by hand.
- `record` recomputes the commit and every hash first, and refuses (saying why) unless the tree is a clean commit equal to
  the one the run was planned on and no hash moved during the run. It also refuses when a `SEMPERE_*` variable outside an
  allow-list is set (`SEMPERE_UPDATE_FIXTURES`, `SEMPERE_REGENERATE_*`, `SEMPERE_FUZZ_*`, `SEMPERE_REQUIRE_*`, ...): such a
  run was not the one the hash names. So every record names a commit someone can check out.
- On the Gitea runner `.build` is a symlink to the cache volume: `.gitignore` ignores `.build` (no trailing slash, which
  would not match a symlink), or the checkout would look dirty and nothing would ever be recorded.
- Every skip is logged with the hash and that commit, and the Mac gate prints the lines on the console too:
  `ci-hash: SKIP AgeTests  linux-test: hash 9e7f6532… passed at 3b1c… (2026-11-08 14:02 EST, host)`.
- An unreadable or missing record means run. `SEMPERE_CI_FORCE_ALL=1` runs everything (and still records). The
  release-bound Mac modes (`--testflight`, `--release`, `--cli`) set it themselves and pass it into the Docker
  jobs: a release runs the whole suite.
- The store is a claim by the machine that wrote it, not a signed artifact. Anyone who distrusts it forces a run
  or deletes the folder; the scheduled full run bounds how long a bad record could hide.

**Why not commit statuses.** One status context per target would flood the commit page and the required-check
list, and a status says "this commit passed", not "this content passed", which is what a stacked pull request
needs. The log line carries the commit. A single informational status that lists skipped targets is possible
later and would not be a required check.

**Build.** The package always builds (`swift build --build-tests`, incremental, cheap when warm), also when every
target is skipped: the benchmark targets are never tested but must still compile, and on Linux all test targets are
one xctest bundle. `ci-linux.sh test` also runs the portability and removable-importer checks every time.

**WebDAV job.** It runs the tests named `Wsgidav*`, which live in `SempereWebDAVTests` and `CLITests`; it is
skipped when both of those hash as already passed under the `linux-webdav` job.

## The lean Gitea gate

Required check names stay as they are (`Linux package tests (offline), portability, removable importers`,
`WebDAV integration tests (wsgidav)`, `local/app-tests`): no rename is needed, and none is proposed.

| Job | Runs on a pull request | Budget |
| --- | --- | --- |
| Linux package tests | the targets whose hash has no passing record (all on a cold store), `check-portability`, `check-removable-importers` | a docs-only or unrelated change: about a minute; a typical change: the targets it touches. Cold, full: the 45–60 minutes of today |
| WebDAV integration | skipped when `SempereWebDAVTests` and `CLITests` are unchanged | same |
| `local/app-tests` | the tooltip lint, iOS compile check, Mac Catalyst unit tests, package tests with the same skipping | unchanged semantics; the package step shrinks |

Static builds, simulator suites and UI tests stay out of pull requests (release layers). The aim is a typical
pull request under ten minutes on the runner; a measurement after part 2 decides whether that holds.

## The scheduled benchmark run

Benchmarks (`<Module>Benchmarks` targets, `scripts/bench.sh`) never gate anything. Proposal for part 2, together
with turning skipping on for the runner's weekly full run: a Gitea Actions
workflow `.gitea/workflows/bench.yml` on `schedule` (weekly, Sunday night) and `workflow_dispatch`, on the same
Linux runner and image, running `scripts/bench.sh` in release mode and keeping the printed timings in the job log.
The same workflow runs the Linux tests with `SEMPERE_CI_FORCE_ALL=1` first, so the skip store is re-proved and
tool drift shows within a week. It is never a required check. A shared runner makes the numbers noisy: the point is a
trend and a crash detector, and a bigger regression is confirmed on the Mac with `just bench`. Not added in part 1 (reviewer decision):
the workflow spends the runner's time, which is the owner's call, and a scheduled workflow only runs from the default branch.

## Decisions (review of part 1)

1. The Mac gate's logic/OS-dependent split stays **off**; it is a switch (`SEMPERE_CI_MAC_PACKAGE=os-dependent`).
2. Records stay **files** (build volume, `~/.cache`), with no branch-protection change.
3. The weekly forced full and benchmark run stays a part 2 design, **together with enabling skipping on the runner**;
   no workflow file is added here.
4. Splitting the big OS-dependent targets is part 2, only if hit-rate data calls for it; the cross-read guard must then
   cover the moved `#filePath` reads (it scans every folder under `Tests/`).

## Migration order

1. **Part 1 (this pull request):** `ci-hash.py` with its self-test, skipping in `ci-linux.sh` (`test`, `webdav`)
   and in the Mac gate's `package` step, the classification in `ci-targets.json`, the release modes forcing
   everything, and the fix for `posix_spawn: Argument list too long` in `scripts/test-linux.sh`.
2. **Part 2:** measure the hit rate on a few real pull requests; decide and flip `SEMPERE_CI_MAC_PACKAGE` to
   `os-dependent` for the gate; split the large OS-dependent targets; hash the Xcode targets of `scripts/app.sh
   test-mac` (project, app sources, the package closure) the same way.
3. **Part 3 (with part 2's runner skipping):** the scheduled workflow (full forced run, then benchmarks), pruning of old records (keep the newest
   few per target), and a summary status for skipped targets if the logs prove hard to read.
