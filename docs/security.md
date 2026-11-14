# Security: what Sempere protects, and its limits

A plain-language summary for people using Sempere. The design is in
[`DESIGN.md`](../DESIGN.md) ("Encryption", "Recovery"), the normative format in
[`format.md`](format.md), and how to report a problem in
[`SECURITY.md`](../SECURITY.md); the security and privacy audits, the evidence for these
claims, are published in [`audits/`](audits/README.md) (none yet: the first, a full audit of 1.1, is
planned before 1.1 is submitted). This page describes the design; it is not a
guarantee. Sempere is free software and comes with no warranty (GPL v3,
sections 15 and 16).

## What the encryption is for

Notes are encrypted on your devices before they are written, with
[age](https://age-encryption.org) and its hybrid post-quantum recipient type
(ML-KEM-768 with X25519). The folder that holds a vault, and every copy of it
(iCloud Drive, another Files provider, a WebDAV server, a backup), holds encrypted
files and one file in the clear, `vault.json`, the vault's device list (see "What others can see").
Someone who gets those files but not a key cannot read the
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
  like the notes themselves. Printing it hands the key to the print path (the
  system's print service, the printer, its queue and any print server): print to
  a printer you trust, connected directly or on your own network, or save the PDF
  and print it offline.
- **The recovery key reads; it does not write.** Opened with the kit, a vault
  can be read and exported but not changed.
- **A passphrase copy is only as strong as its passphrase.** If you chose one,
  a copy of the recovery key sits in the vault, protected by a passphrase. It
  sits with the vault on its storage, so your storage provider, or anyone with
  a copy of the files, can try passphrases on it offline, as many as they
  like. Sempere takes any passphrase and does not judge it: a person's choice
  of words, names, dates or patterns cannot be priced by an estimate. Suggest
  a Passphrase makes seven random words (about 77 bits), which is the safe
  choice; a long random password from a password manager is as good.
  Never use the passphrase anywhere else. A copy with a weak passphrase gives
  away the recovery key, which reads everything.
- **If every device's key and every copy of the recovery key are lost, the
  notes cannot be opened.** Not by you, not by the developer, not by anyone.
  There is no reset, no recovery service and no back door. Print the recovery
  kit when you create a vault and keep it somewhere apart from your devices.
- **Only the vault's home device adds devices.** The device that created the
  vault approves a new device after you compare, on it, six words the new device
  shows with the six on its own screen and tap They Match (or type the words, or
  scan the device's code); the new device then compares six words the home device
  shows back the same way. **Tapping They Match is as safe as typing the words
  only if you compare them. Compare all six.** A tap does not force you to read
  every word, as typing does: an attacker who can reach the home device (nearby,
  or through the sync target) can search for a key whose first one to three words
  look right in minutes, but not one whose six all match (about 2^66 tries). Add
  Device warns when two or more requests wait at once, since an attacker's
  requests can crowd out the real one, and the six words are never shortened to
  a code. The owner check (Face ID or the password) still comes before an
  approval, and nothing approves from a notification, widget or shortcut. When
  the two devices are near each other, the request and the approval also go
  straight between them over Wi-Fi while the two screens are open, with the
  same checks on both ends; the sync target is still used too. The
  list of devices in `vault.json` is tagged under the vault's key and signed by
  the home device, so storage cannot add a device or rename one in a way that
  passes ([`format.md`](format.md) §2.1, §15.12).
- **The root fingerprint identifies the vault; it is not a key.** It is 64
  characters (16 groups of 4 letters and digits), fixed when the vault is
  created, and printed on the first page of the recovery kit under "The vault's
  root fingerprint", below the recovery key's lines; the second page has it as a
  QR code. It opens nothing and is not secret: the recovery key
  (`AGE-SECRET-KEY-PQ-1…`, on the same page) is the secret that opens the vault,
  while the root only lets a device check that a vault is the one it expects and
  not a copy someone made to list the same key. A device that joins by approval
  learns it from the home device's six reply words. A device that opens a vault
  with a key file made elsewhere (by `sempere`, or the demo vault's) has nothing
  to check against, so it opens read-only until you type the root from the
  printed kit (Confirm Vault… in the app, `--root` for `sempere`). Take it only
  from the kit: a root read from the vault's own files proves nothing.
- **Removing a device starts a new vault key.** The home device removes it
  (Settings ▸ Sync & Devices ▸ Devices, or `sempere devices remove`), and
  files written afterward use the new key. The recovery kit can be replaced, and
  everything re-encrypted, from the same screen. Removing a device does not take
  back what it already read: old copies of the files (backups, a
  provider's version history) still open with the keys of the time.

## Backups

A backup copies the encrypted vault to another place (Settings ▸ Backups,
`sempere backup`). It protects against a lost or damaged folder, a provider
problem or a mistake. It does not replace the key: a backup opens with the same
key as the vault. Keep at least one backup somewhere other than the vault's own
storage, and check it now and then (Verify Backup).

## What others can see

Your storage provider, and anyone with a copy of the files, can see:

- that a vault exists, its folder's name (the app sets none, so it is whatever the
  folder is called), how many notes it has, how big each saved change to a note is
  (exactly: only attachments are padded to size classes), and roughly how big each
  attachment is;
- when files were written, and by which device (file names carry random ids,
  device ids, counters and a timestamp, never titles);
- what kind each attachment is (image, PDF, audio, video or transcript: the
  kind is part of the file name), and whether voice notes are waiting in the
  inbox or notebook records exist;
- the public keys of the vault's devices and of its recovery key, the devices'
  names (by default the model and a short tag, such as "MacBook Pro 3F2A",
  never the computer's name; rename them in Devices), each device's kind (iPad,
  iPhone, Mac or command line), when it was added and by which device, which
  device manages the others, the vault's own display name if you set one, its id
  and when it was created, the epoch number and the reason for each key change
  (a device removed, the home handed over, a takeover with the recovery kit, the
  kit replaced) (all in `vault.json`, which is not encrypted), and the
  requests of devices waiting to join (`joins/`, also in the clear).

They cannot see titles, text, ink, tags, notebooks, attachments or transcripts.

While you add a device (Add Device on one, Join This Device on the other), anyone
near enough to receive the two devices' Wi-Fi can see that Sempere is offering
or looking for a join, and the advertising device's network name (Bonjour
announces it for any service). The new device sends its request (its name, kind
and public keys, and the vault's id: what storage holds in `joins/`) only to a
device that shows it knows the vault's id; a device that already knows the id,
from your storage or from watching an earlier join, can therefore receive it,
and anyone listening during the join sees it. The vault's id is the same in
every join, so two joins seen over the air are known to be of one vault, and the
size of the approval tells roughly how long the device list is. The approval
sent back, with the device list, is encrypted to the new device's key
([`design/nearby-join.md`](design/nearby-join.md)).

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
  restore its windows; on every device, each vault's last place in the app's
  preferences (`Sempere.lastPlace.<vault id>`: the vault's id, the open note's id,
  and the sidebar item, a fixed list or a notebook or tag as a digest keyed from
  the vault's key, never a name), which is in the device's backups and is forgotten
  when the vault is removed from the device; and the system's picture of the last
  screen, which it keeps for the app switcher while the app is in the background. They rely on the
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
- **A lost Apple Watch.** With Use on Apple Watch on, the watch holds the same
  capture key as the iPhone (the key that can add voice notes and read nothing).
  Someone who has your lost watch can add voice notes to your inbox as the
  iPhone, until you do three things, in this order: **turn off Use on Apple
  Watch** (the iPhone stops accepting the watch's files and stops sending it keys at
  once, forgets the watch's key, and holds anything that still arrives for you to add
  or delete), **unpair or erase the watch** (Find My), then **replace the key** (a
  new epoch), which retires the copied capture key against someone who also has
  storage access. WatchConnectivity can reach the iPhone through Apple's cloud
  relay, not only within Bluetooth range, so being far from the watch is no
  protection. They cannot read any note. Turning the setting off, or Reset on the
  watch, clears the watch's copy but revokes nothing cryptographic by itself: a copy
  someone already took stays valid against storage until the key is replaced. Reset also
  makes the watch a new provisioning key, so the profile that WatchConnectivity keeps
  in its persisted context (encrypted to the old key) can no longer be opened by the
  watch. Files the iPhone does not admit (the setting was off, or the key changed
  since, or an epoch it never held) are kept on the iPhone only, never in the vault
  or the ledger, and need your **Add** (one note at a time, after a confirmation that
  warns about notes that came after the setting was turned off or under an earlier key,
  which may be a lost watch's; a note under an epoch or vault the iPhone never held can
  only be deleted); **Delete** removes them. At most 200
  files / 500 MB are held, of which 20 files / 50 MB at most may be notes that can only be deleted; past either the watch keeps them. Removing
  the iPhone from the vault ends the watch's captures too (they verify only under
  the iPhone's listed key). A key of its own for each watch, listed in the vault so
  that it can be revoked alone, is not in 1.1 (decision D1 of the design).
- **Who asks the iPhone for the watch's profile.** The watch asks with a public
  key, over WatchConnectivity, and the iPhone encrypts the profile to the key in
  the request. Nothing authenticates the request beyond the pairing: age gives
  confidentiality, not sender authentication. Someone who can already send
  messages to the iPhone as the paired watch (code running on the watch or the
  phone) could name a key of their own and get the capture key, which is the case
  above. The iPhone sends nothing until the setting is on and a profile exists, and
  the watch takes a profile only from the session's callbacks, never from a file
  or a link.
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
