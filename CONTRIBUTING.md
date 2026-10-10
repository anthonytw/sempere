# Contributing to Sempere

Thanks for helping. Read `DESIGN.md` (why), `docs/format.md` (the on-disk format, normative)
and `CLAUDE.md` (the rules for working in this repository, including the hard ones: Linux-buildable
`Sources/`, no hand-rolled crypto, notes are write-once) before touching `Sources/`.
Everyone is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Build and test

Swift 6.0 or newer (CI uses 6.4); `Sources/` must build on Linux and macOS.

```bash
swift build --build-tests
swift test                  # or: swift test --filter AgeTests
scripts/check-portability.sh
scripts/test-linux.sh       # on a Mac with Docker: tests in swift:6.4-noble
```

On Linux install `zlib1g-dev` (and the `age` CLI for the interop tests). The iPad/Mac app needs
Xcode 27 or newer (the app's minimum is iPadOS/iOS 27; the package and CLI need only Swift 6.0): `scripts/app.sh test` and `scripts/app.sh catalyst`. In `swift test` output,
the XCTest `Executed N tests` line is the one that matters.

## Pull requests

1. Open an issue first for anything bigger than a small fix, so the design can be agreed.
2. One task per branch, one PR to `main`. Branch names like `feat/…`, `fix/…`, `docs/…`.
3. Commit messages: `area: imperative summary` (for example `render: clamp page height`).
4. Add tests with the change; format changes go through `docs/format.md` first.
5. Update `CHANGELOG.md` under `[Unreleased]` for anything a user would notice.
6. CI must be green (Linux, macOS, app). Maintainers squash-merge.
7. Fill in the PR template, including the licence and sign-off checkbox.

Style: Swift 6 strict concurrency, `Sendable` value types for the model, typed error enums per
module, no force-unwraps outside tests, `///` on public API, XCTest for tests.

## Adding a language

The app's interface lives in String Catalogs (`Apps/Sempere/Localization/*.xcstrings`); Spanish is
complete. Interface text only: note content, the CLI's messages and the on-disk format are not
localized. Full rules and the Spanish glossary: [docs/localization.md](docs/localization.md).

1. Open `Localizable.xcstrings` and `InfoPlist.xcstrings` (and `AppShortcuts.xcstrings` for the Siri
   phrases) in Xcode 26, add your language, and translate every entry. Plurals need the forms of
   your language's CLDR plural categories; keep `%lld`, `%@` and `%1$@`; “Sempere” stays.
2. Add the language code to `knownRegions` in `Apps/Sempere/Sempere.xcodeproj/project.pbxproj` and to
   `LocalizationCatalogTests.languages` (and its `pluralCategories`).
3. Add a short glossary for your language to `docs/localization.md` first (vault, notebook, tag,
   page) and use it throughout.
4. `swift test --filter LocalizationCatalogTests` must pass (it runs on Linux), and
   `scripts/app.sh pseudo` should show no clipped labels. Do not translate the identifiers in
   `Sources/` or what the app writes into a vault.
5. Open the pull request. A native speaker reviewing the glossary choices helps most.

## Licence and sign-off

Sempere is licensed **GPL-3.0-or-later with an App Store exception** (`LICENSE`,
`LICENSE-EXCEPTION`; background and consequences in
[docs/legal/app-store-exception.md](docs/legal/app-store-exception.md)). The exception is a
GPLv3 section 7 additional permission that lets anyone, the maintainer included, distribute
builds through Apple's App Store under Apple's terms as long as the complete source stays
public under the GPL. It does not relicense your code or give the maintainer any right the
other contributors do not have.

There is **no contributor licence agreement** and no copyright assignment. You keep your
copyright. By contributing you license your work under those same terms (inbound = outbound),
and you certify the [Developer Certificate of Origin](https://developercertificate.org/) by
signing off each commit (`git commit -s`, which adds `Signed-off-by: Your Name <you@example.org>`):
you wrote it or have the right to submit it under this licence, and your employer does not
claim it. Ticking the box in the PR template is the fallback for a commit you could not sign.

Third-party code needs a licence compatible with GPL-3.0-or-later and with App Store
distribution (MIT, BSD, Apache-2.0, ISC); say where it came from in the PR. GPL-only (without
this permission) and AGPL code cannot be accepted.
