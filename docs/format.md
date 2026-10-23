# Sempere on-disk format, version 1

Normative. Changes to this file are format changes and need a version bump
or a documented compatible extension.

## 1. Vault layout

A vault is a directory whose name ends in `.sempere`.

```
Notes.sempere/
  vault.json                              plaintext manifest: the device list and the wrapped vault key (§2, §15.3)
  epochs/
    <e>-<idprefix>.epoch.age              one record per epoch: at creation, then at each device change (§15.6, §15.14)
  joins/
    <id>.join.json                        a device's request to join, until the home device approves it (§15.12)
  keys/
    recovery-<fingerprint>.key.age        optional passphrase copy of the recovery key (§3.2, §15.11)
  notes/
    <noteId>/
      <hlc>-<device>-<seq>.delta.age      append-only revision (§5)
      <hlc>-<device>-<seq>.snapshot.age   append-only snapshot  (§5)
      att/
        <blobName>.<kind>.age             the note's attachment bytes: images, PDFs, audio, transcripts (§8.1)
  inbox/
    <captureId>.capture.age               a voice note sealed without the vault's key (§11), until adopted
    <captureId>.transcript.age            its transcript, sealed the same way (§11)
  sempere-summaries.sealed                optional published note summaries, a hint for listing (§12)
  summaries/
    <device>.sealed                       optional published summaries, one file per writing device (§12.5)
  settings.age                            optional shared settings, merged per key (§13)
  notebooks/
    <recordId>.notebook.age               optional notebook record: keeps empty notebooks (§14)
```

Everything under `notes/` (revisions and `att/` blobs alike), `notebooks/` and `epochs/` is
written once and never modified (`settings.age`, at the root, is a mutable file, §13), with one
exception in this version: a device's **catch-up** (§15.14) replaces a revision or notebook record that
it wrote itself under an earlier epoch's key, and that no device change sealed, with the same body
under the current key (verified first, the old bytes set aside). Re-encrypting everything
(key-hierarchy design §7, phase KH6) will be the other.

A vault is a plain directory, never a package (a bundle that file-sync
services such as iCloud Drive treat as one document): such a service syncs
a package as one item, so two devices writing into it at once make a conflict
of the whole vault, and whichever version is kept lacks what the other device
wrote. As plain files, write-once files with unique names (§5, §8.1.2, §11.2)
never conflict, and only the mutable files below can (§1.3).

Unknown files and directories must be ignored, never deleted.

### 1.1 Hidden names

A name starting with `.` is never a vault file: no vault file name (§5, §8.1.2,
§11) starts with one, and readers ignore such names wherever they are. Writers
use them for files in progress (temporary names `.sempere-tmp-…`, renamed or
linked into place, docs/io.md "Atomic writes") and for the markers below.

### 1.2 Partial copies

A *partial copy* is a vault folder that holds the root files (`vault.json`,
`settings.age`, and the notebook records of §14) of the vault it copies, and a folder
for each of its notes, but not yet every revision or blob: the rest is
fetched later (the WebDAV app copies and `sempere sync webdav
--metadata-only`, docs/io.md "Partial copies"). Three markers, all hidden
(§1.1), say what it lacks:

```
Notes.sempere/
  .sempere-partial/                       the folder is a partial copy (the copier's own files go here)
  notes/
    <noteId>/
      .sempere-pending                    this note's revisions have not all arrived
      att/
        .<blobName>.<kind>.age.sempere-pending   this blob has not arrived
```

- `.sempere-partial/` at the root marks the copy. It is removed once nothing
  is pending; a vault folder without it is complete.
- An empty file `.sempere-pending` in a note folder marks the note
  *incomplete*: its folder may hold some of its revisions, or none. It is
  removed only once the folder holds every revision the source listed when
  the note was fetched (except those the copier refused under §9.1: a refused
  file is settled, left out as a complete download leaves it out), and a
  stand-in for each of its blobs that has not arrived.
- An empty file `.<file name>.sempere-pending` in a note's `att/` stands for
  a blob the copy lacks. It is removed when the blob arrives, when the
  source no longer has it, or when the copier refuses the blob under §9.1.

Readers ignore the markers as they ignore any hidden name, so an incomplete
note may read as empty or partial; a reader that knows them treats such a note
as not yet available, and a missing blob as for any blob not there (§8.5.2).
Writers must obey these rules, which keep anything written from a partial
copy valid once the rest arrives:

1. No revision is written into an incomplete note, and none is deleted from
   it (compaction, thinning, §5.3, §5.8): a revision written there would be
   stamped (§5.1) and sequenced without the revisions still missing, and
   computed from a state that lacks them.
2. No blob of an incomplete note is collected (§8.1.6 rule 1 cannot hold).
3. No re-encryption of the vault (§15.8, KH6) starts or resumes in a partial
   copy: it must see every file.
4. Whatever the copy lacks is never taken as deleted. A sync from a partial
   copy (docs/io.md "WebDAV sync") never removes, nor reports as unexplained,
   a file of an incomplete note or a blob with a stand-in.

### 1.3 Mutable files and conflicting copies

Every file of a vault is written once under a name no other writer uses,
except these, which are replaced whole (atomically):

| File | Written by | When |
| --- | --- | --- |
| `vault.json` | the home device (§15.3); for `label` alone, any listed device | creation, a device approved or renamed (§2), a label change (§2) |
| `settings.age` | devices that opted in | when a shared setting changes, or a device's merged copy is newer (§13.3) |
| `sempere-summaries.sealed` | the CLI and the WebDAV sync | when a listed note changed (§12.4) |
| `summaries/<device>.sealed` | that device only | when its listing changed (§12.5) |

A file-sync service may keep two versions of one of them, written by two
devices at once (iCloud Drive's conflict versions), or a whole other copy of
the vault may turn up (another device's copy, a restored backup). Merging
another copy into a vault keeps everything a reader needs, whichever copy is
kept, and is the same whatever the order of copies merged:

- **Write-once files** (revisions, blobs, inbox files, epoch records, join requests, the passphrase
  copy, notebook records, §14): the union.
  A file the vault lacks is checked like any received file (§9.1) and copied
  in under its name; nothing is overwritten or deleted. A revision a
  compaction deleted on one side may come back; it is covered by the snapshot
  that let it go (§5.3), so notes read the same, and the next compaction
  deletes it again.
- **`settings.age`**: merged per key (§13.3); this needs the vault key.
- **`vault.json`**: one writer, the home device, writes it (§15.3), so two
  versions of one epoch follow each other. Two versions that differ only in
  `label` (§2, covered by no tag or signature) are the same vault. Otherwise
  a writer holding the key takes the other version only when it is a later
  one by home: the same vault, root, epoch and `epochId`, the same epoch head
  (`home`, first list, `parent`, `epochReason`, `epochAuthor`, `epochSig`,
  `recoverySig`), every check of §15.3 passes against the list it holds,
  that list's entries are all still there, and it adds a device or renames one. Anything else is never merged:
  a writer keeps its own version and reports the other.
- **Published summaries** (§12): the version kept stays; they are hints and
  are rewritten by their writers.

A writer that resolves such conflicts by itself never needs to ask the user
to pick a version, and must not pick one by whole-vault or last-writer-wins
rules, which lose notes.

## 2. vault.json

`vault.json` is the plaintext manifest of the key hierarchy (§15; design in
`docs/design/key-hierarchy.md`). It lists the vault's devices and its one
recovery key, and wraps the epoch's vault key `K_e` (§15.2) once to each of
them. A vault starts at epoch 1; each device change (a removal, a handoff, a
takeover, a recovery-kit replacement: §15.14) starts the next epoch, with a new
key. At epoch 1:

```json
{
  "format": "sempere/1",
  "vaultId": "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c",
  "created": "2026-10-20T16:20:00.000Z",
  "root": "…(64 hex digits)…",
  "epoch": 1,
  "epochId": "…(64 hex digits)…",
  "epochRecord": "epochs/1-5b0e6f1a2c3d4e5f.epoch.age",
  "epochRecordHash": "…(64 hex digits)…",
  "keys": [
    { "role": "device", "key": "age1pq1…(1959 characters)…", "id": "a1b2c3d4",
      "sign": { "p256": "…(130 hex)…", "mldsa65": "…(3904 hex)…" },
      "kind": "ipad", "added": "2026-10-20T16:20:00.000Z", "addedEpoch": 1, "addedBy": "a1b2c3d4",
      "addSig": { "p256": "…(128 hex)…", "mldsa65": "…(6618 hex)…" },
      "name": "Alex's iPad",
      "wrap": "-----BEGIN AGE ENCRYPTED FILE-----\n…\n-----END AGE ENCRYPTED FILE-----\n" },
    { "role": "recovery", "key": "age1pq1…", "sign": { "p256": "…", "mldsa65": "…" },
      "name": "Recovery kit", "added": "2026-10-20T16:20:00.000Z",
      "wrap": "-----BEGIN AGE ENCRYPTED FILE-----\n…" }
  ],
  "listTag": "…(64 hex digits)…",
  "epochAuthor": "a1b2c3d4",
  "epochReason": "create",
  "home": "…(64 hex digits: the home device's fingerprint)…",
  "epochSig": { "p256": "…", "mldsa65": "…" },
  "markersTag": "…(64 hex digits)…",
  "author": "a1b2c3d4",
  "authorSig": { "p256": "…", "mldsa65": "…" }
}
```

- `format`: the format identifier, `sempere/<major>` (§7.1); `sempere/1`
  for this version. A reader opens a vault of a later major read-only or not
  at all (§7.3).
- `vaultId`, `created`: the vault's id (a lowercase UUID) and when it was
  created (§6).
- `root`: the vault's root fingerprint (§15.7 rule 2, design §4.2). It never
  changes and is printed on the recovery kit (§15.13).
- `epoch`, `epochId`, `epochRecord`, `epochRecordHash`: the epoch's number,
  its id (§15.2), the path of its record in `epochs/` (§15.6) and the
  record's SHA-256. Epoch 1 has a record too, written at creation.
- `keys`: exactly one entry with `role: "recovery"` and at least one with
  `role: "device"`. Every `key` is an age MLKEM768-X25519 recipient (§3.1,
  Bech32, HRP `age1pq`), listed once. A `vault.json` of this major that lists
  any other key, a classic X25519 one (HRP `age`) included, is invalid, and
  readers MUST refuse to open it.
  - A device entry: `id` (the first 8 hex digits of its fingerprint, §15.4;
    for names and display only: no security decision reads it), `sign` (its signing
    public keys), `kind` (`ipad`, `iphone`, `mac`, `cli`, or another lowercase
    word of 1 to 32 letters), `added`, `addedEpoch`, `addedBy` (the home
    device that approved it) and `addSig` (home's signature over them, §15.5),
    `name`, `wrap`.
  - The recovery entry: the recovery key (printed in the kit, §3), the
    signing keys derived from it (§15.4), `added`, `name`, `wrap`.
  - `name`: a device's display name, at most 40 characters, cleaned as
    `label` (below). Unlike `label` it is covered by `listTag` and `authorSig`,
    so storage cannot rename a device; only home renames one.
  - `wrap`: `K_e` and the vault identity, age-encrypted (armored, one stanza)
    to the entry's key (§15.3 "Wrap plaintext").
- `listTag`, `markersTag`: HMACs under keys derived from `K_e` over the list
  and over the version markers (§15.3, §2.1).
- `epochAuthor`, `epochReason`, `home`, `epochSig`: who created the epoch,
  why, which device is home (the one device that changes the list, §15.3),
  and the author's signature (§15.5). `author`, `authorSig`: the device that
  wrote this version of `vault.json` (home) and its signature.
- `parent`, `epochLink` and `parentList` appear exactly above epoch 1, and
  `recoverySig` in a takeover (or, optionally, a kit replacement) (§15.3);
  `reencryptPending` only during a re-encryption (§15.8), which this version
  never writes.
- `features` (optional): array of strings naming format extensions the vault
  uses. This version defines none: its writers write no `features`, and
  absent means `[]`. A later version adds an extension's name here so that
  readers that do not implement it stop writing: a writer that finds a
  feature it does not implement must not write to the vault (it may still
  read it: read-only access, §7.3).
- `label` (optional): the vault's display name, for lists where the folder
  name says nothing (a WebDAV server's `dav/`). It is stored **unencrypted**:
  anyone who can read the vault folder or the server can read it, and anyone
  who can write there can change it, so it must hold nothing private. A
  string; writers store it on one line (control characters become spaces,
  invisible format characters such as bidi overrides and isolates, Unicode
  Cf, are removed), trimmed, at most 80 characters, and omit it when empty. It is
  informational and covered by no tag or signature: a reader may show it (cleaned the same way) and must not act
  on it; anything but a non-empty string reads as absent.

**Writers.** Only the home device writes `vault.json` (design §5.6): at
creation, when it approves a device (one entry appended with a wrap of the
current `K_e`; no file is re-encrypted) and when it renames one. Each such
write re-computes `listTag` and `markersTag` and re-signs `authorSig`, in one
atomic write. The one exception is `label`: any listed device whose list
checks (§2.1) may set or clear it, writing every other member back as it is.
A writer starts from the `vault.json` on disk and stops if it is no longer
the version it opened (but for `label`). Removing a device, handing the home
role to another device and replacing the recovery key are home's too, and each
starts a new epoch (§15.14); a takeover with the recovery key starts one by
the device that becomes home.

### 2.1 Checking `vault.json`

`vault.json` is plaintext that anyone who can write the folder (a sync
server, a shared folder, a backup put back) can change. A device holding
`K_e` (from its own wrap) checks it before it writes anything, against what
it verified before:

1. At epoch 1, `root` must be the one `K_1` gives (§15.7 rule 2). Above epoch
   1, the epoch record `vault.json` names must be there (else `otherEpoch`: the
   change waits for its record) with the SHA-256 `epochRecordHash` gives, open
   under `K_e`, and carry a chain that verifies from `root` (§15.7, with this
   device's pinned chain for takeovers; else `epochSig`, `introducesDevice` or
   `rootMismatch`), whose last entry is this file's epoch (its id, parent, home,
   reason, recovery key, first and parent lists and signatures). The precedence
   rule (§15.9) over this device's pinned chain and that chain must keep exactly
   that chain (else `otherEpoch`: an older epoch, a branch this device does not
   follow, or a takeover by a kit it has not pinned yet). In every case `root`
   must be the trust record's and the root given by the user when one is (the
   kit's, the join's reply code, `--root`): otherwise `rootMismatch`.
2. With a trust record (§15.10) pinning this epoch: `home` and the
   epoch's first list are the record's, never the file's (another home is
   only a handoff, a new epoch: `entriesChanged` otherwise), so `epochSig`
   and every `addSig` verify under the home the device verified; every check
   of §15.3 passes against the list the device verified (plus home's
   additions, each with a valid `addSig`); every entry it verified is still there with
   the same key and signing keys (`entriesChanged` otherwise: a removal always
   starts a new epoch; only `name` may change); and the version markers are
   at least those it verified (below). Pinning an earlier epoch: every check
   of §15.3 against the epoch's first list from the chain and its parent as the
   chain gives it, and the markers at least those it verified (`newEpoch`).
3. Without one: the checks of §15.3 against the epoch's first list. A device
   that keeps trust records and was given no root cannot tell this vault from
   one storage built around its public key (`rootUnconfirmed`): it reads, and
   writes once the home device's reply code confirmed its join (§15.12) or
   the user gave the kit's root.
4. A record that exists but cannot be read is never taken as "no record"
   (`recordUnreadable`).

A list that fails any check is **refused for writing**: the device writes
nothing to the vault (no revision, blob, inbox file, settings, notebook
record or `vault.json`), and reports why. Reading still works: every file
carries its own tag. A device that writes saves what it verified as its trust
record (§15.10) before it writes; a device that only reads keeps none. The
reference implementation keeps the record in
`$XDG_STATE_HOME/sempere/trust/<vaultId>.json` (CLI, mode 0600 in a 0700
folder) and in the app's Application Support folder. It holds public keys
only, is kept private (it names the vault's devices) and is never copied
between devices.

A vault opened with the recovery key (§3) reads everything and writes
nothing; it keeps no trust record and is checked against the root given with
it (step 1), or against none.

**Link key pairs.** `epochLink` (§15.3) is a pair of signatures by keys
derived from the parent epoch's `K`, deterministic functions of it:

| Key pair | Derivation | Public key | Signature |
| --- | --- | --- | --- |
| Ed25519 (RFC 8032, pure, no context) | private key = the `epoch link ed25519 seed` of §15.2 (the RFC 8032 32-byte seed) | 32 bytes | 64 bytes |
| ML-DSA-65 (FIPS 204) | `ML-DSA.KeyGen_internal(ξ = ` the `epoch link ml-dsa-65 seed` of §15.2`)` (FIPS 204 Algorithm 16) | 1952 bytes (`pk`) | 3309 bytes |

ML-DSA-65 signatures are made with `ML-DSA.Sign` (pure, hedged or
deterministic: both verify the same) with an **empty context string**, and
checked with `ML-DSA.Verify` with an empty context. The private keys and
seeds are never stored. `linkPublicKeys(K)` names the pair of public keys;
epoch 1's are what `root` is computed from, and the trust record keeps each
pinned epoch's. A link is valid only when **both** signatures verify; one
valid signature alone is invalid, so the link stays unforgeable while either
scheme does. Vectors: `Tests/SempereTests/Fixtures/epoch-vectors.json`.

**Version markers.** (Security review 2026-10, N3.) `format` and `features` decide whether a reader may
write at all (§2, §7.3), and like everything in `vault.json` they are
plaintext: without a tag, whoever can write the folder could set `format`
back to `sempere/1` or drop a feature this reader does not implement, and it
would write to a vault it must only read. `markersTag` is the lowercase hex
(64 digits) of

```
HMAC-SHA256(key = markersKey,
            message = "sempere/1" ‖ 0x00 ‖ "markers" ‖ 0x00 ‖ vaultId ‖ 0x00 ‖ format
                      ‖ 0x00 ‖ feature₁ ‖ 0x00 ‖ feature₂ … ‖ 0x00 ‖ featureₙ)
```

with `markersKey` of §15.2, over `vaultId` (lowercase), `format` exactly as
written, and the distinct `features` sorted by their UTF-8 bytes (so their
order and repetitions in the file do not matter), each UTF-8. A marker
containing `0x00` never verifies. Every writer of `vault.json` writes
`markersTag` for what it writes, in the same atomic write. `authorSig` covers
`format` and `features` too (§15.5).

A reader holding `K_e` refuses the vault for writing (above) when
`markersTag` does not verify (`markersTag`), and when the trust record holds
markers and `format` names a lower major or `features` lacks one of the
record's (`markersRolledBack`: an older `vault.json` put back; markers only
grow, since no writer lowers `format` or removes a feature). Newer markers
still make the vault read-only (§7.3) whatever their tag. This version has no
repair: the user puts back the home device's `vault.json` (a backup, another
copy).

**Limits.** The check is only as fresh as the trust record. A device that
opens a vault for the first time with no root to check trusts the list it
finds; that is why a joining device confirms home's reply code (§15.12) and
the kit carries the root.

## 3. Keys

### 3.1 Identity

An age native identity, exactly as the reference `age-keygen -pq` produces
it (c2sp.org/age, "Native recipient types"), of type MLKEM768-X25519:

- **MLKEM768-X25519** (hybrid post-quantum, `age-keygen -pq`, age v1.3+): a
  32-byte seed, Bech32 with HRP `AGE-SECRET-KEY-PQ-` (77 characters). Its
  recipient is the 1216-byte X-Wing public key (ML-KEM-768 encapsulation key
  ‖ X25519 public key), Bech32 with HRP `age1pq` (1959 characters; the
  Bech32 90-character limit does not apply). Files to it carry one
  `mlkem768x25519` stanza: HPKE (RFC 9180) base mode with KEM
  MLKEM768-X25519 (0x647a, draft-ietf-hpke-pq-03, which is X-Wing,
  draft-connolly-cfrg-xwing-kem), HKDF-SHA256 and ChaCha20-Poly1305, `info`
  `age-encryption.org/mlkem768x25519`; the one argument is the base64 1120-byte
  encapsulation, the body the 32-byte sealed file key. Secure against
  "harvest now, decrypt later" by a future quantum computer, provided no
  stanza of another type sits next to it.

Three kinds of key are such identities:

- the **vault identity** `V_e`, derived from `K_e` (§15.2). Every vault file
  (revisions, blobs, inbox files, `settings.age`, notebook and epoch records)
  is encrypted to its recipient `v_e`, in exactly one stanza;
- a **device key**: generated by each device, listed in `keys` with its
  signing keys (§2). Its private half never leaves the device and is never
  stored in a vault. The reference CLI keeps it in
  `$XDG_STATE_HOME/sempere/devices/<vaultId>/device.key` (mode 0600), or
  passphrase-wrapped as `device.key.age`;
- the **recovery key**: one per vault, printed in the recovery kit (§15.13)
  and kept by no device. It opens the vault read-only.

A classic X25519 identity (`age-keygen` without `-pq`, `AGE-SECRET-KEY-1…`)
never opens a vault; implementations should say so rather than only report
that no key matches.

The corresponding recipient is derived from the identity. Reading files
encrypted to an MLKEM768-X25519 recipient with the stock CLI needs `age` 1.3
or later.

### 3.2 The passphrase copy

`keys/recovery-<fingerprint>.key.age` (optional) is the recovery key,
age-encrypted with a single scrypt (passphrase) recipient, with the vault id
and root inside (§15.11). It is the only file in `keys/`. Writers use scrypt
work factor 20; readers must accept any work factor up to 20 and may refuse
larger with an error. The cap exists because scrypt at work factor w needs
2^w × 1 KiB of memory (20 → 1 GiB), the most the iPad target can allocate.

It sits with the vault, so whoever can read the vault's storage can try
passphrases on it offline: writers MUST refuse a passphrase that is easy to
guess (the reference implementation refuses one estimated below about 70
bits, `PassphraseStrength`, with no override; key-hierarchy design §8.2).
`age -d keys/recovery-<fingerprint>.key.age` with the passphrase gives an
identity file stock `age -i` reads.

### 3.3 Key changes

Within an epoch the list changes in two ways, both by home (§2): approving a
device that asked to join (§15.12) and renaming a device. Neither re-encrypts a
file. Removing a device, handing the home role over, a takeover with the
recovery key and replacing the recovery key start a new epoch (§15.14): a new
key for every file written afterward, while the files written before keep
theirs and stay readable through the epoch records. Re-encrypting every file is
phase KH6. Earlier drafts of this format changed recipients by rewrapping every
file; that mechanism is gone, with no migration.

## 4. Encrypted file bodies

Every revision file (`notes/<noteId>/*.age`) is an age v1 file with exactly
one `mlkem768x25519` stanza, to the vault identity's recipient `v_e` (§3.1,
§15.2), whose plaintext is (blobs in `att/` use their own framing, §8.1.3):

| Offset | Size | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `SMPR` |
| 4 | 1 | body version, `0x01` |
| 5 | 32 | HMAC-SHA256 tag (below) |
| 37 | rest | `gzip(JSON)` (§5), gzip framing so `gunzip` reads it |

Tag = HMAC-SHA256(key = tagKey,
message = `"sempere/1" ‖ 0x00 ‖ noteId ‖ 0x00 ‖ filename ‖ 0x00 ‖ gzipBytes`),
where `tagKey` is derived from the epoch's key `K_e` (§15.2), `filename` is the file's base name (e.g. `00017596...-a1b2c3d4-12.delta.age`)
and `noteId` is the note directory name. Binding the file name stops a
revision being replayed under another note or name. The label `sempere/1`
names this framing (body version `0x01`), not the vault's `format`: it stays
the same in a vault of a later major (§7.6).

A body version higher than the reader implements is newer content (§7.2):
the file is reported as newer, not as corrupt.

Readers must verify the tag when the vault key is available and must
report, not silently drop, files that fail. Recovery without the app takes
the vault identity out of the recovery entry first (the kit's script,
§15.13), then reads any file with it:

```
jq -r '.keys[] | select(.role == "recovery") | .wrap' vault.json | age -d -i recovery.txt > vault-keys.txt
age -d -i vault-keys.txt FILE.age | tail -c +38 | gunzip | jq .
```

A device key file opens its own entry's wrap the same way. This needs `age`
1.3 or later (post-quantum keys); older `age` reports that no identity
matched.

## 5. Revisions

Each file directly under `notes/<noteId>/` is one revision. The `att/`
subdirectory holds the note's blobs (§8.1); it is not a
revision and revision listings skip it. Name:

```
<hlc>-<device>-<seq>.<delta|snapshot>.age
```

- `hlc`: hybrid logical clock, 17 ASCII digits: 13-digit Unix milliseconds
  followed by a 4-digit counter, both zero-padded. Lexicographic order of
  `hlc` is causal-ish time order. The clock follows the usual HLC rules:
  on every local event or received revision, `millis = max(wall, seen)`,
  counter increments on ties and resets otherwise. A device does not adopt
  a received `hlc` more than 24 hours ahead of its own wall clock; such a
  revision still merges using its `hlc` exactly as written.
- `device`: 8 lowercase hex chars, random per app installation. Never a
  hardware identifier.
- `seq`: per (note, device) counter, decimal, starting at 1, gap-free,
  at most 2^53 − 1 (9007199254740991, the largest integer every JSON
  implementation holds exactly). A writer chooses `seq` greater than every
  `seq` for its device that appears in a file name of the note or is covered
  by any snapshot's `included` (§5.3), so a seq whose file was compacted away
  is never reused. Readers reject a larger `seq` in a file name, a revision
  or `included` (§9).

Ordering key for anything that needs a total order: `(hlc, device, seq)`.

A reader must reject a revision whose JSON `noteId`, `device`, `seq` or
`hlc` (§5.1) disagree with its directory name or file name, and report it
like any other unreadable file.

What a writer observes (informative). Before writing to a note a writer
observes the readings of the note's revisions, so its revision sorts after
them. It observes only revisions that decrypt, authenticate (§4) and
decode, whose name's `hlc` is then the body's (above). A file that cannot
be read at all (not downloaded yet, removed meanwhile) is observed by its
name with the reading capped at the writer's wall clock; a file that reads
but does not decrypt, authenticate or decode is not observed, since anyone
who can put a file in the folder can make one (§9), and its name must not
move the clock. The next `seq` is still above every `seq` of the device in
any listed name, readable or not, and in every snapshot's `included`: that
only avoids a collision. The app reads every revision for this (headers
checked, without stroke geometry), so content of a newer version (§7.3) is
seen before the write.

### 5.1 Common fields

```json
{
  "type": "delta",
  "noteId": "…",
  "device": "a1b2c3d4",
  "seq": 12,
  "hlc": "17596320000000003",
  "wall": "2026-10-04T16:20:00.123Z",
  "app": "sempere-ios/0.1"
}
```

`wall` is informational (history UI). `app` is informational.

Three optional fields. A reader treats a value of the wrong JSON type or
form as absent; it never rejects the revision for it.

| field | on | value | meaning |
| --- | --- | --- | --- |
| `session` | delta | string, 1 to 64 characters from `[0-9a-z-]` | the editing session that wrote the delta (§5.8.2) |
| `checkpoint` | delta | object, optionally with `name` (a string) | the note as of this delta is a version the user saved (§5.8.1) |
| `asOf` | snapshot | `"<hlc>-<device>-<seq>"` | the snapshot holds the note as of that revision (§5.8.3) |

Two more optional fields mark a revision written by a
later version (§7.1): `format`, a format identifier (`"sempere/2"`), and
`features`, an array of extension names (§2). Writers of this version write
neither. Unlike the fields above, a malformed value rejects the revision
(§7.2), and a newer value makes the reader read the revision as §7.4 says and
keep the vault read-only (§7.3).

```json
{ "type": "delta", "noteId": "…", "device": "a1b2c3d4", "seq": 13,
  "hlc": "17596320000000009", "wall": "2026-10-04T16:25:00.000Z",
  "app": "sempere-ios/0.1", "session": "5f0c3e8a-2b7d-4c1e-9a3f-6d2b8e4f1a07",
  "checkpoint": { "name": "Before the exam" }, "ops": [] }
```

### 5.2 Delta

Adds `"ops": [Op, ...]`, applied in order. Ops:

