# Releasing Sempere

The runbook for every build, deploy and publish step, written for the maintainer on their own Mac:
a TestFlight build ([A](#a-testflight-build)), a release such as v1.0.0 ([B](#b-a-release-v100-or-any-vxyz)),
and a hotfix ([C](#c-a-hotfix)). Everything runs through `just` in this repo (or `just sempere::…` from the
`dev/` workspace root); each recipe is a thin wrapper around a script you can also run directly.

Steps marked **[you]** need the maintainer personally: Apple's web UI, signing into Xcode, submitting for App
Store review, the release date in `CHANGELOG.md`, and approving anything that publishes (tag push, deploys,
uploads). No recipe does any of those silently: tagging, pushing a tag, uploading a build and deploying a
site are each their own recipe; an upload asks `[y/N]` and a tag push asks you to type the version.

| Recipe | What it does | Publishes? |
| --- | --- | --- |
| `just ci` | the PR gate on the current pushed, clean commit; posts `local/app-tests` | a commit status |
| `just ci-testflight` | gate + Mac UI, smoke, offline, perf suites; posts `local/testflight-suite` (takes the screen) | a commit status |
| `just ci-release` | everything, iPad and iPhone simulators too; posts `local/release-sweep` (takes the screen) | a commit status |
| `just changelog` | fold `changelog.d/` fragments into `[Unreleased]` | no (edits the tree) |
| `just testflight-dry [ios\|mac\|both] [REF]` | check config, ref and suite status; stop before `xcodebuild archive` | no |
| `just testflight [ios\|mac\|both] [REF] --export-only` | archive and sign into a local folder | no |
| `just testflight [ios\|mac\|both] [REF]` | archive REF from a temporary worktree and upload, after a `[y/N]` (`--yes` skips it) | **uploads to TestFlight** |
| `just release-prep X.Y.Z` | fold fragments, make the version's section (date left `TODO(user)`), bump versions | no (edits the tree) |
| `just release-check` | App Store checks (versions, no team ID, privacy manifests, entitlements, networking) | no |
| `just release-ready X.Y.Z [REF]` | `release.yml`'s checks on REF (default `origin/main`), locally | no |
| `just release-tag X.Y.Z [REF]` | the checks, a signed tag, then asks before pushing it | **pushes the tag** (after you type the version) |
| `just release-push X.Y.Z` | push a tag made earlier (asks first) | **pushes the tag** |
| `just release-verify X.Y.Z` | the release's workflow run, assets, checksums, provenance, binary version | no |
| `just formula X.Y.Z [TAP]` | the Homebrew formula, to stdout or into a tap clone, then `brew audit` | no (you push the tap) |
| `just screenshots [ipad\|iphone\|mac]` | App Store screenshots into `build/screenshots/` | no |
| `just site-sync` | copy the privacy policy and CHANGELOG into the `sempere-site` checkout | no (edits that tree) |
| sempere-site: `just deploy` | build the website and push it to GitHub Pages | **deploys the website** |
| astro-site: `just deploy` | build the blog and push it to GitHub Pages | **deploys the blog** |

## 0. One-time setup on your Mac

### Prerequisites in the website repos **[you]**

Merge these two PRs once; B.4 and B.7 depend on them:

- **sempere-site PR #6** (`chore/justfile`): the site's justfile (`just install`, `sync-docs`, `viewer`, `build`,
  `preview`, `deploy`) and the pnpm 12 build-script allowlist. Until it is merged, the `first-version` branch has
  no justfile; the commands behind each recipe are in the site's README (`pnpm install`,
  `node scripts/sync-sempere-docs.mjs`, `pnpm build`, `./deploy.sh`).
- **astro-site PR #15** (`fix/pnpm-build`): `katex` as a direct dependency. Without it `pnpm build`, which the
  blog's `deploy.sh` runs, stops with `Rollup failed to resolve import "katex/dist/katex.min.css"`.

### Tools

1. **Xcode 27 or newer** from the App Store, opened once. Then:
   ```bash
   xcodebuild -runFirstLaunch
   xcodebuild -downloadPlatform iOS          # the iOS simulator runtime, about 8 GB (ci-release needs it)
   ```
2. **Command-line tools:** `brew install just gh pnpm node` (Python 3 comes with Xcode's tools).
3. **GitHub CLI:** `gh auth login` (HTTPS or SSH, scopes `repo` and `workflow`). The suites post commit statuses
   with it, and the TestFlight and tag checks read them.
4. **Signed tags:** `git tag -s` uses your git signing key. With an SSH key:
   ```bash
   git config --global gpg.format ssh
   git config --global user.signingkey ~/.ssh/id_ed25519.pub
   ```
   Add the same public key on GitHub as a **signing** key (Settings ▸ SSH and GPG keys) so the tag shows
   Verified. To let `git tag -v` check it locally too, list it in `gpg.ssh.allowedSignersFile`.
5. **Checkouts** (the website recipes assume this layout; `SEMPERE_SITE` overrides it):
   ```bash
   mkdir -p ~/dev/website && cd ~/dev
   git clone git@github.com:anthonytw/sempere.git
   git clone git@git-ssh.lab.gulwertz.net:awertz/sempere-site.git website/sempere-site   # private, branch first-version
   git clone git@git-ssh.lab.gulwertz.net:awertz/astro-site.git website/astro-site       # the blog
   ```
   The sites' `deploy.sh` scripts clone their public GitHub Pages repos next to them on first use.

### Apple account and signing **[you]**

The app record, the bundle ids (`io.github.anthonytw.sempere` and `io.github.anthonytw.sempere.widgets`, with the
App Group) and earlier TestFlight builds already exist in App Store Connect. `scripts/testflight.sh` signs in one
of two modes:

- **`api`: the mode every TestFlight build so far was uploaded with.** An App Store Connect API key uploads;
  signing is manual, with certificates and profiles on this Mac:
  1. App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API ▸ **+**: a key with the App
     Manager (or Admin) role. Download the `.p8` (Apple offers it once) to `~/.config/sempere/`, `chmod 600`,
     and note the key ID and the issuer ID shown on that page.
  2. developer.apple.com ▸ Certificates: an **Apple Distribution** certificate and a **Mac Installer
     Distribution** certificate (it installs as "3rd Party Mac Developer Installer"), each made from a CSR in
     Keychain Access and installed by double-clicking.
  3. developer.apple.com ▸ Profiles: three **App Store** profiles, named exactly (or set the names in
     `release.env`): "Sempere iOS App Store" (iOS, `io.github.anthonytw.sempere`), "Sempere Widgets iOS App
     Store" (iOS, `….widgets`) and "Sempere Mac App Store" (Mac Catalyst, `io.github.anthonytw.sempere`).
     Download and double-click each.

  An App Manager key cannot cloud-sign, which is why this mode signs with the local certificates.
- **`xcode`: no API key, not yet proven by an upload.** Xcode ▸ Settings ▸ Accounts ▸ **+** ▸ Apple ID, sign in
  with the account that holds the membership (Account Holder or Admin role), and check that the team appears.
  Xcode then creates the distribution certificate and the App Store profiles itself (automatic signing,
  `-allowProvisioningUpdates`). Whether it also makes the Mac **installer** certificate on export is not
  established: run the rehearsal below before relying on this mode, and if the Mac export fails on the installer
  certificate, create it by hand as in `api` step 2 (the rest stays automatic).

### `~/.config/sempere/release.env`

Nothing account-specific lives in this repository (`scripts/release-check.sh` fails on a committed
`DEVELOPMENT_TEAM`). The TestFlight script reads your team and key settings from this file; a variable set in
the environment wins over the file (`SEMPERE_SIGNING=api just testflight …` overrides it for one run).

```bash
mkdir -p ~/.config/sempere
cp scripts/release.env.example ~/.config/sempere/release.env
chmod 600 ~/.config/sempere/release.env
$EDITOR ~/.config/sempere/release.env
```

| Variable | Needed for | Value |
| --- | --- | --- |
| `SEMPERE_TEAM_ID` | always | the team ID (developer.apple.com ▸ Account ▸ Membership details) |
| `SEMPERE_SIGNING` | always | `api` or `xcode` (default: `api` when `SEMPERE_ASC_KEY_ID` is set) |
| `SEMPERE_ASC_KEY_PATH`, `SEMPERE_ASC_KEY_ID`, `SEMPERE_ASC_ISSUER_ID` | `api` | the `.p8` path, the key ID, the issuer ID |
| `SEMPERE_PROFILE_IOS`, `SEMPERE_PROFILE_WIDGETS_IOS`, `SEMPERE_PROFILE_MAC`, `SEMPERE_DIST_CERT`, `SEMPERE_INSTALLER_CERT` | `api`, only if your names differ | profile and certificate names |
| `SEMPERE_KEYCHAIN`, `SEMPERE_KEYCHAIN_PASSWORD_FILE` | optional | a separate keychain holding the signing identities, unlocked first (without the password file, `security` asks) |
| `SEMPERE_TF_OUT` | optional | where archives, logs and exports go (default `$TMPDIR/sempere-testflight`; one run at a time per folder) |

`SEMPERE_RELEASE_ENV=/other/file` reads another file. The script never prints these values: its dry run shows
`<SEMPERE_TEAM_ID>` and the like in their place.

### Check the setup

1. The configuration, without building:
   ```bash
   cd ~/dev/sempere
   just testflight-dry
   ```
   Expected (paths shortened):
   ```
   config: ~/.config/sempere/release.env
   signing: api (App Store Connect API key, manual profiles)
   output:  $TMPDIR/sempere-testflight
   commit:  48c0b9f summaries: recognition and compaction snapshots no longer move a note's modified date (#96)
   local/testflight-suite: success
   worktree: $TMPDIR/sempere-testflight/src-48c0b9fdcc0f-12345
   version: 1.0.0 (MARKETING_VERSION; the build number is assigned on upload)

   == ios (dry run) ==
   export options ($TMPDIR/sempere-testflight/ExportOptions-ios.plist):
     ... <key>teamID</key><string><SEMPERE_TEAM_ID></string> ...
   would run:
     xcodebuild archive -project …/Apps/Sempere/Sempere.xcodeproj -scheme SempereApp -configuration Release -destination generic/platform=iOS … DEVELOPMENT_TEAM=<SEMPERE_TEAM_ID> -allowProvisioningUpdates …
     xcodebuild -exportArchive …
   == mac (dry run) ==
     …
   dry run: stopped before xcodebuild archive; nothing was built or uploaded
   ```
   If `main`'s newest commit has not passed the TestFlight suite yet, it stops with
   `error: local/testflight-suite is 'missing' on …`: that is the gate working (A.2).
2. **The signing rehearsal** (once, and again after changing signing mode or certificates): archive and sign both
   apps without uploading anything.
   ```bash
   just testflight both main --export-only
   ```
   Expected: `ios: exported to …/export-ios (not uploaded)` and `mac: exported to …/export-mac (not uploaded)`.
   A Mac failure naming the installer certificate ("3rd Party Mac Developer Installer" or "Mac Installer
   Distribution") means it is missing: create it as in `api` step 2 and run the rehearsal again.

## A. TestFlight build

A TestFlight build is any commit on `main` (or a pushed branch) that passed the pre-TestFlight suite. Batch them:
one build when a visible chunk of work is ready, not one per merge.

1. **Optional: fold the changelog.** Testers read `CHANGELOG.md`'s `[Unreleased]`; to show them this batch,
   fold the fragments in a small PR first: `git switch -c chore/changelog origin/main && just changelog`,
   commit, push, open the PR (`## Tests run`: "None beyond the gate: changelog only"), merge.
2. **The pre-TestFlight suite on the exact commit.** It needs a clean checkout of a pushed commit, and its UI
   tests take over the screen: leave the Mac alone while it runs.
   ```bash
   cd ~/dev/sempere
   git switch main && git pull --ff-only
   just ci-testflight
   ```
   Expected end: `local-ci: all passed in N min; local/testflight-suite posted for 1a2b3c4d`. A failing step
   prints `FAILED (…s): build/local-ci/<step>.log`; fix it in a PR and start again on the new commit.
   `just ci-testflight --list` shows the steps without running them.
3. **Upload.** The script makes a temporary worktree of the commit (your checkout is never switched), shows what
   it is about to upload and asks, then archives the iOS app and the Mac Catalyst app, signs and uploads them:
   ```bash
   just testflight                 # both apps from origin/main
   just testflight ios             # only the iPad/iPhone app
   just testflight both 1a2b3c4d   # a given commit (or branch, or tag)
   ```
   Expected:
   ```
   local/testflight-suite: success
   version: 1.0.0 (MARKETING_VERSION; the build number is assigned on upload)

   About to archive and UPLOAD to TestFlight: ios mac, version 1.0.0, commit 1a2b3c4d5e6f.
   Upload to TestFlight? [y/N] y
   ios: archiving (log: $TMPDIR/sempere-testflight/ios-archive.log)
   ios: exporting and uploading (log: …/ios-export.log)
   ios: uploaded
   mac: archiving …
   mac: uploaded
   Done. The build shows in App Store Connect > Sempere > TestFlight after processing (usually 5-30 minutes).
   ```
   Build numbers are assigned on upload (`manageAppVersionAndBuildNumber`); the version is the project's
   `MARKETING_VERSION`. `--yes` skips the question (needed when there is no terminal).
4. **[you] App Store Connect ▸ Sempere ▸ TestFlight.** When the build has processed: add it to the tester
   group(s), fill in "What to Test" (from `[Unreleased]`), and for external groups submit it for Beta App Review.
   Beta App Review opens the Privacy Policy URL under TestFlight ▸ Test Information: it must be live (B.4).
   Export compliance is answered by the app (`ITSAppUsesNonExemptEncryption` is NO; see "Availability" in B.5),
   so no questionnaire appears.

**If something fails:** the last lines of the archive or export log are printed; the full logs stay in
`$TMPDIR/sempere-testflight/`. "No profiles for …" or "No signing certificate" in `xcode` mode means Xcode is not
signed in to the team (Settings ▸ Accounts) or a certificate is missing (the rehearsal above); in `api` mode, a
profile or certificate name differs from `release.env`. "Copy failed" at export is Homebrew's rsync shadowing the
system one (the script puts `/usr/bin` first). "another testflight.sh run is using …" means a run is in progress
(or one was killed: remove the `.run-lock` folder it names). The worktree is removed at exit (`--keep` keeps it).

**Emergency only:** `just testflight both main --skip-suite-check` uploads a commit that did not pass the suite.
It prints a large warning and waits ten seconds. Prefer running the suite.

## B. A release (v1.0.0, or any vX.Y.Z)

A release is one commit on `main` that is the App Store build, the CLI's GitHub Release (`release.yml`, from the
tag `vX.Y.Z`), the Homebrew formula, the website's changelog and, for v1, the blog post. The order matters: the
website must be live before App Review looks at it (B.4), and nothing public about the version (tag, GitHub
Release, formula, blog) goes out until Apple has approved the app (B.6), so all of it lands on one day.

| Step | What | Who |
| --- | --- | --- |
| B.1 | release PR: `just release-prep`, curate the section, the planned release date | you date it |
| B.2 | `just ci-release` on the merge commit; note its SHA | Mac, unattended |
| B.3 | App Store build of that SHA | you approve the upload |
| B.4 | website live with `/privacy` and `/support` | you approve the deploy |
| B.5 | App Store submission, manual release | **[you]** |
| B.6 | launch day, after approval: tag, GitHub Release, Homebrew, Release This Version, site, blog | you |

### B.1 The release PR

```bash
cd ~/dev/sempere
git switch -c release/1.0.0 origin/main
just release-prep 1.0.0
```

Expected (for 1.0.0, whose section already exists):

```
folded 63 fragment(s) into …/CHANGELOG.md
warning: [1.0.0] already existed, undated: the [Unreleased] entries were appended to it (Added, Changed, Fixed, Removed). Curate that section in the release PR: …
updated CHANGELOG.md
prepared 1.0.0 (CLI version; app MARKETING_VERSION = 1.0.0).
Next, by hand: replace the TODO(user) in the [1.0.0] heading of CHANGELOG.md with the release
date (YYYY-MM-DD), review the section, then commit and open the release PR (docs/releasing.md).
```

What it did: folded every `changelog.d/` fragment into `[Unreleased]`, then moved `[Unreleased]` into the
version's section, pointed the compare links at the new tag, set `sempereVersion` and the `--version` test, and
set every app target's `MARKETING_VERSION` (`updated …` lines appear only for files that changed). The app and
the CLI share one version: `release-prep` refuses a version below the app's current one, and `--no-app` (a
CLI-only release) leaves the app alone. A prerelease such as `1.1.0-rc.1` sets the app to `1.1.0`.
`just release-prep 1.0.0 --dry-run` prints the diff and writes nothing.

1. **Curate the section (the PR's author).** The section becomes the GitHub Release notes and the website's
   changelog. For **1.0.0**, the fragments land after the feature tour as `### Added`, `### Fixed`, `### Changed`
   and `### Removed`, and much of that is pre-release history (fixes of bugs no released version had). Merge the
   user-visible entries into the tour's headings and drop the pre-release fixes and removals. From 1.0.1 on,
   the generated section is normally fine as it is.
2. **[you] The release date.** Replace the `TODO(user)` in the version's heading with the day you plan to launch
   (B.6), as `## [1.0.0] - 2026-11-03`; allow a few days for App Review. `release.yml` refuses a section that
   still has a `TODO(user)` anywhere. If launch day later moves, see "If the date slips" in B.6.
3. `just release-check` (expected: `release-check: ok (version 1.0.0, build 1)`) and
   `just test --filter CLICommandTests` (the `--version` assertion).
4. Commit, push, open the PR:
   ```bash
   git add -A && git commit -s -m "release: 1.0.0"
   git push -u origin release/1.0.0
   gh pr create --fill
   ```
   In the PR's `## Tests run`: `just release-check`: passed; `swift test --filter CLICommandTests`: passed.
5. `just ci` on the branch (the PR gate, `local/app-tests`), CI green, then squash-merge.

### B.2 The release sweep, and the release SHA

```bash
git switch main && git pull --ff-only
sha=$(git rev-parse HEAD); echo "release commit: $sha"    # keep this SHA: B.3 and B.6 use it
just ci-release
```

Every suite, iPad and iPhone simulators included; it takes over the screen for a long time. Expected end:
`local-ci: all passed in N min; local/release-sweep posted for 1a2b3c4d`. `release.yml` refuses to publish a
`vX.Y.Z` tag on a commit without this status. The sweep also satisfies the TestFlight gate, so there is no need
to run `ci-testflight` as well. From here on, pass `$sha` (in a new shell, paste it) instead of `main`, so the
App Store build and the tag are provably the same commit even if something merges meanwhile.

### B.3 The App Store build

```bash
just testflight both "$sha"
```

Wait for processing, then install it from TestFlight on an iPad, an iPhone and the Mac and check it starts and
opens a vault **[you]**. This build is what you submit in B.5.

### B.4 Website live before the submission

App Review (and Beta App Review) opens the Privacy Policy and Support URLs, so the site must serve them before
B.5. The site shows the CHANGELOG and the privacy policy from this repo, and its own copy of the web viewer.

```bash
cd ~/dev/website/sempere-site
git switch first-version && git pull --ff-only
git switch -c release/1.0.0
just install
just sync-docs        # or, from the sempere repo: just site-sync
```

Expected: `privacy: last updated YYYY-MM-DD` and a line for the changelog. Then:

- `git diff`: the new changelog section and, if it changed, the policy (its date must match
  `docs/privacy/index.html`).
- If `web/` changed since `public/viewer/VERSION.txt`: `just viewer` (and regenerate the demo vault if the format
  changed; see the site's README).
- `just build` (expected: `check-no-third-party: ok …`), then `just preview` and look at `/privacy`, `/support`,
  `/changelog` and `/demo`.
- Commit, push, open a PR to `first-version` (`tea pr create` or the Gitea UI); **[you]** merge it.

**[you] Deploy** (replaces the live site with `dist/`, so only after the PR is approved and merged):

```bash
git switch first-version && git pull --ff-only
just deploy
```

Expected: `Building...`, the Astro build and `check-no-third-party: ok`, `Updating deploy repo...`,
`Syncing build output...`, `Committing...`, `Done.` (or `Nothing to deploy.`). Then check that the site is live
(GitHub Pages takes a minute or two):

```bash
for p in privacy support; do curl -s -o /dev/null -w "%{http_code} $p\n" "https://sempere.anthonywertz.com/$p"; done
```

Expected: `200 privacy` and `200 support`. A `404` means the deploy has not propagated yet or failed: do not
submit until both are 200. The changelog page now shows the version with its planned date before the release
exists; B.6 redeploys it if anything changes.

### B.5 App Store submission **[you]**

All in App Store Connect ▸ Apps ▸ Sempere. The iOS app and the Mac app are one record (same bundle id, universal
purchase); each platform has its own version page.

1. **Screenshots** (only when the interface changed): `just screenshots` (or `ipad`, `iphone`, `mac`) writes
   `build/screenshots/{ipad,iphone,mac}/*.png` at the sizes App Store Connect takes (iPad 13", iPhone 6.9",
   Mac 2880 × 1800). Check the iPad status bar's date and the Mac shots by eye (docs/appstore/screenshots.md).
2. **Privacy Policy URL** **[you]**: under App Information and under TestFlight ▸ Test Information it must read
   `https://sempere.anthonywertz.com/privacy` (the URL the app's About screen links). If either still holds the
   old `anthonytw.github.io/sempere/privacy/` URL (which now leads to a 404), change it now that B.4 is live.
3. **Version page** (iOS App, then macOS App): **+ Version** (or the existing one in "Prepare for Submission"):
   - **Version number: exactly the `MARKETING_VERSION`**, `1.0.0` (not `1.0`). The B.3 build appears in the
     Build picker only when the two strings match.
   - **Build:** pick the build uploaded in B.3 (check its number against TestFlight).
   - **What's New in This Version** (shown from the second version on; v1 has none): a short summary of the
     version's CHANGELOG section (`scripts/changelog-section.sh X.Y.Z` prints it once the heading is dated).
   - Promotional text, description, keywords; **Support URL** `https://sempere.anthonywertz.com/support`;
     marketing URL `https://sempere.anthonywertz.com`.
   - Screenshots from step 1.
   - **App Review Information:** contact details and a note: no account or sign-in; "New Vault" creates a vault
     on the device; WebDAV and iCloud Drive are optional.
   - **Version Release: "Manually release this version"**, so the app goes out on launch day with everything
     else (B.6).
4. **App Information:** category; age rating questionnaire; **License Agreement:** Apple's standard one unless a
   reviewed custom text exists (`docs/appstore/eula.md` is a draft).
5. **App Privacy:** "Data Not Collected": the app collects nothing (the policy, and the privacy manifests that
   `just release-check` validates).
6. **Pricing and Availability:** keep **France excluded** until the ANSSI encryption declaration is approved;
   the app declares `ITSAppUsesNonExemptEncryption = NO` on that basis.
7. **Add for Review**, then **Submit to App Review** (both platforms). Review usually takes a day or two; answer
   any question in Resolution Center. A rejection that needs a code change means a new commit: back to B.2 with
   it (sweep, new SHA, new build), and the tag in B.6 goes on that commit.

### B.6 Launch day (after Apple's approval)

Approval with manual release leaves the version "Pending Developer Release". On the CHANGELOG date:

1. **Tag and GitHub Release.**
   ```bash
   cd ~/dev/sempere
   just release-ready 1.0.0 "$sha"      # checks only
   just release-tag 1.0.0 "$sha"        # checks, signed tag, then asks
   ```
   Expected:
   ```
   commit: 1a2b3c4 release: 1.0.0 (#97)
   ok    on origin/main
   ok    Version.swift = 1.0.0
   ok    CHANGELOG.md: ## [1.0.0] - 2026-11-03
   ok    local/release-sweep: success
   ok    v1.0.0 is free
   created signed tag v1.0.0 on 1a2b3c4d (local only)

   Pushing v1.0.0 starts the release workflow, which publishes a GitHub Release and its binaries.
   Type the version (1.0.0) to push v1.0.0 to origin, anything else to stop: 1.0.0
   pushed v1.0.0. Watch it: gh run watch …
   ```
   **[you]** typing the version is the approval. Anything else leaves the tag local: push it later with
   `just release-push 1.0.0` (it re-checks only that the tag is on `main`; the workflow checks the rest), or drop
   it with `git tag -d v1.0.0`.

   The workflow (`.github/workflows/release.yml`):
   - **prepare** fails unless the tag points at a commit on `main`, that commit has a successful
     `local/release-sweep` status (a prerelease tag `vX.Y.Z-rc.N` only warns), the tag is
     `vMAJOR.MINOR.PATCH[-pre]` and equals `Version.swift`, and `CHANGELOG.md` has a non-empty
     `## [X.Y.Z] - YYYY-MM-DD` section with no `TODO(user)` (`scripts/changelog-section.sh`). `just release-ready`
     runs the same checks before anything is pushed.
   - **linux** (static, x86_64 and aarch64, in `swift:6.4-noble`) and **macos** (universal) build, check that
     the binary is static or universal and prints the tag's version, and package `sempere-X.Y.Z-<platform>.tar.gz`
     (binary, LICENSE, LICENSE-EXCEPTION, README, CHANGELOG, `docs/cli.md`, `fonts/`; `scripts/package-cli.sh`).
   - **publish** writes `SHA256SUMS`, attests build provenance for the tarballs and `SHA256SUMS`, and runs
     `gh release create` with the CHANGELOG section as notes (a `-suffix` tag is a prerelease).

   When it is green: `just release-verify 1.0.0`. Expected: the last runs of the workflow,
   `v1.0.0 prerelease=false published=…` and the five assets, `OK` for each tarball in `SHA256SUMS`,
   `attested: …` for each tarball, and `sempere 1.0.0` from the macOS binary.

   If **prepare** fails, nothing was published: fix the cause on `main` (a new commit needs a new sweep), delete
   the tag (`git push origin :refs/tags/v1.0.0 && git tag -d v1.0.0`) and tag again. To try the workflow without
   a release, prepare and tag a prerelease (`just release-prep 1.0.1-rc.1`, …). Not included: a man page
   (`sempere --help` and `docs/cli.md` ship instead) and Apple notarization of the macOS CLI binary.
2. **Homebrew tap.** One-time **[you]**: create the public repo `anthonytw/homebrew-tap` (the `homebrew-` prefix
   is required) with a `Formula/` folder (`packaging/homebrew/README.md`). Then:
   ```bash
   git clone git@github.com:anthonytw/homebrew-tap.git ~/dev/homebrew-tap    # once
   just formula 1.0.0 ~/dev/homebrew-tap
   cd ~/dev/homebrew-tap
   brew install --build-from-source ./Formula/sempere.rb && brew test sempere && sempere --version
   git add Formula/sempere.rb && git commit -m "sempere 1.0.0" && git push       # [you]
   ```
   `just formula 1.0.0` alone prints the formula. It fails if the release's `SHA256SUMS` lacks a platform.
3. **[you] Release the app:** App Store Connect ▸ each platform's version ▸ **Release This Version**. It reaches
   the store within a few hours.
4. **Website.** If the changelog changed since B.4 (a date fix, a curated section), repeat B.4's `just sync-docs`,
   PR and `just deploy`; otherwise nothing to do.
5. **Blog post (astro-site, v1 only).** The post is `src/content/blog/sempere/index.mdx` on the astro-site branch
   `blog/sempere` (PR #14 there). **[you]** set its `date:` to the launch day, keep `draft: false`, review, merge.
   Then **[you] deploy** (pushes the whole site to `anthonytw.github.io`):
   ```bash
   cd ~/dev/website/astro-site
   git switch main && git pull --ff-only
   pnpm install
   just deploy           # ./deploy.sh: pnpm build, then commit and push the build output
   ```
   Expected: `Building...`, `astro check` with 0 errors, the build, then `Committing...` and `Done.` It needs
   astro-site PR #15 (see Prerequisites).

**If the date slips** (approval comes after the CHANGELOG date, or you postpone): the tagged commit must carry
the real date, so the date goes in a one-line PR. That PR is a new commit: run `just ci-release` on it (B.2,
with a new `$sha`) before `release-ready` passes, and tag that commit. The App Store build (from the old commit)
then differs from the tagged commit only in `CHANGELOG.md`; that is fine, and there is no need for a new build.

## C. A hotfix

Every release comes from `main` (`release.yml` refuses a tag that is not on `main`), and every App Store version
has a tag with the same version, so a hotfix is a short release:

1. The fix: a PR to `main` with a `changelog.d/` fragment, the gate (`just ci`) and the targeted tests it calls
   for, as always. Merge.
2. The release PR: `git switch -c release/1.0.1 origin/main && just release-prep 1.0.1`; **[you]** the date;
   `just release-check`; PR; `just ci`; merge (B.1). A CLI-only fix uses `just release-prep 1.0.1 --no-app`,
   which leaves the app's version alone; skip steps 4 to 6 below for it.
3. `just ci-release` on the merge commit, keeping `$sha` (B.2).
4. `just testflight both "$sha"` (B.3).
5. **[you]** App Store Connect: a new version `1.0.1` on each platform (exactly the `MARKETING_VERSION`), pick
   the build, "What's New" from the CHANGELOG section, manual release, submit (B.5). For an urgent fix, ask for
   an expedited review on the submission form.
6. On approval: `just release-tag 1.0.1 "$sha"`, the workflow, `just release-verify 1.0.1`,
   `just formula 1.0.1 ~/dev/homebrew-tap`, **[you]** Release This Version, and `just site-sync` + PR +
   **[you]** `just deploy` in sempere-site for the changelog (B.6).

## Verify a download

`sha256sum -c SHA256SUMS` (or `shasum -a 256 -c SHA256SUMS` on a Mac) and
`gh attestation verify FILE --repo anthonytw/sempere`; `just release-verify X.Y.Z` does both.
