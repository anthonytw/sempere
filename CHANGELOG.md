# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the CLI's
version (`Sources/SempereCLI/Version.swift`) follows [Semantic Versioning](https://semver.org/).
The section for a version is the body of its GitHub Release (`docs/releasing.md`).

## [Unreleased]

### Added

- Emoji shortcodes in naming fields (note titles, notebooks, tags), as in Slack and GitHub: type `:`
  and two letters (`:smile`) for a list of emoji (↑ ↓ to choose, Return or Tab to insert, Escape to
  close); a closed `:smile:` becomes 😄 by itself, in rename dialogs too. Built-in table, no network.

### Fixed

- iCloud Drive: a vault is a plain folder, no longer a package, so iCloud syncs its files one by one; as
  a package, two devices writing at once made a conflict of the whole vault, and choosing one version
  lost the notes written on the other device. The app now merges iCloud's conflict versions of the
  vault's own files itself (union of write-once files, settings per key), so no version picker appears.
- iCloud Drive: note folders without a revision (an import's attachments written before its first
  revision, or a folder iCloud never lists) no longer keep the list on "Downloading" forever.
- "Thin everything except checkpoints" removes every autosave, including each editing session's last one.
- iPad: a dragged notebook's row lifts under the finger (it showed nothing, so notebooks seemed not
  to drag onto other notebooks or onto All Notes); after a drop the notebook that received the notes or the notebook
  flashes, so it is clear where they went.
- iPad: the sidebar and the note list no longer take the keyboard from the search field.

### Added

- Empty notebooks: File ▸ New Notebook… (⌃⌘N), the sidebar's New Notebook button and a notebook's
  New Notebook Inside… make a notebook that stays while it holds no note; Delete Notebook removes an
  empty one. They are kept by small write-once notebook records (`format.md` §14), synced by iCloud
  Drive and WebDAV, merged by `vault merge-copy`, backed up and rewrapped with the vault. CLI:
  `sempere notebooks create|delete`, and `notebooks list|rename|move` include empty notebooks.
