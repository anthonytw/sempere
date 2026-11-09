# A lean CI (thin-app wave 7)

Status: part 1 is built (the hash tool, skipping on Linux and on the Mac, the classification). Part 2 as decided by
the owner on 2026-11-09 is built too: the Linux jobs run in the Mac gate, in Docker, and Gitea runs nothing for a pull
request. The policy tables in [ci.md](../ci.md) describe what runs today.

## Why

A pull request's Gitea run took 45–60 minutes on the Orin runner (aarch64, one job at a time; the Linux package job
alone took ~42 minutes there and 384 s cold in Docker on the Mac), and stacked pull requests each needed a fresh run
although most of their targets did not change. The owner's goals (2026-11-06
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
  `/etc/os-release` and the Docker image id (`ci-linux.sh docker` passes it: the local default tag floats, so a moved tag changes the hashes);
- the files the job runs the tests with (`scripts/ci-linux.sh`, `test-offline.sh`, `test-webdav.sh`,
  `dav-fault-proxy.py`, `webdav-server-requirements.txt`, `ci-hash.py`; for the Mac job, `local-ci.sh` and `test-runner.py`
  instead), so changing how tests run reruns them all; the self-test fails if a script those test scripts invoke is not listed;
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
long any of that can hide: `--testflight`, `--release` and `--cli` run every test (`SEMPERE_CI_FORCE_ALL=1`). The owner decided (2026-11-09) against any weekly or post-merge
full run: a target whose hash has a passing record never reruns, and the release modes are the full proof.

**The record.** When a run passed, every target it ran gets a small file `STORE/JOB/TARGET/HASH` with the commit,
the date and the host. The store is `~/.cache/sempere-ci-pass` on the Mac for the Mac and the Docker jobs alike (`ci-linux.sh docker` mounts it
at `/ci-pass`; so a new or pruned build volume loses no record); `SEMPERE_CI_PASS_DIR` moves it. A bare
`ci-linux.sh test` (a manual runner job) keeps `.build/ci-pass`. A record names a job, a target and a hash, never a
commit: a stacked or rebased pull request, or the push to `main` of a squash whose files the pull request already
passed, has the same hashes and hits the earlier record, so merging costs no run.

**A skip stays honest.**
- A target is recorded only after the whole `swift test` run exited 0, by the script, never by hand.
- `record` recomputes the commit and every hash first, and refuses (saying why) unless the tree is a clean commit equal to
  the one the run was planned on and no hash moved during the run. It also refuses when a `SEMPERE_*` variable outside an
  allow-list is set (`SEMPERE_UPDATE_FIXTURES`, `SEMPERE_REGENERATE_*`, `SEMPERE_FUZZ_*`, `SEMPERE_REQUIRE_*`, ...): such a
  run was not the one the hash names. So every record names a commit someone can check out.
- `.gitignore` ignores `.build` (no trailing slash, so it also matches a symlink or a mounted volume), or the checkout would look
  dirty and nothing would ever be recorded.
- Records are refused in a git worktree (a `.git` file instead of a folder in the container's view: no commit can be
  named). Run the gate from a clone, as the agents do.
- Every skip is logged with the hash and that commit, and the Mac gate prints the lines on the console too:
  `ci-hash: SKIP AgeTests  linux-test: hash 9e7f6532… passed at 3b1c… (2026-11-08 14:02 EST, host)`.
- An unreadable or missing record means run. `SEMPERE_CI_FORCE_ALL=1` runs everything (and still records). The
  release-bound Mac modes (`--testflight`, `--release`, `--cli`) set it themselves and pass it into the Docker
  jobs: a release runs the whole suite.
- The store is a claim by the machine that wrote it, not a signed artifact. Anyone who distrusts it forces a run
  or deletes the folder; the release modes bound how long a bad record could hide.

**Why not commit statuses.** One status context per target would flood the commit page and the required-check
list, and a status says "this commit passed", not "this content passed", which is what a stacked pull request
needs. The log line carries the commit. A single informational status that lists skipped targets is possible
later and would not be a required check.

**Build.** The package always builds (`swift build --build-tests`, incremental, cheap when warm), also when every
target is skipped: the benchmark targets are never tested but must still compile, and on Linux all test targets are
one xctest bundle. `ci-linux.sh test` also runs the portability and removable-importer checks every time.

**WebDAV job.** It runs the tests named `Wsgidav*`, which live in `SempereWebDAVTests` and `CLITests`; it is
skipped when both of those hash as already passed under the `linux-webdav` job.

## The gate (decided 2026-11-09)

