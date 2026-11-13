# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the CLI's
version (`Sources/SempereCLI/Version.swift`) follows [Semantic Versioning](https://semver.org/).
The section for a version is the body of its GitHub Release (`docs/releasing.md`).

## [Unreleased]

## [1.1.0] - 2026-11-13

### Security

This release fixes four issues found by the project's first security audit
([report](https://github.com/anthonytw/sempere/blob/main/docs/audits/2026-11-1.1.md)). Update to 1.1.0 on every device and every machine that runs the CLI.

- **Web viewer hosting** ([GHSA-vr26-635c-vq25](https://github.com/anthonytw/sempere/security/advisories/GHSA-vr26-635c-vq25), High).
  The hosting layout that `docs/web-viewer.md` recommended in 1.0.0 and 1.0.1 served the WebDAV share from the viewer's
  own host name. Someone who can write to the share, such as a removed device that kept its login, could make the viewer
  run their code if you opened a link to it, and read a key as you typed it. Affected: a web viewer set up that way where
  someone other than you can write to the share. Not affected: a viewer on its own host name, a share only you can write
  to, the apps and the CLI. What to do: change the server configuration as in the updated hosting section, or put the
  share on a separate host name; change the share's password if a device that could write to it was removed or lost. If
  you may have typed or passkey-unlocked a key in the viewer after following an unexpected link into the share, treat
  that key as exposed: for a device key, remove that device from the vault; for the recovery key, replace the recovery
  kit. This fix is in the documentation, so you can apply it without updating.
- **Notability import** ([GHSA-qh9v-jp8v-858m](https://github.com/anthonytw/sempere/security/advisories/GHSA-qh9v-jp8v-858m), Medium).
  A crafted Notability file could keep an import busy at full CPU for a long time. No data is exposed or changed.
  Affected: 1.0.0 and 1.0.1, the app and `sempere import notability`, when importing a file from someone else. What to
  do: update; until then import only Notability files you made yourself.
- **CLI tree export** ([GHSA-jg6x-72x7-6vr2](https://github.com/anthonytw/sempere/security/advisories/GHSA-jg6x-72x7-6vr2), Medium).
  Someone who can write to an export folder could make `sempere export --all --format markdown|html --clean` delete a
  file outside the folder or write note files elsewhere, through a symbolic link. Re-exporting over an existing file
  also kept that file's permissions instead of making it readable by you only. Affected: the CLI 1.0.0 and 1.0.1 when
  exporting into a folder other people or programs can write to (the permissions part also affects the app's PDF, share
  and bulk export over an existing file). What to do: update; until then export only into a folder only you can write
  to, and do not use `--clean` on a shared folder. After an earlier export, `chmod -R go-rwx` the folder.
- **Sync with a hostile WebDAV server** ([GHSA-xmqw-cv8m-rh5r](https://github.com/anthonytw/sempere/security/advisories/GHSA-xmqw-cv8m-rh5r), Medium).
  A server could make a sync download several very large files into memory at once, and fill the device's storage
  with refused downloads kept in quarantine, run after run. No note content or key is exposed. Affected: 1.0.0 and 1.0.1,
  the app and the CLI, syncing with a server you do not fully trust. What to do: update. To free space, delete
  quarantined files: in the app, Sync Targets ▸ Details and Repair ▸ Quarantined Files; in the CLI,
  `sempere store quarantine list` and `delete`.

### Apple Watch

- Record a voice note from your wrist: from a complication, a Smart Stack widget, a Control, the Action button or Siri.
  Turn on Settings ▸ Audio & Transcription ▸ Use on Apple Watch (it appears when a paired watch has Sempere). The watch
  encrypts each note as soon as it stops and sends it to your iPhone, which puts it in the vault's inbox; it becomes a
  note the next time the vault is unlocked. Notes for a vault other than the Quick Voice Notes one go to their own vault.
- The iPhone adds a note from the watch to your inbox only while Use on Apple Watch is on and the note was sealed under
  the key the iPhone currently holds. Any other note is kept on the iPhone, never in your vault, until you choose, note
  by note, Add (after a confirmation, with a warning for notes that came after the setting went off or under an earlier
  key) or Delete in Settings. Turning the setting off also makes the iPhone forget the watch's key. If you lose the
  watch: turn the setting off, unpair or erase the watch, then replace the key.
- CLI: `sempere inbox watch keygen|provision|seal|receive` run the watch's voice note steps (provision a watch key, seal
  as the watch, receive as the phone), and `sempere inbox watch held list|add|delete` manages the notes the iPhone keeps
  (`held add --all` skips the notes that need a check).

### Undo and redo

- Note editor: Undo and Redo buttons in the toolbar (on iPhone, in the More menu), disabled when there is nothing to undo
  or redo and naming the step; the iPhone palette's pair is disabled the same way.

### Joining nearby

- Joining a device no longer waits for the sync target when the two devices are near each other: while Add Device
  shows on one and the join screen on the other, the request and the approval go straight between them over
  peer-to-peer Wi-Fi (as AirDrop does) or a shared network, even on different Wi-Fi networks. Both still type or scan
  the six words, and the sync target is used as before; whichever arrives first wins. Add Device marks a request that
  came this way "Nearby", and the join screen says when it has found and reached the other device.
- CLI: `sempere devices approve --qr TEXT` approves a join request named by the text of the code the new device shows
  (what the app's Add Device scans), instead of its six words. `sempere device init --json` prints that text as `qr`.

### Where you left off

- The app opens where you left off: the last folder, tag or list and the last note, on every device, also after you
  swipe the app away, it restarts or updates, or a new Mac library window opens. If the note or folder is gone, it opens
  the folder alone, then All Notes. The place is kept per vault on this device only, never synced or written into the
  vault.

### Other changes

- Voice note widgets: the ready state shows the Sempere nib instead of a microphone on the Lock Screen and Home Screen
  widgets and in the Control Center control; the Lock Screen circle and the Home Screen widget draw it larger.
- Replace Recovery Kit and Re-encrypt Everything ask for Face ID, Touch ID or the passcode when you confirm the change,
  not before the new kit is shown. Nothing changes until the check passes.
- CLI: `sempere notes move` takes several notes: `notes move ID|TITLE... (NOTEBOOK | --none)`. Every note is resolved
  before anything is written, so one that does not resolve moves nothing. `--json` prints one entry per note.
- CLI: `store target add --folder PATH` places the vault's copy where the app's Add Folder… does. A `….sempere`
  folder is the copy itself, as before, and so is a folder that already holds this vault (a target 1.0 synced
  straight into it: re-adding it on another machine, or after `target remove`, joins that copy). Any other folder
  now gets the copy in `PATH/<name>.sempere` (or the next free `<name> N.sempere`), instead of the vault's files
  going straight into `PATH`. A folder holding another vault, a `….sempere` folder holding other files, and a cloud
  placeholder not downloaded are refused when the target is added (exit 1), as in the app. `store import
  --keep-syncing` follows the same rule (the source, which holds the vault, stays the target).
- CLI: `store sync` records a target's last successful sync by the app's rule: a run cut short after it moved
  files (the link lost midway) is progress, not a last success, and the next `store sync` continues it.
- CLI: `webdav check` and `store target add --webdav --check` report the same problem and message as the app's
  Test Connection and Add WebDAV Server…; control characters in the server's error message are escaped.
- CLI: `store create`, `store import --name` and `store restore --name` also refuse a vault name holding a Unicode
  line or paragraph separator (U+2028, U+2029), as the app's New Vault always did. `vault init` and `store create`
  make vaults with the app's own vault creation.
- Releases from 1.1.0 on: the maintainer signs each release tag and its `SHA256SUMS` personally, with their own SSH key
  after the build. SECURITY.md lists the public key and its fingerprint (`packaging/allowed_signers`), and
  the release scripts refuse a tag that key did not sign.

### Fixed

- iPhone and iPad: Sempere was sometimes closed by the system while you were not using it. When iOS started it in the
  background (for a background sync, or a note from the Apple Watch), it could reopen the last vault and keep a lock on
  its files while suspended. Now it locks nothing until it is on screen, and every write in the background has
  background time of its own or waits for the next launch. A note it reopens in the background is no longer read for
  handwriting search until Sempere is on screen.
- iPhone and iPad: an import or a restore that was still running when Sempere had been in the background for longer
  than iOS allows now stops and adds nothing, instead of possibly placing an incomplete copy in the app. The vault or
  backup it came from is never changed; run it again.
- Mac: if Sempere was killed or crashed after Copy Key, the vault key stayed on the clipboard until something else was
  copied. The next launch now clears it. Only a key Sempere itself copied is cleared, never anything another app put
  on the clipboard.
- Joining: a device asking to join a vault in iCloud Drive whose `joins` folder was empty never sent its request, and
  its join screen said the request was in the sync target. The request now goes out with the first sync, and the
  screen says it is sent only once a sync has put it there.
- New Vault explains every vault name it cannot use (a backslash, a name ending in `.SEMPERE`, more than 255 bytes)
  in the app's words, instead of an English error from the vault store; Restore from Backup no longer offers to
  restore under such a name, which then failed.
- Sync: notebook records, join requests and recovery passphrase copies upload to a temporary name and then move
  into place, as revisions and attachments do, so a connection cut mid-upload never leaves a partial file on a
  WebDAV server. A partial copy an earlier version left is replaced by the whole file on the next sync, and a
  join request counts as delivered only once the server holds all of it.
- Sync: a partial `vault.json` on a sync target no longer stops two-way sync there: the next sync of a device
  that has the vault unlocked replaces it with the device list it holds.
- Import: with photo privacy on, an imported HEIC photo that cannot be converted is skipped and reported instead of being
  stored with its location and camera data.
- A Notability import that stops half way keeps the clock readings it already used, so a later edit never sorts before
  a note it imported.
- CLI: an edit written next to a revision that cannot be read yet (still arriving, or replaced while being read) now
  sorts after it, as the app's edits already did, instead of losing to it.

## [1.0.1] - 2026-11-06

### Fixed

- CLI on Linux: the release binary is fully static (built with Swift's Static Linux SDK) and runs on any
  distribution, including Debian 12, Ubuntu 22.04, Ubuntu 25.10 and 26.04 and Alpine. 1.0.0's binary
  needed glibc 2.38 or later and the system's libcurl and `libxml2.so.2`.

## [1.0.0] - 2026-11-05

Initial release.

[Unreleased]: https://github.com/anthonytw/sempere/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/anthonytw/sempere/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/anthonytw/sempere/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/anthonytw/sempere/releases/tag/v1.0.0
