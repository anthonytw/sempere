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

## The key

- **Only a key on the vault's list opens it.** A key is one line of text. You
  can hold it on several devices, on paper (the recovery kit), in a password
  manager, and, if you chose one, as a copy in the vault protected by a
  passphrase. Each of those is a way in: protect them accordingly.
- **A key copy in the vault is only as strong as its passphrase.** That copy
  sits with the vault on its storage, so your storage provider, or anyone with
  a copy of the files, can try passphrases on it offline, as many as they
  like. Sempere refuses a passphrase it estimates as easy to guess; use five
  or more random words, or a long random password, and never one you use
  elsewhere. A copy with a weak passphrase gives away the key, which reads
  and writes everything.
- **If every copy of the key is lost, the notes cannot be opened.** Not by you,
  not by the developer, not by anyone. There is no reset, no recovery service and
  no back door. Print the recovery kit when you create a vault and keep it
  somewhere apart from your devices.
- **Anyone who has a copy of the key can read the vault.** Keep it out of
  shared folders, email and chat.
- **Removing a device's key does not take back what it already read.** It stops
  that key from opening what is written afterwards. Old copies of the files
  (backups, a provider's version history) still open with the old key
  ([`cli.md`](cli.md), `vault recipients remove`).
- **A removed device can still pass things off as authentic for a while.**
  Removing a key changes the vault's secret, which tags notes as yours. Until
  the change has re-encrypted every file, files still tagged with the old
  secret are accepted, so a removed device that kept the old secret and can
  still write to the storage could add notes, attachments, voice notes or
  settings that pass as authentic. Once a device has seen the change finish,
  it accepts nothing made with the old secret again, even if the old change's
  records are put back on the storage ([`format.md`](format.md) §3.3.1). A
  device that opens the vault for the first time, or lost its record of the
  vault, trusts what the vault says about an unfinished change.

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
  device ids and counters, never titles);
- the public keys of the vault's devices and the names you gave them (in
  `vault.json`).

They cannot see titles, text, ink, tags, notebooks, attachments or transcripts.

## What the encryption does not protect

- **An unlocked device.** While a vault is unlocked, the app holds the key and
  shows your notes. Anyone using the device, or software that controls it, can
  read them. Use a device passcode; the remembered key is behind Face ID or
  Touch ID when you choose it.
- **Plaintext the app keeps on the device for speed or safety:** attachments
  opened for display, a recording until it is saved into the note, a voice note
  until it is sealed, and files staged for an export or a drag. They rely on the
  system's data protection where the platform has it (on a Mac, which has none,
  the attachment cache is deleted at each launch instead). The caches of note
  listings, drawings and attachment previews are encrypted under the vault's
  secret ([`format.md`](format.md) §10). Details: [`io.md`](io.md),
  [`quick-capture.md`](quick-capture.md).
- **Exports.** A PDF, image or Markdown export is not encrypted. Where you send
  it is up to you.
- **The locked device's voice capture.** If you turn on quick voice notes,
  anyone holding your locked device can record a voice note into your vault.
  They cannot listen to existing ones ([`quick-capture.md`](quick-capture.md)).
- **Metadata,** as listed above.
- **Bugs.** Sempere has had an independent review
  ([`security-review-2026-10.md`](security-review-2026-10.md)), and its age
  implementation is checked against the public test vectors and the reference
  `age` tool, but software can have flaws. If you find one, please report it
  privately ([`SECURITY.md`](../SECURITY.md)).

## Recovery without the app

The files are standard age files. With the key, the stock `age` tool (1.3 or
later) and common command-line tools can decrypt any note or attachment, as the
recovery kit explains; the free `sempere` command-line tool for macOS and Linux
reads, exports and recovers whole vaults. Neither needs the app, the developer
or a network.
