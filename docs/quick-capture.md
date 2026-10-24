# Quick voice notes

One tap starts a voice note: from a Lock Screen or Home Screen widget, the
Control Center control (also offered to the Action button), or Siri and
Shortcuts ("Record a Sempere voice note"). Stopping it seals the audio into
the vault's inbox, encrypted. The vault is not unlocked and Face ID is not
asked; the device may even be locked. The next time the vault is unlocked on
any device, each voice note becomes a note in the inbox notebook ("Inbox",
configurable), titled with its date and time, holding the recording on its
page (the card a recording made in a note gets, `format.md` §11.3) and, when
it is ready, its transcript in that card. Format: `format.md` §11. Code: core
`Sources/Sempere/CaptureInbox.swift`, CLI `sempere inbox`, app
`QuickCapture.swift`, `AppModel+Inbox.swift`, `SempereShared/` (intents) and
`SempereWidgets/` (widget extension).

## Why a capture key and an inbox

Age encryption needs only a public key (the vault identity's `v_e`, §15.2),
but the format's integrity layer needs the vault key `K_e`:

- every revision body carries HMAC-SHA256(tagKey, …) (§4);
- every blob's file name is HMAC-SHA256(blobNameKey, sha256) (§8.1.2);

both keys derived from `K_e`, which `vault.json` wraps only to listed keys, so
a device that cannot unwrap it cannot write a valid revision or blob. Two
designs allow capture anyway:

1. **Keep the vault key on the device, outside Face ID** (Keychain,
   readable after the first unlock), and write ordinary revisions. Whoever
   extracts it (a forensic dump of a phone after its first unlock, malware
   running as the app) would get the per-device summary and drawing caches
   (§10, §10.1), which hold titles, recognized text and the drawings of
   recently opened notes, and could forge revisions into any note. The
   caches are otherwise protected by Face ID.
2. **A capture key and an inbox (used).** The device keeps a key derived
   from `K_e` that can only *add voice notes to the inbox*, and `v_e`. Captures are
   sealed into `inbox/`, and a device that can read the vault adopts them as
   ordinary revisions. A capture can only be read by a device that can
   unlock the vault, and adoption happens exactly then.

## Threat model

Assets: the content of voice notes (audio, transcript), the rest of the
vault, and the vault's integrity.

| Adversary | What they get |
| --- | --- |
| Storage (iCloud, a WebDAV host, a stolen backup) | Inbox files are age-encrypted to the vault identity. Without the capture key they cannot add a capture that verifies. They see that captures exist, their sizes and times. A junk file costs each device one streamed pass in constant memory (the tag is checked before the file is read whole; a transcript file is bounded at about 64 MiB), and it is then not read again for an hour, doubling up to a week, while it does not change (`format.md` §11.2). |
| Storage that rewrites `vault.json` (adds its own key) | A capture is sealed to the capture profile's `v_e` only, never to anything read from `vault.json`, and a profile is only made or refreshed from a `vault.json` that checks (`format.md` §2.1): a planted key never receives a voice note. The app refuses to enable or refresh quick capture while the list does not check. |
| A thief with the locked device, before its first unlock after boot | Nothing. The profile is a Keychain item readable only after the first unlock, and audio on disk (a recording interrupted by a crash or a restart) is protected until the first unlock. |
| Someone holding the locked device after its first unlock | They can record voice notes from the Lock Screen widget, Control Center, the Action button or Siri without unlocking (the intents need no authentication), and those notes look like the owner's. They cannot listen to any. |
| Forensic extraction after the first unlock (or code running as the app) | The capture profile: `v_e` (a public key) and the capture key. With it they can put voice notes in the inbox, under any title (at most 300 characters) and in any notebook (the manifest names both), but only as that device: each profile holds its own device's capture key (`format.md` §11.1), so the note says "Voice note from <that device>" (`captured`, §8.3.1) and cannot pass as another device's, and they cannot add a transcript to another device's voice note. Removing the device (a new epoch, key hierarchy KH3) stops them (next row). They cannot read any capture, any note, or the caches, and cannot change existing notes: a transcript is bound to its capture's audio (`format.md` §11.2), which they never see. A voice note being recorded or sealed at that moment is plaintext in the app's container until it is sealed (seconds after it stops). |
| Someone using the unlocked device | They can record voice notes, which is the feature. They cannot listen to past ones without unlocking the vault. |
| A removed device (key hierarchy KH3) | Removing a device starts a new epoch with a new vault key, so the old capture keys no longer verify, and a reader derives device capture keys only for devices still listed: its later captures are set aside, kept in the inbox and never adopted. Captures already in the inbox at that moment are sealed by the removal and adopted (`docs/design/key-hierarchy.md` §5.7). A still-listed device whose profile is of an older epoch records each voice note in its write ledger before placing it, and re-seals it under the current key at its next unlock (`format.md` §15.14 "Catch-up"); its profile is then made again. A device that learns it was removed (unlisted, key-hierarchy design §5.5) marks its profile `suspended`: a start is refused ("removed from the vault's device list"), while a recording in progress, leftovers and the queue are still sealed and recorded in the write ledger, so the unlisted screen's Save Files keeps them; listed again, the suspension is lifted. |

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
- On stop, the audio is read into memory, sealed (age, to the vault identity),
  and written to the vault inbox or the queue.
- If transcription is on, the transcript is made on device from that file
  (SpeechTranscriber, else SFSpeechRecognizer on device only; never a server)
  and sealed the same way.
- The folder is deleted right after, and only once the sealed audio is in
  the inbox or the queue, or when no segment holds any audio (not a byte, or
  only finished files of no length): a voice note whose audio was not sealed
  into an inbox file is never deleted. Every
  `segment-NNN.aac` (`segment-NNN.m4a` from build 6 and earlier) in the folder is sealed, also one the recording's
  manifest does not name yet (begun just before the app died), and a folder
  whose manifest is missing or does not decode is sealed from its segment
  files under the id it is named by. Kept, and the "Not Saved" message says
  so: a segment that is there but cannot be read yet (data protection), a
  complete segment that does not decode, bytes of which nothing decodes (the
  app died during the first segment, whose file is unfinished), a profile
  that cannot be read at the stop, a seal or write that fails. Only an
  unfinished last segment that does not decode is left out of a voice note
  sealed from the others (a crash loses at most the segment being written,
  `attachments.md` §13). If the system's background time runs out first,
  the folder is kept rather than losing the voice note: a resumed app
  finishes sealing and deletes it; a terminated one (or a crash) leaves it
  for the sweep. The sweep (`QuickCapture.sweep`) runs at launch and each
  time the app becomes active (one at a time); a profile or a manifest it
  cannot read yet (before the first unlock after a restart) leaves the
  folder for the next one. Without a profile (quick voice notes were turned
  off) nothing can seal it, and it is deleted.
- The transcript's plaintext lives in memory only.

So no plaintext audio stays on disk beyond the capture itself plus the
seconds it takes to seal and transcribe it, except after a crash or a
termination before sealing finished: then until the app next starts or
becomes active and can read it. Audio that cannot be sealed at all (nothing
in it decodes) stays, protected, until quick voice notes are turned off.

### Restarts, force quits and crashes

Segments are AAC in ADTS (`segment-NNN.aac`, `QuickCapture.segmentExtension`), merged into one MPEG-4
file when the voice note is sealed. ADTS frames each stand alone, so a segment the recorder never
finished (the iPhone restarted, the app was force quit or crashed) is readable up to its last frame.
Build 6 recorded MPEG-4 segments of up to ten minutes, whose index is written only when the recorder
finishes the file: a voice note cut off by a restart did not decode at all, was kept "for later" and
never became a note, and nothing said so (TestFlight 1.0.0 (6), iPhone). Apple Lossless, which ADTS
cannot carry, records as AAC for quick voice notes.

The sweep that saves such a recording runs at launch, each time the app becomes active, when protected
data becomes available (the first unlock after a restart, in a process Siri launched before it), and when
Stop is pressed on a Live Activity whose recording the process does not have. The banner says
"Interrupted Voice Note Saved", or "Interrupted Voice Note Not Saved Yet" (once per launch) when it is kept.

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
| Control Center | `VoiceNoteControl` (`ControlWidget`): records when ready, stops while recording, opens the setup otherwise |
| Lock Screen, Home Screen | `VoiceNoteWidget` (circular, rectangular, small): the same three actions |
| While recording | `VoiceNoteLiveActivity`: pulsing record dot, elapsed time and a large Stop, on the Lock Screen and in the Dynamic Island (required for `AudioRecordingIntent`); paused by an interruption (a call, a headset unplugged), "Paused" with the time standing still; then where the voice note went, with the length of the audio |
| In the app | `VoiceNoteBanner`: a red bar with the time and Stop at the top of the window (library and note windows, and the unlock and Settings sheets; on a Mac too) while recording, then where the voice note went |
| Mac | Menu-bar item (`StatusItemHost`, an AppKit bundle: Quick Voice Note, New Note, Open Sempere; Settings ▸ General ▸ Show in Menu Bar), File ▸ Start / Stop Voice Note (⇧⌘M, `VoiceNoteMenu`), Shortcuts and Siri; no widgets or Live Activity in the Catalyst build. Quick voice notes without unlocking work as on the iPad: sealed with the capture profile, the vault stays locked. |
| CLI | `sempere inbox enable`, `capture`, `transcript`, `list`, `import` (`docs/cli.md`) |

### Siri phrases

Say "Sempere" in the phrase: Apple requires the app's name in every App
Shortcut phrase, and a phrase without it ("record a voice note") goes to
Apple's own apps. The Sempere phrases also have to be allowed: Siri on, Sempere's
options on in Settings ▸ Apps ▸ Sempere ▸ Siri, and Siri left on for Sempere's
shortcuts in the Shortcuts app (its Sempere entry, ⓘ). The exact toggle names
change between iOS versions; check them on a device. The phrases are in `VoiceNoteShortcuts`; each English phrase has one Spanish
phrase in `AppShortcuts.xcstrings` (`LocalizationCatalogTests` checks that every
phrase has its Spanish one and that no two read the same).

| Start (English) | Start (Spanish) |
| --- | --- |
| Record a Sempere voice note | Graba una nota de voz en Sempere |
| New Sempere voice note | Nueva nota de voz en Sempere |
| Start a Sempere voice note | Empieza una nota de voz en Sempere |
| Sempere voice note | Nota de voz de Sempere |
| Record in Sempere | Graba en Sempere |
| Record with Sempere | Graba con Sempere |
| Record voice in Sempere | Grabar voz en Sempere |
| Record a voice note in Sempere | Grabar una nota de voz en Sempere |
| Record a voice note with Sempere | Grabar nota de voz con Sempere |
| Take a voice note in Sempere | Toma una nota de voz en Sempere |
| Voice note in Sempere | Nota de voz en Sempere |
| Start recording in Sempere | Empezar a grabar en Sempere |
| Dictate in Sempere | Dictar en Sempere |
| Dictate a note in Sempere | Dicta una nota en Sempere |

| Stop (English) | Stop (Spanish) |
| --- | --- |
| Stop the Sempere voice note | Detén la nota de voz de Sempere |
| Stop the voice note in Sempere | Para la nota de voz de Sempere |
| Stop recording in Sempere | Detener la grabación en Sempere |
| Stop dictating in Sempere | Dejar de dictar en Sempere |
| Finish the Sempere voice note | Terminar la nota de voz de Sempere |
| End the Sempere voice note | Termina la nota de voz de Sempere |
| Stop Sempere recording | Deja de grabar en Sempere |

Siri matches what it heard against these phrases with some freedom, but not
against arbitrary wording: a phrase that is not listed may not work.

The intents live in `Apps/Sempere/SempereShared/`, which both the app and
the widget extension compile. They always run in the app's process
(`AudioRecordingIntent`, `LiveActivityIntent`); the extension only shows
buttons.

The Live Activity belongs to the process that started it, but iOS keeps it
across app restarts (a force quit does not end it). A new process cannot reach
the old recording, so it ends every voice note Live Activity that is not its
own recording's (`endOrphanedActivities`: at launch, each time the app becomes
active, when protected data becomes available, and for any the system reports
later through `activityUpdates` that started before the launch), and saves what
that recording left (`sweep`). Stop on an activity it does not know also ends it,
without an error, and runs the sweep. While recording, the app sends the activity
its state every 45 seconds with a stale date 2 minutes on; when the app dies the
updates stop, the activity turns stale and shows "Voice note interrupted ▸ Open
Sempere to save it" instead of a Stop that would reach nothing (TestFlight 1.0.0
(6): after a force quit the activity kept running and Stop did nothing). Whether
iOS launches a force-quit app for a Live Activity's button is not documented; the
stale state's tap opens the app, which always works. `start()` claims the recorder before its first suspension, so two
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
status holds only the phase and the timer of a recording in progress (its
start, moved later by the pauses so far, and when it paused, as on the Live
Activity): no key, no vault, no note.

