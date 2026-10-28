# Sempere design

`docs/format.md` is the normative on-disk spec; this document records *why*.

## Goals

1. Handwriting on iPad that feels native. A Mac companion for browsing,
   searching, exporting and light annotation.
2. End-to-end encryption with keys the user owns outright: generate anywhere,
   import by AirDrop, QR or paste, export at any time, encrypt to several keys.
   A dead device must cost nothing.
3. Sync through any storage the user already has, with no server of ours.
4. Notes readable and exportable (PDF, SVG, PNG) without the app, from a backup.
5. Small feature set: a few pens, a few papers, notebooks and tags, search,
   and attachments on pages: typed text boxes, images, PDF page backgrounds,
   audio recordings (`docs/attachments.md`). No AI services: handwriting
   recognition, transcription and handwriting-to-LaTeX run on device only,
   opt-in. No accounts, no telemetry, no subscriptions.

## Non-goals

Collaboration between people, real-time sync, Android, Windows, typed text
documents (reflowing text with ink anchored to it; text boxes placed on a page
are in scope). Video clips, typeset equations and recordings shown on a page
are items too (`format.md` §8.2.7–§8.2.9).

## Architecture

The core stack (the other library targets, such as the importers below, build on it):

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  iPad app    │  │   Mac app    │  │  sempere     │
│  SwiftUI +   │  │  SwiftUI via │  │  CLI         │
│  PencilKit   │  │  Catalyst    │  │  (mac+linux) │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       └────────────┬────┴─────────────────┘
            ┌───────┴────────┐
            │ SempereRender  │  B-spline geometry, PDF, SVG, PNG
            ├────────────────┤
            │ Sempere        │  vault layout, note log, merge, keys
            ├────────────────┤
            │ Age            │  age v1 encryption (spec-exact)
            └────────────────┘