| op | fields | effect |
| --- | --- | --- |
| `addStroke` | `page`, `stroke` | add stroke to page (no-op if page removed) |
| `removeStroke` | `page`, `strokeId` | remove stroke; wins over any add |
| `addPage` | `page: {id, order, parent?}` | add an empty page |
| `removePage` | `pageId` | remove page and its strokes; wins over adds |
| `setPageOrder` | `pageId`, `order` | LWW on the page's order key |
| `setPageRecognition` | `pageId`, `recognition` | LWW on the page's recognized text (§5.5); `null` clears it |
| `setPagePaper` | `pageId`, `paper` | LWW on the page's own paper (§5.4.2); `null` makes the page follow the note's paper again |
| `setMeta` | `field`, `value` | LWW per field (§5.4); `tags` is not a field (§5.4.1) |
| `addTag` | `tag` | add one instance of a tag (§5.4.1) |
| `removeTag` | `tag`, `observed` | remove the listed instances of a tag (§5.4.1) |
| `deleteNote` | | LWW with `restoreNote` on `deleted` |
| `restoreNote` | | |
| `addItem` | `page`, `item` | Add a placed item (§8.2) to the page (no-op if page removed) |
| `removeItem` | `page`, `itemId` | Remove the item; wins over any add; permanent tombstone |
| `setItem` | `page`, `itemId`, `field`, `value` | LWW per (item, field) on the item's registers (§8.2.2) |
| `addRecording` | `recording` | Add an audio recording to the note (§8.3) |
| `removeRecording` | `recordingId` | Remove it; wins over any add; permanent tombstone |
| `setRecording` | `recordingId`, `field`, `value` | LWW per (recording, field) (§8.3) |

The LWW timestamp of an op is the revision's `(hlc, device)`. `addPage`
adds the page empty; strokes go in `addStroke` ops and items in `addItem`
ops. A stroke id is never added again after it has been removed; a writer
that undoes an erase, or restores from history, must mint a new id and may
set `parent` to the old one. The same holds for page, item and recording
ids.

### 5.3 Snapshot

Adds:

```json
"included": { "a1b2c3d4": { "upTo": 12, "extra": [15, 16] },
              "99ee00ff": { "upTo": 3,  "extra": [] } },
"state": State
```

`included` names every revision the snapshot already reflects: for each
device, all `seq ≤ upTo` plus the listed `extra` (seen out of order).
`included` must list only deltas the snapshot applied in full: a delta with
an `addStroke`, `setPageOrder`, `setPageRecognition`, `setPagePaper`, `addItem`
or `setItem` naming a page the writer has not seen, a `setItem` naming an item
it has not seen, or a `setRecording` naming a recording it has not seen, is
left out, so it is applied again once the page, item or recording arrives. An
id the writer knows only from a tombstone counts as seen (the op is a no-op).
(Removals of unseen ids are recorded as tombstones instead, §5.4.)

Readers reconstruct a note as the merge of every snapshot present plus every
delta not covered by any snapshot's `included`. Pages, strokes, placed items
(§8.2) and recordings (§8.3) merge as sets: an element is present if some
snapshot holds it or an uncovered delta adds it, unless a tombstone or an
uncovered remove names it, its page is gone, or some snapshot covers the
revision in its `origin` (§5.5, §5.6) but does not hold it. Metadata, page
order, item and recording registers and `deleted` merge by LWW, using each
snapshot's recorded clocks and each delta op's own timestamp.
Reconstruction is order-independent: the same set of revisions gives the
same state whatever order they are read in, and implementations must have a
test that reconstructs from shuffled revision orders and compares.

A device may write a snapshot at any time. A delta may be deleted when at
least one snapshot covers it and it is older than the retention window
(default 30 days by `wall`). A snapshot may be deleted when another
snapshot's `included` is a superset of its `included` and it is older than
the window; of two snapshots with equal `included`, keep at least one.
Compaction never deletes blobs; they have their own per-note collection rule
(§8.1.6). Compaction never deletes a checkpoint
(§5.8.1), and keeps each checkpoint that was a complete restore point (§5.7)
complete: it adds the positioned snapshots and keeps the witnesses that
§5.8.4 rules 2 and 3 require, with the checkpoints as the targets. Thinning
(§5.8.4) is compaction with a different choice of what to delete. A
compactor also keeps the first revision by `(hlc, device, seq)` while any
other revision has an earlier `wall`: `created` comes from the first
revision's `wall` (§5.4), so deleting it would let a later-ordered revision
whose device clock was behind move `created`, in the current state and in
every version.

### 5.4 State and metadata

Tags are matched case-insensitively ("Math" and "math" are one tag) with
inner whitespace runs collapsed (multi-word tags are fine): the **tag key**
of a tag is its whitespace-separated words joined by one space, then
lowercased (Unicode default case mapping). A note's tags are a set keyed by
tag key that merges per tag, not as one register (§5.4.1), so tags added on
two devices concurrently are both kept. Apps list a tag with one spelling
per key (§5.4.1). Titles are labels, never keys: any number of
notes may share a title, in one notebook or several.

```json
{
  "deleted": false,
  "meta": {
    "title": "Lecture 3",
    "tags": ["math", "fall"],
    "notebook": "School",
    "favorite": false,
    "created": "2026-10-04T16:20:00Z",
    "paper": { "kind": "ruled", "spacing": 24,
               "background": "#FFFFFFFF", "lineColor": "#D0D8E8FF" },
    "pageSize": { "width": 612, "height": 792, "infinite": false },
    "lang": "en-US",
    "markersBehindText": true,
    "recognized": { "at": "2026-10-08T14:05:00Z", "pages": 5, "read": 2 }
  },
  "pages": [ Page, ... ],
  "recordings": [ Recording, ... ],
  "tagSet": TagSet
}
```

`recordings` (§8.3) is omitted when empty and sorted by
`(started, id)`. `tagSet` (§5.4.1) is required in a snapshot's `State`;
`meta.tags` is derived from it.

- `created` is set once by the first revision and never changes. Readers take
  the earliest of any snapshot's recorded `created` and the `wall` of the
  earliest known revision by `(hlc, device, seq)`.
- `notebook` is a free string (or `null`: in no notebook). `/` separates
  the levels of a display hierarchy: `Research/Daily log` is the notebook
  `Daily log` inside `Research`. For display, grouping and filtering, each
  segment is trimmed of whitespace and empty segments (leading, trailing or
  doubled `/`) are dropped, so `" Research//Daily log/ "` names the same
  notebook; a name with no segment left is no notebook. Writers should store
  this canonical form but readers must not rely on it. Parent levels exist
  implicitly (no note needs to be in `Research` itself), and selecting a
  notebook shows the notes in it and in every notebook below it. Renaming or
  moving a notebook is one `setMeta` of `notebook` per affected note,
  replacing the old path prefix. A notebook no note names exists only while
  a notebook record declares it (§14): records keep notebooks the user
  created and has not filled yet, or emptied; the rename or move of a
  notebook also renames its records.
- `paper` is the note's paper; see §5.4.2 for its kinds and parameters. Lengths are points (1/72 in).
- `pageSize.infinite: true` means the page grows downward; `height` is then
  the current extent.
- `pageSize.breakHeight` (optional, points): for an infinite page, the height
  of each page a paginating exporter (PDF) splits it into. Absent, it
  is `width × 11 / 8.5` (letter aspect). Ignored for finite pages.
  §5.4.3 calls this the note's *sheet height* and says how exporters
  paginate.
- In a snapshot, `pages` are sorted by `(order, id)`.
- `lang` (optional): the language the note is handwritten in, a BCP 47 tag
  (`en-US`, `es-ES`, `es`). Writers store 1 to 8 subtags of 1 to 8 ASCII
  letters or digits joined by `-`, the first subtag letters only, at most 64
  characters (an imported `en_US` is stored `en-US`). Recognizers (§5.5) read
  the note's handwriting in this language; absent means the recognizer's
  default (the device language, or English). `setMeta` with `null` clears it.
  A `setMeta` value that is not such a tag is invalid (the revision is
  rejected); a snapshot `lang` that is not one reads as absent.
- `markersBehindText` (optional, boolean, absent means `false`): marker
  strokes (`ink.tool` `marker`) are drawn below the page's content items
  instead of above them (§8.2.3), as a highlighter behind typed text.
  Writers omit it when false; a snapshot value that is not a boolean reads as
  `false`.

- `recognized` (optional): the last
  deliberate handwriting reading of the note ("Recognize All Notes" in the
  app, `sempere recognize` in the CLI), an object
  `{"at": RFC 3339 time, "pages": n, "read": m}`: when it ran (§6), how many
  pages the note had and how many of them it wrote recognition for (§5.5),
  integers with `0 ≤ read ≤ pages ≤ 100000`. It is written in the same delta
  as that run's `setPageRecognition` ops, only when the run wrote at least
  one (a note found current is left as it is). Apps list the notes whose
  `at` is within the last 7 days, and not more than a day ahead of the
  device's clock ("Recently Recognized"), on every device,
  since the register syncs like the rest of the note; the recognition a
  page's own editor writes as the user draws does not set it. `setMeta` with
  `null` clears it (the note leaves the list). A `setMeta` value that does
  not decode or breaks the bounds is invalid (the revision is rejected); such
  a snapshot value reads as absent.

`State` carries `"clocks"`, mapping each of the nine LWW registers (`title`, `notebook`, `favorite`, `paper`, `pageSize`, `deleted`,
`lang`, `markersBehindText`, `recognized`) to the stamp of the
op that last set it, encoded `"<hlc>-<device>"`, e.g.
`{"title": "17596320000000003-a1b2c3d4"}`. Writers record all nine, the zero
stamp `00000000000000000-00000000` for a register never set. A delta the
snapshot does not cover wins a register only if its own `(hlc, device)` is
greater than that stamp; between snapshots, the greater recorded stamp wins.
A register with no clock is treated as stamped by the snapshot's own
`(hlc, device)`.

`State` may carry `"tombstones": {"strokes": [uuid, ...], "pages": [uuid, ...],
"items": [uuid, ...], "recordings": [uuid, ...]}`.
A delta adding a tombstoned id stays removed. `strokes` lists ids whose
`removeStroke` was seen while the revision that added the stroke was not yet
covered by `included`; once it is covered, the tombstone may be dropped.
`pages` lists every removed page id and is never pruned, so a late op on a
removed page is a no-op rather than an orphan (§5.3). `items` and
`recordings` list every removed item and recording id
and are never pruned either, for the same reason (`setItem`,
`setRecording`). `lineage` and `superseded` (§5.6.1) keep what that rule needs once compaction has deleted
the deltas: `superseded` lists every stroke id the writer knows to be
superseded, never pruned; `lineage` is
`[{"stroke": uuid, "parent": uuid, "by": "<hlc>-<device>-<seq>"}, ...]`,
sorted by `stroke`: removed, not superseded strokes that replaced `parent`
in the revision `by` (their group), namely every one that is an ancestor,
over replacements, of a stroke the snapshot holds, and for each replaced
stroke whose winning group has no stroke held or listed, one stroke of that
group (the smallest id). An entry whose `by` does not parse is ignored.
All fields are omitted when empty.

#### 5.4.1 Tags: per-tag merge (observed-remove set, add wins)

A note's tags are an observed-remove set of **tag instances**. Each
`addTag` op adds one instance, identified by the op's origin
`"<hlc>-<device>-<seq>-<op>"` (§5.5) and belonging to the key of its `tag`.
A `removeTag` op removes exactly the instances it lists:

```json
{ "op": "addTag", "tag": "Math" }
{ "op": "removeTag", "tag": "math",
  "observed": ["17596320000000003-a1b2c3d4-12-4", "17596310000000000-99ee00ff-7-1"] }
```

- `addTag.tag`: the tag as written: whitespace runs collapsed to one space,
  trimmed, not empty. A writer adds a tag only when the note has no live
  instance of its key. Readers normalize `tag` the same way (in deltas and
  in snapshots) and ignore an instance whose tag is then empty.
- `removeTag.tag`: any spelling of the key; `observed`: every live instance of
  that key the writer sees (a writer removes a tag by listing all of them).
  Instances of other keys are never affected, even if listed. An origin
  names a real revision: its `seq` is at least 1, and an `observed` entry
  that does not parse that way makes the op invalid.
- A tag (key) is on the note while it has at least one live instance. An
  instance is live if some snapshot holds it or an uncovered delta adds it,
  unless any revision's `removeTag` (covered or not) or any snapshot's
  `removed` names it under its key.
  Removed instances are permanent, like page tombstones: a removed
  instance's add arriving late stays removed.

**Concurrent add and remove: add wins.** A remove only removes the instances
its writer had seen, so a tag added on another device that the remover had
not yet received survives, as does a re-add after a remove. This deliberately
differs from strokes (§5.2, remove wins): a stroke id is added once and never
again, so its remove covers its only add, whereas the same tag is added
again routinely, and silently losing a tag the user just added on the other
device is worse than a removal that has to be repeated. Per-key LWW on the
HLC was rejected for the same reason: with clock skew between devices (up to
the 24 hours §5 allows a clock to adopt), a remove could delete an add it
never saw.

**Spelling and order.** A key's spelling is the `tag` of its earliest live
instance by origin order `(hlc, device, seq, op)` (first-seen spelling,
deterministic on every device). Changing the spelling of a tag is a
`removeTag` of the key followed by an `addTag` with the new spelling, in one
delta. Tags are listed in the order of their keys' earliest live instances
(the order they were added).

Tags are not an LWW register: `setMeta` has no `tags` field (§5.4), and a
`setMeta` naming it is an unknown field (the revision is rejected).

**Snapshots.** A snapshot carries the set in `State`:

```json
"tagSet": {
  "instances": [ { "tag": "Math", "origin": "17596320000000003-a1b2c3d4-12-4" } ],
  "removed":   [ { "key": "fall", "origin": "17596310000000000-99ee00ff-7-1" } ]
}
```

- `instances`: every live instance, sorted by `origin`.
- `removed`: every instance (key and origin) named by a `removeTag` or by an
  input snapshot's `removed`, sorted by `(origin, key)`; never pruned.

`tagSet` is required in a snapshot (`instances` and `removed` may be empty
arrays); a snapshot without it is malformed. Its `meta.tags` holds the
resulting tags in display order, for stock-CLI recovery; readers ignore it.

Merging is a union of commutative parts (instances and removals), so
reconstruction stays order-independent (§5.3) and correct through any
compaction.

#### 5.4.2 Paper

`meta.paper` (and a page's own `paper`, below) describes the page background
and ruling:

```json
{ "kind": "cornell", "spacing": 24, "background": "#FFF8E1FF", "lineColor": "#D0D8E8FF",
  "lineWidth": 0.5, "cueWidth": 150, "summaryHeight": 120 }
```

`kind`, `spacing`, `background` and `lineColor` are always written. Every
other field is written only when it differs from the default of its kind
(table) and a missing field means that default.

| field | meaning | default | valid range |
| --- | --- | --- | --- |
| `kind` | pattern, below | | |
| `spacing` | pitch of lines, grid and dots; for `isoDot` / `isoGrid` the dot pitch along a row | 24 | 4 … 200 |
| `background` | page color `#RRGGBB[AA]` (presets: white `#FFFFFFFF`, cream `#FFF8E1FF`, dark `#1C1C1EFF`) | white | |
| `lineColor` | color of rules and dots | `#D0D8E8FF` | |
| `lineWidth` | width of rules | 0.5 | 0.1 … 4 |
| `dotRadius` | radius of dots (`dot`, `isoDot`) | 0.9 | 0.3 … 4 |
| `marginLeft` | distance of a vertical margin line from the left edge; 0 = none | 0 (`marginRuled`: 72) | 0 … 300 |
| `marginTop` | distance of a horizontal margin line from the top; 0 = none | 0 | 0 … 300 |
| `marginColor` | color of the margin lines | `#F2A6A6FF` | |
| `cueWidth` | `cornell`: width of the cue column | 150 | 40 … 400 |
| `summaryHeight` | `cornell`: height of the summary band | 120 | 40 … 400 |
| `staffSpacing` | `staff`: distance between the five lines of one staff | 7 | 3 … 20 |
| `staffGap` | `staff`: gap between one staff's bottom line and the next staff's top line | 40 | 8 … 150 |

Kinds (geometry is in page coordinates, origin top-left, y down; ruling is
laid out from the page's top so it continues unchanged down an infinite
page):

- `blank`: background only.
- `ruled`: a horizontal line at `y = k × spacing`, k ≥ 1, across the page.
- `marginRuled`: `ruled` whose `marginLeft` defaults to 72.
- `grid`: the `ruled` lines plus vertical lines at `x = k × spacing`, k ≥ 1.
- `dot`: a dot at every `(k × spacing, j × spacing)`, k, j ≥ 1.
- `isoDot`: dots in a triangular lattice: rows at `y = j × spacing × √3/2`
  (j ≥ 1), the dots of a row at `x = k × spacing`, shifted by `spacing / 2` on
  odd rows.
- `isoGrid`: the triangular grid through those lattice points: the horizontal
  rows plus the lines `x = n × spacing ± y / √3`, clipped to the page.
- `cornell`: the page (or, on an infinite page, each `breakHeight`-high sheet
  from the top) has a cue column `cueWidth` wide at the left, a summary band
  `summaryHeight` high at the bottom, a vertical line between the cue column
  and the notes area down to the summary band, a horizontal line along the top
  of the summary band (both twice `lineWidth`), and `ruled` lines at
  `spacing` across the notes area only. Cue width is limited to 60 % of the
  page width and the summary band to half a sheet.
- `staff`: staves of five lines `staffSpacing` apart, the first staff's top
  line at `y = staffGap`, the next one `staffGap` below the bottom line of the
  previous; `spacing` is ignored.

`marginLeft` / `marginTop` apply to `ruled`, `marginRuled`, `grid` and `dot`
and are ignored by the other kinds.

Writers keep every parameter inside its valid range. Readers render whatever
they find: they treat a non-finite or out-of-range parameter other than
`spacing` as clamped to its range (non-finite: the default), and draw no
ruling when `spacing` is below 4 or would need an unreasonable number of
lines (the plain background).

**Unknown kinds.** A reader that does not know a `kind` treats the paper as
`blank` (keeping `background`), so a note written by a later version still
opens and renders its strokes. Such a reader keeps the unknown `kind` name and
the fields it knows when it rewrites `paper` (a snapshot or a restore), so its
compaction does not turn the paper into `blank`; fields it does not know are
not kept. Apps should not offer to edit paper they could not render.

**Page paper.** A page may carry its own `"paper"`, which replaces the
note's `meta.paper` for that page; absent, the page follows the note. It is
an LWW register per page, set by `setPagePaper` (`null` clears it so the page
follows the note again), stamped in snapshots by the page's `"paperClock"`,
which works exactly like `recognitionClock` (§5.5): a page with neither
`paper` nor `paperClock` has never had its paper set and does not compete
with a `setPagePaper` the snapshot does not cover. `addPage` ignores any
`paper` in its page object. "Apply to all pages" is a `setMeta` of `paper`
plus a `setPagePaper` with `null` for each page that has its own. A page
added later follows the note's paper.

#### 5.4.3 Paged and pageless notes

A note is **paged** when `pageSize.infinite` is false: every page is a sheet
`width × height`, and pages are read top to bottom in page order (§5.5). It
is **pageless** when `infinite` is true: normally one page that grows
downward. Nothing else marks the layout; it is the `pageSize` register
(LWW, §5.4), so it needs no new op or field.

The **sheet height** `H` of a note is `height` when paged and `breakHeight`
(default `width × 11 / 8.5`) when pageless. Readers use `H = 792` when the
value is not finite or not positive, and clamp it to 72 … 200 000.

**Switching layout** is one delta written from the writer's current state.
It never deletes ink: every stroke that moves is re-added under a new id
with `parent` naming the old one (§5.2), its `transform` translated
vertically (`ty` changed, nothing else), so on screen and in exports each
stroke keeps its position relative to the sheet it is on, and ink keeps
its reading order. A re-added stroke keeps everything else, `rec` included
(§8.3.3). Placed items (§8.2) move the same way: `removeItem` (or the page's
`removePage`) and `addItem` of a new id with `parent` naming the old one
(§8.2.2), `frame` moved vertically by the same amount, every other field
kept; an item's sheet is the one holding the vertical center of its `frame`.

- **Paged → pageless (join).** Let the pages be `P0 … Pn-1` in page order,
  and `s(P)` the sheets a page's ink reaches: 1 + the largest sheet `k` (as
  for a split, below) of its strokes and items, at least 1; it is 1 unless a
  concurrent edit left ink below the page. Page `Pj` starts at
  `oj = (s(P0) + … + s(Pj-1)) × H` (`j × H` when every `s` is 1), so ink
  below one page never lands on the next. `P0` stays. Each stroke of `Pj`
  (j ≥ 1), in that page's stroke order, is re-added to `P0` with `ty + oj`;
  then each `Pj` is removed (`removePage`). If any `Pj` (j ≥ 1) has
  recognition, `P0` gets one `setPageRecognition` (§5.5) whose `text` is the
  pages' texts joined by `\n` and whose `words` are theirs with boxes moved
  by `oj`. Own paper of pages after `P0` is not carried over. Last, `setMeta`
  of `pageSize` with `infinite: true`, the same `width`, `height` the total
  `(s(P0) + … + s(Pn-1)) × H` rounded up to a whole point, and
  `breakHeight: H`, so the pageless page's sheets are where the pages were.
  A pageless note with more than one page (a concurrent split that the
  note's own later `pageSize` write overrode, below) is joined the same
  way, with its sheet height.
- **Pageless → paged (split).** For each page `P` in page order: a stroke
  is on sheet `k = ⌊c / H⌋` (0 for negative or non-finite `c`), where `c` is
  the midpoint of the smallest and largest `y` of its control points after
  its transform. `P` becomes `m` sheets, `m − 1` being the largest `k` of
  its strokes and items, raised for a note with exactly one page to the number of
  whole sheets in `pageSize.height` (`⌊(height + 1) / H⌋`), at least 1 and at
  most 10 000 (larger `k` count as the last sheet). Sheet 0 is `P` itself
  and keeps its strokes. Each sheet `k ≥ 1`, blank ones included so later
  ink keeps its place, is a new page (`addPage`) whose `order` sorts after
  `P` and its earlier sheets and before the next page; each of its strokes
  is removed from `P` and re-added to it with `ty − k × H`; it gets `P`'s own
  paper, if any (`setPagePaper`). A recognition with `words` is split: each
  word goes to the sheet holding the vertical center of its box (beyond the
  last sheet: the last), box moved by `−k × H`; a sheet's `text` is its
  words in order, separated by `\n` where the original text has a line
  break between them (found by locating each word in order in the text;
  if one is missing, all are separated by spaces), else by a space. `P`
  gets a `setPageRecognition` with its share; sheets without words get
  none. A recognition without `words` stays on `P`. Last, `setMeta` of
  `pageSize` with `infinite: false`, the same `width` and `height: H`.

**Recognition that moves** (join, split, and the duplicate and undo-delete
below) keeps telling current from stale (§5.5): its `basis` becomes the digest
of the receiving page's live strokes when every source page's recognition was
current (or the page was blank without any); it is absent when a source had
none (an import, kept until edited); and when a source was stale, or had ink
and no recognition, it is the digest of a freshly generated id, which matches
no strokes, so the text is read again. Text without `words` that stays on a
page whose ink a split moved away is stale.

Translations are exact up to the 3-decimal rounding of `transform` (§5.6),
so a split of a join (or a join of a split) puts every stroke back where
it was, under new ids. Strokes with a non-identity transform keep it:
only `ty` changes.

A concurrent revision merges with a switch like any other: a stroke
another device adds to a page the join removes is removed with it (as for
any page removal, §5.2); a stroke added to a pageless page below its first
sheet after a split was written stays on that page, below its bottom edge,
until the note is joined again. Readers draw and export it anyway (finite
pages, below). A device still drawing on the pageless page may write
`pageSize` (to grow it) after a concurrent split; that write wins the
register, leaving a pageless note with several pages, which readers show in
page order and a join merges.

**Page edits in a paged note** use the ops of §5.2, one delta per user
action:

- *Add a page* (after the current one, or at the end): `addPage` with an
  `order` strictly between its neighbors' keys (§5.5).
- *Move a page*: one `setPageOrder` with a key strictly between its new
  neighbors. Pages with equal keys (two devices inserted at the same place)
  sort by id; when no key fits between the new neighbors, the writer also
  gives the following pages new keys, in order, until one does.
- *Delete a page*: `removePage`. It wins over every concurrent edit of the
  page, a concurrent `setPageOrder` included.
- *Undo a delete*: the page id cannot be added again (§5.2), so the page is
  re-created as for a restore (§5.7): `addPage` with a new id and `parent`
  naming the old one, its strokes and items re-added under new ids with
  `parent` (and their `rec`), its recognition and own paper.
- *Duplicate a page*: `addPage` right after it, copies of its strokes and
  items under new ids (no `parent`: they re-create nothing; `rec` kept), its
  recognition and own paper.

Concurrent moves of one page resolve by LWW on its `order`; moves of
different pages all apply, so the result can interleave both devices'
intentions but always holds every live page exactly once.

**Exporting.** A paginating exporter (PDF, PNG) writes one output page per
page of a paged note, `width × height`. Ink below a finite page (a stroke
whose center `c`, as for a split, is at or below `height`: only a concurrent
edit, above, or another writer leaves one) adds output pages of the same
size after it (at least 72 pt tall, the clamped sheet height), cut like a
pageless page from `height` down and keeping only those that hold ink
centered below the page, so no ink is lost; strokes merely crossing the
bottom edge are clipped by it. A
pageless page is cut into output pages of `width × H`: from the top `t`
of the current output page, the cut is at `t + H`, unless that line
crosses ink; then it moves up to the top of the ink it crosses, if that is
at least `t + 3H / 4` and makes room for the cut (a gap no stroke spans),
otherwise it stays at `t + H` and strokes crossing it appear on both
pages, clipped. A stroke spans the extent of its drawn outline (its
control points under its transform, widened by half its nib); a placed item
(§8.2) spans its frame and, below a finite page, counts by its frame's
vertical center. The next
output page starts at the cut, and the paper is drawn over each whole
output page from `t` down, so ruling stays aligned with the ink. Notes
on `cornell` paper, whose layout repeats every sheet, are always cut at
`k × H`. Exporters may offer fixed cuts (`k × H`) as an option. A
non-paginating exporter (SVG) writes each page as one image of its full
extent.

### 5.5 Page

```json
{ "id": "…", "order": "a0", "strokes": [ Stroke, ... ], "items": [ Item, ... ],
  "recognition": Recognition, "parent": "…", "paper": Paper, "paperClock": "…" }
```

`items` are the page's placed items (§8.2): text boxes,
images and PDF page backgrounds, sorted by `(layer, z, id)` (§8.2.3);
omitted when empty. `addPage` ignores any `items` in its page
object (the page is added empty). `recognition` is optional (below).
`paper` and `paperClock` are optional (§5.4.2).
`parent` is optional: the id of a removed page this one re-creates (a restore from history, §5.7). It is
informational, set by the `addPage` that adds the page and carried into
snapshots; readers may ignore it.

`order` is any string; pages sort lexicographically by `(order, id)`. The
library provides a helper to generate a key between two neighbors.

In a snapshot, a page may carry `"orderClock"`, the `"<hlc>-<device>"` stamp
of the `addPage` or `setPageOrder` that set its `order`, with the same LWW
rule and default as `clocks` (§5.4).

#### Recognized text

A page may carry `"recognition"`, the text recognized in its handwriting:

```json
"recognition": {
  "engine": "vision-26.7",
  "text": "Lecture 3\nlinear maps",
  "words": [ { "t": "Lecture", "box": [52.5, 40.0, 96.25, 30.5] }, ... ],
  "basis": "9f2c4e1d7a0b3c58e6d1f4a2b7c90e13"
}
```

- `engine`: free-form name and version of whatever produced the text, e.g.
  `vision-<OS version>` (Apple's Vision on device: the app on iPadOS, or
  `sempere recognize` on macOS),
  `pencilkit-<iPadOS version>` or `notability-<version>` for an import.
- `text`: the page's recognized text in reading order, lines separated by `\n`.
- `words[].t`: one word of `text`; `words[].box`: its bounding box
  `[x, y, w, h]` in page coordinates (points, origin top-left, y down).
  Writers round to at most 3 decimals. `words` may be empty. Readers that
  draw boxes skip one with a value that is not finite or exceeds 10⁹ in
  magnitude, or a negative `w` or `h` (§9).
- `basis` (optional): which strokes the text was read from, so a writer can
  tell current recognition from stale without reading the ink. The first 16
  bytes, as 32 lowercase hex digits, of the SHA-256 of the page's live stroke
  ids (§5.2): each id as lowercase text, sorted as strings (byte order),
  joined by `\n` with no trailing newline. Strokes are write-once, so equal
  ids mean equal ink. An empty page's basis is the digest of the empty
  string, `e3b0c44298fc1c149afbf4c8996fb924`. Readers ignore a value they do
  not understand and treat it as an opaque string they only compare for
  equality.

Recognition is derived data: it is set as a whole, never merged, and a writer
may replace it at any time (for example after strokes change). It is an LWW
register per page, set by `setPageRecognition`. In a snapshot, a page with
`recognition` or a page whose recognition was cleared carries
`"recognitionClock"`, the `"<hlc>-<device>"` stamp of the op that last set it,
with the same LWW rule as `orderClock` (a `recognition` without a clock is
stamped by the snapshot's own `(hlc, device)`). A page with neither `recognition` nor
`recognitionClock` has never had recognition set and does not compete with
a `setPageRecognition` the snapshot does not cover. `addPage` ignores any
`recognition` in its page object (the page is added empty, §5.2).

Readers that index text for search use `text`; `words` lets a viewer
highlight hits on the page. A recognizer reads a note whose `meta.lang` is
set (§5.4) in that language (with its own fallback when it does not support
it), and otherwise in its default language.

**When recognition is stale.** A page's recognition is *current* when it has
a `basis` equal to the digest of the page's live stroke ids; one with a
different basis is stale (strokes were added or erased since) and a writer
that recognizes text replaces it, with a `basis` of its own. Recognition
without a `basis` (an import, or a writer that does not record one) cannot be
checked: a writer keeps it until it itself changes the page's strokes, and
then replaces it. A page with strokes and no recognition has none yet; a page
with no strokes keeps recognition without a `basis` and clears (sets to
`null`) one whose `basis` names strokes that are gone. Recognition with
empty `text` is valid and current: it says the page was read and had
nothing legible.

In a snapshot, every page and stroke carries `"origin"`,
`"<hlc>-<device>-<seq>-<op>"`: the revision that added it and the op's
index in that revision. A snapshot whose `included` covers that revision but
which does not hold the item has seen it removed. Strokes on a page are
ordered by `origin`. An item without `origin` is treated as added by the
snapshot holding it, at op index equal to its position.

### 5.6 Stroke

```json
{
  "id": "…",
  "ink": { "tool": "pen", "color": "#1A1A1AFF", "width": 2.5 },
  "points": [ [x, y, t, w, h, o, f, az, al], ... ],
  "transform": [1, 0, 0, 1, 0, 0],
  "parent": "…",
  "rec": { "id": "…", "at": 754.125 }
}
```

- `tool` ∈ `pen`, `pencil`, `marker`, `monoline`, `fountainPen`,
  `watercolor`, `crayon`. Unknown tools render as `pen`.
- `color` is `#RRGGBBAA`.
- `points` are the control points of a uniform cubic B-spline, as
  PencilKit's `PKStrokePath` exposes them: location `x,y` in points with
  origin top-left and y down; `t` time offset in seconds; `w,h` the width
  the ink is drawn at, in points (the nib's extent across the stroke, as
  SempereRender draws it); `o` opacity 0...1; `f` force; `az` azimuth and `al`
  altitude in radians. Writers round to at most 3 decimals.
- `w,h` are not `PKStrokePoint.size`: PencilKit draws a pen of size `s`
  `2s − 4` wide (nothing below 2), so a PencilKit reader or writer converts
  per ink (the app's `NibSize`, measured on the iPadOS simulator and Mac Catalyst; on an iPad the drawn width may also depend on the ink).
- `transform` is an optional affine matrix `[a b c d tx ty]`; identity when
  absent.
- `parent` optionally names the stroke this one was sliced from.
- `rec` (optional): the stroke was drawn while recording
  `id` (§8.3) was running, starting `at` seconds after the recording began
  (§8.3.3). Set by `addStroke`, never changed; pieces sliced from a stroke
  copy it.
- A stroke id is never added again after it has been removed; a writer that
  undoes an erase, or restores from history, must mint a new id and may set
  `parent` to the old one.
- `origin` appears only in snapshots (§5.5).
- `replaces` (optional, `true` or absent) appears only in snapshots: the
  revision that added the stroke also removed its `parent` (§5.6.1). Ignored
  inside ops, where readers derive it from the op list.

#### 5.6.1 Replacements and concurrent replacements

A stroke cannot be edited in place, so every edit of one (the pixel eraser
slicing it, a lasso move, resize or recolor, a split moving it to another
sheet, §5.4.3) is a **replacement**: one revision removes stroke `P`
(`removeStroke`) and adds its successors, each with `parent` = `P`. A stroke
`X` *replaces* its parent iff the revision that adds `X` also holds a
`removeStroke` of `X.parent`. Every other stroke with a `parent` (undo of an
erase, a restore from history, the undo of a page delete, a join, §5.4.3,
§5.7) is a **re-creation** and is never affected by this section.

Two devices that replace the same stroke without seeing each other's edit
both remove it, and the union of their successors would show both edits at
once: two sets of pieces drawn over each other, each bringing back ink the
other erased, or a moved copy next to pieces left in place. Readers instead
keep one replacement, last writer wins:

1. The **group** of a replacing stroke is the `(hlc, device, seq)` of the
   revision that added it (its `origin` without the op index, §5.5). The
   groups of `P` are those of every stroke known to replace `P`, live or
   since removed.
2. If `P` has two or more groups, every stroke of the groups other than the
   greatest (compared as `(hlc, device, seq)`) is **superseded**.
3. A stroke that replaces a superseded stroke is superseded too
   (transitively): what the losing device did later to its own pieces goes
   with them. Re-creations do not inherit it.
4. Superseded strokes are treated as removed: not drawn, not in a snapshot's
   `state` (so, once a snapshot covers their add, removed by coverage, §5.3),
   listed in its stroke `tombstones` while their add is not covered, and in
   `tombstones.superseded` (§5.4).

The winning group stays the winner when its strokes are later erased, so
erasing the surviving pieces never brings the other device's back. Because a
removed id is never added again, a group's membership never shrinks while its
revision is present, and more revisions only add groups: a stroke once
superseded stays superseded, so the result is the same for every order and
every subset that contains the same revisions (§5.3).

Evidence for rules 1 to 3 is every stroke of every snapshot (`origin`,
`parent`, `replaces`), every `addStroke` of every delta present, covered or
not, and each snapshot's `tombstones.lineage` (strokes that replace their
`parent`, in group `by`) and `tombstones.superseded`. A snapshot writer sets
`replaces` on each stroke it holds that replaces its parent and writes both
records (§5.4), so deleting the deltas a snapshot covers (§5.3) never changes
the note, now or when more revisions arrive: every group that can still win
is held or listed, every link from a held stroke up to a replaced one is
listed, and every loser is listed as superseded.

Not covered: a re-creation concurrent with a replacement of the same stroke
(one device undoes an erase while another slices the stroke) keeps both, as do
two concurrent re-creations (two joins, two restores). `sempere notes dedupe`
(docs/cli.md) lists such strokes and writes the removals that resolve them.

### 5.7 History and restore

Every revision is a restore point, ordered by `(hlc, device, seq)`, and
shows its `wall`, `device`, `app` and kind, except a snapshot with a valid
`asOf` (§5.8.3), which is history bookkeeping, not a version. A checkpoint
(§5.8.1) is flagged as one, with its name. The note **as of** revision R is
the reconstruction (§5.3) of every revision whose *position* is at or before
R. A revision's position is its own `(hlc, device, seq)`, except for a
snapshot with a valid `asOf`, whose position is its `asOf` (§5.8.3). For a
delta this is not necessarily what R's writer saw (a concurrent revision with
a smaller `hlc` is included, one with a larger is not); it is the only
definition every reader can compute the same way.

Compaction (§5.3) deletes revisions; they are no longer restore points. A
surviving revision R can still be shown only if each deleted revision is
covered by the `included` of a snapshot positioned at or before R, or is
provably ordered after R (R itself, or a surviving revision ordered after
R, of the same device with a smaller `seq`, precedes it). Otherwise readers
report R as incomplete and do not show or restore it. Likewise for an
unreadable revision ordered at or before R, and for every R while any
snapshot is unreadable (it may be the only record of compacted revisions).
A reader that does not know `asOf` positions every snapshot at its own name;
it may then report as incomplete a point that §5.8.3 makes complete, never
the other way round.

Restoring a note to R never rewrites or deletes history. A writer appends
one delta whose ops turn the current state into the state as of R:

- pages, strokes, items and recordings present now but not as of R:
  `removePage` / `removeStroke` / `removeItem` / `removeRecording`;
- pages, strokes, items and recordings present as of R but removed since:
  re-added under new ids (`addPage`, `addStroke`, `addItem`, `addRecording`;
  a re-added page gets its strokes, items, recognition and own paper from R,
  a re-added item or recording its register values as of R), with `parent`
  set to the old id (§5.2);
- `setPageOrder`, `setPageRecognition`, `setPagePaper`, `setItem`,
  `setRecording`, `setMeta` for every page order, recognition, page paper,
  item or recording register and metadata register that differs (except
  `tags`, and `recognized`, which records a reading rather than content and
  is kept as it is), and `deleteNote` or `restoreNote` if `deleted` differs;
- `removeTag` for every tag key present now but not as of R, `addTag` for
  every key present as of R but not now, and both for a key whose spelling
  differs (§5.4.1).

A page, stroke, item or recording counts as present when its id is, or when
one with `parent` naming it is (for a stroke, also with the same `ink`,
`points` and `transform`; for an item or recording, also with the same
immutable fields other than `id` and `parent`, §8.2.2), so restoring the same
point twice writes nothing the second time. Strokes and items are matched
only on the page that corresponds to theirs (the same id, or the re-created
page), so an item moved to another page since R (`removeItem` plus `addItem`
with `parent`, §8.2.2) is put back on its page as of R and its copy on the
other page is removed. An unknown field (§7.5) that an item or recording has now
but did not have as of R is left as it is: no op makes a field absent again
(`null` is a value of it, §8.2.2). Restoring never needs a blob the vault has deleted: a blob
referenced by any surviving revision of its note is never collected (§8.1.6). The delta's `hlc` is issued after observing every revision of the
note, so its LWW ops win over what they set back. Re-added strokes are
drawn above the strokes that stayed (they sort by their new `origin`).
Concurrent revisions the restoring device has not seen merge with the
restore as with any delta: strokes added to a surviving page stay, and
anything on a page the restore removes is removed with it.

### 5.8 Checkpoints, editing sessions and thinning

Three optional fields (§5.1) let a history view say
which versions the user saved, group the autosaves between them, and let
compaction drop most autosaves without losing a saved version. None of them
changes how a note's state is merged (§5.3): a reader that ignores them
reconstructs exactly the same note.

#### 5.8.1 Checkpoints

A **checkpoint** is a delta with a `checkpoint` object: the note as of that
delta (§5.7) is a version the user saved on purpose ("Save Version"). `name`
is the user's label for it; absent, empty or not a string means unnamed.
Writers trim it, store at most 200 characters, and write the checkpoint as a
delta of its own, normally with `"ops": []` after saving any pending edits,
so the version is the note exactly as the user saw it. A checkpoint may carry
ops; the version is then the note as of the delta, ops included. `checkpoint`
on a snapshot means nothing and is ignored.

**Imports are checkpoints.** A writer that imports a note from another
application (the reference importer: `sempere import notability`, including
`--overwrite`) writes the import's delta as a checkpoint: it is a deliberate
full write of the note, not an autosave. The reference importer names it
`Imported from Notability on <UTC minute>` plus ` (modified in Notability
<UTC minute>)` when the source records a modification date. Its `wall` is the
import time, except for a note's first import, whose `wall` is the source's
creation date because it sets `created` (§5.4); the import time is then only in
the name.

A checkpoint is never deleted by compaction or thinning (§5.3, §5.8.4).
Checkpoints are not merged: two devices saving versions at the same time
make two checkpoints, each a restore point.

#### 5.8.2 Editing sessions

`session` is an opaque id an app chooses each time it opens a note for
editing (writers use a fresh lowercase UUID) and writes on every delta it
saves while that note stays open. Closing the note and opening it again, even
a minute later, starts a new id. Readers compare ids only for equality.

A history view groups restore points (§5.7) into **editing sessions**. Walk
the restore points in order; a checkpoint stands alone, at the top level, and
ends the session before it. Every other point joins the current session
unless any of these holds, in which case it starts a new one:

- (a) its `session` differs from the previous point's (absent counts as one
  more value: two points without `session` do not differ by this rule);