The control and the widgets have one action, `VoiceNoteControlIntent` (a control's
template cannot switch on its value; the widgets copy it on purpose): it decides when
tapped, from the app's live state, whether to record, stop, or continue in the app (`continueInForeground`). The widgets used to switch their button per drawn state
(`Button(StartVoiceNoteIntent)`, `Button(StopVoiceNoteIntent)`, or a `widgetURL` that only
opens the app): a Lock Screen widget still drawn "Set Up Voice Notes" or "Live Activities Off"
from a status the system had not reloaded then opened the app and recorded nothing (TestFlight
1.0.0 (2)), while the control, deciding live, recorded. Now a tap on either decides live;
a stale label can no longer turn a tap into "open the app". The status reaches the widgets
three ways: a reload on every change, a forced reload at launch and each time the app becomes
active, and the system's half-hourly refresh (`VoiceNoteStatus.refreshInterval`).

What iOS requires of a recording intent:

- `AudioRecordingIntent`: "you must start a Live Activity when you begin the audio recording and keep it
  active as long as you record audio. If you don't start a Live Activity, the audio recording stops"
  ([AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)).
  Apple documents no ordering against the audio session; we request the activity first.
- Only a `LiveActivityIntent` may start a Live Activity with the app in the background: "your app needs to be in
  the foreground to start a Live Activity. However, you can use a `LiveActivityIntent` and start the Live Activity
  in its `perform()` method" ([LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent));
  otherwise `Activity.request` throws `ActivityAuthorizationError.visibility`. `NSSupportsLiveActivities` is set.
