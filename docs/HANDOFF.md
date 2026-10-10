# Handoff: where the project stands and how to continue

**Start here in a new session.** Then read `CLAUDE.md` (hard rules + gotchas),
`DESIGN.md`, `docs/format.md` (normative), `docs/plan.md`. Anything here that
disagrees with those files or with `gh pr list` is out of date: fix this file.
Last full rewrite: 2026-10-05, by the driving Opus session.

## The project in one paragraph

Open-source (GPL-3.0-or-later + App Store exception), end-to-end-encrypted
handwriting notes for iPad (iPadOS 27+) and Mac (Catalyst 27+), a stripped-down
Notability. Vault = a plain folder of write-once age-encrypted revision files
(any storage: iCloud Drive, Files providers, WebDAV, a folder); user-owned keys;
PencilKit canvas with vector strokes; Notability importer; CLI (`sempere`,
Linux + macOS) for recovery/export. Repo: github.com/anthonytw/sempere
(public, GitHub only — never Gitea).

**Renaming to "Sempere"** (nod to *La sombra del viento*; "Sempere" is taken
on the App Store). See "Rename sweep" below; until it lands, code uses the old
names.

## Status (2026-10-05)

Merged on `main` (squash, CI green): #1–#8 Phase 0 (render, age, note log,
vault I/O, CLI, Notability importer), #10 app scaffold, #11 cloud setup script,
#12 CLI import/search, #13 PNG export, #14 history/restore, #15 vault browser,
#16 WebDAV sync, #17 PencilKit canvas, #18/#19/#31 importer fixes + fidelity
evaluation + full multi-zip backup (.ntb, versions, shapes, folder tags),
#20 debug-launch `~/` paths, #21 usability pass (vault as one item, progressive
iCloud load, layout, palette, rename, tag editor), #29 iCloud sync fixes
(auto-start, progress bar, no blank notes, scroll past ink, Keep Screen On),
#9/#32 docs.

Open PRs (all reviewed-or-in-review by cloud sessions; the driver merges):

| PR | Branch | What | State |
| --- | --- | --- | --- |
| #22 | design/attachments | Attachments FORMAT DESIGN (text boxes, images, audio + transcripts, PDF backgrounds); maintainer decisions final (PR comment 2026-10-05) | final revision in cloud session |
| #23 | feat/tag-set-merge | Tags as an observed-remove set (add wins), legacy `setMeta(tags)` compat; must adapt the importer's folder-tag helper | review session S1 |
| #24 | feat/app-keys-rename-eraser | Keychain-remembered keys (Face ID), long-press title rename, app-side object eraser with sizes + cursor | review session S2 |
| #25 | fix/untrusted-input-hardening | Parser hardening + seeded fuzz harness; adds `format.md` §9 "Untrusted input" (renumbered from §8 after #22 took §8) | review session S1 |
| #26 | chore/release-engineering | Release workflow, Homebrew, CHANGELOG, CONTRIBUTING (App Store exception, no CLA), SECURITY, App Store docs | review session S3 |
| #27 | feat/export-markdown-html | Obsidian Markdown + single-file HTML export | review session S3 |
| #28 | feat/paper-templates | Parametric paper (`format.md` §5.4.2: nine kinds, page-level paper via `setPagePaper`, unknown kinds kept by name and rendered blank) + visual paper picker (apply to page / all pages / default for new notes); app part not yet tried on the iPad | review session S2 |
| #30 | feat/recovery-kit-backup | `keys paper` recovery PDF with QR, backup/verify/restore | review session S3 |
| #33 | feat/pq-recipients | MLKEM768-X25519 hybrid recipients; vaults post-quantum ONLY | review session S1 |

Cloud review sessions (started 2026-10-05 ~3:10 pm ET; prompts in
`~/Documents/sempere-sessions/`): S1 core+crypto session_018MdrghAVBvEAmFhniW8DY9,
S2 app session_01Aq6fucMojZT1mNSPWro6U2, S3 cli+release (Sonnet)
session_01MZXBxdMScB8hq5J7x52FZ2, design #22 session_011NXVJR4jRtMgSKEVY4NvYi.
Each merges main, reviews, fixes, gets CI green, comments on its PRs; none merges.

**Merge order** once reviewed: #25 → #23 → #33 (core; `format.md`: #22 is §8, #25 §9
after the renumbering), then #22 (design, docs), #24 → #28 (app), #30 → #27 → #26.
After each merge, later PRs may conflict: resolve locally in a worktree or tell
the owning session (`claude -p "…" --cloud <session_id>`).

## Decisions (made by the user; do not relitigate)