- (b) its `wall` is 10 minutes or more after the previous point's (a `wall`
  earlier than the previous point's is no gap);
- (c) its `device` differs from the previous point's.

"Previous point" is the one just before it in the walk, which is always in
the current session. A session is labeled by its first and last `wall`, its
device and its number of points. The grouping is derived, never stored: any
reader computes the same sessions from the same revisions.

#### 5.8.3 Positioned snapshots (`asOf`)

A snapshot with `asOf` = A holds the note as of the revision whose
`(hlc, device, seq)` is A (§5.7): its `state` is that reconstruction and its
`included` covers only revisions ordered at or before A (plus the snapshot
itself, §5.3). Thinning writes them (§5.8.4) so that the revisions a kept
version depends on can be deleted. For history (§5.7) such a snapshot is
*positioned* at A instead of at its own name; it is not a restore point. For
the note's current state (§5.3) it is an ordinary snapshot: it merges like
any snapshot written by a device that had seen only the revisions up to A,
which every reader already handles. Its writer records `clocks` for every
register and `origin` for every page, stroke, item and recording, as for any
snapshot, so its own `(hlc, device)` never stamps a value (§5.4).

`asOf` is **valid** when it parses (`hlc` 17 digits, `device` 8 hex, `seq` a
canonical decimal in 1 … 2^53 − 1, §5), is ordered strictly before the
snapshot's own name, and the snapshot's `included` covers no surviving
revision ordered after A other than the snapshot itself and other snapshots
with a valid `asOf` at or before A (a snapshot built from those holds their
content, which history places at or before A anyway). Readers decide
validity in order of `(asOf, name)`, so a snapshot may rely only on ones
decided before it. A reader that finds
`asOf` invalid positions the snapshot at its own name and lists it as an
ordinary restore point. A need not name a surviving revision.

#### 5.8.4 Thinning

Thinning removes old autosaves and keeps the versions a user is likely to
want. With a cutoff of N days (writers default to 30; "never" is allowed and
deletes nothing) and the note's revisions ordered by `(hlc, device, seq)`:

- The **thinned range** is the longest prefix of the order in which every
  revision's `wall` is more than N days old. A revision with a later `wall`
  (a device with a wrong clock, say) ends the range early; thinning never
  looks past it.
- Kept in the range: every checkpoint; the last restore point of every
  editing session (§5.8.2, sessions computed over all the note's restore
  points, so a session that continues past the range keeps its last point
  outside it); the note's newest revision; every snapshot whose valid
  `asOf` names a revision that is kept; the *witnesses* below; and the
  first revision while another has an earlier `wall` (§5.3).
- Everything else in the range may be deleted, deltas and snapshots alike,
  subject to the rules below. Revisions after the range are never deleted.

**Thin everything except checkpoints** is its own rule: every revision whose
`wall` is not in the future is in the range, and no session end is kept: what
stays is every checkpoint and the note's newest revision (and the newest
restore point, which a positioned snapshot of an earlier run may follow by
name), plus the snapshots, witnesses and first revision the rules below and
§5.3 keep. When the first revision is kept because another has an earlier
`wall`, those revisions stay too, so running it twice deletes nothing the
second time (G4). Writers offer it as its own, explicitly labeled action,
never as the default, and say in the preview which rule applies and what it
keeps. (A cutoff of zero with the ordinary rule keeps each session's last
point as well.)

Whether a note has anything to delete is decided from its revisions' names,
`wall`, `checkpoint`, `session`, `asOf` and snapshot `included` only, never
their ops or states; a thinner may keep that metadata per revision file
(§10) and read in full only notes that have a candidate.

A thinner must not delete anything until it has written the snapshots its
deletions rely on, and must keep these rules, which make every subset of its
deletions safe as well (a crash half-way leaves a correct vault):

1. **State.** A delta is deleted only if a snapshot that is not deleted
   covers it; a snapshot X only if a snapshot that is not deleted has an
   `included` that is a superset of X's and is either a strict superset or
   has a greater name (the order of §5.3, so two thinners or compactors
   running at once never delete each other's last cover).
2. **Kept versions.** Call *targets* the kept checkpoints and session ends,
   the newest revision, and every revision after the range, each one that
   was complete (§5.7) before thinning. Each target stays complete with the
   same note as of it. For each target T that a deletion would make
   incomplete, the thinner writes a snapshot with `asOf` = T, built from
   every revision positioned at or before T (before deleting anything). Its
   `included` then also covers the positioned snapshots among those, which
   §5.8.3 allows. When one of those sources covers a revision ordered after
   T that stays (its device's clock ran fast, §5), that `asOf` would be
   invalid: the thinner deletes nothing ordered at or before T instead.
3. **Witnesses.** For a target T and a device X other than T's that has a
   revision ordered after T in the range that is deleted, the first revision
   of X ordered after T is kept. §5.7 can only tell that a deleted revision
   of X is ordered after T from a surviving revision of X at or after T with
   a smaller `seq`; the witness is that revision. A witness is not a target:
   it may itself become incomplete.

**Guarantees.** For any set of readable revisions (thinning refuses a note
with an unreadable revision):

- G1. The note's current state (§5.3) after thinning equals the state before.
- G2. No checkpoint is deleted; each target that was complete stays complete
  and the note as of it is unchanged.
- G3. No revision after the thinned range is deleted, and every blob stays
  (§8.1.6 collects blobs on its own terms).
- G4. Thinning twice with the same cutoff and no new revisions deletes and
  writes nothing the second time.
- G5. Every deleted revision is covered by a surviving snapshot, so the
  ordinary compaction rules (§5.3) hold, and every prefix of the deletion
  sequence keeps G1 and G2.

**Cost.** Each target that needs one gets a full snapshot of the note as of
it, so thinning can add up to (targets in the range) × (size of the note)
bytes while it deletes the autosaves between them; writers report both
before thinning (a dry run). In practice that is one snapshot per editing
session older than the cutoff that had more than one autosave.

## 6. Identifiers and encodings

UUIDs are lowercase, hyphenated. Times are RFC 3339 `date-time` in years
0001 to 9999: `YYYY-MM-DDTHH:MM:SS`, an optional fraction of 1 to 9 digits
(readers keep milliseconds), then `Z` (writers) or `±HH:MM` (readers
accept). Writers emit milliseconds, `2026-10-04T16:20:00.123Z`. JSON writers
must not emit NaN or infinities, and refuse a value they cannot represent
(a date outside those years) rather than write a file readers cannot decode.
Numbers in `points` are plain JSON numbers.

## 7. Versioning

### 7.1 Version markers

The format is identified by four markers:

| marker | where | this version |
| --- | --- | --- |
| `format` | `vault.json` (§2) | `"sempere/1"` |
| `features` | `vault.json` (§2) | absent: this version defines no extension |
| body version byte | offset 4 of every revision body (§4) | `0x01` |
| `format`, `features` | a revision's JSON (§5.1), both optional | absent; absent `format` means `"sempere/1"`, absent `features` means `[]` |

A format identifier is `sempere/<major>`, where `<major>` is a decimal
integer from 1 to 999 999 999 without leading zeros. This document defines
major 1. A reader that implements major N reads every major up to N as
written; this section is about what it does with a higher one.

### 7.2 Newer content

A reader has seen **newer content** when any of these holds:

1. `vault.json`'s `format` names a higher major than it implements;
2. `vault.json`'s `features` lists an extension it does not implement;
3. a revision body's version byte is higher than it implements;
4. a revision's `format` names a higher major, or its `features` lists an
   extension it does not implement (a *newer revision*).

A `vault.json` whose `format` is not a format identifier, or names major 0,
is not a vault this reader can open: it refuses it (`unsupportedFormat`).
So does a reader that cannot decode a newer `vault.json` well enough to
unwrap its key (§2: `vaultId`, `epoch`, `keys` and the reader's own entry's
`wrap`). A
revision whose `format` is present but not a format identifier (or names
major 0), or whose `features` is present but not an array of strings, is
invalid and rejected like any undecodable revision (§5).

Markers 1 and 2 are seen when the vault is opened; 3 and 4 only when the
revision is read, which may be later (a sync may deliver new revisions
before the new `vault.json`).

### 7.3 Read-only access

A reader that has seen newer content may offer **read-only access**
instead of refusing the vault, and must then never write to it. From the
moment it has seen newer content, for the rest of the time it has the vault
open (and, for markers 1 and 2, whenever it opens it), it:

- writes no revision: no delta (edits, imports, recognition, restores,
  checkpoints) and no snapshot;
- deletes no revision: no compaction and no thinning (§5.3, §5.8.4);
- writes, copies, renames, collects or repairs no blob (§8.1);
- changes no key: approves, renames or removes no device and re-encrypts
  nothing (§3.3), and writes no passphrase copy (§3.2);
- does not change `vault.json` (not even `features` or `label`, §2), and
  keeps no trust record for it (§2.1);
- writes nothing to and deletes nothing from `inbox/` (§11): it adopts no
  capture and enables no capture profile;
- does not write `settings.age` (§13);
- writes no notebook record (§14).

It still may: read, verify and report on everything; export and render;
write per-device data outside the vault (caches, §10); and copy the vault's
files byte for byte without changing or deleting any by its own decision
(a backup, a sync that mirrors another replica's files).

The rule holds per vault, not per note: a newer revision in one note makes
the whole vault read-only. A reader must at least refuse every write to a
note whose revisions it has read and found newer, and every vault-wide
change (the device list, `vault.json`, `inbox/`) once it has seen newer content
anywhere. A reader that offers no read-only access refuses to open a vault
with marker 1, and treats a revision with marker 3 or 4 as unreadable
(reported, §4); it must still never write to a vault with marker 2 (§2).

### 7.4 Reading newer content

A read-only reader shows everything it understands and reports the rest. In
a **newer revision** (marker 4):

- An op whose `op` it does not know is skipped; the revision's other ops
  still apply, in order.
- An op it knows that does not decode or validate (a value of the wrong
  type, a `setMeta` or `setRecording` of a field it does not know, a
  `setItem` it would reject, §8.2.2) is skipped the same way.
- In a snapshot, an element of `pages`, of a page's `strokes` or `items`, or
  of `recordings` that does not decode is skipped; members of `state`,
  `meta` or a page that it does not know are ignored. If the envelope (§5.1),
  `included` or `state` itself does not decode, the whole revision is
  unreadable.
- Everything else follows the rules for any revision: unknown item kinds
  are drawn as placeholders (§7.5, §8.5.2), unknown fields are ignored or
  kept (§7.5), unknown ink tools render as `pen` (§5.6).

A file with a higher body version (marker 3) cannot be verified or decoded:
it is unreadable, reported as newer rather than corrupt, and the note is
reconstructed from its other revisions (§5.3).

In a revision that is **not** newer, an unknown op type or `setMeta` field
is invalid and the revision is rejected (fail closed), never applied in
part, so that a damaged or hostile file never passes for a newer one. A newer
revision gains nothing else: it is still decrypted, its tag (§4) verified
and its name checked (§5) like any other.

The state a read-only reader shows is approximate: a skipped op or element
may have removed, moved or replaced something it still shows (a snapshot
that covers a revision but holds none of an element it skipped hides that
element, §5.3). That is why such a state is only shown, never written.

The reader reports, per vault, why it is read-only (the vault's `format`,
its unknown `features`, and the notes holding newer content), and, per
note, what it could not show: the count of newer revisions, of unreadable
newer revisions, of skipped ops by `op` name (and `setMeta` fields by
name), and of skipped snapshot elements. Names are reported cut to 64
characters, at most 32 distinct names per note, the rest counted together
(§9).

### 7.5 Open extensions within a version

An incompatible change needs a version bump (a later major, §7.6, or a
`features` entry, §2): readers of this version then open the vault
read-only (§7.3). Inside the item and recording ops the format is open, so
new item kinds and fields can be added without a version bump:

- An item whose `kind` a reader does not know is kept: it merges like any
  item (its common fields, §8.2.1, must be valid or the revision is
  rejected), its JSON object is carried into snapshots unchanged, and
  renderers draw a placeholder in its frame (§8.5) and report it.
- A field a reader does not know, on an item, a recording, a text run or a
  blob reference, is kept and re-emitted unchanged when the object is
  written into a snapshot. A `setItem` or `setRecording` naming a field the
  reader does not know is an LWW register on that field like any other.
- A blob `type` a reader does not know is kept; the blob is still stored,
  synced, verified and collected, it is just not rendered or played.
- An item `layer` value without a defined meaning is ordered by its number
  (§8.2.3).

`settings.age` (§13) carries its own versions (`$schemaVersion`,
`$minReaderVersion`, §13.4), so new settings need no `features` entry and
no format bump.

A future change that older readers must not merge blindly (new merge
semantics, not just a new kind of placed content) still needs a new op type
in a newer revision, so that older readers skip it and stay read-only
(§7.4), or a `features` entry (§2), so that older writers stay read-only.

### 7.6 Writers of a later major

So that readers of this version can offer read-only access, a writer that
implements a later major N:

- sets `vault.json`'s `format` to `sempere/N` before it writes the first
  revision a major-1 reader would misread, and writes `"format":
  "sempere/N"` in every revision it writes from then on (a revision that
  uses an extension, `features`, lists it in the revision's `features`
  too);
- keeps `vaultId`, `root`, `epoch`, `epochId` and each listed key's `wrap`
  in `vault.json` (§2, §15.3), so that a reader of this version still finds
  its own entry and unwraps the key, and `markersTag` over the markers it
  writes (§2.1), the passphrase copy (§3.2), the revision file names (§5) and
  the envelope fields of §5.1, with their meaning;
- keeps the body framing of §4, version byte `0x01` and tag label
  `sempere/1`, unless it must change them: the label names the framing, not
  the vault's format. A new body version makes its files unreadable to
  older readers (marker 3), and breaks the stock-CLI recovery path, which
  must then be documented anew.

The recovery path of §4 and §15.13 (`age -d -i vault-keys.txt … | tail -c +38 | gunzip | jq .`) and of
§8.1.7 therefore reads newer revisions too.

## 8. Attachments

Typed text boxes, images, PDF page backgrounds and audio
recordings with transcripts. The rationale, the alternatives considered and
the implementation plan are in `docs/attachments.md`; this section is the
normative part. Small, mutable data (text, geometry, titles) lives in the
note's revisions like everything else; large, immutable bytes (images, PDFs,
audio, transcripts) live in *blobs* in the note's own `att/` folder, which
revisions reference by content hash.

### 8.1 Blobs

#### 8.1.1 Blob references

Revisions name a blob with a *blob reference*:

```json
{ "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "size": 482113, "type": "image/jpeg" }
```

- `sha256`: SHA-256 of the blob's content (the JPEG, PNG, PDF, audio or
  transcript file itself), 64 lowercase hex digits.
- `size`: the content's length in bytes.
- `type`: its media type. Defined: `image/jpeg`, `image/png`, `image/heic`
  (§8.2.5), `application/pdf` (§8.2.6), `video/mp4` and `video/quicktime`
  (§8.2.7), `audio/mp4` (§8.3.1), `application/vnd.sempere.transcript+json`
  (§8.3.2). Others are kept (§7.5).

Every blob reference in a revision is a JSON object with these three keys
(and possibly unknown ones, §7.5); no other object in a revision body has a
`sha256` key. Collection (§8.1.6) relies on this to find references inside
item kinds and fields it does not know.

A reference resolves only inside the note that holds the revision: the blob
is `notes/<noteId>/att/…` of that note (§8.1.2). Within one note the same
content is one blob however many items use it. Another note that uses the
same content has its own copy (§8.1.4).

#### 8.1.2 Names

A blob of note `noteId` is stored as
`notes/<noteId>/att/<blobName>.<kind>.age`, where

```
blobName = lowercase hex of HMAC-SHA256(key = blobNameKey,
             message = "sempere/1" ‖ 0x00 ‖ "blob" ‖ 0x00 ‖ sha256)
```

`blobNameKey` is derived from the epoch's key `K_e` (§15.2), and `sha256`
is the content hash as 32 raw bytes. Names are 64 hex digits.
They are keyed so that storage never shows a plaintext content hash: anyone
could otherwise confirm that a vault holds a known file by hashing it. The
name doubles as the blob's authentication tag: only a holder of the vault
key can produce the name that matches a content hash, and a reader checks
it (§8.1.4). There is no tag inside the blob. The name does not depend on the
note, so a blob file copied byte for byte into another note's `att/` is valid
there.

`kind` is derived from the reference's `type`, compared on its type and
subtype only: ASCII case-insensitively, with any parameters (`; codecs=…`)
ignored:

| `type` | `kind` |
| --- | --- |
| `image/*` | `image` |
| `application/pdf` | `pdf` |
| `audio/*` | `audio` |
| `video/*` | `video` (§8.2.7) |
| `application/vnd.sempere.transcript+json` | `transcript` |
| anything else | `bin` |

A reader looks a blob up by the path computed from the reference; it never
guesses another kind. The kind is visible to storage on purpose (sync and the
app fetch images and PDFs when a note opens, audio only when it plays;
`docs/attachments.md` §2).

Entries in `att/` whose name is not 64 lowercase hex digits, `.`, a kind
(1–16 lowercase ASCII letters or digits) and `.age` are unknown files (§1).
Revision listings (§5) never look inside `att/`.

#### 8.1.3 Framing

A blob file is a binary age v1 file, encrypted to the vault identity in one
stanza like a revision (§4). Its plaintext is:

| Offset | Size | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `INKB` |
| 4 | 1 | blob version, `0x01` |
| 5 | 32 | SHA-256 of the content (raw) |
| 37 | 8 | content length `L`, unsigned big-endian |
| 45 | `L` | content, exactly as referenced (not compressed) |
| 45 + `L` | rest | padding: zero bytes |

Writers should pad the plaintext to `padme(45 + L)` bytes, which hides the
exact content length (a known file is otherwise recognizable by its size)
for at most 12 % overhead, less for large blobs:

```
padme(n) = n                                  if n < 2
           E = floor(log2 n), S = floor(log2 E) + 1, z = E − S,
           ((n + 2^z − 1) >> z) << z          otherwise
```

Readers accept any amount of padding but reject non-zero padding bytes.

Test vector: epoch key `K_e` bytes `00 01 02 … 1f` (so `blobNameKey` is its
§15.2 derivation), content the 16 ASCII bytes
`hello, sempere!\n`, type `text/plain` (kind `bin`):

```
sha256    8ff2ca4079cee96a407a038a996ef5d0dd317f201fddc04174f0d89b763add65
blobName  540202258da1b7aa71188692543fcd1704765f5f52a89f9a7649e6d36878dda9
path      notes/<noteId>/att/54020225…dda9.bin.age
header    494e4b4201 8ff2…dd65 0000000000000010   (45 bytes)
padme     61 → 64 (3 zero bytes); 1000 → 1024; 482158 → 483328; 28311597 → 28835840
```

#### 8.1.4 Writing and reading

A writer that adds content to note N:

1. hashes the content and derives `blobName` and the path in N's `att/`;
2. if that file exists and its first STREAM chunk decrypts to a valid header
   (magic, version, the same `sha256`, a name that verifies), reuses it; if
   it exists but fails that check, may replace it atomically with a valid
   encryption (the only replacement of a blob);
3. otherwise writes it with the atomic-write procedure (`docs/io.md`),
   never replacing an existing file of that name;
4. only after the blob is durable, writes the revision that references it.

Copying or moving an item to another note M (copy and paste, "move to
note", duplicating a note) writes the blob into M's `att/` by steps 1–4 for
M; a byte copy of N's blob file is a valid way to do step 3. A writer never
writes a reference in M that relies on a blob of N.

A blob is valid when its framing is well formed, `L` and the content fit the
file, the padding is zero, the SHA-256 of the content equals the header's,
and `blobName` computed from the header's hash under the vault key equals
its file name. Read through a reference, the header's hash and `L` must also
equal the reference's `sha256` and `size`. Readers must check the name when
the vault key is available and must always check the content hash. A
reader that hands out content before the hash is complete (streaming audio,
a large PDF) must stop and report on a mismatch. Failures are reported like
unreadable revisions and the blob is treated as missing (§8.5.2).

Blobs are processed as streams: age's STREAM payload is authenticated in
64 KiB chunks, so readers and writers need memory proportional to a chunk,
not to the blob. Implementations may hold a blob of at most 16 MiB in memory
whole; larger blobs must be streamed (to a private temporary file where
random access is needed, e.g. reading a PDF, deleted when done).

#### 8.1.5 Key changes

Blobs are never rewrapped or renamed in this version: adding a device wraps
the vault key to it and touches no file (§3.3). A blob keeps the name it got
under the key of the epoch it was written in. How files of earlier epochs are
read after a removal, and how re-encrypting everything rewrites blobs, come
with the key hierarchy's later phases (key-hierarchy design §5, §7; KH3,
KH6).

The vault's keys have nothing to do with sharing a note with another person:
that is an export (PDF, SVG, PNG, or a copy), never a change of the device
list.

#### 8.1.6 Collection

Compaction (§5.3) never deletes a blob. Blobs are collected **per note**: a
blob in `notes/<N>/att/` may be deleted only when all of these hold:

1. every revision file of note N was listed, read and verified (one
   unreadable or unlistable revision of N stops collection for N: it may
   hold the only reference);
2. no re-encryption of the vault is unfinished (no `reencrypt-journal.age`,
   §15.8);
3. no revision of N present, snapshot or delta, contains a blob reference
   (§8.1.1) with the blob's content hash (a deleted note, §5.2, still has
   its revisions, so its blobs stay);