- Where `perform()` runs: a widget's button runs its intent in the widget extension unless it conforms to
  `LiveActivityIntent` (or `AudioPlaybackIntent`, `ForegroundContinuableIntent`, …) or opens the app; then it runs
  in the app's process, and the intent must be in the app target
  ([Adding interactivity to widgets](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)).
  `AudioRecordingIntent` alone is not on that list: both recording intents are also `LiveActivityIntent`s and
  are compiled into the app (`SempereShared/`).
- The audio session (`AudioSessionTypes.h`, iOS 27 SDK): `cannotInterruptOthers` ('!int') is "non-mixable and
  trying to go active while in the background", allowed only for the Now Playing app; `cannotStartRecording`
  ('!rec') is "usually because it is starting a mixable recording from the background"; `cannotStartPlaying`
  ('!pla') usually means no `audio` background mode. The session is `.playAndRecord`, not mixable, and the app
  has `UIBackgroundModes` `audio`. The intent exemption from those background rules is not documented further.
- `supportedModes`: `[.background, .foreground(.dynamic)]` runs in the background and may move forward;
  `continueInForeground` "attempts to transition the app to the foreground … If … it's not possible …, the
  system throws a `notAllowed` error" ([continueInForeground](https://developer.apple.com/documentation/appintents/appintent/continueinforeground(_:alwaysconfirm:))).
  Apple does not say whether it returns before the app is active.

