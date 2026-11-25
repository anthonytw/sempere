# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the CLI's
version (`Sources/SempereCLI/Version.swift`) follows [Semantic Versioning](https://semver.org/).
The section for a version is the body of its GitHub Release (`docs/releasing.md`).

## [Unreleased]

## [1.4.0] - TODO(user): release date (YYYY-MM-DD)

### Added

- iCloud (CloudKit) sync target: the sync engine now talks to your private iCloud database. On a Mac, `sempere store target add VAULT --cloudkit` adds it, and the macOS command-line tool ships as a signed and notarized `sempere.app` bundle that Homebrew links `bin/sempere` to (a build from source says that iCloud is not available).
- iCloud (CloudKit) in the app: Sync Targets lists iCloud (CloudKit) first when you add a target, and the welcome list has Open from iCloud…, which finds the vaults in your Apple Account by name, copies one onto this device and keeps it syncing. A device that has a vault but no iCloud target for it suggests the target once. New Vault can sync with iCloud from the start, and offers it in place of a folder in iCloud Drive.
- The status of an iCloud target says what is wrong and what to do: iCloud storage full, signed out, restricted, another Apple Account (Use This Account), data deleted in iCloud settings or gone (Upload Again), or an update needed. Failures that heal by themselves stay out of the bar and show in Vault Details, which also shows the zone's size and Delete from iCloud…. A vault whose only copy besides this device is iCloud explains why to keep a backup too. Everything is in Spanish too.
- `sempere cloudkit list`, `open` and `delete` do what the app's iCloud screens do; `sempere store info` shows an iCloud target's size.

## [1.3.0] - 2026-11-23

### Security

The release audit for 1.3 ([report](https://github.com/anthonytw/sempere/blob/main/docs/audits/2026-11-1.3.md)) found
nothing in released versions except a dependency note: the swift-crypto package that 1.2.0 shipped is covered by
published advisories for code that Sempere never calls, so it is not exploitable, and 1.3.0 updates it. The audit's other
findings, including two Medium ones about what a note shared without dates still carried, were in code that no release
had contained, and they were fixed before this release.

### Added

- Ask your notes: type a question in the search field's new Ask mode (Edit ▸ Find ▸ Ask Your Notes… on the Mac,
  ⌥⌘F) and get a short answer written on your device by Apple's on-device model from your notes, with the notes
  it came from listed under it and numbered buttons that open them at the page. Without Apple Intelligence or Note
  Insights you still get the best-matching notes and passages. Nothing is stored or sent anywhere.
  `sempere ask "question"` does the same on the command line. A question in another language than your notes
  (Spanish about English notes) is translated on the device to find them, and the answer comes back in the
  question's language; after translation, numbers, dates, codes and names are checked against your notes again, so a
  sentence that changed one of them is dropped (a changed negation or common word is not caught).
- Note list: Select mode can now Move To a notebook, Delete (to Recently Deleted, with a confirmation) or Restore
  all the selected notes at once, from the toolbar, the context menu or the Mac menu bar, each as one undo step that Redo can bring back (dragging notes onto a notebook in the sidebar can be redone too).
- CLI: `notes delete` and `notes undelete` take several notes in one command.
- Saved tools: save a pen or highlighter setup (ink, color, exact width, opacity) under a name and pick it with one tap
  from the palette on iPad, iPhone and Mac, or on the Mac with Control-Command-1 to 9 from Tools ▸ Saved Tools. They
  follow you across devices through the vault's shared settings (Settings ▸ Writing ▸ Saved Tools).
- `sempere tools list|add|edit|remove|move|export|import`: manage saved tools from the command line and share a pen set
  as a small `sempere-tools/1` file.
- Note Insights: Settings ▸ Note Insights ▸ Insight Language chooses the language of generated summaries and voice-note
  titles: Same as Note (the default) or one fixed language for the whole vault. Choosing one makes summaries, titles and
  topic summaries be made again in it, a few at a time, on every device; keywords stay as the notes have them.
  `sempere settings set insights.language es` does the same from the command line.
- Share a note as a web page: File ▸ Export ▸ Web Page (Encrypted)… (and `sempere share`) makes one note into a single file, encrypted
  with a passphrase, that opens in any web browser with nothing to install and nothing uploaded. Send the file and the passphrase
  by different ways; the note is flattened to its current state (no history, other notes or keys), pictures lose their location and
  camera data, and recordings, tags, the notebook and dates are included only if you ask. `sempere share --verify` checks a file
  against the release.
- Spotlight: an opt-in switch (Settings > Spotlight, off by default, per vault and per device) shows note titles,
  notebooks, tags and dates in Spotlight search, and a second switch, Include Note Text, adds the text of notes. Items
  are removed when you turn it off, delete a note, change the vault's keys, remove a device or remove the vault, and a
  result opens the note. Spotlight's index is outside the vault's encryption; the switches say so.
- CLI: `sempere spotlight plan` lists exactly what the Spotlight switches would donate.
- Recordings: the Recordings menu of a note has Transcribe Again, which transcribes every recording of the note again in
  a language you choose (Automatic, or any language the speech recognizer supports), replacing the old transcripts, with
  Also Redo Insights to make the note's summary and title again from the new text. `sempere transcribe NOTE --again
  --language es-ES --insights` does the same from the command line, and `sempere transcribe --languages` lists the
  languages. Each recording's Transcribe and Transcribe Again offer the same choices, and All Recordings has Transcribe
  All Again.
- CLI: `sempere vault conflicts` reports whether iCloud Drive holds a vault folder as a package and lists the
  folder's conflict versions with the files only they hold; `--merge` copies back the missing write-once files
  (each checked under the vault's key, quarantined if it fails, nothing overwritten) in one write of the folder,
  settles `settings.age` and `vault.json` by the usual rules, never judges a version it cannot list whole, then marks
  the versions resolved and, once everything is merged, clears the Finder's bundle flag.
- Sync Targets warns when iCloud Drive syncs a sync folder as one package or keeps conflicting versions of the
  whole folder, with the steps to move to a plain folder.
- CLI: `sempere notes revisions NOTE` lists every revision file of a note with its ops, stamps and devices, the
  revisions that do not read here (set aside, pending, unreadable) and which revision set the deleted flag, to tell
  why a deleted note came back (or went away) on a device.

### Changed

- Note Insights: any device that can do the work now does it. There is no longer a "Map and Titles Device" to pick:
  a device with Apple Intelligence makes the summaries and keywords no device has made yet, a device with the embedding
  model makes the vectors no device has and rebuilds the map of related notes when it is due, and any device names voice
  notes. Maps built at the same time are identical, and a summary or title made on two devices at once settles to the
  same one everywhere. A device whose embedding numbers drift from the map's keeps its vectors to itself and never
  writes the shared set. Settings ▸ Note Insights lists each device and what it can do.
- Settings ▸ Note Insights: changing the summary and title language asks first, and says how many summaries and titles will be made again.
- Voice notes with no title of their own are named by the title the list shows (the derived one, else "Voice note" and the date) in Spotlight, export file names, `sempere` note lookups by title, the web viewer and shared web pages (which carry the capture time only when they include dates), and that default title no longer counts as a word of the note in Ask.
- Changing the voice-note title format makes the titles again in the new format.
- Web viewer: a quick voice note with no title of its own is listed as in the app, under the title Note Insights
  derived for it or "Voice note" with the capture's date and time, instead of "Untitled". The published summaries
  (`sempere vault summaries`, `sync webdav --web-viewer`) now carry that title inside the encrypted file, and are
  rewritten when a derived title arrives.
- Voice notes: a quick voice note, from your iPhone or your Apple Watch, no longer gets a title written into it.
  Until you give it one, the list and the editor show "Voice note" (or "Watch voice note") with its date and time, in
  your language and the time zone it was recorded in, and Note Insights' generated title (from the transcript) is kept
  beside the note instead of replacing its title, so it follows the note's text and a title you type is always the one
  shown. Notes from earlier versions keep the titles they have, and still get a generated title while their title is
  the default one. Update every device that shares the vault to 1.3: a device still on 1.2 keeps writing generated
  titles into notes and shows a blank title for new voice notes.
- The sync bar at the bottom of the note list now appears only when something is wrong (a refused password or
  certificate, a sync folder gone or not writable, files that failed, a device-list conflict, an upload problem that
  lasts, a sync target that could not be reached for a week while the device was online). Syncing, synced, offline
  and waiting for iCloud show no bar; each target's status stays in Sync Targets….
- Export: the share sheet (with Save to Files) opens as soon as the file is made, once per export, and not when
  something was left out, so that list stays in view. A web page's Copy Passphrase button shows Copied after a tap.
- Sync: a new folder sync target is now named “<vault>.sempere-vault” instead of “<vault>.sempere”: iCloud Drive
  kept `….sempere` sync folders as packages on some accounts, even new ones, and synced the whole vault as one item.
  The new extension is declared a plain folder (never a package), and Sempere opens a `….sempere-vault` folder like a
  `….sempere` one. A folder that holds the vault is taken as the target whatever its name, and a folder picked to hold
  the copy joins the vault's copy already in it whatever that copy is named (two copies there are refused with a
  request to choose one). Existing `….sempere` targets keep working unchanged, and the vaults kept in the app stay
  `….sempere`. Update every device of a vault to 1.3 before adding a `….sempere-vault` folder on any of them. The
  CLI's `store target add --folder` follows the same rule.

### Removed

- Note Insights: the map and titles device setting and `sempere insights work-device`. The old setting is deprecated: a
  settings file that still holds it stays valid and the value is ignored.

### Fixed

- iPad: a tap on a notebook that holds sub-notebooks opens it again instead of only folding it; the
  chevron at the end of its row folds and unfolds its sub-notebooks, as on the iPhone.
- Sidebar (Mac): a click on a notebook that holds sub-notebooks opens it instead of only unfolding it. The chevron at
  the end of its row folds and unfolds the sub-notebooks, as on the iPhone and iPad, and → and ← still unfold and fold
  the selected notebook.
- Notes: a transcript Sempere writes by itself, when a voice note arrives or finishes, or when you use Transcribe, no
  longer moves the note's modified date or its place in the list sorted by Modified; only your own edits do. (A
  generated voice-note title never touches the note any more either.)
- Notes: deleting, renaming or moving notes while the daily cleanup of old versions runs is written at once. The cleanup
  held every edit until it had gone through the whole vault, so notes deleted meanwhile could come back if the app was
  closed or suspended before it finished.
- Apple Watch: a note your iPhone holds without a vault yet (saved under an old key, or while "Use on Apple Watch" was
  off) now stays on the watch until you add or delete it on the phone, so deleting and reinstalling the iPhone app no
  longer loses it; the watch sends it again after the reinstall.
- Apple Watch: after an iPhone restart, before the first unlock, or when the held-notes folder cannot be read, the phone
  no longer tells the watch it holds nothing, so the watch keeps its copies.
- Devices: voice notes this device saved under its earlier key, before it was removed and joined again, are now re-sealed
  under the new key instead of being retried at every write (only keys this device itself held, which it now remembers
  from this version on); a note no key this device held can open is given up on once and left in the inbox.
- New Vault: Copy Key puts the recovery key on the clipboard where other apps can paste it (it was stored under a
  type they did not read, so it said Copied and pasted nothing). A Copy from the share sheet copies the key too,
  without closing the Vault Created screen.
- Welcome list (iPhone and iPad): Delete from This Device… on a vault stays open while its sync runs; the revealed
  swipe button and the confirmation no longer close by themselves, so one swipe and one tap delete the vault.
  Canceling it after a swipe no longer hides the vault or shows the wrong vaults, and a second swipe no longer locks
  the list. The same goes for removing a WebDAV vault that is still joining, and for the device list's swipe Remove.
- Sync: a vault in iCloud Drive no longer reads "Synced" while iCloud has not uploaded this device's changes. Every file
  the sync wrote counts (settings, device records and summaries too), a file iCloud has not taken in yet waits, and the
  count is checked again between syncs, so the status returns to Synced when iCloud is done. A slow upload is not taken
  for full storage: an upload error shows only once it has lasted about ten minutes, and "storage is full" only when
  iCloud says so. `sempere sync folder` says how many files iCloud has not uploaded yet.
- Sync: a Finder bundle flag on a vault or sync folder that cannot be cleared is now logged instead of failing
  silently, and `store sync` / `sync folder` warn about a target folder held as a package.
- Backup reminders: cancelling a pending reminder no longer runs a blocking notification-center call on the main
  thread (it stalled the app for over a minute after a fresh boot); cancels and schedules now run off the main
  thread, in order.

## [1.2.0] - 2026-11-18

### Security

The release audit for 1.2 ([report](https://github.com/anthonytw/sempere/blob/main/docs/audits/2026-11-1.2.md)) found
one issue in released versions, rated Low: since 1.0.0, after a re-encryption, a sync could download every device's
published summaries file again on every run without counting it against the run's download limit, so a storage host
could make a run download more than the limit allows. It is fixed in this release. The audit's other findings were in code that no release had
contained, and they were fixed before this release.

### Note Insights

Note Insights is new (Settings ▸ Note Insights; off until you turn it on). It makes a short summary, keywords and related
notes for each note on your devices only, with Apple's on-device model, and stores them encrypted in the vault.

- Open a note's insights from its More menu or the note list's context menu. Search also finds notes by their summaries
  and keywords.
- A map of related notes (All Notes' menu, or Settings ▸ Note Insights ▸ Map of Related Notes): notes sit in labeled
  groups that split into smaller ones as you zoom in, lines join related notes, and a tap opens a note. Notes this device
  placed itself are dashed, and a device that has to build its own map says so. A list form shows the same groups for
  VoiceOver and small screens.
- Topic summaries: "Summary" on a notebook or tag with at least 3 summarized notes shows a generated paragraph and the
  notes to check it against, marked when those notes changed. They are made in the background at most once a day each,
  and Regenerate makes one now.
- Every device with Apple Intelligence makes summaries (an iPhone or iPad while charging, or at once with Process Now,
  which says why when there is nothing to make). A new quick voice note gets its summary as soon as it is transcribed,
  also on battery, unless you choose "Only while plugged in" (Settings ▸ Quick Voice Notes). Regenerate in a note's
  insights makes them again for that note.
- When Apple Intelligence is not ready, Note Insights says it may still be downloading or that its language may not
  match the device's language and region (they must match exactly, region included), and How to Fix lists the steps. One device also builds the map and names quick voice notes from their
  transcripts in a format you choose; another takes over if it is not seen for 14 days.
- Turning it off deletes the insights on every device.
- On the command line, `sempere insights` makes them (macOS 26 with Apple Intelligence), and reading them (`show`,
  `related`, `search`, `status`, `map`, `topic --list`) works on Linux too. `sempere insights purge` turns it off and
  deletes them.

### Joining a device

- Both screens now show the six words, and you tap They Match after comparing all six instead of typing them. Typing the
  words and scanning the code stay under "Type the words instead". Tapping is as safe as typing only if you compare all six
  words.
- Add Device warns when two or more devices are asking to join, and They Match waits 1.5 seconds after the words show.
- Add Device keeps one handshake place per remote address, so a device that opens connections very fast ends only its
  own, never the others'.

### Make a Copy

File ▸ Make a Copy… (and a button in the banner of a read-only vault) copies a vault's notes, as they are now, into a new
vault of your own with its own recovery key, attachments and recordings included. It works for a vault opened with its
recovery key, one from a newer version, or one whose device list this device could not confirm, and the copy can be
changed. `sempere store copy` does the same on the command line.

### Apple Watch

- The iPhone holds at most 20 files or 50 MB of Watch notes that can only be deleted (for a vault or key it never held),
  inside the general limit, so a watch sending those cannot use up the room for notes you can add. A file left in the held
  folder without its record is removed after a day. `sempere inbox watch held summary` shows the count per reason, the
  limits and what it removed (`held list --json` is unchanged).
- Recordings the watch cannot place (another vault's, or one whose manifest names none) are no longer silent: the watch
  says "N recordings could not be placed", with Delete. Nothing is deleted by itself.
- Notes held for a reason that has since cleared (the iPhone listed again, or the vault now on the iPhone) go in by
  themselves. Notes sent while Use on Apple Watch was off, or sealed before the vault's key changed, still wait for you,
  and Settings shows why each one is held now. Held Watch notes are kept only on this iPhone, and Settings says so.
- A watch that asks for a profile while Use on Apple Watch is off (after Sempere was reinstalled on the iPhone) is cleared.
- The watch checks with the iPhone at each launch, so after Sempere is reinstalled on the iPhone and Use on Apple Watch is
  turned on again, the watch gets the current profile by itself instead of sending notes that are held (Reset on the
  watch was the way out).

### Fixed

- Apple Watch: after a device was removed (or the vault's key changed another way), every Watch note was held in
  Settings ("The vault has a newer key than this device"), and reinstalling did not help. The quick voice notes profile
  now takes the new key's epoch with the key; a device in that state is repaired at the next unlock, and the watch gets
  the repaired profile. Notes already held for this reason can be added in Settings ▸ Quick Voice Notes. Voice notes
  recorded in that state no longer make each write retry a catch-up that could not finish (`sempere vault catch-up`
  reports them as `relabeled`).
- Turning Quick Voice Notes off and on again keeps your Transcribe Voice Notes choice.
- Quick voice notes recorded on the iPhone or iPad (Lock Screen, Control Center, widgets, Siri) were never named from
  their transcripts: their default title had the date in the device's language, which Note Insights did not recognize.
  New ones are titled "Voice note 2026-11-16 14:32" (the words in your language), and the older ones are recognized too.
- Sync: a revision this device wrote before 1.1.0 and left cut on a server that lists no file sizes is now found and
  replaced (one bounded check per revision, remembered in the sync state).
- Sync: after a re-encryption, a sync no longer downloads every device's published summaries file again on every run,
  and those downloads count against the run's download limit.
- Linux CLI: a WebDAV upload cut by a connection reset on a kept-alive connection failed after the 60-second idle
  timeout; it now fails at once (or is retried with its whole body), and a reset counts as a lost connection.

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

[Unreleased]: https://github.com/anthonytw/sempere/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/anthonytw/sempere/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/anthonytw/sempere/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/anthonytw/sempere/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/anthonytw/sempere/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/anthonytw/sempere/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/anthonytw/sempere/releases/tag/v1.0.0
