# Homebrew tap

`sempere.rb` is a template for `Formula/sempere.rb` in a **separate** tap
repository, `anthonytw/homebrew-tap` (users run `brew install anthonytw/tap/sempere`).
It installs the release tarballs built by `.github/workflows/release.yml`; nothing is
compiled on the user's machine. The tap repo is not created by this project's tooling.

## One-time setup

1. TODO(user): create the public repo `anthonytw/homebrew-tap` (the `homebrew-` prefix is
   required) with a `Formula/` directory.
2. TODO(user): decide whether to automate updates (below) or paste by hand.

## Publishing a release to the tap

After the GitHub Release for `vX.Y.Z` exists:

```bash
git clone https://github.com/anthonytw/homebrew-tap && cd homebrew-tap
/path/to/sempere/scripts/update-formula.sh X.Y.Z > Formula/sempere.rb
brew audit --strict --new --formula Formula/sempere.rb   # on a Mac or Linuxbrew
brew install --build-from-source ./Formula/sempere.rb && brew test sempere
git add Formula/sempere.rb && git commit -m "sempere X.Y.Z" && git push
```

`update-formula.sh` downloads the release's `SHA256SUMS` and substitutes the version and
the three checksums (macOS universal, Linux x86_64, Linux aarch64) into the template.
By hand: replace `@VERSION@` and each `@SHA256_…@` with the value from `SHA256SUMS`.

Before trusting a download you can also verify provenance:
`gh attestation verify sempere-X.Y.Z-linux-x86_64.tar.gz --repo anthonytw/sempere`.

## Notes

- The Linux binary is static except for libcurl and libxml2 (used by WebDAV sync); on
  Linuxbrew these come from the system. If `brew audit` objects, add
  `depends_on "curl"` / `depends_on "libxml2"` under `on_linux`.
- The macOS binary is not notarised. Homebrew downloads set no quarantine flag, so it runs;
  a tarball downloaded in a browser may need `xattr -d com.apple.quarantine sempere`.
  TODO(user): notarise once the Developer ID certificate exists (requires the paid program).
- Optional automation: a workflow in the tap, triggered by `repository_dispatch` from the
  release job, running `update-formula.sh` and opening a PR. Not set up.