`StopVoiceNoteIntent` is `supportedModes = [.background]`; `StartVoiceNoteIntent` and the control's intent are
`[.background, .foreground(.dynamic)]`: they go forward only when they call `continueInForeground` (setup needed,
still saving, or a background start iOS refused), never to stop. All three set
`authenticationPolicy = .alwaysAllowed`: the threat model above ("the intents need no authentication") needs the
system not to ask for a passcode or Face ID before running them from a locked Lock Screen. What the owner sees on
a record tap: the Live Activity (Lock Screen banner, Dynamic Island) and the recording indicator, and the app stays
where it was.

### When iOS refuses a background start

TestFlight 1.0.0 (3) started the recorder before the Live Activity, and every Lock Screen, Control Center and
Shortcuts start failed with `RecordingError.cannotRecord` ("SempereApp.RecordingError 0"). Build (4) asks for the
activity first and, when iOS still refuses, continues in the app; on an iPhone the control then recorded in the
app, but the Lock Screen widget opened the app and recorded nothing: the retry ran right after
`continueInForeground` returned, before the unlock made the app active, failed again, and its error went to an
intent whose surface shows none. Now (`QuickCapture.start(_:)`):

1. The background try asks for the Live Activity and keeps the answer. If `Activity.request` throws while the app is
   not active, the recorder is not started (no activity, no background recording): `liveActivityRefused`.
