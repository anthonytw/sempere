# Sempere Privacy Policy

*Effective: 2026-10-06. Last updated: 2026-10-09.*

This page is the Privacy Policy URL App Store Connect has today. The same text is served by
GitHub Pages from [`docs/privacy/index.html`](../privacy/index.html), at
`https://anthonytw.github.io/sempere/privacy/`. Keep the two identical:
`scripts/release-check.sh` compares their "Last updated" dates.

**Short version: Sempere does not collect, transmit or share any data about you. It has no
servers, no accounts, no analytics and no advertising. The only network connections it makes
are to a WebDAV server that you set up yourself, if you choose to keep a vault there (see
"Network connections").**

## What Sempere is

Sempere is a handwriting notes app for iPad, iPhone and Mac. Your notes are stored in a
"vault", a folder of files encrypted on your device with a key that you create and control. The
developer (Anthony Wertz, "we") cannot read your notes and does not receive them.

## Data we collect

None. Sempere does not collect personal data, usage data, diagnostics, identifiers, location,
contacts or content. It contains no analytics, advertising or crash-reporting software and no
third-party SDK that collects data. We run no server that the app talks to.

## Where your notes live

Your notes, and everything you add to them (photos, video, PDFs, text, equations, audio
recordings and their transcripts), are saved only where you choose:

- on your device, in the app's storage;
- in a folder you pick in the Files app, such as iCloud Drive or another provider;
- on a WebDAV server you run or rent and connect to in the app (Open from WebDAV). The app then
  connects to that server's address, over HTTPS, with the user name and password you enter, to
  upload your encrypted notes. The password is kept only in your device's Keychain. Nothing is
  sent to us or to anyone else.

Those storage services are run by you or by their providers (for example Apple, for iCloud
Drive), under their own terms and privacy policies; we have no access to them. Notes are
encrypted before they are saved, so a storage provider sees file names, sizes and modification
times, but not what you wrote, drew or recorded.

## Your keys

Your encryption key (an "age" identity) is generated on your device. You can keep it in the
iOS/macOS Keychain (optionally synced through iCloud Keychain, if you choose that), print a
recovery kit or export it. **We cannot recover your key or your notes. If you lose every copy of
your key, nobody can decrypt your notes.**

## On-device features

- **Handwriting search** reads your handwriting with Apple's Vision framework on your device.
- **Transcription** of recordings uses Apple's on-device speech recognition. Audio is never
  sent to a server. The system may download a speech model for your language from Apple; that
  download contains none of your data.
- **Photos** you add have their location and camera data removed by default (Settings →
  Photos).
- **Quick voice notes** from the Lock Screen or Control Center are encrypted on the device
  before they are saved, without unlocking your vault.

## Network connections

Sempere connects only to a WebDAV server you set up yourself, and only if you open a vault there
(Open from WebDAV): it then downloads the vault from that server's address, and uploads your
already encrypted vault files to it, over HTTPS, with the user name and password you entered (the password stays in your device's
Keychain). Nothing is sent to us or to anyone else. Otherwise your notes reach iCloud Drive or
another storage provider only through the system's Files and iCloud services, which copy the
encrypted files you saved there; the speech model download above is the system's too.

Besides the WebDAV client, the app contains one other piece of networking code: a downloader for an optional handwriting-to-math
recognition model (Settings → Handwritten Math). It runs only when you tap a model's Download
button, and this version offers no model, so it never runs and has no address to connect to. If a
future version offers a
model, it will be downloaded only when you ask, over HTTPS, from an address this policy will name,
and it will be checked against a fingerprint built into the app. The download request carries
nothing from your vault, and the model then runs on your device: your ink never leaves it. This
policy will be updated before such a version is released.

## Device permissions

Sempere asks for a permission only when you use the feature that needs it:

- the camera, to add photos and video (iPad and iPhone);
- the microphone, to record audio;
- speech recognition, to transcribe recordings on the device;
- Face ID or Touch ID, to unlock a key saved in the Keychain;
- Live Activities, to show a voice note in progress.

Photos and files are chosen with the system pickers, which give the app only what you pick.
Face ID and Touch ID data never leaves the system and is never seen by the app.

## Children

Sempere collects no data from anyone, including children.

## Open source

The source code is public under the GPL-3.0-or-later (with an App Store exception) at
<https://github.com/anthonytw/sempere>, so these statements can be checked.

## Changes

If this policy changes, it will be updated here with a new date. A change that collects data
would first be described in the app's release notes.

## Contact

Questions: open an issue at <https://github.com/anthonytw/sempere/issues>.
Security reports: see <https://github.com/anthonytw/sempere/blob/main/SECURITY.md>.
