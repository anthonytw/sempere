# Sempere

End-to-end-encrypted handwriting notes for iPad, iPhone and Mac, a command-line tool for
macOS and Linux, and a read-only web viewer.

- **Keys you hold.** Every note is an [age](https://age-encryption.org) file encrypted
  to post-quantum hybrid (ML-KEM-768 + X25519) keys. Each device's key is made on that
  device and never leaves it (in the app, it stays in the device's Keychain); the
  recovery kit you save or print when you create a vault is the backup of the key.
  There is no account and no server.
- **A vault is a folder.** A vault is a plain folder of encrypted files, kept on each
  device. It syncs with folders you choose (iCloud Drive, another Files provider, a
  drive or a file share) and with WebDAV servers.
- **Append-only history.** Each note is a log of write-once saves. History is
  browsable, edits from two devices merge, and sync tools never see a conflict.
- **Readable without the app.** `age -d`, `gunzip` and `jq` recover any note. The
  `sempere` CLI verifies a vault and exports PDF, SVG and PNG on any machine.
- **Vector ink.** Strokes are stored as PencilKit B-splines, so erasing, export and
  search work on the original geometry.
- **Attachments.** PDF pages, images, video, typed text, audio recordings with
  transcripts, and quick voice notes from the Lock Screen.

Sempere is free software under GPL-3.0-or-later with an App Store exception
(`LICENSE`, `LICENSE-EXCEPTION`). It has no telemetry and no warranty. What the
encryption protects, and what it does not, is in [docs/security.md](docs/security.md).
The CLI bundles the Noto fonts (SIL Open Font License 1.1,
`Sources/SempereFonts/Fonts/OFL.txt`) for text in exports.

## Build

The Swift package (everything under `Sources/`) builds and tests on macOS and Linux
with Swift 6.0 or newer:

```bash
swift build
swift test
```

On Linux, install `zlib1g-dev` first. The app needs Xcode 27 or newer and runs on
iPadOS/iOS 27 and macOS 27 (Mac Catalyst). Open `Apps/Sempere/Sempere.xcodeproj`
(scheme `SempereApp`), or run `scripts/app.sh test` (iPad simulator) and
`scripts/app.sh catalyst` (Mac). The web viewer: `cd web && npm ci && npm run build`.

## Layout

| Path | What |
| --- | --- |
| `Sources/Age` | age v1 format, including post-quantum recipients |
| `Sources/Sempere` | Vault layout, note log, merge, keys |
| `Sources/SempereRender`, `Sources/SemperePDF` | Stroke geometry; PDF, SVG and PNG writers; PDF reader |
| `Sources/SempereImport`, `Sources/SempereNotability` | Importers (Notability backups) |
| `Sources/SempereSpeech` | On-device transcription of recordings (Apple Speech; an error elsewhere) |
| `Sources/SempereFonts` | The bundled Noto fonts for text in exports |
| `Sources/SempereWebDAV` | WebDAV vault access and sync |
| `Sources/SempereCLI` | The `sempere` command-line tool |
| `Apps/Sempere` | iPad, iPhone and Mac (Catalyst) app |
| `web` | Read-only web viewer that decrypts in the browser |

## Documentation

| Document | Contents |
| --- | --- |
| [DESIGN.md](DESIGN.md) | Why Sempere is built this way |
| [docs/format.md](docs/format.md) | The on-disk format (normative) |
| [docs/security.md](docs/security.md) | What the encryption protects and its limits |
| [docs/cli.md](docs/cli.md) | `sempere` command reference |
| [docs/io.md](docs/io.md) | Opening, saving, syncing and exporting |
| [docs/attachments.md](docs/attachments.md) | PDFs, images, video, text and recordings |
| [docs/mac.md](docs/mac.md), [docs/iphone.md](docs/iphone.md) | Mac and iPhone behavior |
| [docs/quick-capture.md](docs/quick-capture.md) | Quick voice notes |
| [docs/settings-sync.md](docs/settings-sync.md) | Settings shared through the vault |
| [docs/web-viewer.md](docs/web-viewer.md) | The web viewer |
| [docs/import-notability.md](docs/import-notability.md) | Importing Notability backups |
| [docs/localization.md](docs/localization.md) | Translating the interface |

## Releases, contributing, security

Tagged releases publish the CLI for Linux (static, x86_64 and aarch64) and macOS
(universal) with checksums and build provenance: see [CHANGELOG.md](CHANGELOG.md). The maintainer's runbook for TestFlight builds, App Store
and CLI releases is [docs/releasing.md](docs/releasing.md). Issues (bug reports, feature
requests, translation suggestions) are welcome; pull requests from outside the repository are not
accepted ([CONTRIBUTING.md](CONTRIBUTING.md)). Report vulnerabilities privately, as described in
[SECURITY.md](SECURITY.md).
