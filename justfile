# Sempere command index (`just` lists recipes). Works standalone and as a
# module of the dev/ workspace justfile. Releasing: docs/releasing.md.

set working-directory := '.'

# List the recipes
default:
    @just --list --unsorted

# Build everything including tests
build:
    swift build --build-tests

# Run the whole test suite (not the benchmarks: `just bench`)
test *ARGS:
    swift test --skip 'Benchmarks\.' {{ARGS}}

# Run the benchmarks (print-only timings; MODULES: sempere render webdav pdf age, default all; docs/ci.md "Benchmarks")
bench *MODULES:
    scripts/bench.sh {{MODULES}}

# Run tests the way Linux CI does (Docker on macOS)
test-linux *ARGS:
    scripts/test-linux.sh {{ARGS}}

# Fail on Apple-only imports under Sources/
portability:
    scripts/check-portability.sh

# Release build of the CLI
cli:
    swift build -c release --product sempere
    @echo ".build/release/sempere"

# Test the iPad app on the newest iPad simulator (needs Xcode)
app-test:
    scripts/app.sh test

# Build the app for Mac Catalyst, unsigned (needs Xcode)
app-catalyst:
    scripts/app.sh catalyst

# The PR gate's local twin, optional (GitHub Actions runs the gate): about 10 min, no screen; --status posts local/app-tests to Gitea
ci *ARGS:
    scripts/local-ci.sh {{ARGS}}

# Pre-TestFlight suite: the gate plus Mac UI, smoke, offline and perf; posts local/testflight-suite (takes the screen)
ci-testflight *ARGS:
    scripts/local-ci.sh --testflight {{ARGS}}

# Release sweep: everything, iPad and iPhone simulators too; posts local/release-sweep (takes the screen)
ci-release *ARGS:
    scripts/local-ci.sh --release {{ARGS}}

# A CLI-only release's checks: package tests here, Linux + WebDAV + static build in Docker; posts local/cli-suite
ci-cli *ARGS:
    scripts/local-ci.sh --cli {{ARGS}}

# A Linux CI job in Docker, the way the workflow runs it (.github/workflows/ci.yml): test, webdav, static (scripts/ci-linux.sh)
ci-linux *JOBS="test":
    scripts/ci-linux.sh docker {{JOBS}}

# Fold changelog.d/ fragments into CHANGELOG.md [Unreleased] (before a TestFlight build; edits the tree)
changelog *ARGS:
    python3 -I scripts/changelog-collect.py {{ARGS}}

# Archive REF and UPLOAD to TestFlight, after a [y/N] (ios|mac|both; flags after REF: --export-only, --yes, --dry-run, --skip-suite-check)
testflight which="both" ref="main" *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{which}}" in -*) echo "usage: just testflight [ios|mac|both] [REF] [flags], e.g. just testflight both main --export-only" >&2; exit 2 ;; esac
    exec scripts/testflight.sh {{FLAGS}} {{which}} {{ref}}

# Check the TestFlight setup without building or uploading (stops before xcodebuild archive)
testflight-dry which="both" ref="main":
    scripts/testflight.sh --dry-run {{which}} {{ref}}

# Release PR edits: fold fragments, version section (date left TODO(user)), bump Version.swift, its test, the app version
release-prep VERSION *FLAGS:
    python3 -I scripts/release-prep.py {{VERSION}} {{FLAGS}}

# App Store checks: versions, no signing team, privacy manifests, entitlements, no stray networking
release-check *ARGS:
    scripts/release-check.sh {{ARGS}}

# Is REF (default origin/main) ready to tag? The release checks; tags nothing
release-ready VERSION ref="origin/main":
    scripts/release-tag.sh --check {{VERSION}} {{ref}}

# Signed tag vVERSION on REF (default origin/main, GitHub) after the checks; asks before pushing it to GitHub
release-tag VERSION ref="origin/main":
    scripts/release-tag.sh {{VERSION}} {{ref}}

# Push an existing local tag vVERSION to GitHub (asks first)
release-push VERSION:
    scripts/release-tag.sh --push {{VERSION}}

# Build the release binaries here from the tag (Linux in Docker, macOS universal); into build/release/vVERSION
release-build VERSION:
    scripts/release-build.sh {{VERSION}}

# The GitHub Release for vVERSION from the local build: checks the pushed tag, prints the `gh release create` command (--publish runs it)
release-publish *ARGS:
    scripts/release-publish.sh {{ARGS}}

# Check a published release: GitHub's tag is the built commit, the Gitea mirror has it, the assets match SHA256SUMS (and the local build)
release-verify VERSION:
    scripts/release-verify.sh {{VERSION}}

# Homebrew formula for a release (the local build's checksums, else the published ones): to stdout, or into TAP/Formula/sempere.rb and audited (no push)
formula VERSION TAP="":
    #!/usr/bin/env bash
    set -euo pipefail
    tap="{{TAP}}"; tap="${tap/#\~/$HOME}"
    if [ -z "$tap" ]; then exec scripts/update-formula.sh "{{VERSION}}"; fi
    [ -d "$tap/.git" ] || { echo "$tap is not a clone of the tap (git clone https://github.com/anthonytw/homebrew-tap)"; exit 1; }
    mkdir -p "$tap/Formula"
    scripts/update-formula.sh "{{VERSION}}" > "$tap/Formula/sempere.rb"
    echo "wrote $tap/Formula/sempere.rb"
    brew audit --strict --formula "$tap/Formula/sempere.rb" || echo "brew audit reported problems (see packaging/homebrew/README.md)"
    echo "Next, in $tap: brew install --build-from-source ./Formula/sempere.rb && brew test sempere, then commit and push"

# App Store screenshots into build/screenshots (ipad|iphone|mac, or all three)
screenshots *WHICH:
    scripts/screenshots.sh {{WHICH}}

# Copy the privacy policy and CHANGELOG into the website checkout (SEMPERE_SITE, default ../website/sempere-site); deploys nothing
site-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    site="${SEMPERE_SITE:-{{source_directory()}}/../website/sempere-site}"
    [ -f "$site/scripts/sync-sempere-docs.mjs" ] || { echo "no sempere-site checkout at $site (set SEMPERE_SITE)"; exit 1; }
    cd "$site" && SEMPERE_REPO="{{source_directory()}}" node scripts/sync-sempere-docs.mjs
    echo "Now in $site: review 'git diff', commit, then 'just deploy' there (docs/releasing.md)"