- **Post-quantum only:** vaults accept only the age hybrid ML-KEM-768 + X25519
  recipient (newest age spec, interop with `age` ≥ the first PQ release).
  Classic X25519-only keys are rejected ("create a new key"). Passphrases stay
  (they only wrap the key file in `keys/`). ML-KEM from CryptoKit (Apple) /
  swift-crypto (Linux), never hand-rolled.
- **Key flow:** one secret (the key). Create vault → print recovery kit → on
  each new device paste/scan/AirDrop the key once (or a passphrase if the user
  chose one) → Face ID afterwards (Keychain, #24). Default: no passphrase.
- **Licensing:** GPLv3 + App Store exception (§7 additional permission), no
  CLA. All deps are Apache-2.0 (swift-crypto incl. vendored BoringSSL,
  argument-parser, asn1) + zlib: GPL-compatible.
- **CLI first (2026-10-06):** "The CLI should be the first place to get
  features. Everything should be automatable (aside from the UI)." Every
  feature prompt includes a `sempere` command with `--json` output and CLI
  tests, sharing the core code the app uses (see `CLAUDE.md` "CLI first").
- **Export compliance:** mass-market, standard published algorithms, full
  strength. The App Store Connect answer is "exempt" (Info.plist
  `ITSAppUsesNonExemptEncryption = NO`, so no per-build question). France is
  excluded from availability until the ANSSI declaration
  (`docs/appstore/france-declaration.md`) is approved. Research, sources and exact
  answers: `docs/release/export-compliance.md`; the rest of the submission: `docs/release/app-store.md`.
- **Attachments design (#22):**
  - per-note storage `notes/<id>/att/`, keyed-hash names, Padmé padding;
  - LWW item fields, integer z-layers (0 background, 100 content, ink above);
  - full Unicode (system fonts in the app, glyph-subset embedding in exports, Noto on Linux);
  - Spanish localization, and reserved `math` (LaTeX) and `video` items;
  - a settings panel (audio codec and quality, EXIF stripping on by default, rewrap modes);
  - an automatic rewrap policy with settings: adding a device rewrites headers only, removing a device or a PQ migration fully re-encrypts;
  - time-stamped transcript segments, and `rec: {id, at}` to sync ink and audio;
  - Poppler on Linux for PDF backgrounds in SVG/PNG (else a placeholder);
  - a "PDF + attachments" export option and an unused-attachments index in Settings;
  - on-device AI only.
- **Notes are keyed by UUID; duplicate titles are fine everywhere.** Notebooks
  are `/`-separated paths shown as a tree. Folder names become tags on import.
- **Pages vs pageless:** a per-note choice (#52), with continuous scrolling between pages (#80).
- **History:** checkpoints, editing sessions and configurable thinning (#74; details below).

## Personal data

`data/` is git-ignored. It holds the user's full Notability backup as three Google Drive
parts, `Notability-20261005T121200Z-1-00{1,2,3}.zip`. Pass all three together: 928 `.note`,
603 `.ntb`, 395 Notability PDF exports. `data/README.md` says the same.
- **Never** commit, quote or paste its contents: not in code, tests, docs, commits, PR
  bodies, or messages to other agents. Cloud sessions never see it; only the driver
  verifies on it, locally, reporting structure and counts only.
- Real-data tests are gated on `SEMPERE_NOTABILITY_SAMPLES`.
- Scratch output goes under `data/<name>/` and is deleted when done.

Import of the full backup (2026-10-07, after D1–D4, #76):
- **Notes:** 640 imported, 891 skipped, 0 failed.
- **Attachments:** 5,013 PDF pages, 25 images and 53 typed-text items (158 blobs, 968 MB).
- **Recognition:** 536 notes carry Notability's recognition, plus the `.ntb` index (#57).
- **Still dropped, all legitimately:** 2 encrypted PDFs, 1 broken PDF, 3 empty text boxes,
  1 empty image, and 310 dashed strokes (imported solid, counted).
- **Gaps in progress (#79):** `.ntb` top-level PDFs and images (4 notes), PDF text index,
  handwriting language (52 `es_ES`), highlighter behind text.

## Test vault and the user's iPad

- **iPad:** "antpad", an iPad Pro 12.9" 4th gen (A12Z, Face ID, Pencil 2, no hover).
  It runs iPadOS 27, the app's minimum since 2026-10-10 (it ran 26.7.1 before; observations
  below tagged 26.7.1 are from then).
  UDID 00008027-001D30E02131802E. It is reachable over Wi-Fi by `devicectl` when awake.
- **Test vault:** iCloud Drive `Sempere/Notes.sempere`, post-quantum.
  - Key: `~/.config/sempere/identity.key`.
  - Full backup imported; re-imported with attachments on 2026-10-07 (1.2 GB, verified healthy).
  - The user takes no real notes in it yet, so re-importing with `--overwrite` is fine.
  - To put the key on a device: `pbcopy`, then clear the clipboard after a few minutes.
- **Device dev builds:** `xcodebuild … -destination 'id=<UDID>' -allowProvisioningUpdates
  DEVELOPMENT_TEAM=6X3PT3FXGA build`, then `xcrun devicectl device install app` /
  `process launch`. TestFlight builds cannot be debugged; use a dev build.
- **Debugging without the user:**
  - DEBUG launch env vars (`CLAUDE.md`);
  - `devicectl device copy to/from --domain-type appDataContainer`;
  - `--console` for logs;
  - the timing signposts from #56.
- **User testing:** a checklist page per build, read back by the driver (`docs` is not
  the place for its URL; see the driver's memory).

## Apple developer / App Store / TestFlight

**Accounts and keys:**
- Paid Apple Developer Program, team 6X3PT3FXGA (individual).
- App Store Connect app "Sempere" (id 6819333304, iOS + macOS), bundle id
  `io.github.anthonytw.sempere`.
- TestFlight group "Internal" (all builds) holds the user.
- The listing metadata, availability (every country except France), privacy policy URL,
  review contact and categories are set through the API (an `asc.py` helper on the
  driver's Mac).
- API keys live in `~/.config/sempere/`, mode 0600:
  - **Admin**, `sempere-admin-AuthKey_47Z492KR68.p8`, can cloud-sign;
  - **App Manager**, `sempere-app-manager-AuthKey_3M856V593J.p8`, API only, **cannot sign**.
  - Both use issuer `24e225fb-771e-4dc7-b322-632d16493446`.

**Upload a TestFlight build:** run `~/.claude/scripts/sempere-testflight.sh [ios|mac|both]`
on the maintainer's Mac. It archives `main` and uploads, signed with the Admin key, so it
needs no Xcode login. It also handles two gotchas:
- it puts `/usr/bin` first in PATH, because Homebrew's rsync 3.x breaks IPA packaging ("Copy failed");
- it sets `manageAppVersionAndBuildNumber`, which assigns build numbers.

The Mac build uses `-destination 'generic/platform=macOS,variant=Mac Catalyst'`. Its sandbox
entitlements are in `Apps/Sempere/Sempere.entitlements`.

**Never commit `DEVELOPMENT_TEAM`.**

## Rename to Sempere (done 2026-10-05)

The project was called InkVault until this rename; old PRs, commits and
sessions use that name. Everything was renamed in one PR:
- the app "Sempere", bundle `io.github.anthonytw.sempere`;
- the CLI `sempere`, the modules `Sempere*`, the app target `SempereApp`;
- the vault extension `.sempere` and its UTType;
- the format ids `sempere/1` and `sempere-backup/1`, the body magic `SMPR`
  and the HMAC label (existing vaults no longer open, which is fine before
  1.0);
- the Keychain service, the `SEMPERE_*` env vars and `~/.config/sempere/`;
- the repo, now `anthonytw/sempere`, with redirects from the old name.

Next: rebuild the test vault (post-quantum key, full import), then the first
TestFlight build, then one `/ultrareview` (the user has 3 free cloud
multi-agent reviews; the user triggers it).

## How work gets done (what worked, what didn't)

- **One task → one branch → one PR → squash merge, CI green.** Agents never
  merge; the driver session reviews and merges. Every review so far found real
  bugs (several data-loss class) — never merge unreviewed code.
- **Cost model (important):** the user's "Cloud session credit" (~$250) covers
  ONLY cloud *sessions*. Routines (RemoteTrigger / `/schedule`), Projects,
  remote control and local agents all draw the user's **plan limits**. Prefer
  cloud sessions for big work; keep local agents for things that need the Mac
  (Xcode, simulator, the iPad, private `data/`). Prefer Sonnet where enough;
  don't fan out without asking.
- **Starting a cloud session from the Bash tool:**
  `PTY_SECS=180 PTY_STOP_ON_URL=1 python3 ~/.claude/scripts/cloud-session-pty.py
  claude [--model sonnet] --cloud "$(cat prompt.txt)" --ref main`, run from a
  CLEAN clone of the repo (no `data/`). The script provides a pty, answers the
  folder-trust prompt, and strips inherited `CLAUDE_CODE_*`/`CLAUDECODE` env
  vars — without that, `--cloud` silently uploads a "seed bundle" and the
  session gets **403 on push** (its unpushed work is unrecoverable; teleport
  only fetches pushed branches). Check `RemoteTrigger get_run_log <session_id>`:
  "Fetching/Cloning repository" = good, "Cloned from seed bundle" = bad.
- **Messaging a running session:** `claude -p "msg" --cloud <session_id>
  --output-format json` (`-p` is required; without it the error says attaching
  is "not enabled for your account").
- **Cloud VM:** Ubuntu, no Xcode. It builds/tests `Sources/` + `Tests/`; app
  code is compiled only by the GitHub Actions `app` job (push → `gh pr checks
  --watch` → `gh run view --log-failed`). The `sempere` environment's setup
  script (`scripts/cloud-setup.sh`) installs Swift 6.4.0 into /usr/local/bin.
  Sessions use GitHub MCP tools (the VM's `gh` token is invalid).
- **Local agents:** create the worktree yourself
  (`git worktree add .worktrees/<name> -b <branch> origin/main`) and point the
  agent at it; never the Agent tool's `isolation: worktree` from `dev/` (it
  branches the bootstrap repo). Remove worktrees after merge.
- **Racing:** if a review session is still active on a branch, don't fix the
  same branch locally — it will push first and you'll duplicate work.
- **Briefs** must be self-contained: reading list, scope, API shape, tests,
  process (branch, merge-not-rebase, push, PR, don't merge), privacy rules,
  the iPadOS/iOS 27 app minimum (package and CLI stay at their own), co-author line.
- **Waiting:** use background commands / Monitor with until-loops; never chain
  sleeps. `gh pr checks --watch` exits non-zero on failure — never chain
  `gh pr merge` after it without checking.
- **Docs-only PRs** have no CI checks; merge directly.
- **macOS shell:** `rm` is aliased interactive — use `/bin/rm`; `grep -r` from
  `dev/` skips sub-repos.

## CI

CI (`.github/workflows/ci.yml`) is gated so that runs are not wasted. macOS
runners are scarce: every run needs two of them, and on 2026-10-05 eleven runs
queued for up to 30 minutes.

- **Draft PRs run nothing.** Open work as a draft (`gh pr create --draft`) and
  push as often as you like. Run `gh pr ready <n>` when you want CI or a
  review; later pushes to a ready PR run CI again.
- **A newer push to the same PR cancels the older run.**
- **Only affected jobs run.** Docs-only changes run nothing. CLI, importer and
  WebDAV changes skip the app job. App-only changes skip Linux and macOS.
  `main` always runs everything.
- **Web viewer:** `web/` changes run only the `web` (npm lint, typecheck, tests,
  build) and `web-golden` (Swift CLI exports of the fixture vaults diffed with
  `web/test/golden`) jobs; Swift changes do not run them on a PR, `main` does.
  A Swift change to merging or rendering that moves the goldens shows up on
  `main`: regenerate with `web/scripts/golden.sh` (docs/web-viewer.md).
- **On demand:** `gh workflow run CI --ref <branch>` checks any branch.
- **PRs skip what only matters for shipping.** The static Linux release build
  runs on `main` only (with its own build cache, `linux-release`), and so do the
  Mac Catalyst test suites below; every app run builds for Catalyst in
  "Launch smoke tests on Mac Catalyst". Tests run with `--parallel`.
- **Mac Catalyst tests** (`scripts/app.sh test-mac`, `test-mac-ui`) run the app
  suites and `MacWindowUITests` on the runner's macOS, ad-hoc signed and
  sandboxed, on `main` and on dispatch only. A cloud session without a Mac
  checks Mac behaviour with `gh workflow run CI --ref <branch>` (or the GitHub
  MCP `run_workflow`). When the app job fails, its "Summary of failures" step
  prints the failing tests and the UI-test window dumps at the end of the log.
- **Launch smoke tests run on every PR that runs the app job** (any change
  under `Apps/`, the Sources the app links, `scripts/app.sh` or `ci.yml`): a
  build that crashed at launch on the Mac shipped (fresh state, a real vault
  unlocked, sidebar visible) while every UI test started from a demo vault
  the app unlocked itself. `LaunchSmokeUITests` launches with no
  preferences, caches or saved windows (`SEMPERE_DEBUG_FRESH`), unlocks the
  demo vault through the unlock sheet (`SEMPERE_DEMO_PASSPHRASE`), checks the
  library in each column layout and opens Settings, Vault Keys, a note window,
  Export…, Export to Folder or Zip… and Restore from Backup…. On the Mac it is its own
  step, "Launch smoke tests on Mac Catalyst" (`scripts/app.sh
  test-mac-smoke`: a Catalyst build of the app and its UI tests from the
  cache, then four launches; about 5 minutes, the only Catalyst step a PR
  runs). On the iPad its two sidebar/list layouts run inside "UI tests on the
  iPad simulator" (`test-ui`, about a minute more). Their window dumps are
  `SMOKEDEBUG` lines in the failure summary, with the newest Mac crash
  report's crashing thread and, after an iPad UI test failure, the
  simulator's log of the app's faults and hangs. The first smoke test of a
  run launches the app once without querying it (the first launch after an
  install is slow on a CI simulator). The iPad simulator has stopped answering
  accessibility queries for a minute or more ("Timed out while evaluating UI
  query") in some runs; a recurrence is a real failure to diagnose from that
  log, not a re-run.
- **Tools that tests need are required, not optional, in CI** (gap audit GA-61):
  `SEMPERE_REQUIRE_TOOLS` (a comma list of `zbar`, `zip`, `pdftotext`, `bidi`, or `all`;
  `Tests/FuzzSupport/RequiredTools.swift`) turns a missing zbarimg, zip, pdftotext or
  UCD 15.1 `BidiTest.txt` into a test failure; `SEMPERE_REQUIRE_POPPLER` does the same for
  pdftoppm and, on a Mac, pdftotext. The Linux job installs them with apt, the macOS job with
  brew (`poppler`, `zbar`). Locally the tests still skip.
- **Extra jobs** (PRs that change the package run `webdav`; the Swift and web changes the web
  viewer reads run `web-smoke`): `webdav` runs `scripts/test-webdav.sh` (wsgidav, fails on a
  skip) and `web-smoke` builds the CLI, builds the viewer and runs `web/scripts/smoke-all.sh`
  (all six browser smoke scripts in Chromium; `smoke-cache` gets a copy of the sample vault
  with summaries and an index). The `app` job also runs `scripts/app.sh pseudo`
  (double-length, right-to-left and Spanish layouts on an iPad simulator). New required
  checks for the ruleset: `WebDAV integration tests (wsgidav)` and `Web viewer browser smoke
  tests (Chromium)`.
- **Every scene injects the app environment:** `AppSceneEnvironmentTests`
  (Linux, plain `swift test`) reads `Apps/Sempere/SempereApp/` and fails when
  a `WindowGroup` (or any other scene) does not put `AppModel`,
  `VaultLibrary` and `RememberedKeys` into its root view's environment
  (directly or through `appEnvironment(model:library:keys:)`), or when a view
  reads one of them with a plain `@Environment(X.self)` instead of the
  non-trapping wrappers (`AppModelEnvironment.swift`). App-only PRs
  run it in the "Localization catalogs and app scenes (Linux)" job.
- **Age is compiled with `-O` even in debug builds** (`Package.swift`).
  Unoptimized scrypt made the passphrase tests take minutes: 37 s for one test
  on macOS CI, and 138 s for one app test. Keep that flag.
- **Build caches:** each job restores `.build` (or `.build/xcode` for the app)
  from the newest cache saved by a `main` run; PRs never save. The key is the
  checkout path, toolchain version and `Package.resolved` (precompiled modules embed absolute paths, so a repo rename must start fresh caches), so changing either starts a
  fresh cache. If a build ever fails in a way a clean build would not (stale
  products), run `gh cache delete --all` and re-run.
- Tell every cloud session in its prompt: draft PR first, `gh pr ready` once
  the work is done and the local `swift test` passes.

## Lessons learned (technical, beyond CLAUDE.md gotchas)

- "No ink on the iPad" was iCloud (dataless real-name files on 26.7.1, folders
  listed before contents), not rendering: verify on the device with a DEBUG
  snapshot from a local copy before theorising about renderers.
- The simulator renders PencilKit faithfully; a 2020 iPad Pro on 26.7.1 drew a
  real imported note identically.
- Notability backups from Google Drive keep every old copy of moved/renamed
  notes; pick the newest per uuid, keep divergent ink as a version note.
- The first "backup" was only part 2 of a 3-part Drive download — always check
  for `-00N` siblings.
- Canvas snapshot tests flake on cold CI simulators (PencilKit draws tiles
  async): retry per band, never widen tolerances.

## Roadmap

The roadmap is in `docs/ROADMAP.md`: tables by component (shared library,
CLI, iPad app, macOS app) and the order of work.

Phase 1 task detail (historical, for reference):

2. **Phase 1, iPad app** (needs Xcode on the Mac or the macOS CI runner;
   Opus for 3a/3c, Sonnet for the rest). Split:
   - 3a **done** (branch `feat/ipad-app-scaffold`): `Apps/Sempere/Sempere.xcodeproj`,
     hand-maintained with folder-synchronized groups (no XcodeGen/Tuist),
     scheme `SempereApp`, iPadOS 26 then (27 since 2026-10-10), Catalyst on, links the package's
     `Sempere` + `Age` products. Shell: `AppModel` (`@Observable`,
     `@MainActor`) opens a vault folder locked, unlocks with a pasted
     identity or a stored key file's passphrase, loads `Vault.summaries()`
     off the main actor and filters by sidebar selection (all, notebook,
     tag, deleted); `RootView` is a three-column `NavigationSplitView`
     (sidebar, note list, placeholder canvas) with a folder picker and an
     unlock sheet. Tests: Swift Testing in `SempereAppTests` against the
     fixture vault. Build/run: open the project in Xcode and run on an iPad
     simulator, or `scripts/app.sh test` / `scripts/app.sh catalyst`
     (CI job `app`). The folder picker does not persist access yet: 3b adds
     bookmarks, iCloud, vault creation and a real sidebar.
   - 3b **done** (branch `feat/app-vault-browser`): vault browser.
     `VaultLibrary` (recent vaults as bookmarks in
     `Application Support/Sempere/recents.json`, vault creation, folder-name
     validation), welcome screen (recents, vaults in the app's Documents folder,
     New Vault, Open Folder), `NewVaultView` (name, "On This Device" or any
     picked folder, generate an X25519 key or paste an `age1…` recipient,
     optional passphrase-wrapped copy in `keys/`; a generated key is shown once
     with copy/share), reopen of the last vault on launch, stale bookmarks
     re-saved, dead ones dropped with a message and the folder picker. Sidebar:
     rename notebook (applies to every note in it, deleted ones too). Note list:
     title search, sort (modified/title), new note (title, paper, notebook),
     context menu / swipe: add/remove tag, move to notebook, delete, restore.
     Every edit is one delta through `NoteWriter.append` with the same
     `DeviceClock` as the canvas (device id and clock in
     `Application Support/Sempere/device.json`; `Vault.apply` in
     `Edit.swift` stays for the CLI), the app writes no vault file itself. Tests: `BrowserTests` (app), `EditTests` (package).
     Leftovers: iCloud Drive works only through the picker (a folder inside
     iCloud Drive; the ubiquity container needs the iCloud entitlement
     `com.apple.developer.icloud-container-identifiers` +
     `com.apple.developer.ubiquity-container-identifiers` and a paid team, so
     `url(forUbiquityContainerIdentifier:)` is not used); evicted iCloud
     files are downloaded before reading and on every reload, with progress
     and cancel (`CloudVault.swift`, `docs/io.md` "iCloud Drive"; untested
     against real iCloud in CI, the simulator has none). Notebooks are a
     tree of `/`-separated paths (`format.md` §5.4, `Notebooks.swift`):
     selecting a folder shows its sub-folders' notes, rename/move rewrites
     the prefix of every descendant. Bookmarks on
     Catalyst use plain options (`.withSecurityScope` is not in the Catalyst
     SDK) and are untested on a sandboxed Mac build; the "On This Device"
     folder is not exposed in Files (needs `UIFileSharingEnabled` /
     `LSSupportsOpeningDocumentsInPlace`); vaults cannot be deleted or renamed;
     the new-vault key is not stored in the Keychain (3d); the empty notebook
     does not exist without a note (notebook is a note field).
   - 3c **done** (branch `feat/app-canvas`): `NoteCanvasView` shows one page
     at a time (`PageCanvasView`: `PKCanvasView` + system `PKToolPicker`,
     `PaperView` vector ruling from `SempereRender.PaperRenderer` under it, fit
     to width, pinch to 4x; infinite pages grow 400 pt below the ink and save
     the new `pageSize`). Conversion in `StrokeConversion.swift`; masked
     (pixel-erased) strokes become one stroke per `maskedPathRanges` range via
     the Linux-tested `BSpline.substroke` (SempereRender). Stable ids:
     `StrokeLedger` (pure, per page) matches canvas strokes by an O(1)
     content fingerprint (`CanvasStrokeInfo`) as a multiset, mints fresh ids
     for new content, infers `parent` (retired same-content stroke → same
     path signature → same family with containing bounds), revives ids whose
     removal is not on disk yet. `NoteEditor` debounces (1.5 s) into ONE
     delta per pause and flushes on page switch, background, note switch and
     vault close; `NoteWriter`/`DeviceClock` (actors) pick `seq`, tick the
     package `HybridClock` and keep `DeviceState` in Application Support.
     AppModel has a generation token so late `unlock`/`openVault`/`reload`/
     `openEditor` results after `close()` are dropped (`CancellationError`).
     Worked on iPadOS 26 at the time (the app's minimum is 27 since
     2026-10-10); tests passed on iOS 26.5 and 27 simulators. Left: no UI tests and no
     run on real hardware yet (pixel eraser verified with synthetic masks);
     the note list does not refresh its stroke counts after edits; remote
     changes arriving while a note is open were not merged into the canvas
     until it was reopened (merged in place since #91); no page delete/reorder; the app never writes
     snapshots; `reed` ink is stored as `fountainPen`.
   - 3b + 3c merge (#15 onto #17): the generation token also guards the
     iCloud download wait, browser edits (`refresh`), `createVault` (a vault
     created while another was opened is returned with its key, not opened)
     and the unlock after it; `close()` releases folder access only after the
     editor's last save and any browser edit in flight; the canvas reads and
     writes under `NSFileCoordinator` in iCloud Drive (`NoteEditor.open(...,
     coordinated:)`, `NoteWriter`); deleting or restoring the open note
     reopens it (read-only / editable).
   - 3d Keys: generate on device, import by paste/QR scan/AirDrop (`.key`
     file UTType), export (QR, share sheet), Keychain storage behind
     Face ID, passphrase-wrapped key file option; add second recipient
     flow ("add this Mac's key").
     **Keychain storage done** (branch `feat/app-keys-rename-eraser`):
     after a manual unlock (passphrase or pasted key) the unlock sheet offers
     "Remember on this iPad" (on) and "Also sync via iCloud Keychain" (off);
     a vault with a remembered key unlocks after Face ID as soon as it opens,
     falling back to the form when cancelled, missing or broken (a key that
     no longer opens the vault is offered for replacement). Sidebar key menu:
     "Forget Key for This Vault". `VaultKeyStore` (protocol) /
     `KeychainVaultKeyStore` (one generic-password item per vault id, service
     `io.github.anthonytw.sempere.vault-key`, label "Sempere — <name>"),
     `RememberedKeys` (observable, separate from `AppModel`), tests with
     `FakeKeyStore`. Untested on hardware: Face ID prompts, iCloud Keychain
     sync, Catalyst keychain (needs a signed build). Still open in 3d: key
     generation/export/QR/AirDrop, add-recipient flow, offering to remember
     the key of a newly created vault.
   - 3e Export: PDF via `SempereRender` through the share sheet; whole-vault zip
     dump; `verify` screen.
   - 3f **done** (branch `claude/handwriting-search-4793yc`): recognition is Vision
     on rendered pages (not PencilKit 27), see `CLAUDE.md` § Gotchas "Handwriting
     search". Original plan: iPadOS 27 PencilKit recognition → `setPageRecognition`
     per page after edits; search field over recognition text with word-box
     highlights.

## History and restore (how it works)

- A restore point is a revision; the note as of R is
  `NoteReducer.reconstruct` of every revision ordered `≤ R` by
  `(hlc, device, seq)`. There is no parallel merge implementation.
- `NoteHistory.restoreOps(current:target:)` diffs two states into one delta.
  Items correspond by id or by `parent` (for strokes also same ink/points/
  transform), which is what makes a repeated restore a no-op.
- Pages gained an optional `parent` (`format.md` §5.5) so a re-created page
  names the one it restores; old readers ignore it.
- Completeness after compaction: gone revisions are the `(device, seq)`
  listed in some snapshot's `included` without a file. A point is complete if
  each is covered by a snapshot `≤` it or provably after it (`Completeness`
  in `History.swift`; ranges are compared, never enumerated, since `upTo` is
  read from a file). An unreadable snapshot makes every point incomplete. This
  is conservative: some points that could be rebuilt are reported incomplete.
- App (`HistoryView.swift`, `AppModel+History.swift`): the note toolbar's
  "Version History…" opens a sheet with one row per restore point (time,
  device, kind, app; newest first, newest marked current). A row opens a
  read-only preview (a writer-less `NoteEditor` on the state as of the
  point, shown with `PageCanvasView`). "Restore This Version" calls
  `AppModel.restoreVersion`: the open canvas is flushed first, then
  `NoteWriter.restore` reads the note strictly inside one coordinated read
  (iCloud `requireLocal` before and after), computes `restoreOps` from that
  read and writes one delta with the app's `DeviceClock`; the open canvas is
  reopened from the result. Incomplete points are greyed out, and a notice
  says compacted revisions are not restore points (shown when the note has a
  snapshot or an incomplete point). Not tried on the iPad yet.
- Re-added strokes render above the strokes that stayed (new `origin`); exact
  historical z-order is not restored.

## Version history round 2 (PR #74; maintainer decisions 2026-10-06)

- Format `docs/format.md` §5.8, all optional fields older readers ignore:
  `checkpoint` (`{name?}`) and `session` on deltas, `asOf` on snapshots.
  Malformed values are ignored, never fatal.
- Checkpoint = a delta with no ops after the pending ink is saved
  (`Vault.checkpoint`, `AppModel.saveVersion` through `NoteWriter.append`).
- Sessions (`NoteHistory.groups`): new session on a different `session` id
  (each `NoteEditor` mints one, `editingSession`; browser edits write none), a
  wall gap ≥ 10 min, or another device; checkpoints stand alone. Snapshots
  group like deltas without a session.
- Thinning and compaction share `CompactionPlanner.plan` (`Thinning.swift`):
  candidates by policy, witnesses (first revision of each other device after
  a target), then a loop that writes a snapshot positioned at each target that
  would become incomplete and a cover snapshot if a deletion is not covered or
  dominated. It checks the current state before returning. A stand-in
  snapshot tells `Completeness` what is about to be gone (it only learns gone
  revisions from snapshots). Device-less `Vault.compact` keeps everything a
  complete checkpoint depends on instead (it cannot write snapshots).
- Guarantees G1–G5 in §5.8.4 are property-tested on random multi-device
  logs (`VersionHistoryTests.testThinningGuaranteesOnRandomLogs`, 120 seeds per run;
  3000 seeds were run once: 2 636 non-trivial plans, 0 failures), and over two
  rounds (thin, add revisions, thin again later: `testThinningTwiceOnRandomLogs`,
  81 seeds per run; 1500 run once, 0 failures).
- A snapshot built for a target covers the older positioned snapshots it was
  built from; §5.8.3 validity allows covering valid positioned snapshots at or
  before its `asOf` (decided in `(asOf, name)` order). Stripping them instead
  broke rule 1 or prefix safety (found by the independent review, 2026-10-07).
  A candidate that the target's snapshot cannot cover (a delta orphaned there)
  is kept rather than failing the plan.
- Cost: one full snapshot per kept version that needs one; the dry run
  reports bytes deleted and added.
- App: thinning setting `Sempere.thinAfterDays` (per device; 0 = never),
  automatic run once a day per vault after the listing (`thinIfDue`, open
  notes and non-local iCloud notes skipped, off in tests and DEBUG scripted
  runs), Settings sheet from the sidebar's gear button (now the E6 panel, below).
- Performance round 3 (PR #88, TestFlight build 6 feedback; maintainer decisions 2026-10-07):
  - Imports are checkpoints (`format.md` §5.8.1): "Imported from Notability on <UTC time>
    (modified in Notability <date>)". An `--overwrite` is dated when it ran; a first import keeps
    the creation date as `wall` because it sets `created`. Imports written before this carry no
    checkpoint: thinning then deletes an older import as an autosave. The build 6 report
    ("deleted autosaves from all notes") was that case and was correct: the state and the kept
    re-import were unchanged (`testLegacyReimportThinsOnlyTheFirstImportAndChangesNothing`).
  - Two explicit rules (`ThinningRule`, shared wording): "Thin versions older than N days"
    (the setting; `compact --thin-older-than`) and "Thin everything except checkpoints"
    (`compact --thin-all`, cutoff 0). Previews state the rule and what it keeps.
  - Thinning decides from revision metadata (`RevisionMeta`, kept in the summary cache next to
    each summary; `CompactionPlanner.select` / `mayDelete`) and reads in full only the notes
    with a candidate; snapshots are encoded once (`PreparedCompaction`); notes run in
    parallel (`prepareCompactions`, app `thinningConcurrency`) with per-note progress.

## Gotchas collected so far

PencilKit (from 3c): `PKStrokePoint` keeps locations, sizes and times as
Float32 and quantizes opacity/azimuth/altitude (~1e-4; altitude even drifts on
every re-wrap), so conversion round trips are equal within 2e-4, not bit for
bit. `PKStroke.id`, `substroke(range:)` and `PKDrawing.erasePath` are
iOS 27 APIs; the app's minimum is 27, so the app may use them directly, but
`Sources/` cannot (no PencilKit there).


See `CLAUDE.md § Gotchas` (case-insensitive paths, FoundationXML, static
link flags, test-output grepping, the app project). Also: the app and screenshot jobs
run on GitHub's `xcode-27` image (the app needs the iOS 27 SDK), while the package job and
the CLI release build stay on `macos-26`, which has an older compiler than local Xcode 27,
so dense expressions in `Sources/` that compile locally can time out there; swift-crypto types are not `Sendable` on Linux (store raw
bytes); SempereImport reads binary plists with its own `BinaryPlist` reader, since
`PropertyListSerialization` crashes on some hostile binary plists on Linux.
