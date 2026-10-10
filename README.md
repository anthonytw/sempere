# Sempere

*Formerly InkVault (renamed 2026-10-05; the name nods to the Sempere bookshop in
Carlos Ruiz Zafón's* La sombra del viento*).*

A stripped-down handwriting notes app for iPad (and Mac), with the few features
that matter and nothing else:

- **Your keys, your notes.** Every note is an [age](https://age-encryption.org)
  file encrypted to keys you generate, import, export and back up yourself.
  No account, no server, no key you cannot take with you.
- **Sync is a folder.** A vault is a plain folder of encrypted files. Put it on
  the iPad, in iCloud Drive, on a NAS share, behind WebDAV, or zip it anywhere.
- **Nothing is ever lost quietly.** Each note is an append-only log of saves.
  History is browsable, edits from two devices merge, and sync tools never
  see a conflict.
- **Readable without the app.** `age -d` plus `gunzip` plus `jq` recovers any
  note. The `sempere` CLI exports PDF and SVG from a backup on any machine.
- **Real ink.** Strokes are vectors (PencilKit B-splines), so erasing, export
  and search stay clean.

Free software under the GPL-3.0-or-later with an App Store exception (`LICENSE-EXCEPTION`), no telemetry, and no warranty. What the encryption protects, and what it does not, is in [`docs/security.md`](docs/security.md). The `sempere` CLI is a
first-class Linux citizen: keys, unlock, verify, recovery and PDF/SVG export
all run natively on Linux, and CI publishes a static Linux binary. The CLI ships the Noto fonts (SIL Open Font License 1.1, `Sources/SempereFonts/Fonts/OFL.txt`) for text in exports.

## Layout

| Path | What |
| --- | --- |
| `Sources/Age` | Spec-exact Swift implementation of the age v1 format |
| `Sources/Sempere` | Vault layout, note log, merge, keys |
| `Sources/SempereRender` | Stroke geometry, PDF and SVG writers |
| `Sources/SempereCLI` | Command-line tool: keys, verify, export, recover |
| `Apps/Sempere` | iPad app, Mac via Catalyst (Xcode project, phase 1; a shell so far) |
| `web` | Read-only web viewer, decrypts in the browser (`docs/web-viewer.md`) |
| `docs/format.md` | The on-disk format, normative |
| `DESIGN.md` | Why it is built this way |
| `docs/plan.md` | Phases and task board |

Everything under `Sources/` builds and tests on Linux and macOS with
`swift test` (Swift 6.0 or newer). The apps need Xcode 27 or newer and run on
iPadOS/iOS 27 and macOS 27 (Mac Catalyst): open
`Apps/Sempere/Sempere.xcodeproj` (scheme `SempereApp`), or run
`scripts/app.sh test` (iPad simulator) and `scripts/app.sh catalyst` (Mac).

## Status

Phase 0 (core library and CLI) is nearly done: the `sempere` CLI (keys, vault, verify, export, recover; see `docs/cli.md`) works on Linux and macOS. The iPad app is a scaffold: it opens and unlocks a vault and lists its notes; drawing comes next.

## Releases, contributing, security

Tagged releases publish the CLI for Linux (static, x86_64 and aarch64) and macOS (universal)
with checksums and build provenance; see [CHANGELOG.md](CHANGELOG.md) and
[docs/releasing.md](docs/releasing.md). To contribute, read [CONTRIBUTING.md](CONTRIBUTING.md)
(licence, DCO sign-off, no CLA); to report a vulnerability, [SECURITY.md](SECURITY.md).
Homebrew formula template: `packaging/homebrew/`. App Store submission: `docs/release/` (checks: `scripts/release-check.sh`).