2. On that or `cannotRecord`, the intent continues in the app; if iOS refuses that too and the app is not in front,
   the start fails at once (`couldNotOpenApp`).
3. Otherwise it waits for the app to become active (`UIApplication.didBecomeActiveNotification`, at most 12 s,
   `foregroundWait`; `AppActivation.wait`) and tries once more. The wait and the retry run in an app-owned task, so
   cancelling the intent does not cancel them.
4. If that try fails, the banner says "Voice Note Not Recorded" with the reason and stays until dismissed.

### Start order: the audio session before the Live Activity

TestFlight 1.0.0 (6), iPhone, iOS 27.0.1, from the unified log of a Control Center tap: chronod ran
`VoiceNoteControlIntent` through BackgroundShortcutRunner, liveactivitiesd gave the app a
fake-foreground assertion, the app (launched in the background) requested the Live Activity, which
began, and liveactivitiesd invalidated the assertion at once ("reason: activityBegun"). Nine
milliseconds later `setActive` on the non-mixable `.playAndRecord` session failed in audiomxd with
"Cannot interrupt others" (-12985, '!int'), with no other audio playing, and the start continued in
the app. So a start (`QuickCapture.startRecorderOnce`) now:

1. makes the session active first, off the main thread (`AudioCaptureBackend.activateSession`), while the
   assertion holds; not mixable;
2. if iOS refuses that with the app not in front, activates it mixable (`.mixWithOthers`, which interrupts
   no one), and Recent Starts says so (`session=mixable after a refusal (…)`); a refusal of both continues
   in the app as before;
3. asks for the Live Activity;
4. starts the recorder on the active session (`begin` does not activate it again).

Build 3 started the recorder before the Live Activity and failed with `cannotRecord`; that try activated
the session and started the recorder in one step, and its error text was lost (`RecordingError 0`), so
which step failed is not known. Whether a mixable recording from the background is refused ('!rec',
"usually because it is starting a mixable recording from the background", AudioSessionTypes.h) once the
session is already active is not documented either: the Recent Starts line of a start that needed it says.

