# Local-first development

Decided by the owner on 2026-11-06. Development, CI and releases run on the LAN. GitHub only receives the
public source and the CLI binaries, once per release.

## Where things live

| What | Where |
| --- | --- |
| Source of truth: branches, pull requests, reviews, tags | Gitea, `git.lab:awertz/sempere` (the `origin` remote) |
| CI | Gitea Actions. Linux jobs run on a runner on the Orin. Mac work runs on the Mac through the agents' `xc-lock`, as now. There is no Mac CI runner. |
| Public source | GitHub, `anthonytw/sempere`: **one squashed commit per release** |
| CLI binaries, Homebrew formula | GitHub Releases and `anthonytw/homebrew-tap`, built locally and uploaded by the owner |
| Public feature issues | GitHub issues (#8 onward). Bugs and maintenance stay in the private `data/TODO.md`. |

Tags are created on Gitea. A release tag names the Gitea commit that was released.

## Releasing to GitHub

GitHub's history is one commit per release, with nothing in between. To publish release `X.Y.Z`:

1. Tag `vX.Y.Z` on Gitea (`just release-tag`). After an App Store build this happens only once the
   release sweep has passed. A CLI-only release needs only a green CI run.
2. Build the release binaries locally. Linux uses the Static Linux SDK (musl) in Docker for `x86_64`
   and `aarch64`. macOS builds a universal binary on the Mac. Then smoke-test them on the distro list
   (`scripts/smoke-linux-cli.sh`).
3. Make the GitHub commit. Its tree is the Gitea tag's tree and its parent is GitHub's current `main`,
   so it is a single squash of everything since the last release. Its message is the release's
   CHANGELOG section. Tag it `vX.Y.Z` too.
4. **The owner pushes the commit and the tag**, creates the GitHub Release with the binaries and
   checksums, and updates the Homebrew formula.

The tooling for steps 2 and 3 prepares everything and prints the owner's commands. It never pushes to
GitHub itself.

Consequences:

- GitHub runs no workflows. `.github/workflows/` is removed, so a release push costs nothing there.
- A pull request opened on GitHub is applied on Gitea by hand. It appears on GitHub with the next
  release's squash, and is then closed with a comment.
- Commit SHAs differ between Gitea and GitHub. The tag name and the tree are what match.
  `release-verify` compares trees.

## CI on Gitea

- The PR gate is the lean set from the test sweep: Linux package tests, the web viewer, a compile check
  of the app, and the release checks. The suites that need a simulator or the screen run only in the
  release sweep, on the Mac.
- The Orin runner takes one job at a time, under a CPU quota, so CI never slows the inference services
  on the same host.
- Benchmarks, long fuzz runs and stress runs go in their own targets and run on a schedule (Gitea Actions
  `schedule`) and in the release sweep, never in the gate.
- Scripts that called `gh api` (commit statuses, check runs, release-tag, release-verify, local-ci)
  use the Gitea API instead.
