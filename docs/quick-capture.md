# Quick voice notes

One tap starts a voice note: from a Lock Screen or Home Screen widget, the
Control Center control (also offered to the Action button), or Siri and
Shortcuts ("Record a Sempere voice note"). Stopping it seals the audio into
the vault's inbox, encrypted. The vault is not unlocked and Face ID is not
asked; the device may even be locked. The next time the vault is unlocked on
any device, each voice note becomes a note in the inbox notebook ("Inbox",
configurable), titled with its date and time, holding the recording and,
when it is ready, its transcript. Format: `format.md` §11. Code: core
`Sources/Sempere/CaptureInbox.swift`, CLI `sempere inbox`, app
`QuickCapture.swift`, `AppModel+Inbox.swift`, `SempereShared/` (intents) and
`SempereWidgets/` (widget extension).

## Why not "write a blob and a delta directly"

The request was to write the age-encrypted blob and a delta revision
directly, needing only the public recipients. Age encryption needs only the
recipients, but the format's integrity layer needs the vault secret:

- every revision body carries HMAC-SHA256(vaultSecret, …) (§4);
- every blob's file name is HMAC-SHA256(vaultSecret, sha256) (§8.1.2).

The secret is age-encrypted to the recipients, so a device that cannot
decrypt cannot write a valid revision or blob. There were two ways to
capture anyway:

1. **Keep the vault secret on the device, outside Face ID** (Keychain,
   readable after the first unlock), and write ordinary revisions. That gives
   whoever extracts it (a forensic dump of a phone after its first unlock,
   malware running as the app) the per-device summary and drawing caches
   (§10, §10.1). Those hold titles, recognised text and the drawings of
   recently opened notes. It also lets them forge revisions into any note.
   The caches are protected by Face ID today; this would weaken all of it.
2. **A capture key and an inbox (chosen).** The device keeps a key derived
   from the secret that can only *add voice notes to the inbox*. Captures are
   sealed into `inbox/`, and a device that can read the vault adopts them as
   ordinary revisions. Nothing a user can see changes: a capture can only be
   read by a device that can unlock the vault, and adoption happens exactly
   then.

The maintainer may prefer option 1's simpler mechanics; that is an open
question on the PR.

## Threat model

Assets: the content of voice notes (audio, transcript), the rest of the
vault, and the vault's integrity.

| Adversary | What they get |
| --- | --- |
| Storage (iCloud, a WebDAV host, a stolen backup) | Inbox files are age-encrypted to the recipients. Without the capture key they cannot add a capture that verifies. They see that captures exist, their sizes and times. A junk file costs each device one streamed pass in constant memory (the tag is checked before the file is read whole; a transcript file is bounded at about 64 MiB), and it is then not read again for an hour, doubling up to a week, while it does not change (`format.md` §11.2). |
| Storage that rewrites `vault.json` (adds its own recipient) | A capture is sealed to the capture profile's recipients only, never to the list in `vault.json`, and a profile is only made or refreshed from a list that checks (`format.md` §2.1): a planted recipient never receives a voice note. The app refuses to enable or refresh quick capture while the list does not check. |
| A thief with the locked device, before its first unlock after boot | Nothing. The profile is a Keychain item readable only after the first unlock, and audio on disk (a recording interrupted by a crash or a restart) is protected until the first unlock. |
| Someone holding the locked device after its first unlock | They can record voice notes from the Lock Screen widget, Control Center, the Action button or Siri without unlocking (the intents need no authentication), and those notes look like the owner's. They cannot listen to any. |
| Forensic extraction after the first unlock (or code running as the app) | The capture profile: public recipients (public anyway) and the capture key. With it they can put voice notes in the inbox, under any title (at most 300 characters) and in any notebook (the manifest names both), but only as that device: since the security review of 2026-10 (C2) each profile holds its own device's capture key (`format.md` §11.1), so the note says "Voice note from <that device>" (`captured`, §8.3.1) and cannot pass as another device's, and they cannot add a transcript to another device's voice note. Removing the device's key (Keys) stops them at once (C3, next row). A profile made before attribution held the vault-wide capture key: its voice notes are shown as from an unverified device, and the app replaces it at the next unlock. They cannot read any capture, any note, or the caches, and cannot change existing notes: a transcript is bound to its capture's audio (`format.md` §11.2), which they never see. A voice note being recorded or sealed at that moment is plaintext in the app's container until it is sealed (seconds after it stops). |
| Someone using the unlocked device | They can record voice notes, which is the feature. They cannot listen to past ones without unlocking the vault. |
| A removed device (its key taken off the vault) | Removing a recipient rotates the vault secret (§3.3), so the old capture key no longer verifies. Captures already in the inbox at that moment are re-tagged and re-encrypted by the recipient change (`format.md` §3.3.1), so they are still adopted, and the removed key cannot open them any more; its later captures are reported, kept in the inbox and never adopted, also while the recipient change is unfinished (security review 2026-10, C3): a reader derives device capture keys only for devices still listed, and takes captures of the vault-wide key of the outgoing secret only in the run that rotated it. Captures it sealed before its removal are refused the same way. A removed device that held the vault key itself (not only a profile) knows the outgoing secret, and can seal voice notes attributed to a listed device until that rewrap finishes, as it can tag revisions (`format.md` §3.3.1). The same holds for a device that is still authorized but has not unlocked the vault since the key change (its profile still has the old capture key): voice notes it records in that window stay in the inbox unadopted, readable only with the stock-CLI recipe (`format.md` §11.2). Open question: adopt them after a confirmation. Its profile also encrypts to the old recipient list: re-enable quick capture after key changes (the app refreshes the profile at every unlock and right after a key change or a migration on that device; the CLI needs `sempere inbox enable` again). |