```

Everything under `Sources/` builds on Linux without Apple frameworks
(Foundation, swift-crypto and zlib, plus swift-argument-parser for the CLI).
That rule keeps the format independent of Apple frameworks, and lets most
of the project build and test on Linux. Anything that imports UIKit, AppKit, PencilKit or
CoreGraphics lives under `Apps/`.

Importers from other apps are optional modules. `SempereImport` holds what every importer
needs (zip, property-list and keyed-archive readers for untrusted input, and the `VaultImporter` interface the
hosts use); the Notability importer is `SempereNotability`, one directory that the CLI and the app list in one gated
line each. Deleting that directory leaves a package that builds, passes its tests and has no `import notability`
(`docs/import-notability.md` "Structure"; CI checks it on every change). Core and the renderer never
name an importer: what an importer leaves in a vault (an `engine: notability-…` string, derived ids) is data.

## Ink

PencilKit does the drawing. Its strokes are uniform cubic B-splines whose
control points carry location, width, opacity, force, azimuth and altitude.
We serialize those control points into our own JSON, not PencilKit's opaque
`dataRepresentation()`, so the format is open and the renderer can be pure
Swift. PencilKit's pixel eraser slices strokes into new strokes, so the
drawing stays vector; in our log that is one `removeStroke` plus the
surviving pieces as `addStroke`s.

Each page may also carry its recognized handwriting text (`format.md` §5.5):
produced on device by Vision's text recognition on a rendering of the page (iPadOS 27) or
carried in by an importer, stored inside the
encrypted note body like everything else, and used to power search. It is
derived data, replaced as a whole, so it merges last-writer-wins per page.

## Encryption

Container: age v1 (age-encryption.org/v1), implemented in Swift on CryptoKit /
swift-crypto and validated against the public C2SP test vectors and against
the reference `age` CLI. Recipients are only age's native hybrid post-quantum type
(MLKEM768-X25519, `age1pq1...`, age v1.3+): a `vault.json` that lists a
classic X25519 key is invalid and does not open. See `docs/post-quantum.md` for the threat ("harvest now,
decrypt later") and the choice.

Why age and not GPG: one fixed modern construction (X25519, HKDF-SHA256,
ChaCha20-Poly1305, every chunk authenticated), no cipher negotiation, a
tiny spec, several independent implementations, and a stock CLI that reads
our files.

Keys: a key hierarchy (`docs/design/key-hierarchy.md`, `format.md` §2, §15).
A vault has a 32-byte vault key per epoch; an age identity derived from it,
the vault identity, is what every file is encrypted to, in one stanza, so a
file's header does not grow with the number of devices. `vault.json` wraps
the vault key once for each device's own key (made on the device, never
copied off it) and once for one recovery key, printed in the recovery kit and
kept by no device. The recovery key may also be stored in the vault
passphrase-wrapped (`age -p` compatible, scrypt work factor 20, any passphrase;
Sempere suggests seven random words). A vault starts with one epoch: adding a
device wraps the key to it and touches no file; removing one starts a new
epoch.

age does not sign. To stop someone with write access to the storage from
planting a note that decrypts, every plaintext carries an HMAC keyed by a key
derived from the vault key, which only key holders can unwrap. The stock-CLI
recovery path simply skips the tag. The device list in `vault.json` is tagged
the same way and signed (P-256 and ML-DSA-65) by the one device that changes
it, the vault's home; each device remembers what it verified as public keys
only, and checks every later `vault.json` against that and against the vault's
root fingerprint, printed on the kit (`format.md` §2.1).

## Storage and sync

A vault is a folder. The app reads and writes files; sync is whatever moves
the folder: on-device, a Files-app provider (iCloud Drive, SMB, Nextcloud,
Dropbox, ...), the built-in WebDAV client (the app downloads a local copy when the vault is opened,
edits it, and pushes changes back to a server the user runs; the pushes are push-only; `docs/io.md`), or a zip through the
share sheet. Providers see UUID file names, keyed-hash blob names with their
kind (image, pdf, audio, …), sizes (blobs padded to a size class) and times,
nothing else.

## Network

The app's only connections go to a WebDAV server the user sets up and opens
a vault from (`docs/io.md`, "WebDAV vaults in the app"): it downloads the
vault's already encrypted files from there when the vault is opened and uploads
its changes, push-only, over HTTPS (plain http is accepted only for localhost). Otherwise files move through the
system's Files and iCloud services, and on-device speech models are the
system's downloads. Network code lives in `Sources/SempereWebDAV` (the CLI's
`sync webdav` and the app's WebDAV vaults, through
`Apps/Sempere/SempereApp/WebDAVRemote.swift`) and in one other app file, the
handwritten-math model downloader (`Apps/Sempere/SempereApp/MathModels.swift`),
which is inert: it runs only from a Download button per catalog entry, and
the catalog (`MathModelCatalog.entries`) is empty, so no model ships.
`scripts/release-check.sh` fails on networking anywhere else in the shipping
app and on a non-empty catalog; shipping a model means updating the privacy
policy, the App Store privacy answers and the Mac entitlements first. The web
viewer (`web/`) fetches only the vault's files and its own assets.

## Append-only note log

A note is a folder of immutable encrypted revision files. Every save appends
a *delta* (strokes added or removed, metadata set) stamped with a device id,
a per-device sequence number and a hybrid logical clock. Periodically a
device writes a *snapshot* that records which deltas it includes. Deltas and
snapshots older than a retention window are compacted away.

Consequences:

- Sync tools only ever see new files, so no conflict copies.
- Concurrent edits are two branches; ink merges by set union of stroke ids
  (remove always wins), metadata merges last-writer-wins per field, except
  tags: they merge per tag as an observed-remove set where a concurrent add
  wins (`format.md` §5.4.1), so tags added on the iPad and the Mac at the same
  time are both kept. Tags differ from strokes because the same tag is
  re-added routinely while a stroke id never is.
- History is the log; restore writes a new delta, so history itself is
  append-only. Restored strokes and pages get new ids with `parent` naming
  the old ones; revisions removed by compaction are no longer restore points
  (`format.md` §5.7).
- Recovery without the app reads the newest snapshot; at worst the deltas
  since it are lost, never the note.

Two devices slicing, moving or recoloring the same stroke concurrently would
keep both sets of pieces (overlapping copies, each bringing back ink the other
erased). Readers keep the later edit instead, last writer wins like any other
register (`format.md` §5.6.1); snapshots carry what the rule needs, so
compaction never changes the result. A stroke brought back by undo while
another device sliced it still shows twice; `sempere notes dedupe` finds and
removes such leftovers.

## Recovery

The aim is that a dead device or a lost copy of the key need not cost notes,
as long as another copy of the key and a backup exist. If every copy of the key
is lost, nobody can open the notes; the app says so when a vault is created or
first unlocked on a device ("About Your Key"). Three things support the aim,
none of which need us, a server or the app:

- **The recovery key on paper.** `sempere keys paper` prints a recovery kit:
  the vault's recovery key as a QR code and as text, the vault id and root
  fingerprint, and recovery steps that need only the stock `age`, `tail`,
  `gunzip` and `jq` (a frozen script, `format.md` §15.13).
  The QR encoder is our own (pure Swift, `Sources/SempereRender/QRCode.swift`, no
  imaging library) and is checked module for module against an independent
  implementation and by decoding with zbar. Text is typed back, so every line
  carries a 4-hex-digit SHA-256 checksum anyone can recompute with
  `sha256sum`: the key's own Bech32 checksum already rejects a typo, but cannot
  say where it is. The plain sheet *is* the key and says so in a box at the
  top. The `--passphrase` variant prints the scrypt-wrapped key file instead
  (wrapping only the secret key line), for people who would rather keep a sheet
  that is useless without a passphrase in a drawer than a bare key in a safe.
- **Backups of the encrypted files.** A vault is a folder of write-once files,
  so a backup is a copy that only ever grows: `sempere backup --to DIR` copies
  new files (atomically, each read back and hash-checked), keeps every
  previous version of the few files that do change (`vault.json`,
  `settings.age`) under `versions/`, and deletes
  nothing unless `--prune` proves with the compaction rules that a snapshot
  in the backup covers it. A backup folder is itself a vault, so every
  command, and the stock-tool path, works on it directly; `backup.json` records
  every file's SHA-256 so it can be checked without the key. A tar
  (`--archive`) is the single-file form for off-site copies. Backups never
  hold plaintext, so they can go anywhere.
- **Restore is verification.** `sempere restore` rebuilds a vault from a
  backup and runs the full verify on the result, and `backup verify` with a
  key decrypts every revision, so a backup is known to be readable before it
  is needed.
- **The app backs up the same way.** Settings → Backups runs the CLI's
  backup, verify and restore code on a folder the user picks (another drive
  or provider), with a reminder after N days without a backup; a restore
  always makes a new vault after showing what the backup holds.

## Attachments

Images, PDFs, audio and transcripts are immutable *blobs* in the note's own
`att/` folder, named by an HMAC of their content hash under a key derived from the vault key
(no plaintext hashes on storage; the name is also the integrity tag),
deduplicated within the note, and collected per note only when no surviving
revision of that note references them. Text boxes (full Unicode), images and
PDF pages are *placed items* on a page with LWW geometry and text, on integer
z-layers, always drawn below the ink. Recordings belong to the note; strokes
drawn while recording carry the recording time. Adding a device touches no
blob. Details and alternatives:
`docs/attachments.md`; format: `format.md` §8.

## Export

One renderer evaluates the B-splines and writes vector PDF and SVG, and raster PNG. It is used
by the apps' share sheet and by the CLI, so exports from a backup match
exports from the app. Textured inks (pencil, crayon, watercolor) are
approximated; pen, monoline and marker are faithful.

## Distribution

Public repository on GitHub under GPL-3.0-or-later with an App Store exception
(`LICENSE-EXCEPTION`): a GPLv3 section 7 additional permission that lets anyone
distribute builds through the App Store while the complete source stays public.
The maintainer writes the code himself and does not accept pull requests, which keeps the
licensing (and the App Store exception) simple; issues are welcome (`CONTRIBUTING.md`). The app ships through the App Store; the CLI
ships as GitHub release binaries (`docs/releasing.md`).

## Linux

The CLI is the Linux face of the project: it builds natively, is published as
a static binary from CI, and covers everything that does not need a pen:
key management, unlock, verify, recovery, backup, and export to PDF, SVG and
PNG. On Linux, notes can also be read in the web viewer (`docs/web-viewer.md`).