- Mac: a notebook drags by its whole row in the sidebar, not only by its name.
- `sempere vault merge-copy FROM` merges another copy of the vault (an iCloud conflict version, another
  device's copy, a restored backup) without overwriting or deleting anything (`format.md` §1.3).
- Note list: rows show small icons for the attachments a note holds (pictures, equations, video,
  audio, PDF) and a colored star for favorites, and keep their tags on one line. Sort by Date Created
  joins Date Modified and Title, and "Favorites at Top" applies under any order; both are remembered on
  the device. New Note sits right after Sort in the toolbar. CLI: `sempere notes list --sort
  title|modified|created --favorites-first`, and `--json` rows gain `created` and `attachments`.
- Index-first listing: each device publishes its notes' summaries in `summaries/<device>.sealed`
  (`format.md` §12.5; `sempere vault summaries --device-file`), and a device on which notes are still
  arriving lists them by title from those files.

## [1.0.0] - TODO(user): date of the first release

First release. Sempere stores handwriting notes as end-to-end-encrypted files in a plain folder
(a vault), edited by the iPad, iPhone and Mac apps and the `sempere` command-line tool, and read by a
web viewer.

### Writing

- Pencil ink on paper or pageless canvases. Strokes are vectors with stable ids; erasing is by object
  (adjustable size) or by pixel. Concurrent slicing, moving or recoloring of one stroke on two devices
  resolves to the later edit (`format.md` §5.6.1); `sempere notes dedupe` removes leftover strokes.
- Paged notes (fixed-size pages) and pageless notes (one infinite page) switch into each other without
  moving ink (`sempere notes layout`). Pages are added, moved, duplicated and deleted, with undo;
  paper kinds are parametric and set per note or per page.
- Text boxes, images, PDF pages, equations and recordings are placed items. Select mode moves, resizes,
  rotates, duplicates, copies (also between notes), reorders and deletes them; each gesture is one
  delta with undo.
- Markdown text boxes: headings, emphasis, strikethrough, code, lists, task lists, links, quotes, rules
  and inline `$…$` or display `$$…$$` LaTeX, drawn rendered and edited as source (`format.md` §8.2.4).
- Equations hold LaTeX source and a stored typeset rendering, so exports, the CLI and the web viewer
  draw them without a typesetter. LaTeX sources are bounded (8 KiB, 4 096 tokens, 64 levels).
- Handwriting to LaTeX: circle ink, check the LaTeX a Core ML model read, replace the ink or place the
  equation beside it. Off by default; no model is bundled or downloaded in this release.
- Recordings: audio is recorded with ink timing; strokes link to the moment they were written, and
  playback highlights them. Transcripts are produced on the device, and a recording is a movable card on
  the page.
- Video clips are placed items with a poster image; location metadata is removed on import.
- Quick capture: voice notes from the Lock Screen, Control Center, widgets, Siri and the Mac menu-bar
  item are sealed into the vault's inbox without unlocking and adopted when the app next opens the vault.
- New-note titles use a preset or a custom date pattern (Unicode or strftime) with live preview.
- Interface in English and Spanish, including permission prompts, Siri phrases, widgets and Live
  Activities (`docs/localization.md`).

### Organizing

- Notebooks are `/`-separated paths, created by typing or picked from suggestions. Notes and notebooks
  move by drag or by command (each drop is one undo step); renaming a notebook renames its subtree.
- Tags (case-insensitive, merged per tag across devices), favorites, a Recently Deleted list with restore, and a
  "Recently Recognized" list of notes the last recognition run changed.
- Version history: every save is a restore point. Checkpoints are named versions; autosaves group into
  editing sessions; thinning removes old autosaves (default 30 days) while keeping every checkpoint and
  each session's newest autosave. `notes restore` and `export --at` read any point.

### Search

- Search covers titles, tags, notebooks, text boxes, recognized handwriting and, optionally, recording
  transcripts; all words must match, results are ranked, and the matching words are highlighted on the
  page with previous and next buttons.
- Handwriting is read on the device with Vision after the strokes change, stored as page recognition,
  and not read again unless the page's ink changes. "Recognize All Notes" and `sempere recognize` read
  a whole vault.

### Attachments

- Attachments are stored per note as streamed, padded, hash-verified age files named by a keyed hash
  (`docs/attachments.md`, `format.md` §8.1). Images drop location and camera metadata unless asked
  otherwise (a photo-privacy setting, `--keep-image-metadata`); stored PDFs are never encrypted PDFs.
- In iCloud Drive and on WebDAV, attachments download when a page shows them or a recording plays.
- Settings → Storage lists unused attachments with the version that last used each, and deletes them
  30 days after they were first found unused; `sempere blobs unused|gc|verify|repair` do the same from the
  command line.

### Sync and storage

- A vault is a folder: on the device, in iCloud Drive, in another app's Files provider, on a NAS share or
  on a WebDAV server. The note log is append-only; edits from several devices merge without conflicts.
- iCloud Drive: notes load progressively, a note open in the app takes in what another device writes
  without reopening, and a sync in flight when the device locks finishes in background time.
- WebDAV in the app: a local copy that works offline and pushes changes shortly after they are made, on
  return to the app and every five minutes. Push-only: the server never changes the vault. HTTPS only;
  a self-signed server needs an explicit "Trust This Certificate", after which only that certificate is
  accepted. The password stays in the Keychain. Downloads show progress and run in parallel, and a vault
  opens from the server's note summaries before the notes arrive.
- Opening is fast: summaries are read in parallel and kept in an encrypted per-device cache; opened notes
  load from an encrypted drawing cache (200 MB).
- Backups: Back Up Now copies new encrypted files to a folder you choose; Verify Backup decrypts every
  note; Restore from Backup creates a new vault; an optional reminder follows. `sempere backup`,
  `backup status --max-age DAYS` (exit 3 when stale) and `restore --dry-run` do the same.
- A vault may carry a display name (`label` in `vault.json`, stored unencrypted).
- Settings sync through the vault (`docs/settings-sync.md`): devices that opt in follow a shared
  settings file merged per key, with per-device-type blocks and "Only on This Device" overrides.
  `sempere settings list|get|set|reset|edit|validate|schema`.
- Vaults of a later format version open read-only, showing everything this version understands;
  every write is refused (CLI exit 7).

### Security

- Notes are age v1 files, spec-exact and tested against the C2SP vectors and the reference `age` CLI.
  Vault keys are post-quantum only (ML-KEM-768 with X25519); a note is recoverable with `age`, `gunzip`
  and `jq`.
- The list of recipients is authenticated; a rewrap journal counts only when a signed secret link
  (Ed25519 and ML-DSA-65) ties it to the vault; `format` and `features` are authenticated. A tampered
  list is refused for writing (exit 6). `sempere vault link|markers`.
- Keys can be remembered in the Keychain behind Face ID or Touch ID, saved to Files with a paper
  recovery kit, and replaced or removed per device; a device list changed without its key can be
  repaired.
- Quick-capture voice notes are sealed without the identity, attributed to the device that recorded
  them, and bound to their transcripts. A removed device cannot add captures.
- The app first shows "About Your Key": only the key opens the notes, and nobody can recover them if
  every copy is lost. A quick tour follows once. `docs/security.md` says what the encryption protects and
  what it does not; `SECURITY.md` describes the advisory process.
- Untrusted input is bounded everywhere: readers fail with a typed error instead of trapping or
  allocating without limit, and a seeded fuzzer covers every parser.
- The apps contain no analytics or telemetry. The only network code is the WebDAV client, which connects
  to the server you configure; `scripts/release-check.sh` enforces this.

### Export and import

- Export a note or a whole vault as PDF (vector, with searchable text and embedded font subsets), SVG,
  PNG (`--dpi`), Markdown, HTML, "PDF + attachments" (with an attachment list linked to each embedded
  file), or "Media" (recordings, transcripts, video clips, images and PDFs as files with a manifest).
  `--at` exports a past version.
- Exports cut pageless pages at gaps in the ink. Text in any script is shaped and set with the bundled
  Noto fonts; images, PDF pages and equations are embedded or, if they cannot be drawn, replaced by a
  placeholder with a warning.
- Dragging a note out of the app on a Mac writes a PDF.
- Import PDFs as notes (one page per PDF page, with the page as background).
- Import from Notability backups: `.note` packages and backup zips, including ink, recognized
  handwriting, PDF backgrounds, images, typed text and recordings (`docs/import-notability.md`).
  The importer is an optional module.

### CLI

- `sempere` runs on Linux (static x86_64 and aarch64) and macOS (universal). Every feature that reads or
  changes a vault has a command with `--json` output: `keys`, `vault`, `notes`, `notebooks`, `tags`,
  `pages`, `items`, `attach`, `recordings`, `blobs`, `search`, `recognize`, `recognize-math`, `transcribe`, `export`,
  `import`, `compact`, `snapshot`, `recover`, `backup`, `restore`, `sync webdav`, `inbox`, `settings`,
  `webdav check`, `about`. See `docs/cli.md`.
- Each edit is one delta through the same code as the app.
- Release archives carry `SHA256SUMS` and build provenance attestations; a Homebrew formula template is
  provided.

### Web viewer

- A static, read-only page opens a vault from a web server (static files or WebDAV) or a local folder
  and decrypts it in the browser with the pasted key or a passphrase-wrapped key file. Notebooks, tags,
  search (including transcripts), and notes drawn like the SVG export, with images, text boxes, PDF
  pages and recordings with transcripts.
- The list comes from the vault's published sealed summaries; encrypted files are cached in IndexedDB
  (512 MiB, least recently used) and nothing decrypted is stored.
- A key can be remembered with a WebAuthn passkey (PRF extension), bound to where the vault was opened.
- The key stays in the tab's memory. Strict Content-Security-Policy with Trusted Types; no third-party
  requests. Interface in English and Spanish.

### Platforms

- iPad (iPadOS 27) with Pencil, the Mac through Mac Catalyst (macOS 27), and iPhone as a reader with
  light finger annotation (iOS 27).
- Mac: menu bar and shortcuts from one command list, a window per note with state restoration, mouse and
  trackpad input, a Vault Keys window, and an optional system menu-bar item (Quick Voice Note, New Note,
  Open Sempere).
- License: GPL-3.0-or-later with an App Store exception (`LICENSE-EXCEPTION`). Contributions carry a DCO
  sign-off; there is no contributor license agreement.

[Unreleased]: https://github.com/anthonytw/sempere/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/anthonytw/sempere/releases/tag/v1.0.0