### Plaintext audio

- While recording, `AVAudioRecorder` writes the audio to a file in the app's
  container (`Application Support/Sempere/QuickCapture/<id>/`, not backed up).
  It is protected `completeUntilFirstUserAuthentication`: unreadable before
  the device's first unlock after boot, readable afterwards while the device
  is locked. Not `completeUnlessOpen` (what in-note recordings use): its files
  can be written while locked but not reopened once closed until the device is
  unlocked, and a voice note started and stopped on the Lock Screen is
  assembled from its closed segment files and read back to be sealed before
  any unlock; it would fail to seal, and the voice note would be lost.
- On stop, the audio is read into memory, sealed (age, to the recipients),
  and written to the vault inbox or the queue.
- If transcription is on, the transcript is made on device from that file
  (SpeechTranscriber, else SFSpeechRecognizer on device only; never a server)
  and sealed the same way.
- The folder is deleted right after. If the system's background time runs
  out first, the folder is kept rather than losing the voice note: a resumed
  app finishes sealing and deletes it; a terminated one (or a crash) leaves
  it until the next launch, when it is sealed (from the finished 10-minute
  segments) and deleted.
- The transcript's plaintext lives in memory only.

So no plaintext audio stays on disk beyond the capture itself plus the
seconds it takes to seal and transcribe it, except after a crash or a
termination before sealing finished: then until the next launch.

## Delivery and queueing

The sealed files are written to `<vault>/inbox/` through the vault's bookmark,
as a coordinated write in iCloud Drive. iCloud Drive accepts writes offline
and uploads them later. When the folder cannot be reached (the bookmark is
stale, the folder was moved, it is another vault), the files go to a local
queue (`Application Support/Sempere/CaptureQueue/<vaultId>/`, already
encrypted). They move into the vault when the app becomes active and when
the vault opens. A vault whose `vault.json` says it was written by a newer
version (`format.md` §7.3) is read-only for this one: voice notes for it go
to the queue too, and stay there until an updated app (or one that can write
it again) flushes them; neither delivery nor the queue writes into its
`inbox/` (`QuickCapture.acceptsCaptures`).

## Transcription

Voice notes are transcribed on device as they stop, when "Transcribe Voice
Notes" is on (the default once quick voice notes are on). If that cannot
finish (no time in the background, no model yet), the note is transcribed
after adoption, the next time the vault is unlocked on a device with
transcription on. That transcript goes through the normal path: a blob, then
`setRecording`.

## Surfaces

| Surface | How |
| --- | --- |
| Siri, Shortcuts | `StartVoiceNoteIntent` (an `AudioRecordingIntent`) and `StopVoiceNoteIntent`, phrases in `VoiceNoteShortcuts` |
| Action button | Any of the above, or the control |
| Control Center | `VoiceNoteControl` (`ControlWidget`, iOS 18+): records when ready, stops while recording, opens the setup otherwise |
| Lock Screen, Home Screen | `VoiceNoteWidget` (circular, rectangular, small): the same three actions |
| While recording | `VoiceNoteLiveActivity`: pulsing record dot, elapsed time and a large Stop, on the Lock Screen and in the Dynamic Island (required for `AudioRecordingIntent`); then where the voice note went |
| In the app | `VoiceNoteBanner`: a red bar with the time and Stop at the top of the window (library and note windows, and the unlock and Settings sheets; on a Mac too) while recording, then where the voice note went |
| Mac | Menu-bar item (`StatusItemHost`, an AppKit bundle: Quick Voice Note, New Note, Open Sempere; Settings → General → Show in Menu Bar), File > Start / Stop Voice Note (⇧⌘M, `VoiceNoteMenu`), Shortcuts and Siri; no widgets or Live Activity in the Catalyst build. Quick voice notes without unlocking work as on the iPad: sealed with the capture profile, the vault stays locked. |
| CLI | `sempere inbox enable`, `capture`, `transcript`, `list`, `import` (`docs/cli.md`) |

