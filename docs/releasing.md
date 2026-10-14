# Releasing the CLI

A release is a git tag `vX.Y.Z`. `.github/workflows/release.yml` does the rest.

## Steps

1. In a PR: bump `sempereVersion` in `Sources/SempereCLI/Version.swift`, update the
   `--version` assertion in `Tests/CLITests/CLICommandTests.swift`, and in `CHANGELOG.md`
   rename `[Unreleased]` content into a `## [X.Y.Z] - YYYY-MM-DD` section (add the compare
   link at the bottom). Merge.
2. Tag the merge commit on `main` and push the tag (a maintainer does this by hand):
   `git tag -s vX.Y.Z -m "Sempere CLI X.Y.Z" && git push origin vX.Y.Z`.
3. The workflow:
   - **prepare**: fails unless the tag points at a commit reachable from `main` (the workflow does not run
     the tests itself: merge only with CI green, then tag), is `vMAJOR.MINOR.PATCH[-pre]`, equals the version in
     `Version.swift`, and `CHANGELOG.md` has a non-empty section for it whose heading is
     `## [X.Y.Z] - YYYY-MM-DD` and which holds no `TODO(user)` anywhere
     (`scripts/changelog-section.sh`, tested by `scripts/test-changelog-section.sh` in CI's `release` job):
     a placeholder left for the maintainer, such as the release date, never reaches the release notes or the
     tarballs' CHANGELOG;
   - **linux** (x86_64 on `ubuntu-24.04`, aarch64 on `ubuntu-24.04-arm`, both in
     `swift:6.4-noble`) and **macos** (`swift build --arch arm64 --arch x86_64`): build, check
     that the binary is static (Linux) or universal (macOS) and prints the tag's version, and
     package `sempere-X.Y.Z-<platform>.tar.gz` (binary, LICENSE, LICENSE-EXCEPTION, README, CHANGELOG,
     `docs/cli.md`; `scripts/package-cli.sh`);
   - **publish**: `SHA256SUMS`, build provenance attestations for the tarballs and
     `SHA256SUMS` (`actions/attest-build-provenance`), then `gh release create` with the
     CHANGELOG section as notes (a tag with a `-suffix` is a prerelease).
4. Update the Homebrew tap (`packaging/homebrew/README.md`).

Verify a download: `sha256sum -c SHA256SUMS` and
`gh attestation verify FILE --repo anthonytw/sempere`.

Not included: a man page (the ArgumentParser manual plugin is not a dependency of the
package; `sempere --help` and `docs/cli.md` ship instead), Apple notarisation of the macOS
binary, and the iPad/Mac app (TestFlight and App Store builds are made from Xcode).
To exercise the workflow without a release, push a prerelease tag (`vX.Y.Z-rc.1`, which also
needs a CHANGELOG section).