The microphone permission read in a process an intent launched in the background (Siri after a restart:
"Sempere is not allowed to use the microphone", TestFlight 1.0.0 (6)) is not taken as the user's answer:
a refusal there continues in the app (`microphoneUnconfirmed`), where the answer is fresh and the prompt
can show; in front, a refusal is `microphoneDenied`. A start before the first unlock after a restart says
to unlock once (`beforeFirstUnlock`). Recent Starts keeps the permission read (`mic=`) and whether protected
data was available (`protectedData=`) for each try; a start log written by a launch that could not read
the file is merged with it, not written over it.

### Recent starts (diagnostics)

Each start (intent or app) is kept in `Application Support/Sempere/QuickCaptureDiagnostics/recent-starts.json`
(the last 8, `VoiceNoteStartLog`, protected until the first unlock) and written to the unified log (subsystem
`io.github.anthonytw.sempere`, category `quick-capture`, every field public). For each: the source (Siri or
Shortcuts, widget or Control Center, the app), the intent's `currentMode`, the app's state, what `Activity.request`
did (started, its error, or why it was not asked), the error of the background try (Swift type, domain, code and
text; the audio system's code is named, for example `'!rec' cannotStartRecording`, with the step that failed:
`setCategory`, `setActive` or `AVAudioRecorder`), whether the app became active and after how long, the retry's
error, and the outcome. No note content, no keys, no vault name. Settings ▸ Quick Voice Notes ▸ Recent Starts
shows them (selectable text), with Clear.