The intents live in `Apps/Sempere/SempereShared/`, which both the app and
the widget extension compile. They always run in the app's process
(`AudioRecordingIntent`, `LiveActivityIntent`); the extension only shows
buttons.

The Live Activity belongs to the process that started it, but iOS keeps it
across app restarts and reboots. A new process cannot reach the old
recording, so it ends every voice note Live Activity that started before it
launched. Stop on an activity it does not know also ends it, without an
error. `start()` claims the recorder before its first suspension, so two
intents firing together cannot start two recordings. With Live Activities
off, iOS ends an intent's recording, so `start()` refuses with an
explanation (also shown in Settings).

## What the widgets and the control show

The widget extension cannot ask the app anything, so the app writes a small
status (`VoiceNoteStatus`, `SempereShared/VoiceNoteStatus.swift`) into the
App Group container `group.io.github.anthonytw.sempere` after every change
(recorder state, quick voice notes turned on or off, the app becoming active,
Live Activities switched in Settings) and reloads the widgets
(`WidgetCenter`) and the control (`ControlCenter`) when it changed. The
status holds only the phase and the start time of a recording in progress: no
key, no vault, no note.

The control has one action, `VoiceNoteControlIntent` (a control's template
cannot switch on its value): it decides when tapped, from the app's live
state, whether to record, stop, or continue in the app (iOS 26
`continueInForeground`). The widgets switch their button per state.

| Phase | Shows | A tap |
| --- | --- | --- |
| Not set up | mic slashed, "Set Up Voice Notes" | opens the app at Settings ▸ Quick Voice Notes (`sempere://quick-voice/settings`; the control's `VoiceNoteControlIntent` continues in the app) |
| Live Activities off | mic slashed, "Live Activities Off" | the same; the section explains and links to the app's page in Settings |
| Ready | mic | records (`StartVoiceNoteIntent`) |
| Recording | stop, the elapsed time | stops and saves (`StopVoiceNoteIntent`) |
| Saving | "Saving Voice Note" | opens the app at the banner |

The file is protected until the first unlock after boot. Before it, the
extension cannot read it (and nothing can record: the capture profile is a
Keychain item readable only after the first unlock), and the widget shows
the plain mic button. The widget uses only system symbols and is marked
`unredacted()`: the placeholder iOS shows before the first unlock is
otherwise redacted to an empty grey box (build 7). Without the App Group (an
unsigned build) the widgets show the plain mic button, as before.

A stale status cannot trap anyone: the app rewrites it at launch, and Stop on
a recording the process does not know ends the orphaned Live Activity quietly
(#106).

## After Stop

The Live Activity shows "Saving" while the audio is sealed, then, as soon as
the sealed file is in the inbox (before any transcript), "Saved to Inbox"
("Saved on This Device" when it went to the queue, "Not Saved" on failure),
and is dismissed 5 seconds later (12 for a failure). The app's banner says
the same when the app is open. Opening the app from the Live Activity
(`sempere://quick-voice/recording`) lands on the banner. Any other `sempere:` URL is
ignored (`VoiceNoteLink.route`): anyone can open one, and it is never taken
for a vault.

## Not verified yet

- On a device: the Lock Screen path (intent launch while locked, Keychain
  after first unlock, writing to an iCloud Drive folder while locked, the
  Live Activity).
- The widget extension's code signing in a TestFlight build: it needs the
  bundle id `io.github.anthonytw.sempere.widgets` (automatic signing creates
  it).
- The App Group `group.io.github.anthonytw.sempere` on both the app and the
  widget extension (`SempereiOS.entitlements`, `SempereWidgets.entitlements`):
  automatic signing should register it; if the group is missing from a
  provisioning profile, the widgets fall back to the plain mic button.
- On a device: the control and the widgets switching between Set Up, record
  and Stop; the Live Activity's pulse, its final "Saved to Inbox" state and
  its dismissal; the Lock Screen widget after a reboot, before the first
  unlock.