The Linux jobs moved to the Mac: the Orin runner needed ~42 minutes for the package job that takes 384 s cold in
Docker on the Mac. `scripts/local-ci.sh` (the PR gate, `local/app-tests`) now runs, in a lane beside the Mac steps (see "Order and concurrency"), the Linux
package tests, portability and removable-importer checks (`ci-linux.sh docker test`) and the WebDAV tests
(`docker webdav`), each with hash skipping on. `local/app-tests` is posted only when every step passed. The Gitea
workflow `linux.yml` is deleted (reviewer decision 2026-11-09; the owner's Orin runner is no longer used for this), so no
Linux context is produced for a pull request. A bare `scripts/ci-linux.sh test` still works on any Linux host with the
Swift image's toolchain, with its records in `.build/ci-pass`; the contexts `Linux package tests (offline), portability, removable importers` and
`WebDAV integration tests (wsgidav)` therefore must not be required on `main` (see the pull request).

| Step | Runs on a pull request | Budget |
| --- | --- | --- |
| `help`, `ios-build`, `mac`, `package` | as before (`package` skips by hash) | as before |
| `linux` | the targets whose hash has no passing record (all on a cold store), `check-portability`, `check-removable-importers` | docs-only change: about a minute (the build is incremental) |
| `webdav` | skipped when `SempereWebDAVTests` and `CLITests` hash as passed | same |

Static builds, simulator suites and UI tests stay out of pull requests (release layers).

**Order and concurrency.** The Mac steps (`help`, `ios-build`, `mac`, `package`) run one after another as before; the two
Docker steps run as a lane beside them, started first and joined at the end (`SEMPERE_CI_LINUX_LANE=serial` puts them
after the Mac steps; the release-bound modes run them serially and force every test). Each Docker job holds a lock on its build volume for the whole job (plan, build, test, record), so two checkouts that
share the volume cannot rebuild `.build` under each other's `--skip-build` test run and record passes for code never tested.
A gate that stops (a failed step, SIGINT or SIGTERM) removes its own containers (label `sempere-ci-run`) and posts no
success; the verdict on the lane comes from `build/local-ci/lane.result`, one `passed` line per lane step. A Linux failure
fails the gate as soon as the next Mac step ends. Docker's VM (14 CPUs, 7.7 GB) and the Mac's Catalyst runs do
not compete in practice. Measured on this Mac, 2026-11-09, wall-clock without the wait for `xc-lock`:

| Gate run | Mac steps (`help` + `ios-build` + `mac` + `package`) | Docker lane (`linux` + `webdav`) | Whole gate |
| --- | --- | --- | --- |
| Cold, serial (empty record store, fresh volume) | 19 + 55 + 249 + 275 s | 415 + 144 s | **19.3 min** |
| Cold, lane beside the Mac steps (same) | 20 + 16 + 224 + 236 s | 389 + 169 s | **10 min** (Mac steps no slower) |
| Warm, every target skipped | 20 + 24 + 221 + 8 s | 125 + 7 s | **about 5 min** (`mac` is the floor) |
| One line changed in `Sources/SempereImport` | 20 + 15 + 236 + 200 s | 313 + 195 s | **8.5 min** |

Before: a gate of about 10 minutes plus the Gitea run of ~52 minutes on the Orin (the package job ~42, WebDAV the rest),
one after the other in practice, since a merge waited for both. Now one 10-minute gate when cold and 5-9 minutes warm.
The warm floor is the Catalyst `mac` step (not hashed yet, part 2 leftovers) and the Linux job's fixed 2 minutes (container
start, `apt-get install`, the incremental build and the portability and removable-importer checks). A one-line change
reruns most targets because `SempereTests` reads all of `Sources/` and `Apps/` (`extra_inputs`), the known cost of the
catalog tests; splitting them out is what would let it skip.

## The scheduled benchmark run

Benchmarks (`<Module>Benchmarks` targets, `scripts/bench.sh`) never gate anything. Proposal, still open and separate from the Linux tests: a Gitea Actions
workflow `.gitea/workflows/bench.yml` on `schedule` (weekly, Sunday night) and `workflow_dispatch`, running
`scripts/bench.sh` in release mode and keeping the printed timings in the job log. It would not rerun the tests (no
weekly full run, owner 2026-11-09) and is never a required check. A shared runner makes the numbers noisy: the point is a
trend and a crash detector, and a bigger regression is confirmed on the Mac with `just bench`. Not added in part 1 (reviewer decision):
the workflow spends the runner's time, which is the owner's call, and a scheduled workflow only runs from the default branch.

## Decisions (review of part 1)

1. The Mac gate's logic/OS-dependent split stays **off**; it is a switch (`SEMPERE_CI_MAC_PACKAGE=os-dependent`).
2. Records stay **files** (`~/.cache/sempere-ci-pass`; the build volume only for a bare run), with no branch-protection change.
3. (Superseded 2026-11-09.) The weekly forced full run and the runner-skipping plan are dropped: CI never reruns a
   target whose hash has a passing record, and the Linux jobs run in the Mac gate. No scheduled workflow is added.
4. Splitting the big OS-dependent targets is part 2, only if hit-rate data calls for it; the cross-read guard must then
   cover the moved `#filePath` reads (it scans every folder under `Tests/`).

## Migration order

1. **Part 1:** `ci-hash.py` with its self-test, skipping in `ci-linux.sh` (`test`, `webdav`) and in the Mac gate's
   `package` step, the classification in `ci-targets.json`, the release modes forcing everything, and the fix for
   `posix_spawn: Argument list too long` in `scripts/test-linux.sh`.
2. **Part 2 (2026-11-09, owner decisions):** the Linux package and WebDAV jobs join the Mac gate in Docker with records in
   `~/.cache/sempere-ci-pass`; the Gitea workflow `linux.yml` is deleted; no weekly full run, no full run after a merge. Still
   open: flipping `SEMPERE_CI_MAC_PACKAGE` to `os-dependent`, splitting the large OS-dependent targets, and hashing the
   Xcode targets of `scripts/app.sh test-mac` the same way, each only if the measured hit rate calls for it.
3. **Later:** pruning of old records (keep the newest few per target), a summary status for skipped targets if the logs
   prove hard to read, the benchmark workflow above if the owner wants it.
