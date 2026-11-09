# Where development lives: GitHub first, Gitea as the mirror

Decided by the owner on 2026-11-09. GitHub (`anthonytw/sempere`) is the primary remote again: pull requests, CI and
merges happen there. Gitea (`git.lab:awertz/sempere`) is a mirror of it, and the fallback if GitHub access is lost
again. Releases are still built on the owner's Mac.

## Where things live

| What | Where |
| --- | --- |
| Source of truth: branches, pull requests, reviews, merges, tags | GitHub, `anthonytw/sempere` (the `origin` remote) |
| PR gate | GitHub Actions, `.github/workflows/ci.yml` ([ci.md](../ci.md)). Linux jobs in the pinned `swift` image on Ubuntu runners; the iOS build and Mac package tests on the `xcode-27` runner image (Xcode 27.1, iOS 27 SDK). The Mac Catalyst app tests stay on the Mac gate: they are unreliable on the hosted VM. |
| Mirror and fallback | Gitea, the `gitea` remote. `scripts/mirror-gitea.sh` copies main, branches and tags from GitHub, fast-forward only, from a Mac on the LAN (GitHub cannot reach Gitea). |
| Release-bound suites, App Store builds | The owner's Mac: `scripts/local-ci.sh --testflight`, `--release`, `--cli`, `just testflight`. Results are commit statuses on Gitea (`scripts/forge.sh`), which is why the mirror must have copied a commit before one of these runs on it. |
| CLI binaries, Homebrew formula | GitHub Releases and `anthonytw/homebrew-tap`, built locally ([releasing.md](../releasing.md)) |
| Public feature issues | GitHub issues. Bugs and maintenance stay in the private `data/TODO.md`. |

Remotes in a checkout: `origin` is GitHub, `gitea` is the mirror (`git remote rename origin gitea` and add
`git@github.com:anthonytw/sempere.git` as `origin` in a checkout that began on Gitea). Open a pull request with
`gh pr create`; GitHub's ruleset on `main` takes squash merges only, with the checks listed in [ci.md](../ci.md)
required.

## The local gate is optional, except for the app's tests

`scripts/local-ci.sh` (about ten minutes on a Mac, one at a time under `xc-lock`) is no longer what a pull request needs
to merge. Use it to reproduce a failure that GitHub's run showed, to check a change before pushing it, for a change that
touches the app (the Mac Catalyst unit tests run only there: they fail on the hosted VM for lack of a key window), and for the
release-bound modes: the UI suites (`--testflight`, `--release`) need a screen and a simulator, which no hosted runner
runs reliably. It shares its steps with the workflow (`scripts/ci-mac-package.sh`, `scripts/ci-linux.sh`,
`scripts/app.sh`), so a failure on one reproduces on the other.

## The mirror

`scripts/mirror-gitea.sh` pulls GitHub into a bare clone of its own and pushes to Gitea what is behind:

- **main, every other branch and every tag**, fast-forward only. Nothing is forced and nothing is deleted.
- A ref that **diverged**, or a **tag that names a different commit** on the two sides, is refused and reported (exit 1).
  A person decides; the usual cause is a push made to Gitea first.
- Gitea **ahead** of GitHub (for example until GitHub's `main` has been fast-forwarded to it) is left alone and noted.

It runs every ten minutes from a launchd agent (`packaging/launchd/net.gulwertz.sempere-mirror.plist`, copied and loaded
by hand) and by hand after a merge (`scripts/mirror-gitea.sh`). The user it runs as needs read access to GitHub and push
access to Gitea (Gitea's `main` has no branch protection).

### If GitHub access is lost again

Gitea has everything up to the last mirror run. Make the `gitea` remote `origin`, push branches there and merge there
and run the gate with `scripts/local-ci.sh --status` (it posts `local/app-tests`). When GitHub is back: fast-forward GitHub from Gitea by hand if Gitea is ahead
(`git push git@github.com:anthonytw/sempere.git gitea/main:main`, after checking `git merge-base --is-ancestor`), then
let the mirror run again.

## History

- **Until 2026-11-06**: GitHub was the home, with its Actions CI (slow and flaky: the iPad UI step timed out on every
  push, so `main` was red).
- **2026-11-06 to 2026-11-09 (local-first)**: the owner's GitHub account lost the bot's access, so work moved to Gitea
  and the LAN. CI ran on the Mac; the Orin runner proved too slow (about 42 minutes for the Linux package job, six in
  Docker on the Mac) and ran nothing. GitHub received one squashed commit per release, pushed by the owner.
- **2026-11-09 (this document)**: access came back. GitHub is primary again, with a lean Actions gate built on the
  hash-skipping of [ci-lean.md](ci-lean.md). GitHub's `main` (release 1.0.1, `d175447`) is an ancestor of Gitea's, so the owner
  fast-forwards it once instead of replaying history.

The release tooling written for the squash-per-release flow (`release-github.sh`, `release-tag.sh`, `release-verify`)
still describes it; the tag/squash steps there are to be reworked once the owner decides how releases are tagged on a
history GitHub now holds in full. Building the binaries, the sweeps and the smoke tests are unchanged.
