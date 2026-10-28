# Sempere command index (`just` lists recipes). Works standalone and as a
# module of the dev/ workspace justfile. Releasing: docs/releasing.md.

set working-directory := '.'

# List the recipes
default:
    @just --list --unsorted

# Build everything including tests
build:
    swift build --build-tests

# Run the whole test suite
test *ARGS:
    swift test {{ARGS}}

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

# The PR gate on this pushed, clean commit; posts local/app-tests (about 10 min, no screen)
ci *ARGS:
    scripts/local-ci.sh {{ARGS}}

# Pre-TestFlight suite: the gate plus Mac UI, smoke, offline and perf; posts local/testflight-suite (takes the screen)
ci-testflight *ARGS:
    scripts/local-ci.sh --testflight {{ARGS}}

# Release sweep: everything, iPad and iPhone simulators too; posts local/release-sweep (takes the screen)
ci-release *ARGS:
    scripts/local-ci.sh --release {{ARGS}}

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

# Is REF (default origin/main) ready to tag? release.yml's checks, run locally; tags nothing
release-ready VERSION ref="origin/main":
    scripts/release-tag.sh --check {{VERSION}} {{ref}}

# Signed tag vVERSION on REF (default origin/main) after the checks; asks before pushing it
release-tag VERSION ref="origin/main":
    scripts/release-tag.sh {{VERSION}} {{ref}}

# Push an existing local tag vVERSION (starts the release workflow; asks first)
release-push VERSION:
    scripts/release-tag.sh --push {{VERSION}}

# Check a published release: workflow run, assets, SHA256SUMS, provenance, the macOS binary's version
release-verify VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{trim_start_match(VERSION, 'v')}}"; repo=anthonytw/sempere
    gh run list --repo "$repo" --workflow release.yml --limit 3
    gh release view "v$v" --repo "$repo" --json tagName,isPrerelease,publishedAt,assets --jq '"\(.tagName) prerelease=\(.isPrerelease) published=\(.publishedAt)", (.assets[].name)'
    d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
    gh release download "v$v" --repo "$repo" --dir "$d"
    (cd "$d" && shasum -a 256 -c SHA256SUMS)
    for f in "$d"/*.tar.gz; do gh attestation verify "$f" --repo "$repo" >/dev/null && echo "attested: ${f##*/}"; done
    if [ "$(uname)" = Darwin ]; then
      tar -xzf "$d/sempere-$v-macos-universal.tar.gz" -C "$d"
      "$d/sempere-$v-macos-universal/sempere" --version | head -1
    fi

# Homebrew formula for a published release: to stdout, or into TAP/Formula/sempere.rb and audited (no push)
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