Every tap that reaches Sempere is kept too (`VoiceNoteTap`, `SempereShared/VoiceNoteTapLog.swift`), whatever it
was decided to do, in `VoiceNoteTaps.json` in the App Group container (the last 12, protected until the first
unlock, so the widget extension could add to it as well) and in the unified log (`voice note tap …`): which
intent ran (`VoiceNoteControlIntent`, `StartVoiceNoteIntent`, `StopVoiceNoteIntent`) or that a widget opened the
app (below), in which process, the phase the widget or control was drawn with and the app's live phase, the
decision (start, stop, open Settings, open the banner, or `unavailable`: the app's hooks were missing), the
intent's `currentMode` when `perform()` began, the app's state, and what failed after the decision
(`continueInForeground` refused, a Stop that threw). Settings ▸ Quick Voice Notes ▸ Recent Starts lists taps and
starts together by time; Clear clears both. Build 6 kept only starts, so a tap that went on into the app or
never reached an intent left nothing.

### Widget taps that open the app

TestFlight 1.0.0 (6), iPhone: a tap on the Lock Screen widget opened the app, recorded nothing and left no
Recent Starts entry, so `perform()` never ran. The widget's `Button(intent:)` used `.buttonStyle(.plain)`
around its label: a plain button takes taps only where its label draws, and on the rectangular widget that
was the glyph and the two lines of text. Any other point of the widget is the widget's own tap, which opens
the app (with its `widgetURL`, or with none), and there was nothing else. Now:

- the label fills the widget and `contentShape(Rectangle())` makes every point of it the button's;
- the widget has a `widgetURL` of its own (`VoiceNoteLink.widgetTapURL`, `sempere://quick-voice/widget`): a
  tap that still opens the app (iOS deciding so, for example) arrives there, is kept as `widgetOpenedApp`, and
  the app does what the button would have done from its live state (`QuickCapture.widgetOpenedApp`): record
  (in front, so no background permission is needed), stop, or show the setup or the banner. Anyone can open
  that URL; it does nothing a tap on the widget, the control or Siri could not do (see "Threat model").

Apple: "On a locked device, buttons and toggles are inactive and the system doesn't perform actions unless a
person authenticates and unlocks their device"
([Adding interactivity to widgets](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)).
So a tap on the Lock Screen widget of a locked iPhone first asks for Face ID (or the passcode) even though
the intents set `authenticationPolicy = .alwaysAllowed`. Apple does not say whether the button's intent then
runs or the app opens; the tap log says which (a `controlIntent` tap, or a `widgetOpenedApp` one).

| Phase | Shows | A tap |
| --- | --- | --- |
| Not set up | mic slashed, "Set Up Voice Notes" | opens the app at Settings ▸ Quick Voice Notes (`sempere://quick-voice/settings`; the control's `VoiceNoteControlIntent` continues in the app). Only when no profile is stored: a profile the Keychain will not hand over now shows as Ready, and a start says that the settings could not be read |
| Live Activities off | mic slashed, "Live Activities Off" | the same; the section explains and links to the app's page in Settings |
| Ready | mic | records (`StartVoiceNoteIntent`) |
| Recording | stop, the length of the audio (standing still while paused) | stops and saves (`StopVoiceNoteIntent`) |
| Saving | "Saving Voice Note" | opens the app at the banner |

Settings ▸ Quick Voice Notes also says, with a button to Sempere's page in the system Settings, when Live
Activities or the microphone are off for Sempere (`VoiceNoteBlocker`): either stops a voice note from the
Lock Screen, Control Center, the Action button or a widget from recording, whether or not quick voice
notes are set up yet.

The file is protected until the first unlock after boot. Before it, the
extension cannot read it (and nothing can record: the capture profile is a
Keychain item readable only after the first unlock), and the widget shows
the plain mic button. The widget uses only system symbols and is marked
`unredacted()`: the placeholder iOS shows before the first unlock is
otherwise redacted to an empty gray box. Without the App Group (an
unsigned build) the widgets show the plain mic button.

A stale status cannot trap anyone: the app rewrites it at launch, and Stop on
a recording the process does not know ends the orphaned Live Activity quietly.

## After Stop

The Live Activity shows "Saving" while the audio is sealed, then, as soon as
the sealed file is in the inbox (before any transcript), "Saved to Inbox"
("Saved on This Device" when it went to the queue, "Not Saved" on failure),
and is dismissed 5 seconds later (12 for a failure). The app's banner says
the same when the app is open. Opening the app from the Live Activity
(`sempere://quick-voice/recording`) lands on the banner; the widget's own
`sempere://quick-voice/widget` is a widget tap ("Widget taps that open the app"). Any other `sempere:` URL is
ignored (`VoiceNoteLink.route`): anyone can open one, and it is never taken
for a vault.

## Not verified yet

- On an iPhone (build 7): a Control Center, Action button or Siri start records in the background, with
  Recent Starts showing `session=not mixable` (the order fixed it) or `session=mixable after a refusal`
  (the fallback did), and the recording is audible with music playing in another app in the mixable case.
- On an iPhone: restart during a voice note, unlock, open Sempere (or just unlock and wait): the banner
  says "Interrupted Voice Note Saved" and the note has the audio up to the restart. Force quit during one:
  within 2 minutes the Live Activity says "Voice note interrupted"; tapping it opens Sempere, which ends it
  and saves the note. Whether Stop on that activity launches the force-quit app at all.
- On an iPhone: `AVAudioRecorder` writing ADTS for a `.aac` URL (the simulator tests write ADTS with
  `AVAudioFile`; the unit tests use a fake recorder).
- On an iPhone: Siri after a restart and one unlock: a start records (in the background, or after opening
  Sempere); Recent Starts shows the `mic=` value that build 6 took for a refusal.

- On a device: which refusal iOS gives a background start (Settings ▸ Quick Voice Notes ▸ Recent Starts), and
  whether the Lock Screen widget now records after the unlock.
- On a device (build 7): a Lock Screen widget tap is kept as a `controlIntent` tap (the button ran) or a
  `widgetOpenedApp` one (iOS opened the app instead); none at all means the tap never reached Sempere.
- On a device: why a mic tap (control or widget) brings the app forward. The tap's `mode` says whether iOS
  had already put the app in front when `perform()` began; a decision `openSettings` or `openRecording` means
  the live state needed the app; a start whose outcome is "Recorded after opening Sempere" has the background
  refusal on its "First try" line (`activity=failed …` is ActivityKit's, `error=… '!rec'/'!int'/'!pla'` the
  audio system's).
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