4. the collecting device found 1–3 true for this blob at least the retention
   window (§5.3, default 30 days) ago, and has found it unreferenced every
   time it looked since. It records this in its own device-local state,
   never in the vault.

No other note is read: references never cross notes (§8.1.1). Blob files
that cannot be decrypted or verified (as a whole, §8.1.4, with the name
checked under the current key) are never deleted by collection; they
are reported. Because every surviving revision keeps its blobs, history
(§5.7) never loses an attachment that a restore point needs.

Rule 4 covers a device that reuses a blob (§8.1.4 step 2) while another
collects it: the reference must stay unsynced for longer than the window to
be left dangling. A reader that finds a referenced blob missing reports it
and draws a placeholder (§8.5.2); a writer that still holds the content
should write it again.

A sync tool deletes a blob on one side because the other side dropped it only
if rules 1–3 hold for its note on the side it deletes from (as it does for
compacted revisions, `docs/io.md`). When the side that dropped it is a server,
which holds no key and cannot show that the collector waited, the deleting
device also applies rule 4 itself: it deletes the blob only once it has found
rules 1–3 true for it for the retention window, every time it looked.

#### 8.1.7 Recovery without the app

```
B=notes/NOTE/att/NAME.KIND.age
age -d -i key.txt "$B" | head -c 37 | tail -c 32 | xxd -p -c 32   # content sha256
age -d -i key.txt "$B" | head -c 45 | tail -c 8  | xxd -p         # L, hex
age -d -i key.txt "$B" | tail -c +46 | head -c "$((16#<L hex>))" > out
```

The content hash matches the `sha256` of the item or recording that uses the
blob (readable from any revision of the same note, §4); `KIND` and
`file out` tell the type. Without `head -c` the output carries the zero
padding after the content. `$((16#…))` is bash/zsh arithmetic, and BSD `head` (macOS) refuses
`-c 0` (an empty content has nothing to extract); where `xxd`
is missing, `od -An -v -tx1 | tr -d ' \n'` prints the same hex.

### 8.2 Placed items

A page's `items` (§5.5) are text boxes, images, PDF page backgrounds, video
clips, equations and recordings placed on the page, in page coordinates
(points, origin top-left, y down).

#### 8.2.1 Common fields

```json
{
  "id": "6f1c2d4e-…",
  "kind": "image",
  "layer": 100,
  "frame": [72, 144, 288, 216],
  "rotation": 0,
  "z": "a0",
  "parent": "…",
  "rec": { "id": "…", "at": 12.5 },
  "origin": "17596320000000003-a1b2c3d4-12-4",
  "clocks": { "frame": "17596320000000003-a1b2c3d4" }
}
```

plus the fields of its kind (§8.2.4–§8.2.9).

- `id`: UUID.
- `kind`: `text`, `image`, `pdfPage`, `video` (§8.2.7), `math` (§8.2.8) or
  `audio` (§8.2.9); others per §7.5.
- `layer`: integer z-layer, 0 to 65 535 (§8.2.3). Defined: `0` background,
  `100` content. Absent means `100`. Writers write only defined values;
  readers order by any value in range and treat a value out of range or not
  an integer as `100`.
- `frame`: `[x, y, w, h]`, the item's box before rotation; `w` and `h` > 0.
- `rotation`: degrees, clockwise about the frame's center; absent means 0.
- `z`: order key within the layer, compared like page `order` (§5.5).
- `parent`: optional, the item this one replaces (moved to another page or
  note, restored from history, or an image whose picture was replaced:
  `removeItem` of the old one and `addItem` of the new one in one delta,
  since `blob` is immutable, §8.2.2).
- `rec`: optional, as on strokes (§5.6, §8.3.3).
- `origin`: snapshots only, as on strokes (§5.5).
- `clocks`: snapshots only, maps each register (§8.2.2) to the
  `"<hlc>-<device>"` stamp of the op that last set it; a register without a
  clock is stamped by the snapshot's own `(hlc, device)`.

Numbers are rounded to at most 3 decimals by writers.

The fields of a defined kind (§8.2.4–§8.2.9) are required unless that section
says what their absence means (`rotation`, `crop`, `orientation`, `family`,
`lang`, `poster`, …). An item of a defined kind that lacks one, holds one of the wrong
type or out of its stated range (a frame, crop, `pixelSize` or `pageSize`
side not positive, `orientation` outside 1–8, a negative `pageIndex`, a text
`size` outside its range, a `duration` negative or not finite, a
`videoRotation` other than 0, 90, 180 or 270, a `recording` that is not a
UUID) is invalid like a bad common field: the revision is
rejected. A field of another kind on an item (an image with `pageIndex`) is
an unknown field there and kept (§7.5); so are all fields beyond the common ones
on an item of an unknown kind.

#### 8.2.2 Registers, ops and merge

Every field an item has is either a *register*, changed with `setItem` and
merged last-writer-wins per (item, field), or *immutable*, set by `addItem`
and never changed.

| Kind | Registers | Immutable |
| --- | --- | --- |
| every kind | `frame`, `rotation`, `z` | `id`, `kind`, `layer`, `parent`, `rec` |
| `text` | `text` | |
| `image` | `crop` | `blob`, `pixelSize`, `orientation` |
| `pdfPage` | `crop`, `pageText` | `blob`, `pageIndex`, `pageSize` |
| `video` | `poster` | `blob`, `pixelSize`, `duration`, `videoRotation`, `codec` |
| `math` | `math` | |
| `audio` | | `recording` |

- `addItem` sets every field; its register values carry the op's stamp.
- `setItem` with `field` naming an immutable field of any kind, or the
  snapshot-only `origin` or `clocks`, is invalid (the revision is rejected),
  as is a value of the wrong type or out of range for a register in the table.
  `value: null` (or no `value`) resets an optional register (`rotation`,
  `crop`, `poster`) to absent; `null` for `frame`, `z`, `text` or `math` is invalid. A field
  the reader does not know is a register (§7.5), and `null` is a value of it
  like any other.
- `setItem` on a removed item, or an item on a removed page, is a no-op.
  Writers name the item's own page in `setItem`; readers key the registers by
  item id and use `page` only to tell whether the op is an orphan (§5.3).
- A field named like an immutable field of some kind (`blob` on a text item,
  an unknown field there, §8.2.1) is not a register either: `setItem` can
  never name it, so it keeps the value its `addItem` gave it. Snapshot
  `clocks` list every register of the item, including `rotation`, `crop` and
  `poster` while absent (a reset is a value with a stamp, like `recognitionClock`,
  §5.5).
- Items merge as sets like strokes (§5.3), with permanent tombstones (§5.4).
  An item belongs to one page; moving it to another page is `removeItem`
  plus `addItem` of a new id with `parent` naming the old one (to another
  note: the same, with the blob copied first, §8.1.4).

Concurrent moves, resizes and text edits of one item therefore keep the last
writer's value per field; the other is still in history (§5.7).

#### 8.2.3 Layers and drawing order

A page is drawn, bottom to top:

1. the paper background color (the page's own paper, else the note's, §5.4.2);
2. the paper ruling;
3. items by `(layer, z, id)`: lower layers first, then by `z`, then by `id`.
   An item whose `layer` is below 100 (a background layer) first fills its
   frame (rotated) with the paper background color, so ruling never shows
   through it;
4. strokes, by `origin` (§5.5).

On a note with `markersBehindText` (§5.4), the marker strokes (`ink.tool`
`marker`) leave step 4 and are drawn, by `origin`, between the items of
background layers (below 100) and the first item of a layer of 100 or more;
on a page without such items, before the other strokes. Everything else is
unchanged: a highlighter then sits above a PDF page background but below
text boxes and images, and below pen ink.

Otherwise ink is drawn above every item, whatever its layer. Layers other than 0 and
100 have no defined meaning yet; a later format change may give some of them
one (for example a layer above the ink) without changing how existing items
are stored. `image` and `pdfPage` items are clipped to their frame; text is
not. An exporter that leaves out the paper also leaves out the fill of
step 3. For an infinite page, items count toward the extent like strokes
(their rotated frame's lowest point), and an item crossing a break is cut
across export pages like a stroke.

#### 8.2.4 Text

```json
{ "kind": "text", "layer": 100, "frame": [72, 90, 300, 40], "z": "a1",
  "text": {
    "font": "sans", "family": "SF Pro", "size": 12, "color": "#1A1A1AFF",
    "align": "start", "dir": "auto", "lang": "en",
    "runs": [ { "t": "Lecture 3", "b": true, "size": 18 },
              { "t": "\nlinear maps and their kernels" } ],
    "breaks": [] } }
```

- `font`: `sans`, `serif` or `mono` (unknown values are `sans`): the generic
  family. Every renderer maps it to fonts it has (§8.5.3).
- `family`: optional, informational: the concrete family the writer laid the
  text out with (e.g. `SF Pro`, `Noto Sans`).
- `size`: points, greater than 0 and at most 1000. `color`: `#RRGGBBAA`.
- `align`: `start`, `center`, `end`, `left` or `right` (unknown values and
  absent are `start`). `start` and `end` follow each paragraph's direction.
- `dir`: `auto`, `ltr` or `rtl` (unknown and absent are `auto`): the
  paragraph direction. `auto` takes each paragraph's direction from its first
  strong character (Unicode bidirectional algorithm, UAX #9, rules P2–P3),
  left to right if it has none.
- `lang`: optional BCP 47 tag of the text's language; a run may override it.
  Renderers use it to choose fonts (Chinese, Japanese and Korean share code
  points but not glyph shapes).
- `runs`: the text, possibly empty. Each run has `t` (the run's text, any
  Unicode scalar values except C0 controls other than `\n` and `\t`) and
  optionally `b` (bold), `i` (italic), `u` (underline), `s`
  (strikethrough), all `false` when absent, and `color`, `size`, `lang`
  and `font` (a generic family as above; unknown values are the box's),
  which override the box's. The item's text is the concatenation of every
  `t` in logical (typing) order; `\n` is a hard line break (writers store no
  other line terminator). Writers store text in NFC and merge adjacent runs
  with equal attributes.
- `breaks`: optional, the writer's soft line breaks: strictly increasing
  offsets, in Unicode scalar values from the start of the item's text, at
  which a new line starts that is not after a `\n`. Writers that lay text out
  should store it; renderers use it (§8.5.3). `breaks` belong to the frame
  width they were computed for: a writer that changes a text box's width
  (a resize) writes the text again in the same delta, with new `breaks` (or
  none). An empty array is valid: the writer laid the text out and no
  paragraph wraps.
- `frame` width is the wrapping width. `frame` height is the height the
  writer laid the text out to; renderers never clip text to it (§8.5.3).

The whole `text` object is one register: concurrent edits do not merge
character by character, and `breaks` always belongs to the text it was
computed for. The item's text is part of the page's searchable text, beside
`recognition` (§5.5); it is never copied into `recognition`.

##### Markdown text

A text box can
hold Markdown source with LaTeX math, drawn rendered (§8.5.4):

```json
{ "kind": "text", "layer": 100, "frame": [72, 90, 300, 61.2], "z": "a1",
  "text": {
    "font": "sans", "size": 12, "color": "#1A1A1AFF", "markup": "markdown",
    "runs": [ { "t": "# Lecture 3\n\nLet $f(x) = x^2$ and\n- **linear** maps" } ],
    "layout": { "of": "5a1c09e2", "breaks": [] },
    "math": [ { "latex": "f(x) = x^2", "display": false, "size": 12,
                "color": "#1A1A1AFF", "depth": 4.1,
                "render": { "sha256": "…", "size": 3072, "type": "application/pdf" },
                "renderSize": [41.25, 16.5], "engine": "swiftmath-1.7.3" } ] } }
```

- `markup`: optional. `"markdown"`: the item's text (the runs' `t`,
  concatenated) is Markdown source, rendered by §8.5.4. Absent: the runs are
  styled text as above. A value the reader does not know is ignored: the
  runs are drawn as styled text.
- The source is stored as the item's text itself (Markdown is meant to be
  readable as it is). Writers store the source as one run without attribute
  overrides, and no `breaks` (they would be breaks of the raw source). `font` is the body family (`sans` or
  `serif`); `size`, `color`, `align`, `dir` and `lang` apply to the rendered
  text as §8.5.4 says. Readers of this section ignore the run attributes and
  any `breaks` of a Markdown box.
- `layout`: optional, the writer's line breaks of the rendered text:
  `{"of": h, "breaks": [...]}`, `h` the FNV-1a 32-bit hash of the UTF-8
  bytes of the item's text, as 8 lowercase hexadecimal digits (offset basis
  2166136261, prime 16777619), and `breaks` strictly increasing offsets, in
  Unicode scalar values of the source, of the first character of every
  rendered line that does not start a rendered paragraph or follow a hard
  line break (§8.5.4). A `layout` whose `of` differs from the text's hash
  was written for another text and is ignored. Its `breaks` belong to the frame width,
  as `breaks` do.
- `math`: optional, at most 1 000 typeset formulas of the source, each a
  math value (§8.2.8: `latex`, `display`, `size`, `color`, `render`,
  `renderSize`, `engine`) with `render` present, plus `depth`: the distance
  in points from the bottom of `render`'s page up to the formula's baseline,
  from 0 to `renderSize`'s height. A formula of the source (§8.5.4) is drawn
  from the first entry whose `latex`, `display`, `size` (to 3 decimals) and
  `color` equal its own; entries no formula matches are ignored (they are
  stale: blob collection still keeps them while they are in the value).
  The CLI, which has no typesetter, writes no entries.

These fields are part of the one `text` register: the whole value is
replaced at once, so a rendering never pairs with another device's source.
An item whose `markup`, `layout` or `math` has the wrong type or breaks
these rules is invalid like any bad field of a defined kind (§8.2.1).

For search (§5.5) and as the item's text in reports, a Markdown box's text
is its plain text (§8.5.4): the source without markup. Text exports
(Markdown) write the source as it is; HTML exports render it (§8.5.4).

#### 8.2.5 Image

```json
{ "kind": "image", "layer": 100, "frame": [72, 144, 216, 288], "z": "a0",
  "blob": { "sha256": "…", "size": 482113, "type": "image/jpeg" },
  "pixelSize": [3024, 4032], "orientation": 6, "crop": [0, 0, 3024, 4032] }
```

- `blob`: `image/jpeg` (baseline or progressive Huffman coding, 8 bits, one
  or three components; not CMYK, not arithmetic-coded), `image/png` (any
  valid PNG) or `image/heic`. Writers convert anything else (WebP, GIF,
  TIFF, CMYK JPEG) to JPEG or PNG, and should convert HEIC too unless the
  user chose to keep it (`docs/attachments.md` §7); a renderer that cannot
  decode HEIC draws a placeholder (§8.5.2).
- Metadata: unless the user chose to keep it, writers strip metadata from
  the stored bytes: in a JPEG every APPn segment except APP0 (JFIF), APP2
  (ICC profile) and APP14 (Adobe), and COM segments; in a PNG every
  ancillary chunk except `tRNS`, `gAMA`, `cHRM`, `sRGB`, `iCCP` and `pHYs`;
  in a HEIC the `Exif` and XMP items. Exporters strip the same metadata from
  bytes they pass through into an export unless asked to keep it, whatever
  is stored (a photo's location must not travel with a shared PDF).
- `orientation`: EXIF orientation, 1–8; absent means 1. Renderers apply this
  field and ignore any orientation stored in the image data.
- `pixelSize`: `[w, h]` after orientation, for layout before decoding.
  Renderers use the decoded size.
- `crop`: `[x, y, w, h]` in oriented pixel coordinates; absent means the
  whole image. Renderers intersect it with the image.

The crop rectangle is drawn onto the frame (§8.5.1). Writers keep the frame's
aspect ratio equal to the crop's; renderers scale the axes independently.

#### 8.2.6 PDF page

```json
{ "kind": "pdfPage", "layer": 0, "frame": [0, 0, 612, 792], "z": "a0",
  "blob": { "sha256": "…", "size": 1830221, "type": "application/pdf" },
  "pageIndex": 3, "pageSize": [612, 792], "crop": [36, 36, 540, 720] }
```

- `blob`: a PDF (versions 1.0–2.0) without encryption (no `/Encrypt` in the
  trailer). Writers remove encryption or refuse the file.
- `pageIndex`: 0-based index of the page in page-tree order.
- The *effective page* is the page's CropBox (inherited; default the
  MediaBox) intersected with its MediaBox, turned clockwise by its `/Rotate`
  (inherited; normalized to 0, 90, 180 or 270). It is a `W' × H'` rectangle
  in points, origin top-left, y down (§8.5.1).
- `pageSize`: `[W', H']`, informational: renderers that parse the PDF use its
  own boxes; others use it for layout and placeholders.
- `crop`: `[x, y, w, h]` on the effective page; absent means all of it.
- `layer` is `0` (background) for a page being annotated; `100` (content)
  places a page as a figure.

- `pageText` (optional register): the page's text,
  for search: `{ "text": "…", "engine": "pdftotext-24.02", "truncated": true }`.
  `text` is the page's text in reading order, NFC, lines separated by `\n`
  (no other control characters but `\t`), at most 65 536 UTF-8 bytes;
  `engine` names what extracted it (`notability-<version>` for Notability's
  PDF index, `semperepdf-<n>`, `pdftotext-<version>`, `pdfkit-<OS version>`);
  `truncated` (absent means false) says the writer cut the text at the limit.
  It is derived from the blob and its page, describes the whole effective
  page whatever the `crop`, and a writer may set it with `setItem` at any time
  (`null` removes it), for example when a device that can extract text
  better reads an item another device added. Readers that index text for
  search take `text` (beside `recognition` and text boxes, §5.5, §8.2.4);
  a value that is not such an object (or whose `text` is longer than the
  limit) is ignored as if absent, never rejected. It is never drawn.

The crop rectangle is drawn onto the frame (§8.5.1). The PDF's annotations
(`/Annots`) are not drawn; a writer that wants them flattens them into the
PDF before storing it. Within a note one PDF blob serves any number of
`pdfPage` items. How a writer lays pages out (one note page per PDF page, or
bands of an infinite page) is its choice (`docs/attachments.md`).

#### 8.2.7 Video

(`docs/attachments.md` §14.)

```json
{ "kind": "video", "layer": 100, "frame": [72, 144, 320, 180], "z": "a2",
  "blob": { "sha256": "…", "size": 48211330, "type": "video/mp4" },
  "pixelSize": [1920, 1080], "duration": 42.517, "videoRotation": 90,
  "codec": "hevc",
  "poster": { "sha256": "…", "size": 81211, "type": "image/jpeg" } }
```

- `blob` (immutable): the clip, kind `video` (§8.1.2), at most 1 GiB (§8.4).
  Writers store `video/mp4` (an ISO base media file, `.mp4`/`.m4v`) or
  `video/quicktime` (a QuickTime movie, `.mov`): a file that starts with an
  `ftyp` box (an older QuickTime movie may start with `moov`, `wide`, `free`,
  `skip` or `mdat` instead), holds one
  `moov` box with at least one video track (`hdlr` `vide`) whose first sample
  entry is H.264/AVC (`avc1`, `avc3`) or HEVC/H.265 (`hvc1`, `hev1`), and
  optionally sound tracks (AAC, `mp4a`, recommended) and others (timed
  metadata, timecode). Writers convert anything else first (another codec,
  WebM, AVI, fragmented MP4 without a `moov` sample table) or refuse it. They
  should place `moov` before `mdat` ("fast start") so a reader can show the
  clip's size before reading the samples; readers accept either order.
- Metadata: unless the user chose to keep it, writers remove the location
  and device metadata from the stored bytes: every `udta` and `meta` box
  directly inside `moov` or a `trak` (`©xyz`, `com.apple.quicktime.location.ISO6709`,
  make, model, software, creation date), every top-level `meta` box, and
  every XMP `uuid` box (usertype `BE7ACFCB-97A9-42E8-9C71-999491E3AFAC`,
  which may hold `exif:GPSLatitude` and the like) at the top level or
  directly inside `moov` or a `trak`, and a top-level `udta`, has its type changed to `free` and
  its contents set to zero bytes. Positions recorded per frame in the
  samples of a timed-metadata or text track (a drone's or action camera's
  telemetry) are not removed this way. Nothing else moves, so every sample offset
  (`stco`, `co64`) stays valid and the clip plays unchanged. Exporters do the
  same to bytes they pass through into an export unless asked to keep them
  (as for images, §8.2.5). Stripping fails closed: a file with more than one
  `moov`, or whose last top-level box other than `mdat` runs past the end, is
  refused rather than stored with metadata the walk did not see.
- `pixelSize` (immutable): `[w, h]`, the clip's display size in pixels: the
  video track's `tkhd` width and height, swapped when `videoRotation` is 90 or
  270. For layout and the poster's aspect; players use the decoded size.
- `videoRotation` (immutable, optional): `0`, `90`, `180` or `270`, the
  clockwise rotation the video track's `tkhd` matrix applies for display
  (an iPad held upright records 90); absent means 0. Informational: players
  apply the track matrix themselves, and `pixelSize` and the poster are
  already upright. It is independent of the item's `rotation` (§8.2.1).
- `duration` (immutable): seconds, 3 decimals, finite and not negative: the
  movie's `mvhd` duration (the video track's `mdhd` duration when `mvhd` has
  none).
- `codec` (immutable, optional, informational): `h264` or `hevc`, the video
  track's codec; other names may come from importers.
- `poster` (optional register): an image blob reference (§8.2.5 rules for
  `image/jpeg` and `image/png`, metadata stripped), the frame shown before
  the clip plays and the only part of the item that renderers draw. It is
  stored upright: renderers ignore any orientation in its data. Its aspect
  should match `pixelSize`; renderers scale the axes independently. Absent
  (or `null`) means no poster: a writer that cannot decode the clip (the CLI
  on Linux without `--poster`) leaves it absent, and a device that can (the
  app) may set it later with `setItem`, as for `pageText` (§8.2.6). A value
  that is not a blob reference is invalid (§8.2.2).

