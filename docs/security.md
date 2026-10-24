# Security: what Sempere protects, and its limits

A plain-language summary for people using Sempere. The design is in
[`DESIGN.md`](../DESIGN.md) ("Encryption", "Recovery"), the normative format in
[`format.md`](format.md), and how to report a problem in
[`SECURITY.md`](../SECURITY.md). This page describes the design; it is not a
guarantee. Sempere is free software and comes with no warranty (GPL v3,
sections 15 and 16).

## What the encryption is for

Notes are encrypted on your devices before they are written, with
[age](https://age-encryption.org) and its hybrid post-quantum recipient type
(ML-KEM-768 with X25519). The folder that holds a vault, and every copy of it
(iCloud Drive, another Files provider, a WebDAV server, a backup), holds only
encrypted files. Someone who gets those files but not a key cannot read the
notes, their titles, tags, attachments, recordings or transcripts.

Each note also carries a tag that only key holders can compute, so someone who
can write to the storage cannot add a note, or change the list of devices,
in a way that passes as yours ([`format.md`](format.md) §2.1).

Sempere has no server and no account. The developer never receives your key,
your notes or any information about them, and the app sends nothing about
your use (no telemetry).

## The keys

- **Each device has its own key, and the vault has one recovery key.** A
  device's key is made on that device and never leaves it. The vault's own key
  is wrapped once for each listed device and once for the recovery key, which
  is printed in the recovery kit when the vault is created and kept by no
  device ([`format.md`](format.md) §2, §3). The kit is a way in: protect it
  like the notes themselves.
- **The recovery key reads; it does not write.** Opened with the kit, a vault
  can be read and exported but not changed.
- **A passphrase copy is only as strong as its passphrase.** If you chose one,
  a copy of the recovery key sits in the vault, protected by a passphrase. It
  sits with the vault on its storage, so your storage provider, or anyone with
  a copy of the files, can try passphrases on it offline, as many as they
  like. Sempere refuses a passphrase it estimates below about 70 bits (the
  estimate prices words as dictionary words and finds keyboard walks,
  sequences, repeats and common passwords), with no override; use six or more
  random words, a long random password, or one your password manager
  generates, and never one you use elsewhere. A copy with a weak passphrase
  gives away the recovery key, which reads everything.
- **If every device's key and every copy of the recovery key are lost, the
  notes cannot be opened.** Not by you, not by the developer, not by anyone.
  There is no reset, no recovery service and no back door. Print the recovery
  kit when you create a vault and keep it somewhere apart from your devices.
- **Only the vault's home device adds devices.** The device that created the
  vault approves a new device after you type, on it, six words the new device
  shows; the new device then checks six words the home device shows back. The
  list of devices in `vault.json` is tagged under the vault's key and signed by
  the home device, so storage cannot add a device or rename one in a way that
  passes ([`format.md`](format.md) §2.1, §15.12).
- **Removing a device, or replacing the recovery kit, is not in this version**
  (it starts a new vault key, key hierarchy phase KH3). Removing a device will
  not take back what it already read: old copies of the files (backups, a
  provider's version history) still open with the keys of the time.

## Backups

A backup copies the encrypted vault to another place (Settings ▸ Backups,
`sempere backup`). It protects against a lost or damaged folder, a provider
problem or a mistake. It does not replace the key: a backup opens with the same
key as the vault. Keep at least one backup somewhere other than the vault's own
storage, and check it now and then (Verify Backup).

## What others can see

Your storage provider, and anyone with a copy of the files, can see:

- that a vault exists, how many notes it has, and roughly how big each note and
  attachment is (attachments are padded to size classes);
- when files were written, and by which device (file names carry random ids,
  device ids, counters and a timestamp, never titles);
- what kind each attachment is (image, PDF, audio, video or transcript: the
  kind is part of the file name), and whether voice notes are waiting in the
  inbox or notebook records exist;
- the public keys of the vault's devices and of its recovery key, the names
  you gave the devices, which device manages the others, the vault's own
  display name if you set one, its id and when it was created (all in
  `vault.json`, which is not encrypted), and the requests of devices waiting
  to join (`joins/`).

They cannot see titles, text, ink, tags, notebooks, attachments or transcripts.

## What the encryption does not protect

- **An unlocked device.** While a vault is unlocked, the app holds the key and
  shows your notes. Anyone using the device, or software that controls it, can
  read them. Use a device passcode. This device's key for a vault is in its
  Keychain, never synced or exported, and its signing key in the Secure Enclave;
  a vault opens by itself on the device that holds its key, unless you set it to
  ask for Face ID or Touch ID (Settings ▸ Sync & Devices). A vault handed to the
  app from another app or AirDrop asks before it closes the open one.
- **Plaintext the app keeps on the device for speed or safety:** attachments
  opened for display, a recording until it is saved into the note, a voice note
  until it is sealed, and files staged for an export or a drag; on a Mac, the
  titles of note windows open when the app quits, which the system keeps to
  restore its windows. They rely on the
  system's data protection where the platform has it (on a Mac, which has none,
  the attachment cache is deleted when the app quits, and after a crash at the
  next launch, before any vault opens). The caches of note
  listings, drawings and attachment previews are encrypted under keys derived
  from the vault's key ([`format.md`](format.md) §10). Details: [`io.md`](io.md),
  [`quick-capture.md`](quick-capture.md).
- **Exports.** A PDF, image or Markdown export is not encrypted. Where you send
  it is up to you.
- **The locked device's voice capture.** If you turn on quick voice notes,
  anyone holding your locked device can record a voice note into your vault.
  They cannot listen to existing ones ([`quick-capture.md`](quick-capture.md)).
- **Metadata,** as listed above.
- **Bugs.** Sempere's code has been through a multi-agent security review with
  Claude (October 2026), and its age implementation is checked against the public test vectors and the reference
  `age` tool, but software can have flaws. If you find one, please report it
  privately ([`SECURITY.md`](../SECURITY.md)).

## Recovery without the app

The files are standard age files. With the recovery key, the stock `age` tool (1.3 or
later) and `jq` take the vault's key out of `vault.json` and then decrypt any
note or attachment, as the recovery kit explains; the free `sempere` command-line tool for macOS and Linux
reads, exports and recovers whole vaults. Neither needs the app, the developer
or a network.