Drawing (renderers, exports and readers that do not play the clip, or before
it plays): the whole poster is mapped onto the frame (§8.5.1, with the crop
`[0, 0, w, h]` of the poster's decoded size, orientation 1), clipped to the
frame, then a *play mark* is drawn over it: with `d = min(48, 0.3 · min(fw, fh))`
and the frame's center `(mx, my)`, a disc of diameter `d` centered there,
filled `#00000080`, and a triangle filled `#FFFFFFFF` with corners
`(mx − 0.18 d, my − 0.25 d)`, `(mx − 0.18 d, my + 0.25 d)` and
`(mx + 0.27 d, my)`; both are turned with the item's `rotation` about
`(mx, my)`. An item whose poster is absent, missing, invalid or not
decodable is drawn as a placeholder (§8.5.2) with the play mark over it, and
counted in the export report like any placeholder (an absent poster is
reported as "no poster", not as missing content). A video item counts toward
an infinite page's extent and is cut across export pages like an image.

Playing: a reader that plays video plays the verified clip (§8.1.4) from a
private temporary file or memory (`docs/attachments.md` §2 "Large files"),
applies the track matrix, and draws the frame's rectangle with the decoded
picture fitted inside it (aspect kept). A reader that cannot play the clip
(no decoder for its codec, a renderer, an exporter) shows the poster and play
mark as above and may offer the clip as a file. A `pdf` export with
attachments embeds the clip as an embedded file (`docs/attachments.md` §10).

#### 8.2.8 Math

An equation, edited as LaTeX source and drawn typeset:

```json
{ "kind": "math", "layer": 100, "frame": [72, 300, 163.25, 41.5], "z": "a3",
  "math": {
    "latex": "\\int_0^1 x^2\\,dx = \\frac{1}{3}",
    "display": true, "size": 20, "color": "#1A1A1AFF",
    "render": { "sha256": "…", "size": 5120, "type": "application/pdf" },
    "renderSize": [163.25, 41.5], "engine": "swiftmath-1.7.3" } }
```

`math` is the item's only register of its own, and it is replaced whole
(like `text`, §8.2.4): the rendering belongs to the exact source, style,
size and color it was typeset from, so concurrent edits never pair one
device's source with another's rendering. Its fields:

- `latex`: the source, in LaTeX math mode without delimiters (no `$`, `\[`
  or `\begin{equation}` around it): at most 8 192 UTF-8 bytes of Unicode
  scalar values, no C0 controls other than `\n` and `\t`. Writers store it
  as the user typed it (NFC) and do not write an empty source (they remove
  the item instead); an empty one is valid and draws nothing.
- `display`: `true` for display style (large operators, limits above and
  below, full-size fractions, as in `\[…\]`), `false` for text (inline)
  style (as in `$…$`). The item is placed freely either way.
- `size`: the font size of the typeset result in points (1 em), greater than
  0 and at most 1000. `color`: `#RRGGBBAA`, the color of every mark.
- `render`: optional, a blob reference (§8.1.1) to the typeset result: a PDF
  (`application/pdf`, kind `pdf`; versions 1.0–2.0, no `/Encrypt`, as for
  `pdfPage`, §8.2.6) whose first page's effective page (§8.2.6) is the
  typeset box, in points at `size`, with the margin the writer chose. It
  draws only marks in `color` (alpha included) on a transparent page: no
  page fill, no other color. Absent: no typesetter has rendered this value
  yet (a writer without one, such as the reference CLI, writes none).
- `renderSize`: `[w, h]`, the size in points of `render`'s effective page,
  both positive; present exactly when `render` is (else the item is
  invalid). Informational like `pageSize` (§8.2.6): renderers that parse the
  PDF use its own boxes; writers use it to keep the frame's scale.
- `engine`: optional, informational: the typesetter and its version that
  made `render` (e.g. `swiftmath-1.7.3`, `tectonic-0.15`).
- Unknown fields of `math` are kept (§7.5) and belong to the value: a writer
  that changes the source drops the ones it does not understand.

A writer that changes `latex`, `display`, `size` or `color` writes a new
`render` (or none) in the same value; a value whose `render` was typeset
from something else is a writer bug that readers cannot detect. When it
stores a new `render` it also sets `frame` in the same delta: the same
top-left corner, the render's page size times the scale the frame had to the
previous render (`frame.w / renderSize.w` of the old value; 1 when there
was none). Writers keep the frame's aspect
ratio equal to the render's; renderers scale the axes independently.

**Drawing.** A renderer draws the first of these it can:

1. `render`: page 1 of the PDF (`pageIndex` 0) mapped onto the frame and
   rotated exactly like a `pdfPage` item without `crop` (§8.5.1), clipped to
   the frame. A renderer that rasterizes the page onto an opaque white
   background (the CLI's Poppler, Core Graphics as the app uses it) recovers
   the coverage from the known `color`: a pixel `p` of channel `k`, where `k`
   maximizes `255 − color_k`, has coverage `(255 − p_k) / (255 − color_k)`
   (clamped to 0…1), drawn in `color`; when every channel of `color` is
   above 250 the page is drawn as rasterized.
2. Its own typesetting of `latex` (the app, when there is no `render` yet),
   within the limits below.
3. The source as text: a text item (§8.2.4) with `font` `mono`, the math
   `size` and `color`, the frame, and one run holding `latex`, laid out by
   §8.5.3 without stored breaks. The export reports it like a placeholder.
4. The placeholder of §8.5.2.

**Limits of typesetting.** `latex` is untrusted input (§9). Before a
typesetter parses it, readers check it and treat a source that fails as one
they cannot typeset (step 3): more than 4 096 tokens (a token is a control
sequence, `\` plus letters or `\` plus one character, or any other
character that is not white space); a group closed by the wrong kind or
never closed (`{…}`, `\left…\right`, `\begin{…}…\end{…}`, and `[…]`
right after `\sqrt`, its degree, closed by the next `]` of the same level);
or a nesting deeper than 64, where each open group counts one level and so
does each control sequence, `^` or `_` in a run of them (the arguments a
typesetter would parse recursively; `\sqrt\sqrt\frac` is three levels, any
other token ends the run). A group opened after a run sits below it and was
an argument: the run goes on after it closes (`\frac{a}\frac{b}\frac{c}d`
nests each `\frac` in the one before). `\over`, `\atop`, `\choose`,
`\brack` and `\brace` add one level for the rest of their group, the
denominator (`a\over b\over c` is two). Writers never store a `render` for such a source.

**Text, search and export.** `latex` is part of the page's searchable text,
beside `recognition`, text boxes and `pageText` (§5.5); it is never copied
into `recognition`. Text exports (Markdown, HTML) write it as `$$latex$$`
for display style and `$latex$` for text style. A device that converts
handwriting into an equation writes one delta that removes the strokes and
adds the `math` item (`docs/attachments.md` §6).

#### 8.2.9 Audio

A recording belongs to the
note (§8.3.1); an `audio` item shows one on a page, where it can be played
from, moved, resized and deleted like any item.

```json
{ "kind": "audio", "layer": 100, "frame": [72, 144, 300, 96], "z": "a3",
  "recording": "0d9e5c1a-…" }
```

- `recording` (immutable): the id of a recording of the same note (a UUID,
  written lowercase). The item shows the recording with that id; if it is not
  present, the present recording whose `parent` names it (one re-created by a
  restore, §5.7; the first by `(started, id)` if several), as for `rec`
  (§8.3.3); otherwise the recording is *missing*. Any number of items may
  show one recording, on any pages.
- The item has no registers of its own: its title, duration and transcript
  are the recording's (§8.3.1, §8.3.2), so renaming or transcribing the
  recording changes every item that shows it.

Writers: an app that stops a recording should place one `audio` item on the
page the user was looking at, in the same delta as the `addRecording`, so
the recording is never off the page. Removing an `audio` item (`removeItem`)
removes only the item: the recording stays in the note (a reader lists the
note's recordings, §5.4, and can place it again). Removing a recording
(`removeRecording`) should remove, in the same delta, the `audio` items of
its note that show it; an item left showing a missing recording (a
concurrent removal, a writer that did not remove it) is drawn as below and may be removed by
any writer.

Drawing (renderers, exports, and readers before they play): with the frame
`[fx, fy, fw, fh]`, `m = min(fw, fh)`, the padding `p = min(8, 0.1 · m)` and
the icon size `d = min(24, m − 2p)`, everything below in frame coordinates
and then turned with the item's `rotation` about the frame's center:

1. the *card*: the frame filled `#F1F3F4FF` and outlined 1 pt in
   `#DADCE0FF`;
2. the *icon*, when `d > 0`: a disc of diameter `d` filled `#1A73E8FF`
   centered at `(cx, cy) = (fx + p + d/2, fy + p + d/2)`, and over it, in
   `#FFFFFFFF`, a microphone: a capsule (a rectangle with semicircular ends)
   filled, from `(cx − 0.12 d, cy − 0.3 d)` to `(cx + 0.12 d, cy + 0.08 d)`;
   and stroked `0.06 d` wide with round caps, the lower half of a circle of
   radius `0.2 d` centered at `(cx, cy − 0.04 d)`, a line from
   `(cx, cy + 0.16 d)` to `(cx, cy + 0.3 d)` and a line from
   `(cx − 0.12 d, cy + 0.3 d)` to `(cx + 0.12 d, cy + 0.3 d)`;
3. the *label*: a text box (§8.2.4, laid out by §8.5.3) with the frame
   `[fx + 2p + d, fy + p, fw − 3p − d, fh − 2p]` (nothing when its width or
   height is not positive), `font` `sans`, `color` `#202124FF`, `align`
   `start`, `dir` `auto`, no `breaks`, and the runs: the recording's
   `title`, or `Recording` when it is empty or absent, bold, size 12; when
   the recording has a finite `duration`, ` · ` and the duration as `m:ss`
   (`h:mm:ss` from an hour), size 12; when it has a valid transcript (§8.3.2),
   a line break and the text of its segments joined by single spaces, size
   10, `color` `#5F6368FF`, `lang` the transcript's `language`, cut to its
   first 2 000 Unicode scalar values. Unlike a text item the label is
   clipped: a line whose bottom is below `fy + fh − p` is not drawn, nor
   any after it.

An item whose recording is missing is drawn as a placeholder (§8.5.2) and
reported as "recording missing". A transcript that is missing, unreadable or
invalid is left out of the label (reported); the card is still drawn. An
`audio` item counts toward an infinite page's extent and is cut across
export pages like an image.

Playing: a reader that plays audio plays the recording (§8.3.1) when the
item is tapped or its play control used, and may show the position and the
transcript as it plays (§8.3.2). A reader that cannot play shows the card.
A `pdf` export with attachments embeds the recording once however many
items show it (`docs/attachments.md` §10).

### 8.3 Recordings

#### 8.3.1 Recording

A recording belongs to the note, not to a page (`recordings`, §5.4):

```json
{ "id": "…",
  "blob": { "sha256": "…", "size": 28311552, "type": "audio/mp4" },
  "started": "2026-10-04T16:20:00.000Z",
  "duration": 3540.25,
  "codec": "aac", "sampleRate": 48000, "channels": 1, "bitRate": 64000,
  "title": "Lecture 3",
  "transcript": { "sha256": "…", "size": 52011,
                  "type": "application/vnd.sempere.transcript+json" },
  "parent": "…", "origin": "…", "clocks": { "title": "…" } }
```

- `blob`: the audio. Writers write `audio/mp4`: an MPEG-4 file with one audio
  track coded as AAC-LC (`codec: "aac"`), HE-AAC (`"he-aac"`) or ALAC
  (`"alac"`). Readers that play audio must support AAC-LC and should support
  the other two. The recording settings (codec, bit rate, sample rate,
  channels) are the user's choice; the default is AAC-LC, mono, 48 kHz,
  64 kbit/s (`docs/attachments.md` §9). Other types (from importers) are
  allowed and may be unplayable.
- `started`: RFC 3339 wall time of the first sample (sorting, display).
- `duration` (seconds, 3 decimals), `codec`, `sampleRate`, `channels`,
  `bitRate` (bits per second, average): informational. `duration` is the
  sound track's `mdhd` duration (what plays), the movie's `mvhd` duration
  when that is absent or 0.
- `captured` (optional, immutable): for a voice
  note adopted from the inbox (§11.3), who captured it:
  `{ "device": "a1b2c3d4", "recipient": "…(64 hex digits)…" }`. `device` is
  the capturing device's id (§5) as its capture named it; `recipient` the
  fingerprint (§11.1) of the key of the listed device whose device capture key sealed
  the capture. Both are required. A reader that finds a value of
  another shape treats it as absent; it never rejects the revision for it.
  Readers show that device's `name` (§2) while it is listed, and that the
  device is no longer in the vault otherwise.
- Registers: `title` (string; absent means `""`) and `transcript` (a blob
  reference or `null`), changed with `setRecording` and merged LWW per
  (recording, field) like item registers (§8.2.2), with `clocks` in
  snapshots. Every other field is immutable: a `setRecording` naming one, or
  `origin` or `clocks`, or giving `title` a non-string or `transcript` a value
  that is not a blob reference, is invalid (the revision is rejected); `null`
  resets `title` to absent. Unknown fields as in §7.5; like an item's (§8.2.2)
  they are registers, set by `setRecording` and stamped in `clocks`.
- Recordings merge as sets like items, with permanent tombstones (§5.4).

#### 8.3.2 Transcript

A transcript is a blob whose content is UTF-8 JSON (not compressed):

```json
{ "format": "sempere-transcript/1",
  "recording": "<recording id>",
  "engine": "apple-speechtranscriber-26.4",
  "language": "en-US",
  "created": "2026-10-04T17:21:00Z",
  "segments": [
    { "start": 0.52, "end": 3.1, "text": "Today we look at linear maps.",
      "confidence": 0.94,
      "words": [ { "t": "Today", "start": 0.52, "end": 0.8, "c": 0.97 },
                 { "t": "we", "start": 0.8, "end": 0.93, "c": 0.91 } ] } ] }
```

- `recording`: must be the id of the recording whose `transcript` register
  holds it; readers ignore and report a transcript naming another one.
- `engine`: name and version of the speech recognizer, as for recognition
  (§5.5), e.g. `apple-speechtranscriber-26.4`, `apple-sfspeech-26.7`,
  `notability-<version>`. `language`: BCP 47 tag of the language recognized; a
  segment may carry its own `language` when it differs.
- `created`: when the transcript was produced (RFC 3339).
- `segments`: time-stamped pieces of text (a phrase or sentence), sorted by
  `start`, not overlapping. Each has `start` and `end` (seconds from the
  start of the recording, 3 decimals, `start ≤ end`), `text`, and optional
  `confidence` (0…1, the recognizer's confidence in the segment).
- `words`: optional, per segment: the segment's words in order, each with
  `t` (the word as it appears in `text`), `start`, `end` (as for segments,
  within the segment's range) and optional `c` (confidence 0…1). A segment
  has all its words or none.

A transcript whose `format` is not `sempere-transcript/1`, or whose segments
or words break these rules (order, overlap, `start ≤ end`, words inside their
segment, confidences in 0…1), is invalid: readers treat it like a blob that
fails verification (reported, shown as missing, §8.1.4).

Segments are what search and the transcript view use; word timings let a
player highlight each word as it is read back and seek from a tapped word,
and word confidences let a viewer mark doubtful words (for example underline
words under 0.5) or let search skip them. A transcript is derived data,
replaced as a whole by `setRecording` of `transcript`, never merged. Readers
that index text for search include it.

#### 8.3.3 Ink and audio

In plain words: while a recording is running, everything written or placed
on the page is stamped with *which* recording was running and *how many
seconds* into it the writing happened. Tapping that ink later plays the audio
from that moment, and playing the recording can show the ink appearing as it
was written.

Precisely: a stroke or item drawn, typed or placed while a recording runs
carries `"rec": {"id": <recording id>, "at": <seconds>}`, the time from the
start of the recording to the stroke's first point (the item's creation). It
is set when the stroke or item is added and never changes (a stroke sliced by
the eraser passes it to its pieces). A player can highlight or fade in what
was written up to the current position and seek to where a stroke was drawn;
with a transcript, a word's `start` finds the strokes drawn around it. A
`rec` naming a recording that is not present refers to a present recording
whose `parent` names it (one re-created by a restore, §5.7; the first by
`(started, id)` if several), else it is ignored. `rec` is immutable, so this
is how links survive a recording being removed and restored.

### 8.4 Limits

Writers must stay within, and readers may reject anything beyond:

| What | Limit |
| --- | --- |
| blob content (any kind, including video) | 1 GiB (2^30 bytes) |
| transcript content | 64 MiB |
| text of one item | 65 536 UTF-8 bytes, 1 000 runs, 10 000 `breaks` |
| typeset formulas of a Markdown text box (`math`) | 1 000 |
| LaTeX source of a `math` item | 8 192 UTF-8 bytes; typeset only within 4 096 tokens and 64 levels (§8.2.8) |
| items per page | 10 000 |
| recordings per note | 1 000 |
| image to decode | 100 000 000 pixels (renderers draw a placeholder beyond) |

Frames, crops and coordinates are finite and within the renderer's extent
limit, as stroke coordinates are.

### 8.5 Rendering

#### 8.5.1 Mapping a source onto a frame

An image or PDF page is drawn by mapping its crop rectangle `[cx, cy, cw, ch]`
(source coordinates, y down) onto the frame `[fx, fy, fw, fh]`, then
rotating about the frame's center `(mx, my)` by `rotation` θ:

```
p = (fx + (u − cx) · fw / cw,  fy + (v − cy) · fh / ch)
x = mx + (p.x − mx) · cos θ − (p.y − my) · sin θ
y = my + (p.x − mx) · sin θ + (p.y − my) · cos θ
```

The clip is the frame, rotated the same way.

*Image source coordinates* are oriented pixel coordinates `(u, v)`. For a
stored pixel position `(a, b)` in an image `w × h` pixels as stored:

| `orientation` | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `(u, v)` | `(a, b)` | `(w−a, b)` | `(w−a, h−b)` | `(a, h−b)` | `(b, a)` | `(h−b, a)` | `(h−b, w−a)` | `(b, w−a)` |

*PDF source coordinates* are effective-page coordinates `(u, v)`. For a
point `(a, b)` in PDF user space, with the visible box (CropBox ∩ MediaBox)
`[x0, y0, x1, y1]`, `bw = x1 − x0`, `bh = y1 − y0`, `s = a − x0`,
`t = y1 − b`:

| `/Rotate` | 0 | 90 | 180 | 270 |
| --- | --- | --- | --- | --- |
| `(u, v)` | `(s, t)` | `(bh − t, s)` | `(bw − s, bh − t)` | `(t, bw − s)` |
| `W' × H'` | `bw × bh` | `bh × bw` | `bw × bh` | `bh × bw` |

#### 8.5.2 Missing and unknown content

An item whose blob is missing, unreadable, invalid (§8.1.4) or of a type the
renderer cannot draw, an `audio` item whose recording is missing (§8.2.9),
and an item of an unknown kind (§7.5), is drawn as a placeholder (a `math`
item falls back to its source first, §8.2.8): its frame (rotated) outlined 1 pt in
`#9AA0A6FF` with both diagonals. A background placeholder still fills its
frame (§8.2.3). The export goes on and reports each placeholder; it never
fails because of one.

#### 8.5.3 Text layout

Text is full Unicode: any script, mixed scripts, and right-to-left text.
Renderers draw it with fonts they have (system fonts in the app, bundled and
installed fonts in the CLI, `docs/attachments.md` §6), so glyph widths differ
between renderers. Layout stays consistent because the vertical metrics are
fixed by the format and the line breaks are the writer's:

- **Lines.** The text is split into paragraphs at `\n`. If `breaks` is
  present and valid (strictly increasing, every offset inside a paragraph,
  after its first character, and at a grapheme cluster boundary), each
  paragraph is cut into lines exactly at those offsets and nowhere else.
  Otherwise the renderer breaks each paragraph greedily into lines no wider
  than the frame width, at line-break opportunities of the Unicode line
  breaking algorithm (UAX #14); a renderer without a full UAX #14
  implementation must at least break after white space (Unicode
  `White_Space`, except no-break spaces), after `-` (U+002D), and between two
  characters of East Asian Width `W` or `F` (CJK), and breaks a word wider
  than the frame between grapheme clusters. Writers compute `breaks` the same
  way from their own fonts.
- **Widths.** The sum of the shaped glyph advances at each run's size.
  Renderers shape with whatever they have (CoreText; the CLI's own shaper,
  `docs/attachments.md` §10); a renderer that cannot shape a script draws it
  unshaped and reports it. White space at a line end does not count toward
  its width and is not drawn. A tab advances like four spaces. A line wider
  than the frame (another renderer's fonts are wider) overflows on its end
  side and is never re-broken or clipped.
- **Vertical metrics** (font independent). A line's size `S` is the largest
  run `size` on it (the box `size` for an empty line). Its height is `1.2 S`
  and its baseline is `0.95 S` below its top. The first line's top is the
  frame's top; each next line follows. So every renderer puts every line at
  the same height, whatever font it uses.
- **Direction and alignment.** Each line is reordered for display by UAX #9
  (rules L1–L2) with its paragraph's direction (`dir`); `start` aligns to the
  left of `[x, x + w]` for a left-to-right paragraph and to the right for a
  right-to-left one, `end` the opposite, `left`, `center` and `right` as
  named.
- **Decoration.** Underline: `S/18` thick, `0.12 ×` the run's size below the
  baseline; strikethrough at `0.3 ×` the run's size above it, same
  thickness.
- **Faces and fallback.** `b` and `i` select bold and italic faces of the
  family; a renderer without one emboldens (outline stroke of `size/30`) or
  slants (12°) the regular face. A character the chosen font lacks is drawn
  with another font that has it (preferring one for the run's `lang`). A
  renderer with no font for a character draws the missing-glyph box and
  reports which script was missing; an exporter must not produce an export
  that shows missing-glyph boxes without reporting it.

#### 8.5.4 Markdown text

A Markdown box (§8.2.4, `markup` `"markdown"`) is drawn from its source in
four steps, the same in every renderer: parse the source into blocks, turn
the blocks into rendered paragraphs (font independent), break those into
lines (the writer's `layout`, else greedily), and draw. `s` below is the
box `size`; every length is in points.

**Dialect.** A subset of CommonMark with GitHub's strikethrough and task
lists and Pandoc's math, line based so that it parses in linear time:

- The source is split into lines at `\n`. A line is *blank* when it holds
  only spaces and tabs. Its *indent* is the number of leading spaces, a tab
  counting as 4. Up to 3 spaces of indent are ignored when a line is tested
  for a block start below; indented code blocks, setext headings, HTML
  blocks, link reference definitions and lazy continuation lines do not
  exist (such lines are paragraph text).
- **Blocks**, tested in this order on each line that is not blank:
  1. *Fenced code*: 3 or more `` ` `` or `~`; the rest of the line (the info
     string) is ignored. The block holds the following lines until a line
     whose ignored indent is followed by at least as many of the same
     character and then only spaces or tabs, or the end of the container.
     Each content line loses up to as many leading spaces as the opening
     fence had.
  2. *Display math*: `$$`, with no other `$$` on the line except at its
     end (trailing spaces and tabs aside). If the rest of the line, trimmed of spaces and
     tabs, ends with `$$` and is longer than that, the formula is what lies
     between the two marks. Otherwise the formula is the rest of the line,
     then every next line, until a line that, trimmed at its end, ends with
     `$$` (its text before that `$$` belongs to the formula), or the end of
     the container. The formula's lines are joined with `\n` and trimmed of
     spaces, tabs and line feeds; an empty one is a paragraph `$$` instead.
  3. *Heading*: 1 to 6 `#` followed by a space, a tab or the end of the
     line. The text is the rest, trimmed, without a closing sequence (a run
     of `#` at the end preceded by a space or tab, or making up the whole
     rest).
  4. *Thematic break*: 3 or more of one of `-`, `*`, `_`, with only spaces
     and tabs between them and nothing else.
  5. *Block quote*: `>`. The quote holds this line and every next line that
     starts (after its ignored indent) with `>`, each with the `>` and one
     space or tab after it removed; its content is parsed as blocks.
  6. *List item*: a bullet `-`, `+` or `*`, or an ordered marker of 1 to 9
     digits followed by `.` or `)`, then a space, a tab or the end of the
     line. With `n` the line's indent, `m` the marker's length and `k` the
     spaces after it (counted 1 when there are none, when the line ends there,
     or when there are more than 4), the item's *content column* is
     `n + m + k`. Its first line is the rest of the line after those `k`
     spaces; it then holds every next line whose indent is at least the
     content column (minus that many columns of indent) and every blank line
     followed, after more blank lines, by such a line. Its content is parsed
     as blocks. An item whose content starts with `[ ]`, `[x]` or `[X]`
     followed by a space, a tab or the end is a *task*, unchecked or checked,
     and that prefix (and one space after it) is removed. Consecutive items
     (blank lines between them allowed) with the same bullet character, or
     ordered with the same delimiter, make one list; an ordered list counts
     from its first item's number (leading zeros ignored), each next item
     one more.
  7. *Paragraph*: the line and every next line that is not blank and does
     not start a block of rules 1–6. Each line is trimmed of spaces and tabs
     at both ends and loses one trailing `\`; a line break inside a
     paragraph is a **hard line break** (unlike CommonMark: what is typed on
     a new line shows on a new line).
- Blocks nest at most 16 deep (quotes and list items); a line that would
  open a deeper container is paragraph text.
- **Inline content** (paragraphs and headings), scanned left to right:
  - `\` before an ASCII punctuation character is that character, literally.
  - A run of `n` backticks starts a *code span* that ends at the next run of
    exactly `n` backticks; its content is literal, line feeds become spaces,
    and if it starts and ends with a space and is not only spaces, one space
    is removed at each end. Without a closing run, the backticks are text.
  - `$$` starts *display-style math* that ends at the next `$$`; content
    literal, not empty, else the `$$` is text.
  - `$` not followed by a space, tab or line feed starts *math* that ends at
    the next `$` that is not preceded by `\`, a space, a tab or a line feed,
    and is not followed by an ASCII digit; content literal (backslashes
    kept), not empty, else the `$` is text. So `$5 and $6` stays text.
  - `[text](destination)` is a *link* and `![text](destination)` an
    *image*: brackets balanced (escaped ones not counted), the destination
    `<…>` or a run without spaces, tabs or line feeds and with balanced
    parentheses, optionally followed by spaces and a title in `"…"`, `'…'`
    or `(…)`, then `)`. Only the text is drawn: a link's text with the link
    style, an image's text (its alternative text) as text. Nothing is ever
    fetched.
  - `<scheme:rest>` with a scheme of 2 to 32 characters (an ASCII letter,
    then letters, digits, `+`, `.`, `-`) and no space, `<` or `>` in `rest`
    is an *autolink*: the URL as link text.
  - Runs of `*`, `_` (any length) and `~~` (exactly two; other runs of `~`
    are text) are *delimiter runs*, matched as CommonMark §6.2 does
    (left- and right-flanking runs, `_` not opening or closing inside a
    word) without the "multiple of 3" rule: each closer, left to right,
    matches the nearest earlier opener of the same character that can
    open; they use 2 characters when both have at least 2 (`**`: bold) or
    1 (`*`: italic), `~~` makes strikethrough, delimiters between them are
    dropped (as text), and what is left of either run is matched again.
    Unmatched delimiters are text.
  - Anything else, HTML included, is text.

**Rendered paragraphs.** Each heading, paragraph, code block, display
formula and thematic break becomes one rendered paragraph, laid out in a
*content column* `[x, x + w]`: the frame's, narrowed by its containers.

- Containers: a block quote moves the column right by `s`, and draws a bar
  `0.15 s` wide at its left edge + `0.25 s`, from its first paragraph's top
  to its last paragraph's bottom, in the box color at 40 % of its alpha. A
  list item moves it right by `1.6 s`; its first paragraph gets the marker
  in the space it leaves, on its first line: a bullet is a disc of diameter
  `0.36 S` (`S` that line's size) centered `0.8 s` left of the column and
  `0.32 S` above the baseline, filled in the box color, a ring (stroke
  `S/16`) at odd nesting depths of bullet lists (the second, fourth, …); a
  task is a square of side `0.66 S`, stroke `S/14`, its right side
  `0.35 s` left of the column and its bottom on the baseline, with a check
  mark (a polyline through (0.18, 0.52), (0.42, 0.76), (0.82, 0.24) of the
  square, stroke `S/9`) when checked; an ordered item's number and
  delimiter (`3.`) is text in the box style, its right end `0.35 s` left of
  the column on the baseline.
- Gaps: a paragraph that follows another in the same box starts `0.5 s`
  below it when one or more blank source lines lie between them, else
  right below it.
- Styles: text in the box style; a heading of level 1, 2, 3 at `1.6 s`,
  `1.4 s`, `1.2 s`, levels 4–6 at `s`, bold; a code block and a code span
  in font `mono` at the size around them; a code block is laid out without
  alignment (`start`), `0.5 s` in from its column, with `0.25 s` more above
  its first line and below its last, all of which (the column's width) is
  filled with the box color at 8 % of its alpha; a thematic break is one
  empty line of size `s` with a line `s/12` thick across the column at
  `0.6 s` below its top, color as the quote bar; links are underlined and
  `#1F6FEBFF`; bold, italic and strikethrough as runs' `b`, `i`, `s`
  (§8.5.3).
- Formulas: an inline formula has the size and color of the text around
  it; a display formula (a display-math block, drawn centered in its column)
  has the paragraph's size and the box color. A formula with a matching
  `math` entry (§8.2.4) is one *box*: `renderSize` wide and high, its
  baseline `depth` above its bottom, never broken, with a break
  opportunity before and after it; drawn like a math item's render
  (§8.2.8 step 1) without rotation of its own. A formula without one is its
  `latex` as text in font `mono` (a display one as a paragraph in its
  own right, centered), and the export reports it like an equation drawn as
  its source.

**Lines.** A rendered paragraph is cut into lines at its hard line breaks,
then at the `layout`'s `breaks` when the `layout` is usable: its `of`
matches; every offset is the source offset of a character or formula that
is drawn (not markup), lies inside a rendered paragraph after its first
item and not right after a hard line break, is not inside a formula box,
and is a grapheme cluster boundary of the drawn text. Otherwise every
paragraph is broken greedily, like §8.5.3 with its minimum break rules
(after white space, after `-`, between wide characters, and around formula
boxes), the widths being the renderer's. A line's metrics follow §8.5.3
with boxes added: with `S` its largest text size, its ascent is the larger
of `0.95 S` and every box's height minus its depth, its descent the larger
of `0.25 S` and every box's depth; so a line without boxes is `1.2 S`
high. The first paragraph's top is the frame's top. Lines are aligned in
their column by the box `align` and `dir` (§8.5.3), display formulas
centered.

**Drawing.** Text lines are drawn as text items (§8.2.4, §8.5.3) with the
lines decided above (never broken again), boxes as math renders, markers,
bars, rules and code fills as filled or stroked shapes. A renderer that
must draw a box line piece by piece puts the pieces left to right in
logical order (right to left in a right-to-left paragraph). Writers store
the frame height of the rendered lines (at least `1.2 s`), and a
`layout` for the frame width, as they store `breaks` (§8.2.4).

**Plain text** (search, reports): every rendered paragraph's text, with
formulas as their `latex`, joined with `\n`; markers, markup, link
destinations and the content of nothing else.

**HTML exports** write the parsed blocks as HTML elements (`h1`–`h6`, `p`
with `br`, `ul`/`ol` with `start`, `li` with a disabled checkbox for
tasks, `blockquote`, `pre`/`code`, `hr`, `strong`, `em`, `del`, `code`, `a`
for `http`, `https` and `mailto` destinations only, else the link text),
every text escaped; formulas as their source between `\(`…`\)` or
`\[`…`\]`, inside `span class="math"`.

## 9. Untrusted input

Everything in a vault folder may come from a hostile sync server, a shared
folder or a crafted import, and is untrusted until its age header, body tag
(§4) and content have been checked; even then a listed device may be malicious.
A reader must fail on bad input with an error it reports (§4, §5), never by
crashing, hanging, or allocating without a bound. Concretely, readers:

- reject a `seq` above 2^53 − 1 anywhere (§5) and a date that is not the
  RFC 3339 form of §6, including impossible ones (`02-30`, hour 24, second 60);
- treat sizes, counts and coordinates as claims to check against the bytes
  actually present before allocating for them;
- never follow a reference chain, nesting or `parent` link without a bound,
  and never expand shared references (a plist object used many times, an
  XML entity) into copies;
- bound the work a renderer or importer does by the size of its input, not
  by the distances, extents or counts the input names.

The reference implementation (`Sources/`) enforces these limits; other
readers may choose their own. Larger inputs fail with a typed error, except
where the table says how they degrade.

| What | Limit | Where |
| --- | --- | --- |
| revision file, sync state | 256 MiB on disk, 256 MiB after gunzip | `BoundedRead`, `Gzip.defaultMaxOutput` |
| `vault.json` | 16 MiB; a wrap 16 KiB; at most 4096 entries and 256 additions per epoch (§15.3, §15.7) | `EpochManifest.maxBytes` |
| `vault.json` `label` (§2) | anything but a string reads as absent, never a parse error | `EpochManifest` |
| epoch record, re-encryption journal (§15.6, §15.8) | 64 MiB on disk and after gunzip | `EpochRecord.maxBytes` |
| join request, passphrase copy, device key file (§15.11, §15.12) | 16 KiB | `JoinRequest.maxBytes`, `RecoveryPassphraseCopy.maxBytes`, `DeviceKeys.maxBytes` |
| blob collector state (device-local, §8.1.6) | 64 MiB | `BlobCollectorState` |
| identity file, device state | 1 MiB | `BoundedRead` |
| attachment blob file (§8) | 1 GiB of content plus 64 MiB of framing and age overhead (padme of a 1 GiB blob adds up to 32 MiB) | `BoundedRead` |
| `backup.json`, export manifest (`.sempere-export-*.json`) | 256 MiB | `BoundedRead` |
| files read at all | regular files only (no FIFOs or devices; symlinks followed in a vault, not in an imported package, and never below a backup folder or a restore source: a backup run, verify or restore reports a link there and does not read through it) | `BoundedRead` |
| JSON nesting | 512 levels (Foundation's decoder) | |
| names of skipped ops, fields and features reported (§7.4) | 64 characters each; 32 distinct per note (or vault), the rest counted together | `NewerContent.maxNameLength`, `.maxNames` |
| unknown fields kept verbatim (§7.5, §8) | 24 levels deep from the document root; 16 384 values per file | `JSONValue.maxDepth`, `.maxValues` |
| `seq`, `included` `upTo` / `extra` | 1 … 2^53 − 1 | `RevisionName.maxSeq` |
| age header | 2 MiB, 1024 stanzas | Age `HeaderCodec` |
| scrypt work factor (the passphrase copy, a passphrase-wrapped identity) | 2^20 (1 GiB) | `ScryptIdentity`, `IdentityFile` |
| WebDAV response | 256 MiB for a revision, 16 MiB otherwise; a blob is fetched in 2 MiB segments, up to the blob file limit above; PROPFIND bodies must be UTF-8 with no DTD or processing instruction | `WebDAVClient` |
| WebDAV sync run (§9.1) | 100 000 note folders, 10⁶ listed entries, 64 GiB downloaded, 12 hours; the run stops there with an error and the next one continues | `SyncLimits` |
| zip entry (import) | 1 GiB uncompressed, CRC and size checked; a stored entry's two sizes equal, a deflated one at most its size + 0.1 % + 64 bytes; no two entries of one name, and no two whose header and data overlap (else the archive is refused); all reads of one archive, repeated and failed ones included, at most 32 × its size and at least 2 GiB uncompressed (an unzipped package: 4 GiB read); a read that failed is not repeated; thumbnails: 8, 16 MiB each | `ZipArchive`, `NotePackage` |
| binary plist (import) | 64 levels; no cycles; each object parsed once; keyed archives must be binary | `BinaryPlist` |
| XML plist (import: a recordings library, a PDF metadata index, a few small Notability plists) | 4 MiB, 64 levels; only the five predefined entities and numeric character references; a DOCTYPE with an internal subset refused | `XMLPlist` |
| keyed-archive UID chain | 64 hops | `KeyedArchive` |
| Notability coordinates and widths | ±10⁶ units, finite; recognized pages up to 100 000; dates outside 0001…9999 dropped (`.note` and `.ntb`) | `NotabilityNote` |
| `.ntb` bundle (import) | geometry, erase lists and titles decoded: 4 × the bundle's size + 64 KiB; pages below 100 000 | `NotabilityBundle.decodeBudgetFactor` |
| shape objects (import) | 1 curve point per byte of the `shapes` plist + 65 536 | `NotabilityShapes.pointsPerByte` |
| duplicate detection (import) | 256 stroke comparisons per stroke + 10⁶ per copy; beyond, the copy is imported as a separate version | `NotabilityImporter.PrintIndex` |
| page size and stroke extent (render) | 200 000 pt | `RenderLimits.maxExtent` |
| item frame (app canvas, hit testing) | every number finite, rotated corners within 200 000 pt; other items are not drawn or selectable | `ItemFrames.isDrawable` |
| curve samples per stroke | 64 per control point + 1024 (sparser beyond) | `RenderLimits.samplesPerPoint` |
| outline points per page | 40 M | `RenderLimits.maxOutlinePoints` |
| nib width | 1 000 pt (drawn no wider) | `RenderLimits.maxNibWidth` |
| paper ruling | 40 000 commands per band, 1 M per page (plain background beyond) | `RenderLimits.maxPaperCommands…` |
| PNG image | 40 M pixels by default | `PNGOptions.maxPixels` |
| image decoded for export (§8.2.5) | 100 M pixels (§8.4) and at most 1 024 per byte of the file + 1 M (a header cannot claim more than its data can hold); 64 MiB per image blob; a truncated JPEG scan decodes as far as its data goes | `ImageLimits` |
| items drawn per page | 10 000 (§8.4), a Markdown box counting as the pieces it is drawn as (§8.5.4); the rest are reported, not drawn | `RenderLimits.maxItemsPerPage` |
| font file (font packs, render) | 64 MiB; 512 tables; composite glyphs 8 levels and 65 536 points; CFF subroutines 10 levels, 65 536 charstring operations, 48 operands; layout substitutions 2^20 steps, nested lookups 8 levels; any failure falls back to another font | `OpenTypeFont`, `CFFFont`, `GSUBApplier` |
| font-pack scan | 20 000 font files, 64 faces per collection | `FontLibrary` |
| notebook levels shown | 64 | `NotebookNode.maxDepth` |
| notebook name (a capture's title and notebook, §11.3; the `quickCapture.notebook` setting) | 300 characters and 1 200 Unicode scalars; a capture cuts a longer name, the setting refuses it | `CaptureAdoption.maxNameLength`, `.maxNameScalars` |
| LaTeX source (`math`, §8.2.8) | 8 192 UTF-8 bytes (else the revision is rejected); typeset only within 4 096 tokens, balanced groups and 64 levels of nesting (else drawn as source text) | `MathSource.check` |
| PDF attachment (export, `SemperePDF`) | 1 GiB file; 10⁶ objects; 256 MiB per decoded stream, 1 GiB decoded per file; the object parser reads at most 4 bytes per byte of the file and of its decoded streams, plus 64 MiB; nesting and page-tree depth 64; 32 reference hops; 4 096 cross-reference sections; 16 filters per stream; encrypted files refused | `PDFLimits` |
| PDF page drawn as pixels (SVG, PNG) | 16 M pixels per page (drawn at a lower resolution beyond), 256 M per export (placeholders beyond) | `RenderLimits.maxBackgroundPixels…` |
| summary cache file (§10) | 64 MiB on disk, 256 MiB after gunzip; any failure discards it | `SummaryCache.maxFileBytes` |
| published summaries (§12) | 64 MiB on disk, 256 MiB after gunzip; unknown fields skipped, not kept; any failure ignores the file, a bad entry only that entry | `PublishedSummaries.maxFileBytes` |
| notebook records (§14) | 64 KiB on disk and after gunzip per record; 256 `add` paths and 4 096 `remove` ids per record, a path at most 1 200 Unicode scalars (else the record is refused); 10 000 records per vault (the rest ignored and reported) | `NotebookRecords.maxFileBytes`, `.maxAdds`, `.maxRemoves`, `.maxRecords` |
| shared settings (§13) | 1 MiB on disk, 1 MiB after gunzip; 4 096 slots, 32 type blocks (else the file is refused); a malformed `$meta` entry or version, or an invalid value, is ignored alone | `SharedSettings.maxFileBytes`, `.maxSlots`, `.maxBlocks` |

Foundation's own parsers are not safe on hostile bytes on every platform:
on Linux, `PropertyListSerialization` crashes on a binary plist holding a
set, `ISO8601DateFormatter` dies in ICU on a long fraction, and `XMLParser`
crashes on an element name that is not UTF-8 or on a processing
instruction without data. The library parses dates and binary plists
itself and checks PROPFIND bodies before `XMLParser` sees them.
`Tests/FuzzSupport` fuzzes every parser above on each test run.

### 9.1 Received files

A writer that copies revisions or blobs into `notes/` from elsewhere (a sync
server, a shared folder it pulls from) checks each file **before** it places
it, because a placed file is write-once and every later reader trusts its
name:

- **With the vault unlocked**, a revision must decrypt with the vault
  identity, its tag (§4) must verify under the epoch's key, and it must decode as a revision of
  that note and file name; a revision marked as written by a later version
  (§7) passes, as it would when read. A blob must decrypt whole, with valid
  framing, zero padding and content hash (§8.1.3, §8.1.4), and its file name
  must be the keyed name of its hash (§8.1.2). The checks are those of a read
  under the key `vault.json` holds once any `vault.json` received in the
  same run has been taken (§1.3, §2.1).
- **Locked** (no identity, or a first pull without one), only structure can
  be checked: an age header that parses, with exactly one stanza, of type
  `mlkem768x25519`, and a payload long enough for one chunk.

A file that fails is **quarantined**: never placed under `notes/`, kept
outside the vault (the reference implementation: next to the sync state,
`<state>.quarantine/<path>`, mode 0600; a later copy of the same path with
other bytes is kept beside it, never over it) and reported. It is not fetched again
while neither it, `vault.json` nor the lock state changed (`sempere sync
webdav --retry-quarantined` fetches it again). It is never deleted silently.

**One bad file never blocks a note.** Readers already skip a revision they
cannot read (§5, reported). A writer choosing its next `seq` (§5) skips a
snapshot whose tag does not verify: it decrypted with the vault identity but
was not written under the vault key, so no writer of the vault made it and
its `included` covers nothing; skipping it can never reuse a `seq`. A
snapshot that does not decrypt may be a real
one whose coverage is unknown, so a writer still refuses to pick a `seq`
until it can be read or is removed. A locked sync places such well-formed
forgeries (it cannot tell), and they then fail only their own reads.

## 10. Per-device summary cache (outside the vault)

Not part of a vault and never stored in one: a reader may keep, per device,
the summaries of a vault's notes (title, tags, notebook, deleted flag, page,
stroke and recognized-page counts, the recognized text of each page for search, newest `wall`) so that listing the vault
again does not decrypt every note. The reference implementation keeps it in
the app's Application Support folder and, for the CLI, in
`$XDG_CACHE_HOME/sempere/` (default `~/.cache/sempere/`). Other readers need
not read or write it; it is documented because it is derived from the vault
key and holds note metadata.

**Key and name.** With the epoch's key `K_e` (§15.2) as HKDF-SHA256 input key
material (RFC 5869, empty salt):

```
key  = HKDF-SHA256(ikm = K_e, salt = "", info = "sempere/1 summary-cache key",  L = 32)
name = HKDF-SHA256(ikm = K_e, salt = "", info = "sempere/1 summary-cache name", L = 16)
file = lowercase hex(name) ‖ ".summaries"
```

The file name says nothing about the vault without its key; a vault that
starts a new epoch gets a new, empty cache, and the old file is never read
again.

**File.** `SMPS` ‖ `0x01` ‖ ChaCha20-Poly1305 sealed box (12-byte random
nonce ‖ ciphertext ‖ 16-byte tag) under `key`, with associated data
`SMPS` ‖ `0x01` ‖ the file name (UTF-8). The plaintext is `gzip(JSON)` of
`{"schema": N, "notes": …}`: per note id, the sorted file names of the
revisions the summary was made from, the summary and, optionally, the metadata
of each of those revisions that thinning needs (name, `wall`, `checkpoint`,
`session`, `asOf`, snapshot `included`; §5.8.4), used only when it names
exactly the entry's files. Its JSON shape is the
implementation's own and changes with `schema`.

**Validity.** Revision files are write-once and named by `(hlc, device,
seq)` (§5), so an entry is used only when the note's current revision file
names are exactly the entry's; anything else (a new, compacted or removed
revision) means the note is read again. Summaries of notes with unreadable
revisions are not stored. A file that is missing, too large, fails to
authenticate or decompress, does not parse, or has another `schema` is
ignored and replaced on the next write. Because entries trust file names, a
revision damaged in place after it was cached is reported only when the note
is opened, not in the listing.

### 10.1 Other per-device caches

A reader may keep other caches derived from a vault on a device, under the
same rules as §10: never in the vault, unreadable and unlinkable to the vault
without its key, and never trusted over the vault. Each cache has a
*purpose* (lowercase ASCII letters and digits in hyphen-separated words, at
most 64 bytes) and a 5-byte magic. The purposes `summary-cache`, `capture`,
`list`, `markers`, `blob` and `recipients` are reserved: with them the
derivations below would give the keys of §10, §11.1 and §15.2 (`list key`,
`markers key`; `blob name`, whose first 16 bytes a cache folder's name would
show), and `recipients` that of an earlier draft of this format. Every other
info string of §15.2 either has a space where `<purpose>` would be, which no
purpose can, or does not end in ` key`, ` entry` or ` name`. With the epoch's key `K_e` as
HKDF-SHA256 input key material (empty salt):

```
key      = HKDF-SHA256(ikm = K_e, salt = "", info = "sempere/1 <purpose> key",   L = 32)
entryKey = HKDF-SHA256(ikm = K_e, salt = "", info = "sempere/1 <purpose> entry", L = 32)
name     = HKDF-SHA256(ikm = K_e, salt = "", info = "sempere/1 <purpose> name",  L = 16)
folder   = lowercase hex(name)
entry    = lowercase hex(first 16 bytes of HMAC-SHA256(entryKey, label)) ‖ suffix
```

where `label` is the implementation's description of the entry (for example
a note id and its revision file names). Each entry file is `magic` ‖
ChaCha20-Poly1305 sealed box (12-byte random nonce ‖ ciphertext ‖ 16-byte
tag) under `key`, with associated data `magic` ‖ the entry's file name
(UTF-8), so an entry renamed or copied over another fails to open. A file that
is missing, too large or fails to open is a miss. A vault that starts a new
epoch derives another folder; the old one is never read again and may be
deleted.

The reference app keeps one such cache, the **drawing cache** (purpose
`drawing-cache`, magic `SMPD` ‖ `0x01`), in its Caches folder: per note
*version* (the note id and the sorted file names of its revisions, which
identify its content because revision files are write-once, §5), the note's
state without stroke geometry (a JSON `layout`) and, per page, PencilKit's
`dataRepresentation` of the page's ink, one canvas stroke per stored stroke.
Its contents are the implementation's own, change with its schema number, and
are checked against the revisions read from the vault before they are drawn
on. It is limited in size (least recently used entries go first) and deleted
when the vault is closed on that device.

It keeps four more, under the same derivation:

- the **render cache** (purpose `render-cache`, magic `SMPI` ‖ `0x01`):
  pictures of image items and previews of PDF page items as drawn on that
  device, labeled by everything the pixels depend on (the item's drawing
  fields, the blob reference, the scale), sealed as above; limited in size and
  deleted when the vault is closed;
- the **attachment index** (purpose `attachment-index`, magic `SMPX` ‖
  `0x01`, one entry per note named `entryName("note|<note id>")` plus
  `.idx`, in Application Support): per note, the blob files of `att/`, the
  blob references of each revision by file name, the hashes the current
  state shows, and this device's first-seen-unreferenced times for §8.1.6
  rule 4 (`docs/attachments.md` §4). Losing it only restarts those windows;
  collection reads the note again before deleting anything;
- the **activity** file (purpose `activity`, magic `SMPA` ‖ `0x01`, one entry
  named `activity`, not keyed by `entryName`): the notes "Recognize All" read in
  the last seven days and the recent search queries, kept across launches;
- the **saved selection** (purpose `selection`, Mac; no file): the library
  window's selection, which the system keeps in plaintext with its window
  state, names a notebook or tag only as `entryName("notebook|<canonical
  path>")` or `entryName("tag|<tag key>")`, resolved against the unlocked
  vault's notebooks and tags;
- the **blob cache** (purpose `blob-cache`): decrypted attachment content
  (§8.1), which PDF and image readers need as plain files, so its entries are
  **not** sealed: each file holds a blob's verified content, is named
  `entryName("blob|<note id>|<sha256>|<size>")` plus a type extension, and is
  protected only by the device's file protection. A file found there from an
  earlier session is used only after its size and SHA-256 match the
  reference again; the folder is deleted when the vault is closed. Audio, video
  and transcripts are not kept: their files are deleted as soon as nothing plays
  or reads them, carry a name prefix (`t-`) so that a launch deletes any a
  killed session left without knowing the key, and are never adopted. Where the
  system does not encrypt files at rest (Mac Catalyst has no data protection
  class), files are never kept across launches: quitting the app deletes them,
  and a launch (after a crash) deletes what an earlier one left before any vault
  opens.

## 11. Capture inbox

A device may add voice notes to a vault without its
device key and without the vault key: it keeps the vault identity's public
recipient `v_e` and a **capture key**, and seals each voice note into `inbox/`.
Any device that can read the vault later **adopts** it: it becomes a note,
written as ordinary revisions and blobs (§5, §8). Files under `inbox/` are
not revisions and are not write-once: they are deleted once adopted. Readers
that do not implement this section ignore `inbox/` (§1); no `features` entry
is needed, since nothing under `notes/` changes. Rationale and threat model:
`docs/quick-capture.md`.

### 11.1 Capture key

```
fingerprint(r)      = lowercase hex of SHA-256(UTF-8 of r)       r: a device's key as written in vault.json
deviceCaptureKey(r) = HKDF-SHA256(ikm = K_e, salt = "",
                                  info = "sempere/1 device capture key" ‖ 0x00 ‖ fingerprint(r), L = 32)
```

with `K_e` the epoch's key (§15.2). `fingerprint(r)` is not the device
fingerprint of §15.4, which also covers the signing keys: capture keys and
capture attributions keep this one.
Captures are attributed (security review 2026-10, C2, C3). A capture
profile is made by a listed device `r` that unlocked the vault, and holds
`v_e`, `deviceCaptureKey(r)` and `fingerprint(r)`:
besides that profile, only a holder of `K_e` itself (a listed
device that unlocks, which can also write revisions as anyone, §4) can seal a
capture that verifies as coming from `r`, so captures are **attributed** to a
device of the authenticated list (§2.1), and a holder of another device's
profile cannot impersonate it. Attribution says which profile sealed a
capture against profile holders, never against key holders. There is no
vault-wide capture key: every capture is sealed with a device capture key.

Each device capture key authenticates inbox files and nothing else. It cannot decrypt anything,
tag a revision (§4), name a blob (§8.1.2) or derive a per-device cache key
(§10), and HKDF does not reveal `K_e`. It changes with the epoch: removing a
device starts a new one (§15.14), which revokes every capture key handed out
before. An inbox file sealed under an earlier epoch is adopted when the record
that closed that epoch seals it with its exact bytes; the device that sealed
one later re-seals it from its write ledger (§15.14 "Catch-up"); any other
stays in the inbox, set aside, never adopted. A capturing device stores the key and `v_e` (a
*capture profile*); how it stores them is up to the implementation. The
profile is made only from a vault whose `vault.json` checked (§2.1) when it
was made or refreshed, and a capturing device seals to its profile's `v_e`
only, never to anything it reads from `vault.json` without the key.

### 11.2 Inbox files

`inbox/<captureId>.<kind>.age`, with `<captureId>` a lowercase UUID and
`<kind>` `capture` or `transcript`. Other names are unknown files. Each file is
an age v1 file encrypted to `v_e` in one stanza, like a revision. Its
plaintext is:

| Offset | Size | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `SMPC` |
| 4 | 1 | version `0x01` |
| 5 | 32 | tag = HMAC-SHA256(key = deviceCaptureKey(r), message = `"sempere/1" ‖ 0x00 ‖ "capture" ‖ 0x00 ‖ filename ‖ 0x00 ‖ rest`) |
| 37 | rest | one line of UTF-8 JSON (no `0x0A` inside), `0x0A`, then the payload |

`filename` is the file's base name, so a file renamed to another capture id or
kind does not verify. A reader verifies the tag before it parses anything
after it, under each key of its **key ring**, in the same streamed pass:
the device capture key of every device listed
in a `vault.json` whose list checks (§2.1; a reader refuses to read
captures against a refused one), under the epoch's key. The key that verifies attributes the
file to that device. A device no longer listed has no key in the
ring, so the captures of a removed device never verify. A file that fails is untrusted
input (§9): reported, kept, never adopted.

So that the work does not grow with the list, a reader tries for a
`capture` file only the device capture keys of the device its manifest
**claims**: before the tag is checked it scans the
first 64 KiB of the JSON line (up to its `0x0A`), as bytes and without
parsing it, for `"recipient"`, optional JSON whitespace, `:`, optional
whitespace and a string of 64 lowercase hex digits, and takes at most two
such claims. Writers therefore write `recipient` without escapes and keep
what sorts before it short (the `notebook` at most 300 characters and 1200
scalars, as adopted). The claim only chooses keys: the tag decides, and a
manifest whose parsed `recipient` is not the verifying key's is rejected
(above); a wrong or missing claim only makes the file fail. That is one
streamed HMAC per claim whatever the list's length. A `transcript`
file names no device and is tried under the whole ring; its bound (below)
keeps that cost small. The whole plaintext is at
most 256 MiB for a `capture` and, for a `transcript`, 37 bytes plus one JSON
line of at most 64 MiB (§8.3.2), `0x0A` and 64 hex digits; a reader checks
the file's size against its kind's bound before decrypting. The tag covers
everything after it, so a reader computes it while decrypting, as a stream,
without keeping the plaintext, and reads a file whole only once its tag
verified: a file nobody with the capture key wrote costs one pass in constant
memory.

A file that fails is kept (it may be a real capture this device cannot check
yet, for example sealed under a secret whose `vault.json` has not arrived),
but a reader need not decrypt it again at every unlock. The reference
implementation keeps a per-device record outside the vault (like §10) of
files that failed, by vault id, name, size and modification time, and does
not read such a file again for an hour after its first failure, then twice
as long after each further failure, up to a week, unless it changes; a read
that verifies clears its record. Failures to read the file at all (I/O,
iCloud) are not recorded.

- **`capture`**: the JSON is the capture manifest and the payload is the
  audio, as recorded:

  ```json
  { "format": "sempere-capture/1", "id": "<captureId>", "device": "a1b2c3d4",
    "vault": "<vaultId>", "created": "2026-10-07T14:33:05.120Z",
    "started": "2026-10-07T14:32:41.000Z", "title": "Voice note 2026-10-07 14:32",
    "notebook": "Inbox", "recipient": "…(64 hex digits)…",
    "audio": { "sha256": "…", "size": 196608, "type": "audio/mp4" },
    "duration": 24.1, "codec": "aac", "sampleRate": 48000, "channels": 1, "bitRate": 64000 }
  ```

  `id` must equal `<captureId>` and `vault` the vault's `vaultId`. `audio` is
  a blob reference (§8.1.1) of the payload: its size and SHA-256 must match.
  `device` is the capturing device's id (§5). `recipient` (required, 64
  lowercase hex digits) is `fingerprint(r)` of the profile's device key; a
  reader rejects a manifest without it, or whose `recipient` is not that of
  the key that verified the file. `title`, `notebook` (absent:
  `Inbox`) and the informational fields become the note's; the title and
  the notebook as at most 300 characters (and 1200 Unicode scalars: one
  character may hold any number of combining marks), control characters replaced by
  spaces (any holder of the capture key writes them, §11.3).
- **`transcript`**: the payload is the 64 lowercase hex digits of the
  capture's audio SHA-256 (its manifest's `audio.sha256`). That binds the
  transcript to the audio: the capture key is on every capturing device and
  capture ids are in the clear, so otherwise any holder of the key could add
  a transcript to a voice note it never heard. A reader adds a transcript
  only to the recording whose blob has that hash, and never one whose
  payload is anything else: such a transcript is deleted once its note exists, never adopted. It is
  also adopted only when it is attributed like its capture (the same
  device; for a capture adopted earlier, the recording's
  `captured.recipient`, §8.3.1). The JSON
  is a transcript (§8.3.2) whose `recording` is the
  capture's recording id (§11.3).

Recovery without the app (the audio of a capture):

```
age -d -i key.txt inbox/ID.capture.age | tail -c +38 | head -n 1 | jq .   # the manifest
age -d -i key.txt inbox/ID.capture.age | tail -c +38 | tail -n +2 > note.m4a
```

### 11.3 Adoption

The note, its page and its recording have ids derived from the capture id,
`derived(name)` being the first 16 bytes of SHA-256 of the UTF-8 `name` with
the UUID version set to 8 and the variant to `10` (RFC 9562):

```
note      = derived("sempere-capture/1 <captureId> note")
page      = derived("sempere-capture/1 <captureId> page")
recording = derived("sempere-capture/1 <captureId> recording")
card      = derived("sempere-capture/1 <captureId> card")
```

so devices that adopt the same capture concurrently write the same note, and
an adoption interrupted before the inbox file was deleted adds nothing when
repeated. To adopt, a reader verifies the files (§11.2), writes the audio
(and transcript) as blobs of the note (§8.1.4), then writes one delta as
itself (its own device id and clock):

- a note that does not exist yet gets `newNote` (title, notebook, one page
  with the derived page id, the reader's default paper and page size) and
  `addRecording` (the derived recording id, the blob, `started`, the
  informational fields, and `captured`: the manifest's `device` and the
  device key fingerprint the file is attributed to, §8.3.1), with `transcript` set when a
  transcript file attributed like it is there; writers should also add, in
  the same delta, the recording's `audio` item (§8.2.9) on that page with the
  derived `card` id, placed as a new card is on an empty page (300 × 96
  points, narrower on a narrow page, centered across the page a margin from
  its top; `z` the first key), so the note shows the recording and its
  transcript as a recording made in a note does. Readers accept an adopted
  note with or without the card;
- a note that exists gets only `setRecording(transcript)`, and only when the
  recording is there without a transcript, its blob is the audio the
  transcript is bound to, and the transcript is attributed like the
  recording's `captured` (§11.2).

The delta is the adopter's, not the capturing device's: revision names carry
a per-device `seq` (§5) that two devices adopting the same capture, or the
capturing device editing the note afterwards, would both use, and the
capturing device holds no vault key to tag a revision with. Attribution
is therefore `captured`, which the adopter writes after verifying it.

Afterwards the capture file is deleted once the note exists, and the
transcript file once the recording has a transcript (or is gone, or holds
other audio than the transcript is bound to, §11.2). A
transcript file whose capture has not arrived yet stays.

### 11.4 Syncing the inbox

Inbox files are not write-once, so a writer that keeps two copies of a vault
in step (a sync, §1.3) does not follow the table of `notes/`. A file on one
side only is deleted from that side when **adoption explains it**: the note
derived from the capture id (§11.3) has a revision on the side that judges, is
complete there (§1.2), and the file is one that adoption deletes after it (a
capture once the note exists; a transcript once its recording has a
transcript, is gone, or holds other audio, §11.2, judged with the
transcript's bytes). Adoption would delete it there anyway, and a file it
explains is never copied, so writers that bridge two copies cannot hand it
back and forth. It is judged with the vault unlocked. Otherwise:

- if both sides held it at the last sync, the other side deleted it without
  adoption to explain it: it is copied back; locked, it is left alone (neither
  deleted nor copied back) until an unlocked sync;
- if not, it is copied to the other side, never over a file there, after the
  checks of §9.1 (unlocked: as an adoption reads it, §11.2; locked: its age
  structure). One that fails is quarantined, never placed and never deleted;
- on both sides with other bytes (a re-encryption re-sealed one copy, §15.8,
  KH6): neither is replaced by a sync that does not implement the
  replacement rules of a key change (the reference implementation reports it).

A writer syncs the notes before the inbox, so an adopted note reaches the
other side before its inbox files are deleted there. Two devices that adopt
the same capture write the same note (§11.3) and both delete their copies;
the audio blob they each wrote has the same name and content (§8.1.2) and
neither replaces the other.


## 12. Published summaries

A vault may hold, at its root, `sempere-summaries.sealed`:
the summary of each note (title, tags, notebook, flags, page count and the
searchable text of each page) together with the names of the revision files
it was made from, so that a reader can list and search the vault without
decrypting every revision. It exists for readers that start cold on every
visit, such as the web viewer (`docs/web-viewer.md`), and is published next
to a copy of the vault (a WebDAV mirror) rather than kept per device like
the cache of §10.

The file is **a hint**. It is derived from the revisions, never needed to
read the vault, and never trusted over them: a reader that does not
implement this section ignores it (§1), and a missing, stale, damaged or
foreign file is never an error, only a slower listing. It is not under
`notes/` and is not write-once: a writer replaces it whole (atomically, or
with one `PUT`). It needs no `features` entry (§2).

### 12.1 Key and file

```
key = HKDF-SHA256(ikm = K_e, salt = "", info = "sempere/1 published summaries key", L = 32)
```

| Offset | Size | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `SMPU` |
| 4 | 1 | version `0x01` |
| 5 | 12 | nonce, random per write |
| 17 | rest | AES-256-GCM ciphertext under `key`, then its 16-byte tag |

The associated data is the first 5 bytes ‖ `"sempere/1"` ‖ `0x00` ‖ the
vault's `vaultId` (§2, lowercase, ASCII). The plaintext is `gzip(JSON)`
(UTF-8). AES-GCM rather than the ChaCha20-Poly1305 of §10 because browsers
provide it (WebCrypto); with a random 96-bit nonce per write and one write per
change of the vault's listing, nonce reuse is not a concern. `K_e` is the
epoch's key (§15.2): only holders of it (the vault's listed keys) can write
or read the file. A vault that starts a new epoch derives another key, so its
old file no longer opens and is ignored until rewritten.

Test vector (`K_e` = 32 bytes `0x00 0x01 … 0x1f`, `vaultId`
`0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c`, nonce 12 bytes `0xa0 0xa1 … 0xab`,
plaintext the ASCII bytes `{}` (not gzip, to keep the vector short)):

```
key  = 4ffd10840df4dc46092a2c424919f611c1bcc355fe7526a19e25a1489bf5510a
file = 534d505501a0a1a2a3a4a5a6a7a8a9aaabb466bcf027fe45b94f3fe195f6e0b57d9c6e
```

### 12.2 Content

```json
{
  "format": "sempere-summaries/1",
  "vaultId": "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c",
  "notes": {
    "6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10": {
      "revisions": ["17596320000000000-a1b2c3d4-1.delta.age",
                    "17596952000000000-a1b2c3d4-2.delta.age"],
      "title": "Groceries",
      "tags": ["home"],
      "notebook": "Personal/Lists",
      "favorite": false,
      "deleted": false,
      "created": "2026-10-04T16:20:00.000Z",
      "modified": "2026-10-06T09:12:44.512Z",
      "pages": 2,
      "pageTexts": [{ "page": 1, "text": "milk eggs" }]
    }
  }
}
```

- `format` is `sempere-summaries/1` and `vaultId` the vault's; a file with
  another value of either is ignored.
- `notes` maps a note id (a lowercase UUID, the note's directory name) to its
  entry. A writer includes only notes whose listed revisions it read
  completely and could reconstruct (§5.3); a note with an unreadable revision,
  or with content of a newer format version it does not understand (§7.4),
  has no entry.
- `revisions`: the file names of every revision of the note the summary was
  made from (canonical names, §5), sorted, at least one.
- The rest describes the note's state (§5.4) merged from exactly those
  revisions: `title`; `tags` (the current tags, §5.4.1); `notebook`, absent
  when the note has none; `favorite`; `deleted`; `created`; `modified`, the
  greatest `wall` (§5.1) among the revisions; `pages`, the number of pages;
  `pageTexts`, for each page with searchable text, its 1-based position and
  that text: the page's recognized text (§5.5), then the text of each text
  item (§8.2.4), the `pageText` of each PDF page item (§8.2.6) and the LaTeX
  source of each math item (§8.2.8) in drawing order (§8.2.3), the non-empty
  ones joined by `\n`, in page order. Pages
  without such text are left out. Dates are as in §6.

Unknown fields are ignored. Writers emit no others under `format`
`sempere-summaries/1`; a change readers must not misread changes `format`.

### 12.3 Reading

A reader uses an entry only when the note's revision file names in its own
listing of the vault are exactly the entry's `revisions`. Revision files are
write-once and named by `(hlc, device, seq)` (§5), so the same names are the
same revisions and the same summary. For any other note (a new, compacted or
removed revision, no entry, or an entry that does not validate) it reads the
revisions as usual; entries of notes the listing does not have are ignored.
A reader may show the entries before its listing is complete, as long as it
replaces each one that turns out not to match.

The whole file is ignored when it is missing, larger than its limit (§9),
does not start with `SMPU` `0x01`, fails to authenticate, does not gunzip or
parse, or has another `format` or `vaultId`. An entry whose id, `revisions`
or any field above is malformed is ignored alone.

Trust. The file is authenticated under the vault key, so a storage server
cannot forge or alter an entry; it can withhold the file or serve an older
one, whose entries then either still match (unchanged notes) or are read
again. A malicious listed device, which can also write revisions, can write
entries that disagree with the revisions; a reader shows what the revisions
say once it opens a note, and prefers that summary from then on.

### 12.4 Writing

`sempere vault summaries` writes the file (docs/cli.md); `sempere sync
webdav` keeps the server's copy current, computed from what the server holds
after the sync. The file is never copied between the two sides of a sync:
each writer computes it from its own listing. The apps do not write it: they
write per-device files (§12.5).

### 12.5 Per-device files

A vault may also hold `summaries/<device>.sealed`, where `<device>` is a
writer's device id (§5, 8 lowercase hex digits): the same file as §12.1 and
§12.2 (same key, same associated data, same content), written only by that
device, from its own listing, when the notes it has read change. Since no two
devices ever write one file, a file-sync service never has two versions of
it to reconcile (§1.3), whatever the devices do at once. Names that are not
`<device>.sealed` with a valid device id are ignored.

A reader may read all of them, and the root file, before the notes arrive
(a device opening a vault that a file-sync service is still delivering):
for each note it uses an entry whose `revisions` are exactly the note's
listed revision file names (§12.3), else, provisionally, the entry made from
the most revisions, then with the latest `modified`, then with the greatest
last revision name, so every reader picks the same one. A provisional entry is
shown only until the note's revisions are read, which replaces it. Entries are
hints from the vault's devices (§12.3 "Trust"): never used to write.

Writers write their own file when their listing is complete, not on every
change (it is replaced whole), and leave other devices' files alone; a file
that no longer opens (a new epoch) is rewritten by its device or
ignored. A writer that no longer exists leaves a file that only goes stale.

A sync (§1.3) copies every device's file to the side that lacks it, and when
both sides hold different copies of another device's file, takes the side that
changed since its last sync (the remote's if both did). A device's own file is
only ever written by that device: a sync never replaces it with another copy.
A received file is placed only when it starts with `SMPU` `0x01` and, with the
vault unlocked, opens (§12.3); otherwise it is skipped (a hint, never
quarantined). Nothing is ever deleted.

A per-device file may carry, at the top level next to `notes`, `synced`: the time (RFC 3339) its device last
completed a two-way sync (key-hierarchy design §5.5; §15.15). Its device rewrites the file to update it, at most
once an hour, keeping its entries; readers that do not know the field ignore it. The root file has none.

## 13. Shared settings

A vault may hold, at its root, `settings.age`: settings
that the devices which opted in follow, merged per key (rationale, the list of
settings and the app's behavior: `docs/settings-sync.md`; JSON Schema:
`docs/settings.schema.json`). It is not under `notes/` and is not write-once: a
writer replaces it whole, atomically. A reader that does not implement this
section ignores it (§1).

### 13.1 File

`settings.age` is an age file encrypted to the vault identity (one stanza, §4), whose plaintext
is the body framing of §4 with the label `settings` in place of the note id:

```
Tag = HMAC-SHA256(key = tagKey,
                  message = "sempere/1" ‖ 0x00 ‖ "settings" ‖ 0x00 ‖ "settings.age" ‖ 0x00 ‖ gzipBytes)
```

(`settings` is never a note id, §6.) Recovery without the app is that of §4:
`age -d -i vault-keys.txt settings.age | tail -c +38 | gunzip | jq .` A reader verifies the tag
under the epoch's `tagKey` (§15.2); a file that does not verify is not read. Readers bound the file at 1 MiB
on disk and after gunzip (§9).

### 13.2 JSON

A JSON object (VS Code `settings.json` style):

- `"$schemaVersion"` and `"$minReaderVersion"`: integers ≥ 1 (§13.4). A missing or
  malformed one reads as 1.
- **Settings**: every other member whose name starts neither with `$` nor with
  `[`. The name is the setting's key, flat and dotted (`editor.defaultPaper`); the
  value any JSON value. The keys, their values and defaults are listed once in
  `docs/settings-sync.md` §5 with the device types that use them.
- **Type blocks**: a member named `[t]`, `t` 1 to 16 lowercase ASCII letters or digits
  starting with a letter (`[mac]`, `[ipad]`, `[iphone]`), whose value is an object of
  settings for devices of type `t` only. A `[t]` member that is not an object is kept
  as an unknown member.
- `"$meta"`: an object with, per setting at the top level, and under `[t]` per
  setting of block `t`, the setting's last write: `{"modified": m, "type": t}` with
  `m` Unix milliseconds, an integer 0 … 2^53 − 1, and `type` the kind of device that
  wrote it (absent for a writer that is not a device, such as the CLI). Unknown
  members of an entry are kept. A malformed entry is ignored (its setting has no
  entry).
- Other members starting with `$` are unknown members, kept.

A **slot** is one setting at the top level or in one block: its value, or none,
and its `$meta` entry, or none. A slot with an entry and no value is a **reset**:
the setting reads as its default (at that level). A device of type `t` resolves a
setting from the first of: its own local choice (outside the vault), the slot in
`[t]`, the slot at the top level, the setting's default. A value of the wrong type
or out of range for a setting the reader knows is skipped, with a warning, and
resolution goes on; it never makes the file unreadable.

### 13.3 Merge

Two copies merge slot by slot; for each slot the copy with the greater
`(modified, type, value)` wins: `modified` as an integer, a slot without an entry
lowest; then `type` as a string, absent lowest; then the value's canonical JSON
(sorted object keys, no whitespace), a reset lowest; then the canonical JSON of the
entry. This total order makes the merge commutative, associative and idempotent.
Slots, blocks and members a reader does not know are merged and written back
unchanged. `$schemaVersion` and `$minReaderVersion` merge to the larger value;
unknown `$` members (and `[t]` members that are not objects) to their union, the
greater canonical JSON winning when both copies hold the member with different values.

A write of a slot (a value or a reset) records `modified = max(now, m + 1)`, where
`m` is the `modified` the writer holds for that slot, so a write wins over what its
writer saw whatever the clocks. A writer merges the file as it is on disk into what
it writes. A device keeps its own merged copy and writes the merge back when the file
lacks or holds older slots than its copy (a write lost to a file-level race on the
storage is thus restored).

### 13.4 Versions

`$schemaVersion` names the version of the keys' names and meanings; this document
defines version 1. Changes are additive (new keys); a rename or a change of meaning
keeps the old key written beside the new one (equal values) for several releases,
and a reader that knows both resolves from whichever slot was written last.
Migrations from an older `$schemaVersion` run on read, on the reader's copy, copying
old keys into new ones with their `$meta` entries; they never remove a key that a
reader of at least `$minReaderVersion` reads.

`$minReaderVersion` is the oldest reader version that may read **and** write the
file; it is raised only for a breaking change. A reader older than it (its version,
1 for this document, is below the file's `$minReaderVersion`) does not apply, merge
or write the file; it may still copy it byte for byte (a sync, a backup, a
re-encryption that keeps its JSON unchanged, §15.8). A reader at least as new, saving a file of a
later `$schemaVersion`, keeps everything it does not know verbatim, and both numbers.

### 13.5 Writers

Writing `settings.age` is a write to the vault: refused for a read-only vault (§7.3)
and a `vault.json` that does not check (§2.1). A writer that replaces a file
that does not verify first checks that `vault.json` on disk is still of the epoch (`epochId`
and `root`) whose key it holds: one that stayed open while another device started a new epoch
would otherwise overwrite the current file with one under the old key. WebDAV sync (`docs/io.md`)
merges the file when both sides changed and the vault is unlocked.

## 14. Notebook records

A notebook exists while a note names it (§5.4). A notebook that no note names
(one the user created and has not filled yet, or emptied) is kept by *notebook
records*: small write-once files under `notebooks/` at the vault root, each
declaring notebooks or ending earlier records.

```
Notes.sempere/
  notebooks/
    <recordId>.notebook.age
```

`<recordId>` is a random lowercase UUID (§6), new for every file. Records are
written once under a name no other writer uses, so a file-sync service never
has two versions of one, and merging another copy of the vault is the union
of its records (§1.3). They are never modified (§1), and never deleted in this version (a record is a
few hundred bytes). A reader that does not implement this section ignores the
folder (§1) and shows only the notebooks notes name; a notebook record needs
no `features` entry (§2). Names in `notebooks/` that are not
`<recordId>.notebook.age` are ignored.

### 14.1 File

An age file encrypted to the vault identity (one stanza, §4), whose plaintext is the body
framing of §4 with the label `notebooks` in place of the note id and the
record's file name:

```
Tag = HMAC-SHA256(key = tagKey,
                  message = "sempere/1" ‖ 0x00 ‖ "notebooks" ‖ 0x00 ‖ "<recordId>.notebook.age" ‖ 0x00 ‖ gzipBytes)
```

(`notebooks` is never a note id, §6.) Binding the file name stops a record
being replayed under another id, which another record's `remove` would not
name. Recovery without the app is that of §4:
`age -d -i vault-keys.txt notebooks/F.notebook.age | tail -c +38 | gunzip | jq .`
A reader verifies the tag under the epoch's `tagKey` (§15.2).

### 14.2 JSON

```json
{
  "format": "sempere-notebooks/1",
  "created": "2026-10-15T14:00:00.000Z",
  "add": ["School/Math", "Archive"],
  "remove": ["3f0c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c"]
}
```

- `format`: `sempere-notebooks/1`. A record with another value is not read
  (reported); a later change that readers must not misread changes it.
- `created`: when the record was written (§6). Informational only.
- `add` (optional, absent means none): notebook paths (§5.4) the record
  declares. Writers store canonical paths; readers canonicalize each, and skip
  one that names no notebook.
- `remove` (optional, absent means none): the ids of records (their
  `<recordId>`, lowercase) this record ends. A record never names itself; a
  reader ignores such an entry, and ids that name no record.

Writers write a record only when `add` or `remove` is non-empty. Unknown
fields are ignored.

### 14.3 Reading

A record is *ended* when any readable record lists its id in `remove`. The
*declared notebooks* are the canonical paths that records which are not
ended `add`. This is an observed-remove set, like tags (§5.4.1): a `remove`
ends only the records its writer had seen, so a notebook declared on another
device at the same time survives (add wins), whatever the order the records
arrive in.

The notebooks a reader shows are every notebook a live note names, every
declared notebook, and every parent level of either (§5.4). Selecting a
declared notebook no note is in shows no notes.

A record that cannot be read (it does not decrypt, its tag does not verify,
it does not gunzip or decode, it breaks a limit of §9 or has another
`format`) is skipped and reported: its `add` and its `remove` both count for
nothing. A damaged record can thus only bring back a notebook it ended, never
hide one.

### 14.4 Writing

Writing a record is a write to the vault: refused for a read-only vault
(§7.3) and a `vault.json` that does not check (§2.1). Records are written whole under
their final name (atomically, docs/io.md "Atomic writes").

- **Create** a notebook `P`: when `P` is not declared already, write a record
  adding `P` (its parent levels need no record). A notebook a note names may
  be declared too: it then stays when its last note leaves.
- **Rename or move** `P` to `Q` (the `setMeta` of every note within `P`,
  §5.4): one record that ends every record (not already ended) adding a path
  within `P`, and adds each of their paths again, renamed as the notes are
  (`Q` replacing the `P` prefix; a path that renames to no notebook is
  dropped) or unchanged for paths outside `P`. Writers write it before the
  notes' deltas: an interrupted move then shows the notebook under both names,
  never under neither.
- **Delete** `P`: one record that ends every record adding a path within `P`
  and adds again their paths outside it. Deleting a notebook does not delete
  or move notes: a writer deletes only a notebook no live note is in, or moves
  or deletes the notes first (one delta per note, §5.4).

## 15. Key hierarchy

Status: **normative. KH3: this version writes and reads vaults of any epoch** (§2, §2.1, §3, the tags
of §4, §13.1 and §14.1, the blob names of §8.1.2 and the capture keys of §11.1 use it; vaults of the
earlier format, with a recipients list and a vault secret, are not read, with no migration before v1):
removals, handoffs, takeovers and recovery-kit replacements start new epochs, with the acceptance rule,
the write ledger and the set-aside store of §15.14. Since KH4 a sync carries epoch records, join requests and
the passphrase copy between targets and judges a `vault.json` of another epoch by the chain (§15.15). The
re-encryption journal (§15.8, KH6) is specified here but not written yet. This section freezes the bytes of the key
hierarchy designed in `docs/design/key-hierarchy.md`, so that the printed recovery kit and
a second implementation can rely on them. Where the design leaves an encoding open, this section decides it, and the
shared vectors pin it: `Tests/SempereTests/Fixtures/epoch-vectors.json` (key schedule, wraps, lists,
links, root, fingerprints, the recovery key's signing pair, the three signatures, join codes; made by
Swift and by `web/scripts/make-epoch-vectors.ts`), `epoch-chain-vectors.json` (a chain with a handoff
and a takeover, and its negative cases) and `epoch-precedence-vectors.json` (the precedence rule's
trees). Code: `Sources/Sempere/Epoch*.swift`, `JoinCodes.swift`;
`web/src/vault/epoch.ts`.

### 15.1 Encodings

- **`lp(x)`**: the 4-byte big-endian length of `x`, then `x`. Every message below is a literal ASCII
  prefix followed by `lp()` fields, never JSON.
- **Field values.** A value that a JSON file holds is the UTF-8 of its JSON text, exactly as written:
  hex stays lowercase hex (so `lp(sign.p256)` is the 130-digit hex), a UUID is lowercase, a number is
  decimal ASCII without leading zeros, an absent value is the empty string. A digest that the message
  computes itself (`SHA-256(wrap)`, `SHA-256(listMessage)`, a join commitment) is its 32 raw bytes.
- **Lists** in a message are `lp(count)` followed by `lp()` of each element, sorted by UTF-8 bytes;
  fingerprints in lists are their 64 hex digits.
- **Signatures** (`addSig`, `epochSig`, `authorSig`) are two: P-256 ECDSA over SHA-256 of the message,
  `r ‖ s` (64 bytes), under the uncompressed X9.63 public key (65 bytes); and ML-DSA-65 (FIPS 204, pure,
  empty context, 3309 bytes) over the message, under a 1952-byte key. Both must verify. A verifier
  accepts an ECDSA signature whatever the half of its `s`; writers normalize `s` to the lower half
  (`s ≤ n/2`), so the bytes do not depend on the library. JSON:
  `{ "p256": "…(128 hex)…", "mldsa65": "…(6618 hex)…" }`; signing keys `{ "p256": "…(130 hex)…",
  "mldsa65": "…(3904 hex)…" }`.

### 15.2 Vault epoch keys and derivations

`K_e` is 32 random bytes per epoch. With `K_e` as HKDF-SHA256 input key material (empty salt, `L =
32`), `info` as below (UTF-8):

| Key | `info` |
| --- | --- |
| identity seed | `sempere/1 vault identity seed` |
| `tagKey` (body tags §4, §13.1, §14.1, epoch records, journal) | `sempere/1 body tag` |
| `blobNameKey` (§8.1.2) | `sempere/1 blob name` |
| `listKey` | `sempere/1 list key` |
| `markersKey` (§2.1 "Version markers") | `sempere/1 markers key` |
| `epochId` (public) | `sempere/1 epoch id` |
| link seeds | `sempere/1 epoch link ed25519 seed`, `sempere/1 epoch link ml-dsa-65 seed` |
| `pendingKey` | `sempere/1 reencrypt pending key` |
| capture keys (§11.1) | `sempere/1 device capture key` ‖ 0x00 ‖ `fingerprint(r)` of §11.1 |

The **vault identity** `V_e` is the MLKEM768-X25519 identity whose 32-byte seed is the identity seed
(`AGE-SECRET-KEY-PQ-1…`); its recipient `v_e` (`age1pq1…`) is what every file of the epoch is
encrypted to, in one stanza. The link key pairs are §2.1's "Link key pairs" (Ed25519 from the seed; ML-DSA-65
`KeyGen_internal` from the seed). §10, §10.1 and §12.1 keep their `info` and take `K_e` as input.

### 15.3 vault.json

As §2 (and the design's §3), with these rules for readers (a file breaking one is malformed):

- at most 16 MiB; `epoch` ≥ 1; `parent` and `epochLink` present exactly when `epoch` > 1;
  `epochRecord` is `epochs/` followed by §15.6's name for `epoch` and `epochId`;
- exactly one entry with `role: "recovery"`, which has `sign` (the recovery key's derived signing
  keys, §15.4) and none of `id`, `kind`, `addedEpoch`, `addedBy`, `addSig`; every key `age1pq1…` and
  listed once;
- every device entry has `id`, `sign`, `kind`, `addedEpoch`, `addedBy` and `addSig`, and `id` is the
  first 8 hex digits of its fingerprint (§15.4); a wrap is at most 16 KiB; at least one device entry;
- `epochReason` is one of §15.7's reasons, `create` exactly at epoch 1; `home` (a fingerprint, the
  home device after this epoch, design §5.6) is the fingerprint of a device entry; `epochAuthor` is
  home's id except in a `handoff`; `author` is home's id or `epochAuthor`; `recoverySig` (a signature
  pair, §15.5) is present in every `takeover`, may be present in a `recovery` or `reencrypt` epoch (the
  old kit's agreement, verified when present), and in no other epoch; `parentList` (sorted fingerprints, the parent list
  as the epoch author saw it) is present exactly when `epoch` > 1.

**`epochSig` from `vault.json` alone** (review H2: a direct child of the pinned epoch is taken before
its record arrives, design §4.3). The epoch's **first list** is the recovery entry, every device
entry with `addedEpoch` below `epoch`, and the home entry (at epoch 1 the creating device; after a
takeover possibly a device it introduced); its recovery fingerprint is the recovery entry's. With
`epochReason`, `home` and `parentList`, that gives every field of §15.5's `epochSig` message. Above
epoch 1 the device must supply **the parent as it verified it** (its list, home, recovery key and the
lists of its ancestry: from the pinned epoch or the record's chain); the file's own `home` never
stands in for the parent's (round 7, M3). `epochSig` must verify under the signing keys of the entry
whose id is `epochAuthor`: at epoch 1 and in a `takeover`, that entry is the home (at epoch 1, in the
verified first list); otherwise it is the parent's home, in `parentList` and in the parent's list, and
it is the home itself except in a `handoff` (where the home is another device). A `takeover`'s
`recoverySig` must also verify over the same message under the recovery entry's `sign`, whose
recovery fingerprint is the one §15.7's takeover rule names for the parent. The first list must be
within the parent's list except a new recovery key of a `recovery` or `reencrypt` epoch; a
`takeover`'s may also hold its home and devices of its ancestry's lists. Of the two ways to make `epochSig` checkable here, this one keeps the signed parent list (from
which removals are computed) under the epoch author's own signature in every copy; dropping the
parent list from the message would leave it signed only by whoever wrote a later copy of the chain.

**Entries and additions** (review H1, design §5.6). The device checks a `vault.json` against the
epoch's list as it verified it (the first list from the chain, or from this file once `epochSig`
verified as above, plus the additions it already admitted). An entry in that list needs no new check of
its `addSig`. Every other device entry must have `addedEpoch` = `epoch`, `addedBy` = home's id and an
`addSig` valid under home's signing keys: only home approves. A `takeover`'s home entry, when the
takeover introduces it, has `addedBy: "recovery"` and an `addSig` valid under the recovery entry's
`sign`. An entry that is not admitted makes the file tampered. `authorSig` must verify under home, or
under `epochAuthor` when it is `author` (the old home writing its handoff).

**Wrap plaintext** (an age file to the entry's key, armored, one stanza):

```
# sempere vault key: vault <vaultId>, epoch <e>
# sempere-epoch-key: <64 hex digits of K_e>
AGE-SECRET-KEY-PQ-1…
```

exactly these three lines, each ending in `\n`. A reader refuses a wrap whose first line names another
vault or epoch than the `vault.json` it is in, or whose identity is not the one derived from the key.

**`listTag`** = lowercase hex of HMAC-SHA256(`listKey`, `listMessage`), with

```
listMessage = "sempere/1 list" ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(epochRecordHash)
  ‖ lp(count) ‖ per entry in list order: lp(role) ‖ lp(key) ‖ lp(id) ‖ lp(sign.p256) ‖ lp(sign.mldsa65)
  ‖ lp(kind) ‖ lp(added) ‖ lp(addedEpoch) ‖ lp(addedBy) ‖ lp(addSig.p256) ‖ lp(addSig.mldsa65)
  ‖ lp(name) ‖ lp(SHA-256(wrap))
```

**`epochLink`**: the link signatures (§2.1 "Link key pairs") of the parent epoch's key over
`"sempere/1" ‖ 0x00 ‖ "epoch link" ‖ 0x00 ‖ vaultId ‖ 0x00 ‖ e ‖ 0x00 ‖ epochId(K_e)` (`e` decimal,
`epochId` raw): the design keeps today's secret-link encoding for this one message.

**`markersTag`**: §2.1's "Version markers" message under `markersKey`.

### 15.4 Fingerprints, entries and the recovery key's signing pair

- device fingerprint = `SHA-256("sempere/1 device" ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65))`;
- recovery fingerprint = `SHA-256("sempere/1 recovery" ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65))`,
  over the recovery key's derived signing pair;
- a device's `id` is the first 8 hex digits of its fingerprint.

**The recovery key's signing pair** (design §5.6), from its 32-byte X-Wing seed (what
`AGE-SECRET-KEY-PQ-1…` encodes), HKDF-SHA256 with an empty salt and `L = 32`: the P-256 scalar is the
first `HKDF(seed, "sempere/1 recovery signing p256" ‖ c)`, `c` = 0, 1, … as one byte, with
1 ≤ scalar < n; the ML-DSA-65 seed is `HKDF(seed, "sempere/1 recovery signing mldsa65")`.

An entry's `addSig` (§15.5) is checked when the entry first appears as an addition: it verifies under
the signing keys of the epoch's home, whose id is `addedBy`; or, for the new home a `takeover`
introduces, under the recovery key's pair with `addedBy: "recovery"`. Anything else (a self-signed
entry included) is tampering.

The device that creates the vault writes its own entry with a self-signed `addSig` and its own id in
`addedBy` (the design does not cover the creator's entry). It is in epoch 1's first list, so it is
never checked as an addition; a later copy of it outside the verified list is refused like any entry
that is not an addition of the current epoch (review M3).

### 15.5 Signed messages

| Signature | Message |
| --- | --- |
| `addSig` | `"sempere/1 author entry"` ‖ lp(vaultId) ‖ lp(addedEpoch) ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65) ‖ lp(kind) ‖ lp(added) ‖ lp(addedBy) |
| `epochSig`, `recoverySig` | `"sempere/1 author epoch"` ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(parent) ‖ lp(reason) ‖ lp(recovery) ‖ lp(home) ‖ the first list ‖ the parent list as the author saw it (lists as §15.1; `parent` empty at epoch 1; `recovery` the epoch's recovery fingerprint, review M1; `home` the home's fingerprint after the epoch). `recoverySig`, in a `takeover` only, is by the recovery key's pair over the same message |
| `authorSig` | `"sempere/1 author manifest"` ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(epochRecordHash) ‖ lp(SHA-256(listMessage)) ‖ lp(format) ‖ the distinct `features` (a list, §15.1) |

### 15.6 Epoch records

`epochs/<e>-<idprefix>.epoch.age`: `<e>` decimal, `<idprefix>` the first 16 hex digits of `epochId`.
Other names in `epochs/` are unknown files. An age file to `v_e` (one stanza); its plaintext is §4's
framing with the label `epochs` in place of the note id and the file name (`<e>-<idprefix>.epoch.age`,
without `epochs/`), tagged under `tagKey` of `K_e`; so `tail -c +38 | gunzip` gives the JSON:

```json
{ "format": "sempere-epoch/1", "vaultId": "…", "root": "…(64 hex)…", "epoch": 4, "epochId": "…",
  "parent": { "epoch": 3, "epochId": "…", "key": "…(64 hex: K_3)…", "identity": "AGE-SECRET-KEY-PQ-1…",
              "sealed": { "<path>": "<sha256 hex>", … }, "recordHash": "…(64 hex: SHA-256 of record 3)…" },
  "chain": [ <chain entry>, … from epoch 1 up to and including this epoch ],
  "created": "…", "by": "<author id>", "reason": "remove", "removed": ["<fingerprint>", …] }
```

- `parent` is absent at epoch 1. A `reencrypt` record's `parent` has neither `key` nor `identity`;
  otherwise both or neither, and `identity` is the one derived from `key`, whose `epochId` is
  `parent.epochId`.
- `chain` has `epoch` entries, the last being this epoch, and `parent.epochId` is the previous one.
- `parent.recordHash` is the SHA-256 of the parent epoch's own record file. The current record is bound
  by `vault.json`'s `epochRecordHash` (under `authorSig`), and every earlier one by the `recordHash` of the
  record above it: a reader walking down to earlier keys and sealed sets takes a record only when it
  hashes to that link, and stops otherwise (its keys and everything below are then unknown, files under
  them pending). Without the link, a device removed later, which holds that record's key, could rewrite
  its sealed set to cover what it wrote after its removal (review of KH3, M1). Every record above epoch 1
  carries it; a reader stops at a record without one.
- `reason` equals the last chain entry's, and `by` is its author's id (review M6). `removed` is
  informational (§15.7 computes removals). Readers use the chain entry, never these fields.
- Readers bound the file and its gunzipped JSON at 64 MiB.

A **chain entry**:

```json
{ "epoch": 2, "epochId": "…", "parent": "…", "linkPublicKeys": { "ed25519": "…", "mldsa65": "…" },
  "link": { "ed25519": "…", "mldsa65": "…" }, "reason": "remove",
  "list": ["<fingerprint>", …], "parentList": ["<fingerprint>", …],
  "author": { "key": "age1pq1…", "p256": "…", "mldsa65": "…" }, "epochSig": { "p256": "…", "mldsa65": "…" },
  "recovery": "<fingerprint>", "home": "<fingerprint>",
  "recoveryAuthor": { "key": "age1pq1…", "p256": "…", "mldsa65": "…" }, "recoverySig": { … },
  "additions": [ { "key": "age1pq1…", "sign": { "p256": "…", "mldsa65": "…" }, "kind": "iphone",
                   "added": "…", "addedEpoch": 2, "addedBy": "<id>", "addSig": { … } }, … ] }
```

`parent` and `link` are absent at epoch 1; `recovery` is the epoch's recovery fingerprint and `home`
the home after the epoch, both signed by `epochSig`; `recoveryAuthor` (the recovery key and its
signing keys) and `recoverySig` are present in every `takeover` and optionally (the old key's) in a
`recovery` or `reencrypt` epoch. `additions` is written only when not empty (absent reads as empty) and holds the additions
made during that epoch that the next epoch's author saw. Lists hold at
most 4096 fingerprints; a chain at most 100,000 entries.

### 15.7 Checking a chain

From epoch 1 (`EpochChain.verify`):

1. Entry `i` has `epoch` = `i`; `reason` is one of `create`, `remove`, `recovery`, `reencrypt`,
   `handoff`, `takeover`; `create` only at epoch 1; `recoveryAuthor` and `recoverySig` only in a
   `takeover`.
2. Epoch 1: no `parent`, `link` or parent list; `root` = SHA-256 of its link keys (design §4.2); its
   author's fingerprint is in its first list and is its `home`.
3. Epoch `e` > 1: `parent` is epoch `e−1`'s id; `link` verifies (§15.3) under `e−1`'s link keys.
   - A `takeover`: the author is its `home`; `recoveryAuthor`'s recovery fingerprint is the one the
     **takeover rule** names and `recoverySig` verifies under its keys. The takeover rule
     (`TakeoverRule.recoveryKey`): for an unpinned verifier, `e−1`'s `recovery`; for a pinned one, the
     `recovery` of its pinned frontier (the last epoch it pinned), and only when `e−1`'s `recovery` is
     that key; otherwise no key is valid and the takeover is refused. A kit replaced on the pinned chain
     never signs again, and a kit introduced below the frontier signs only once the epoch that
     introduced it is pinned (the verifier then reports `kitNotPinned`, not tampering, and verifies
     again after pinning the epoch before the takeover). The verifier checks `recoverySig` under
     `e−1`'s `recovery` first: a takeover whose signature fails there is `badTakeover` whatever the
     pin, and only a valid one refused by the rule alone is `kitNotPinned`. A takeover's parent is the
     taking-over device's pinned frontier; the first list holds the home and otherwise only fingerprints of the
     lists of epochs 1 to `e−1` (a device a stolen home removed may be re-admitted), and no earlier
     recovery key; `recovery` is `e−1`'s.
   - Any other epoch: the author is `e−1`'s `home`; `home` is unchanged, except in a `handoff`, which
     names another device (not the recovery key); the first list is within `e−1`'s **list**. A
     `recovery` or `reencrypt` epoch **replaces** the recovery key (its optional `recoveryAuthor` and
     `recoverySig` are the old key's, whose recovery fingerprint must be `e−1`'s `recovery`): its `recovery` is the one
     fingerprint not in `e−1`'s list, and `e−1`'s `recovery` is not in its first list; any other epoch
     keeps `e−1`'s `recovery` (review M1).
4. `home` and `recovery` are in the first list, and `recovery` is no known device; `epochSig` verifies
   under the author's signing keys.
5. Epoch `e`'s **list** is its first list plus its admitted additions: at most 256 (more is
   tampering), each with `addedEpoch` = `e`, `addedBy` = the id of `e`'s home and an `addSig` valid
   under the home's keys (§15.4). An addition that fails is not admitted; an epoch whose first list
   then holds it fails rule 3.
6. The signing keys of devices come from the chain's authors and additions, and from the `keys` of
   the `vault.json` at hand; every one is checked against its fingerprint.

**Removals are computed**: the keys epoch `x` removed are the fingerprints in both `x`'s signed parent
list and the parent's list as verified, minus `x`'s first list. The chain's `recovery` fields are
the vault's recovery keys: never a device.

### 15.8 The re-encryption journal

`reencrypt-journal.age`: an age file to `v_m`, §4's framing with the label `reencrypt` and the file
name `reencrypt-journal.age`, tagged under `tagKey` of `K_m`:

```json
{ "format": "sempere-reencrypt/1", "vaultId": "…", "epoch": 7, "epochId": "…",
  "keys": [ { "epoch": 6, "epochId": "…", "key": "…(64 hex)…", "identity": "AGE-SECRET-KEY-PQ-1…" }, … ],
  "created": "…", "by": "<id>" }
```

Each key's `epochId` and `identity` are the ones derived from it, and its `epoch` is below the
journal's. `vault.json` binds it with `reencryptPending` = lowercase hex of HMAC-SHA256(`pendingKey` of
the current epoch, `"sempere/1 reencrypt pending"` ‖ lp(vaultId) ‖ lp(SHA-256(journal file bytes))),
re-computed by every later epoch while the journal exists. Its accepting and finishing rules (an
unbound or finished journal gives no key) are specified with phase KH6; this version writes no
journal. Bounded at 64 MiB.

### 15.9 Precedence

Over the tree of every epoch whose signatures verified (`EpochPrecedence.resolve`; design §5.6). No
questions:

1. An epoch is **valid** under its parent when it is signed by the parent's home and keeps `home`
   (a `handoff`: names another), or is a `takeover` whose `recoverySig` verifies under the recovery
   key the takeover rule names for this device's pinned chain (§15.7: the pinned frontier's own kit,
   or for an unpinned device the parent's), whose author is its home, whose list holds only that home and
   devices of its ancestry's lists and no recovery key its ancestry retired, and whose `recovery` is the parent's. `home` is in the epoch's list
   and is not its recovery key. A `takeover` that meets every other condition, with `recoverySig`
   valid under its parent's `recovery`, but that the takeover rule refuses only because that kit was
   introduced below the pinned frontier (`kitNotPinned`, §15.7) is **deferred** with its subtree: not
   followed, not tampering, and taken by the next run once the replacement is pinned (or, at a home
   conflict before it, once the user picks). Every other epoch is ignored with its subtree.
2. From epoch 1, the device walks down the valid tree. If a valid `takeover` lies below the current
   epoch with no takeover between, it goes to the one with the smallest `epochId` (bytes compared
   lexicographically) and goes on from there; a takeover below a takeover is reached the same way.
3. Otherwise it follows the one valid child. With more than one (home's key signed twice: a **home
   conflict**), it follows the child on its pinned chain, or the child the user picked, or stops there;
   never the smaller id. It reports the conflict with its children either way.
4. The pinned chain's epochs that the result leaves out (home epochs after a takeover's parent) are
   **dropped**; files under their keys are set aside (§15.6 sealed sets do not apply to them).
5. A malformed epoch 1 gives an empty chain with every epoch ignored: tampering, never an empty vault.

**The write ledger** (KH3) prunes an entry only when its sealing record is on the pinned chain with a
kit replacement (an epoch whose `recovery` differs from its parent's) pinned at or above it
(`LedgerRule.sealIsFinal`; plain home epochs above it can still be dropped by a takeover). It finds a replacement by `recovery`
changing between two pinned epochs, which relies on §15.7 rule 3: a `recovery` or `reencrypt` epoch must change the kit
and no other epoch may. Repair's bulk Keep takes the set-aside
files of dropped epochs that the ledger holds (`LedgerRule.keepable`).

`EpochPrecedenceTests` checks the rule against an independent oracle on random trees (2000 seeds in
`swift test`; `SEMPERE_PRECEDENCE_PROPERTY_SEEDS` for more), and six test-only mutations (and the
round-7 seal rule) must each fail it; `Fixtures/epoch-precedence-vectors.json` holds the shared cases.

### 15.10 Trust record v3

`sempere-trust/3`, outside the vault: `vaultId`, `root`, `chain` (from epoch 1: `epoch`, `epochId`,
`parent`, `linkPublicKeys`, `list` of the first list's fingerprints, and, since KH3, `recovery`, `home` and
`reason`, so the precedence rule can weigh the pinned chain against a takeover that drops part of it; a
record without them does not read, and fails closed), `list` (the current list: `role`,
`key`, `sign`, `name`), `markers`, `reencryptFinished` (written only when true) and `home` (the
fingerprint of the pinned epoch's home). Readers refuse a chain that does not start at epoch 1 or
whose `parent`s do not follow, and a missing or malformed `home`.

**Sightings** (KH4, design §4.3, §5.5): next to the record, `<vaultId>.seen.json` (`sempere-sightings/1`:
`vaultId`, and `sightings`, at most 8, each `source` (where it was seen), `seen` (RFC 3339) and `manifest`
(the `vault.json` bytes, base64)) keeps the `vault.json` versions of other epochs this device met on a sync
target and did not take: one it cannot verify yet (unverified-pending), or one it verified that does not list
it (unlisted). A sighting that cannot be read fails closed (the device would upload again). Every open judges
them again (§15.15): one now verified and followed is taken by the next two-way run, one dropped or no longer
of interest is forgotten. A device also keeps, in its write ledger, the key of every epoch it pinned (not only
those it wrote under), so that files under an epoch a takeover later dropped read as set aside, not unreadable.

### 15.11 The passphrase copy

`keys/recovery-<recovery fingerprint hex>.key.age`: one scrypt stanza (writers: work factor 20), whose
plaintext is exactly:

```
# created: <RFC 3339>
# sempere-vault: <vaultId, lowercase>
# sempere-root: <64 hex digits>
# public key: <age1pq1…>
AGE-SECRET-KEY-PQ-1…
```

with the public key the identity's. Stock `age -i` reads it as an identity file. Bounded at 16 KiB.

### 15.12 Joining

- Join request `joins/<id>.join.json` (bounded at 16 KiB): `{ "format": "sempere-join/1", "vaultId",
  "key", "sign": { "p256", "mldsa65" }, "name", "kind", "created" }`; `key` is `age1pq1…`; `kind` is
  a lowercase word of 1 to 32 letters `a`–`z`.
- Commitment `c = SHA-256("sempere/1 join" ‖ lp(vaultId) ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65) ‖
  lp(kind))`; the name is not covered.
- **Six words**: the first 66 bits of a digest as six 11-bit indices, most significant bit first, into
  the BIP-39 English list (2048 words, SHA-256 of the list file
  `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`). Typed words compare ignoring case
  and surrounding spaces.
- The joining device's QR payload: the vault id's 16 bytes (RFC 4122 order), then `c`: 48 bytes.
- Reverse code: six words of `SHA-256("sempere/1 join reply" ‖ lp(vaultId) ‖ lp(c) ‖ lp(root) ‖
  lp(frontier))` (`c` raw; `root` and `frontier`, the approver's current `epochId`, hex); its QR is
  `sempere-reply:<vaultId>:<root hex>:<frontier hex>`. The approver is home (design §5.6). The joining
  device pins the chain up to the frontier the words confirm.
- The flow (design §6.2): the joining device writes its request (create-only; `<id>` is its id,
  §15.4) and shows the six words of `c`; home finds the request whose commitment the typed words
  give, appends the entry with a wrap of `K_e` and its `addSig` (§2), deletes the request and shows the
  reverse code; the joining device types it. Until then it reads but does not write (§2.1
  `rootUnconfirmed`). Home refuses a request of another vault, a key that is not `age1pq1…`, a bad
  `kind`, a key already listed, or an `id` a listed device has (the joining device generates another
  key).
- A join with the recovery key is a `takeover` (§15.7 rule 3, design §6.3, §15.14).
- Over a sync (§15.15) a request travels in `joins/`; once home approved it (and deleted it), the joining
  device, which the local `vault.json` does not list yet, takes a later `vault.json` of the same vault and root
  that lists its key and whose wrap opens to a key of its epoch, and then confirms it with the reply words.

### 15.13 The recovery kit

The kit prints the recovery key (as `sempere keys paper`), the root as 16 groups of 4 hex digits each
followed by its line checksum (the first 4 hex digits of SHA-256 of the group as typed), the QR code
`sempere-root:<vaultId>:<64 hex>`, and this script (`KitRecovery.script`, byte for byte; tested in CI
against stock `age` 1.3+ and `jq` on a vault with two removals, an orphan record, a dropped epoch and an
unfinished re-encryption, `EpochChainTests.testFrozenRecoveryScriptOpensEveryEpoch`):

```sh
# 0. Only if you use the passphrase copy instead of the printed key:
#    age -d keys/recovery-<fingerprint>.key.age > recovery.txt
# 1. The current vault key, from the recovery entry.
jq -r '.keys[] | select(.role == "recovery") | .wrap' vault.json \
  | age -d -i recovery.txt > vault-keys.txt
# 2. Earlier vault keys, newest record first. Run twice: the second pass picks up
#    records that open only with a key the journal (2b) added.
for pass in 1 2; do
  for f in $(ls epochs | sort -t- -k1,1nr); do
    age -d -i vault-keys.txt "epochs/$f" | tail -c +38 | gunzip \
      | jq -r '.parent.identity // empty' > prev.txt
    cat prev.txt >> vault-keys.txt
  done
  # 2b. Only while a re-encryption is unfinished (the file exists only then):
  if [ -f reencrypt-journal.age ]; then
    age -d -i vault-keys.txt reencrypt-journal.age | tail -c +38 | gunzip \
      | jq -r '.keys[].identity' > prev.txt
    cat prev.txt >> vault-keys.txt
  fi
done
# 3. Any note, as before.
age -d -i vault-keys.txt notes/ID/NAME.delta.age | tail -c +38 | gunzip | jq .
```

Step 0 needs a terminal (`age -d` reads passphrases from one only), so CI runs steps 1 to 3 with the
passphrase copy's plaintext as `recovery.txt`.

### 15.14 Epochs above 1: changes, acceptance, the write ledger, set aside

(Design §5.2 to §5.8, §6.3, §6.5; `Sources/Sempere/VaultEpochChange.swift`, `VaultEpochs.swift`,
`VaultCatchUp.swift`, `WriteLedger.swift`, `SetAside.swift`.)

**A device change** writes, under the vault's write lock and in this order, each durable before the next:

1. the parent epoch's **sealed set**: the path (relative to the vault folder) and SHA-256 of the exact
   bytes of every file of the working copy that the acceptance rule (below) takes under the parent's key
   or an earlier one: revisions, blobs, notebook records, `settings.age`, and inbox files of the parent
   epoch whose tag verifies under a listed device's capture key. Files set aside or pending are left out.
   A removal first catches up the remover's own files (below), so they are sealed too;
2. the new epoch's record (§15.6) under its **final name**, with the parent's key, identity and sealed
   set, and the chain: the parent's chain, whose last entry gains the parent epoch's additions approved by
   its home, plus the new entry signed as §15.7 requires. A crash after this step leaves an **orphan**
   record that no `vault.json` names: readers ignore it and nothing deletes it;
3. `vault.json` at the new epoch, with a wrap of the new key to every key of its list, in one atomic
   write. From then on the writer encrypts and tags every new file under the new key.

| Change | By | List | `home` | Signed by |
| --- | --- | --- | --- | --- |
| `remove` | home | the parent's, minus the removed devices (never home itself) | unchanged | home |
| `handoff` | home | the parent's | another listed device | the old home, which also writes this `vault.json` |
| `recovery` | home | the parent's minus the devices removed in the device review, the new recovery key instead of the old | unchanged | home; optionally also the old kit (`recoverySig`, evidence only) |
| `takeover` | the holder of the recovery key on the device that becomes home | the user's pick among the devices of the parent's ancestry, plus the new home | the taking-over device | the new home and the recovery key (`recoverySig`) |

A takeover's parent is the taking-over device's pinned frontier (a device that never joined: the
current epoch, checked against the kit's root); its recovery key must be the frontier's kit (§15.7's
takeover rule). A kept device keeps its entry when the parent's list has it; a device a later epoch
removed is re-admitted with its entry rebuilt from the approval the chain carries (its claim and
`addSig`); one whose approval the chain does not carry (an epoch's author) is approved again by the new
home in the takeover's own epoch. A new home the parent's ancestry did not list joins with `addedBy:
"recovery"` and an `addSig` by the recovery key's pair (a kit join). A kit replacement's new passphrase
copy is written before `vault.json`, and superseded copies (whose fingerprint no key of `vault.json` has)
are deleted after it.

**The acceptance rule** (design §5.3). A reader holds the current key and, through the records (each
gives its parent's key and sealed set; read newest first, only as far as needed), the keys of the
earlier epochs of its chain; its write ledger also holds the keys of epochs it wrote under that are off
the chain (dropped by a takeover). A vault file:

1. that decrypts under the current vault identity and verifies under the current key is **accepted**;
2. that decrypts and verifies under an earlier epoch `j` of the chain is accepted when the record whose
   parent is `j` seals its path with exactly its SHA-256;
3. that no held key decrypts while a record of the chain could not be read is **pending**: neither
   accepted nor set aside, and blob collection of its note waits;
4. that decrypts and verifies under a held key otherwise (not sealed, other bytes, or a key off the
   chain) is **set aside**: never placed (a note reads without it, `RevisionReadError.setAside`), never
   deleted, and it blocks blob collection of its note (rule 1 of §8.1.6);
5. anything else is unreadable, as before.

A file's tag (or a blob's name) is checked under the key it decrypted with before rule 2's seal.

**The write ledger** (design §5.4): device-local, never in the vault, per vault. One entry per file the
device writes (`path`, `sha256`, `epoch`, `epochId`, `time`), appended durably **before** the file is
placed; it also keeps the key of every epoch the device wrote under, and the epoch it last caught up to.
An entry lives until the record whose parent is its epoch seals its path with its digest and that seal
is final (§15.9: a kit replacement pinned at or above the sealer), or until its file is re-encrypted
under a later epoch (the new file gets an entry), or until it is superseded or stale. Per path, the
**live** entry is the newest whose digest is the file's bytes now: older entries of the path are
superseded and go; newer ones are intents not placed (a crash between the entry and the file, or a write
still in flight in another process) and go after an hour, as do entries whose file is gone (deleted by
compaction or adoption). Catch-up acts on live entries only, so a crash after a re-encrypted copy's entry
and before the copy is placed never drops the entry that still names the file (review M2). The writer
prunes this way every 512 appends, so the ledger follows the vault's live files, and the CLI warns above
256 MiB (review S5). An append of an entry of another epoch than the one caught up to clears that mark,
so the next write catches it up (a locked capture with an older profile, review M3). The
reference CLI keeps it in `$XDG_STATE_HOME/sempere/ledger/<key>/<vaultId>/` (`<key>`: the first 16 hex digits of the device key's §11.1 fingerprint, so two device keys on one machine never share one): `key.age` (32 random bytes,
age-encrypted to the device key), `log` (records of a 4-byte big-endian length and a ChaCha20-Poly1305
box of one JSON object, authenticated with `"sempere/1 write ledger <vaultId>"`; a record cut off at
the end is an append that never returned and is ignored, any other damage fails closed; each record
carries a sequence number) and `state` (one such box, with the last sequence number appended: a log
that ends before it was cut and fails closed). A ledger that cannot be read fails closed: nothing is caught up or set aside on its
account.

**Catch-up** (design §5.4). The first write after a device verifies an epoch above the one it last
caught up to (or `sempere vault catch-up`) first takes each ledger entry of an earlier epoch: sealed on
the chain, it is kept (or pruned when final); otherwise its file is re-encrypted under the current key
(revisions, notebook records and `settings.age` keep their name and get a new file key and tag; a blob
is written under its new name and the old name stays), the copy is decrypted and its body compared,
the old bytes are set aside, the new entry is recorded, and only then the copy replaces the file. An
inbox file (§11) is re-sealed the same way: its plaintext's tag is checked under the device's own
capture key of the epoch it was written under, re-tagged under the device's capture key of the current
epoch (the JSON line and payload unchanged), and the result encrypted to the current `v_e`. A capturing
device records each inbox file in the ledger before placing it, under the epoch of the profile that
sealed it (a profile records `epoch` and `epochId`; a capture queued outside the vault keeps its own, never
the profile current when it is moved in, review M4; the CLI's `inbox capture` records when the device key
is stored without a passphrase, the app always). Making a profile records its epoch's key in the ledger. Every other file the acceptance rule sets aside (inbox files included)
is then copied into the set-aside store. The app keeps its ledger and set-aside store in its App Group
container, the ledger sealed with a key in a this-device-only Keychain item of class
`AfterFirstUnlockThisDeviceOnly`; a release build has no other place for it and fails closed (debug builds
without the Keychain entitlement keep it in a 0600 file), and it never makes a new key while a ledger
exists (review S1).

**The set-aside store** (design §5.8): device-local, outside the vault
(`$XDG_STATE_HOME/sempere/setaside/<vaultId>/<vault path>/<sha256>.age`, with a `<sha256>.json` holding
`path`, `reason` (`not-sealed`, `bytes-differ`, `dropped`), `epoch`, `epochId` and `setAside`), at most
16 copies per path. A copy is durable before anything replaces or removes the original, and a copy that
cannot be kept stops that replacement. Nothing leaves it but by the user: export (as it is), keep
(re-encrypted under the current key; refused when the path holds an accepted file with another body,
which is never replaced), clear. Earlier keys come only from a chain that verified: a `vault.json` that
does not check is still read, but files under earlier keys are then not taken through its record. A file set
aside in the working copy (it was accepted when it arrived, before the change) stays there, unread and never
uploaded, until an accepted copy of the same path replaces it (§15.15); a received file that would be set aside
is never placed.

**Unlisted devices** (design §5.5). A device whose key the current `vault.json` does not list, whose
trust record pins the parent epoch, and which verifies the change from that record alone (the link
under the pinned link keys, `epochSig` by the pinned home, or a takeover's signatures by its new home and
the pinned kit) knows it was removed: it writes nothing (`VaultError.removedFromVault`, CLI exit 8). A
change it cannot verify is not taken as its removal.

**Revision names** keep the writing machine's own id (its device state, §5), as before the key
hierarchy; ids decide nothing. Its `summaries/<device>.sealed` (§12.5) and sync state use its id in the
vault (the first 8 hex digits of its fingerprint, §15.4). The join-time id check (§15.12) therefore
covers summaries files, not revision names.

### 15.15 Device changes over sync

(Design §4.3, §5.2–§5.5, §6.2, §8.2; KH4. Code: `Sources/SempereSync/EpochSync.swift`,
`EpochChangePull.swift`; `Sources/Sempere/VaultIncomingEpoch.swift`.) A sync (§1.3) of a vault above
`sempere/1`'s single epoch carries what a device change needs, and judges it by the chain, never by which side
changed since the last run:

- **`epochs/`** is synced first in every run, before `vault.json`: write-once, the union of both sides, never
  deleted. Every device pushes the records it holds to every target it syncs, so a withheld or lost record
  comes back (a device the newest list does not hold uploads nothing). A received record is checked for its
  shape only (its name, at most 64 MiB, one `mlkem768x25519` stanza): it counts once a `vault.json` names it
  with its hash. A `vault.json` is never uploaded to a target that does not hold its record (record first,
  then `vault.json`, also when an upload of the record fails).
- **`vault.json` of another epoch** (another `epochId`) is judged against this device's own (design §4.3,
  §5.6), from local files only:
  - a later epoch whose chain (its record, here by now) verifies from the root and the trust record, and which
    the precedence rule keeps over this device's pinned and own chains (a removal, a handoff, a kit replacement,
    a takeover, also one whose number is lower than this device's): **taken**. The vault is reopened under it,
    pinned, and this device's own files are caught up (§15.14), before any note is judged or uploaded;
  - a direct child of the pinned epoch whose record has not arrived, linked under the pinned epoch's link keys
    and signed by the pinned home (a takeover: by its new home, and `recoverySig` by the pinned kit), passing
    every check of §2.1 against the pinned list: **taken, record pending**. It is followed (writes are under
    its key) but not pinned, files under older keys are pending, catch-up and device changes wait; when the
    record arrives, the next run pins it and catches up;
  - a later epoch this device cannot verify yet: **unverified-pending**. It keeps its own `vault.json`, keeps
    writing locally, and the run uploads nothing new (J5b): only `epochs/` is synced, both ways, and
    `vault.json` is judged. It is remembered as a sighting (§15.10), so runs with every target hold back too,
    until it is verified;
  - a later epoch this device verified (from the pinned chain: a direct child, or a takeover under any pinned
    epoch) whose kept chain does not list it: **unlisted** (design §5.5). It never pins it and keeps its own
    `vault.json`; it writes nothing (`VaultError.removedFromVault`, CLI exit 8), uploads nothing, keeps pulling
    `epochs/` and `vault.json`, and takes a later takeover that lists it again;
  - this device's chain is the later one (an older version of its epoch, an ancestor epoch, a branch the
    precedence rule drops) or the target's does not check (tampered, forged by a device that is not home): its
    own replaces the target's, under the version read (`If-Match`);
  - a home conflict, or versions that are not one writer's: both kept, never merged, reported.
  A run without the key (a locked vault's upload-only run) compares only epoch numbers: a target holding a later
  or another epoch makes it upload nothing new.
- **Received files** under an earlier key are judged by the acceptance rule (§15.14) before they are placed: one
  that is set aside is kept in the set-aside store and never placed (not quarantined); one whose key's record
  has not arrived is **pending**: not placed, not quarantined, fetched again once a record or `vault.json`
  arrives.
- **An accepted copy replaces an unaccepted one** (design §5.4 step 4), for revisions and notebook records:
  when both sides hold a path with other bytes, and this device set its copy aside, or rewrote it since both
  sides last held the same bytes (a catch-up), or holds set-aside copies of the path (a bridge carrying a
  replacement from one target to another), or both sides came to hold it on their own (neither copied it to
  the other), the target's copy is read. An accepted copy (current preferred, else sealed) replaces an
  unaccepted one (not sealed, other bytes, under a dropped epoch's key, or opened by no key this device holds
  while no record it waits for is missing: a dropped epoch it never held), on the
  target under its strong version tag (a target without one keeps its copy, reported) or here; the unaccepted
  copy is set aside on this device first, and a copy that cannot be kept stops the replacement. An accepted
  copy is never replaced. A file this device set aside is never uploaded.
- **`joins/`**: the union, and a request one side deleted since both held it (home approved it, or it expired)
  is deleted on the other. A received request must parse, name this vault and be named after its own key.
  Home deletes requests older than 7 days and those of keys already listed.
- **`keys/`**: the union of passphrase copies (one `scrypt` stanza, at most their bound), except a copy whose
  fingerprint (in its name) matches no key of the local or the target's `vault.json`: superseded (§15.11). A
  device whose own verified epoch is at least the target's deletes it there and here, and never uploads it
  again.
- **`synced`**: at the end of a complete two-way run (no error, every note listed) a device records the time in
  its own `summaries/<device>.sealed` (§12.5), at most once an hour; home reads it to warn that a device it
  removes last synced long ago.

The remover's **best-effort pull** (design §5.2 step 2) is a pull-only pass with a throwaway sync state (a union
that deletes nothing and records nothing) on every target the device can reach, at most 10 seconds each,
before a removal, handoff, kit replacement or takeover; an unreachable target is reported, never waited for.
