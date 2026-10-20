# Key hierarchy: vault keys, device keys and one recovery key (design)

Status: **design, 2026-10-20, revised after three rounds of independent review (§16).** It follows the owner's
decisions of 2026-10-20 (below). Each open question was settled by its recommendation, which the
owner pre-approved ("Decided (recommended, owner pre-approved 2026-10-20)", §15). It replaces the
key-change part of `docs/design/device-first-sync.md` (§6 and the P4a, P4 and P10 rows of §10; see
§13 here). No code changes with this document. The normative text goes into `docs/format.md` in
phase KH1 (§12).

Owner's decisions (2026-10-20):

1. **Every key change is immediate.** There is no late-file window and there are no routine or
   compromised modes. Files under an old key from other devices that arrive after a change are set
   aside, never deleted.
2. **A key hierarchy.** Each file has its own file key, wrapped to a vault key. The vault key is
   wrapped once per listed key. Adding a device wraps the vault key to it and rewraps no file.
   Removing a device creates a new vault key for every file written afterward, and old files stay as
   they are. The vault records, authenticated under the new key, the set of files that existed at the
   moment of the change.
3. **Per-device keys only**, plus exactly one recovery key (the printed kit). A device's private keys
   never leave it. Keys are never copied between devices, and vault keys are never synced through
   iCloud Keychain.
4. **"Re-encrypt everything"** is a separate, explicit and rarer operation: a new vault key and a new
   recovery key, then every existing file re-encrypted.
5. **Removed devices** detect their removal, stop syncing, keep their data readable and offer to
   export what they did not sync. Removing a device warns when its last sync is stale.
6. **No backward compatibility** before v1. The format may change freely, and the owner re-imports.

## 0. Summary

- **The vault key is an age identity.** Each *epoch* of the vault has a 32-byte secret `K_e`. The
  seed of an age MLKEM768-X25519 identity, the **vault identity**, is derived from it, and so is
  every other vault key. Every vault file is an ordinary age file with exactly **one**
  `mlkem768x25519` stanza, addressed to the vault identity, under a fresh file key. A file's header
  is therefore one stanza whatever the number of devices: about 1.6 KB, against 4.7 KB for three
  devices and a paper key today (§9).
- **`vault.json` wraps `K_e` once per listed key**: one entry per device and one for the recovery
  key. Adding a device appends a wrap, rewraps nothing, and keeps the epoch.
- **Removing a key starts a new epoch.** The removing device writes a new `K_{e+1}` and a write-once
  **epoch record**, encrypted to the new vault identity. The record holds `K_e` (so that old files
  stay readable to current keys) and the **sealed set**: the path and SHA-256 of every file under
  `K_e` that the remover held after pulling what it could reach. From that moment every write on any
  device that has seen the change uses `K_{e+1}`.
- **The acceptance rule.** A file that opens under the current key is accepted. A file that opens
  only under an older key `K_j` is accepted if and only if its exact bytes are in the sealed set of
  the record that closed `j`. Anything else under an old key is **set aside**: kept, never deleted,
  never placed. Device ids and file names decide nothing.
- **Catch-up by provenance.** Each device keeps a device-local **write ledger**: the path and
  SHA-256 of every file it wrote, recorded before the file is placed and kept until a record seals it.
  A still-listed device that was offline during a change re-encrypts under the current key exactly
  the files of its ledger that the change did not seal.
- **Authenticated authors.** Each device also has its own signing pair (P-256 and ML-DSA-65, both in
  the Secure Enclave on Apple devices). It signs every epoch it creates, every `vault.json` it
  writes, and every entry it adds, over length-prefixed byte strings, never JSON (§4.1). An entry
  that signed itself is a kit join, whatever it claims. An epoch never introduces a device.
- **Forks are never merged.** At each branch the subtrees are compared, not the two children:
  a side whose author the other side removed anywhere loses; mutual removal is always put to the
  user, in the parent's names, with a signed answer; a stale side loses to
  one that went on; otherwise the smaller `epochId`. Only removals of a losing side are re-applied on
  top, with a fresh key. A removed device, or a coalition of them, can therefore never get a key
  admitted, nor get its files sealed, through a fork (§5.6).
- **Joining is verified both ways.** The kit and the passphrase copy carry the vault's **root
  fingerprint**, and every chain is checked from it. An approval join exchanges typed codes or QR
  commitments in both directions (§6).
- **One recovery key**, printed as today's kit. The optional passphrase copy wraps the recovery key
  (scrypt, work factor 20, at least about 70 bits, superseded copies deleted). Stock-`age` recovery
  still works, with one extra `age -d` per epoch (§8).
- **Re-encrypt everything** (§7) starts a new epoch with a new recovery key, then rewrites every
  file under the current key, verifying each replacement before the old copy goes. It reuses P4a's
  journal, claims, coordinator, rewrap-replace rules and fault suites.
- **PR #57** (P4a) is mostly superseded (§13).

## 1. Terms

| Term | Meaning |
| --- | --- |
| epoch `e` | a period with one vault key. Epoch 1 starts when the vault is created; each removal of a listed key, recovery-kit replacement or re-encryption starts the next |
| `K_e` | the epoch's 32 random bytes, the HKDF input of every key of the epoch (§2.2) |
| vault identity `V_e` | the age MLKEM768-X25519 identity whose seed is `HKDF(K_e, "sempere/1 vault identity seed")` (`AGE-SECRET-KEY-PQ-1…`), and its recipient `v_e` (`age1pq1…`) |
| device key | the MLKEM768-X25519 key pair a device generated. Its private half never leaves the device |
| device signing pair | the P-256 and ML-DSA-65 key pairs a device generated, for authorship (§4.1) |
| recovery key `R` | the one MLKEM768-X25519 identity printed in the recovery kit. It is never stored on a device |
| root fingerprint | `SHA-256` of the vault id and epoch 1's link public keys; constant for the vault's life, printed on every kit (§4.2) |
| wrap | `K_e` and `V_e` encrypted to one listed key (an age file), in `vault.json` |
| epoch record | `epochs/<e>-<idprefix>.epoch.age`: the parent key, the sealed set, and the public chain of every epoch since epoch 1 (§5.2.1) |
| fork | two epochs with the same parent epoch (§5.6) |
| kept chain | the path from epoch 1 that fork resolution keeps, over every epoch a device has seen (§5.6) |
| first list | the list an epoch was created with, signed in `epochSig` (§4.1); removals are computed from it |
| sealed set | the paths and SHA-256 digests of the files under the parent key that the change kept |
| write ledger | device-local: every file this device wrote (path, SHA-256, epoch) |
| set aside | kept in device-local storage outside the vault (P4a's quarantine), listed in the app, never deleted without the user |

## 2. Vault identity and derived keys

### 2.1 Why the vault key wraps an age identity

The owner asked for a symmetric vault key that either wraps or derives each file key, staying close
to age. age has exactly one symmetric recipient, scrypt, and the spec (c2sp.org/age, "scrypt
recipient stanza") requires it to be the **only** stanza of a file. Its passphrase is also read
interactively. A vault key used as an scrypt "passphrase" would work in stock `age`, but only by
typing 77 characters per file. A custom symmetric stanza type (`-> sempere-vk …`) would break stock
recovery altogether.

The native MLKEM768-X25519 identity is a 32-byte symmetric seed that age expands to the key pair.
So the vault key `K_e` determines a vault identity:

- **Each file key is wrapped to the vault identity.** The file key is a fresh 16-byte age file key,
  sealed in one `mlkem768x25519` stanza to `v_e` (HPKE, format.md §3.1). It is not derived from the
  vault key: derivation would take the file key out of the age header and break `age -d`.
- **Stock `age` reads every file** with the vault identity (`age -d -i vault-keys.txt FILE.age`),
  and the vault identity is one `age -d` away from the recovery key (§8).
- **Writers that hold only `v_e` can encrypt.** Quick capture already seals without the secret
  (format.md §11). Its profile now holds `v_e` instead of the recipient list.
- **Cost.** One X-Wing encapsulation per write and one decapsulation per read, a fraction of a
  millisecond each, against N encapsulations per write today.
- **Post-quantum.** Every public-key step is X-Wing, as today. Everything else is symmetric
  (ChaCha20-Poly1305, HMAC and HKDF over SHA-256), which Grover's algorithm only halves.

The identity's seed is `HKDF(K_e, "sempere/1 vault identity seed")`, not `K_e` itself, so `K_e`
feeds only HKDF and the seed feeds only X-Wing's SHAKE256 expansion. Every party that needs the
identity gets it next to `K_e` (in a wrap or a record), and readers check that it equals the
derivation.

### 2.2 Derivations

With `K_e` as HKDF-SHA256 input key material (RFC 5869, empty salt, `L = 32` unless stated). These
replace every use of `vaultSecret` in format.md:

| Key | `info` | Replaces |
| --- | --- | --- |
| identity seed | `sempere/1 vault identity seed` | (new) the vault identity's seed |
| `tagKey` | `sempere/1 body tag` | `vaultSecret` as the HMAC key of §4, §13.1, §14.1 and the epoch record |
| `blobNameKey` | `sempere/1 blob name` | `vaultSecret` in blob names, §8.1.2 |
| `listKey` | `sempere/1 list key` | `recipientsKey`, §2.1 |
| `markersKey` | `sempere/1 markers key` | unchanged, §2.1 "Version markers" |
| `epochId` | `sempere/1 epoch id` | `secretId`, §2.1 |
| `linkEdSeed`, `linkMLSeed` | `sempere/1 epoch link ed25519 seed`, `… ml-dsa-65 seed` | the secret-link seeds, §2.1 |
| `pendingKey` | `sempere/1 reencrypt pending key` | `rewrapPending`'s key, §3.3.1, now only for re-encryption (§7) |
| capture keys | `sempere/1 device capture key` ‖ 0x00 ‖ fingerprint | §11.1, unchanged except the input |
| caches, published summaries, settings | as §10, §10.1, §12.1 | unchanged except the input |

Body framing (§4), blob framing (§8.1.3) and every file layout stay as they are. Only the key that
the tag or name uses changes.

## 3. vault.json

```json
{
  "format": "sempere/1",
  "vaultId": "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c",
  "created": "2026-10-20T16:20:00Z",
  "root": "…(64 hex digits)…",
  "epoch": 3,
  "epochId": "…(64 hex digits)…",
  "parent": "…(64 hex digits: the parent epoch's epochId; absent at epoch 1)…",
  "epochRecord": "epochs/3-5b0e6f1a2c3d4e5f.epoch.age",
  "epochRecordHash": "…(64 hex digits)…",
  "keys": [
    { "role": "device", "key": "age1pq1…(1959 characters)…", "id": "a1b2c3d4",
      "sign": { "p256": "…(130 hex)…", "mldsa65": "…(3904 hex)…" },
      "kind": "ipad", "added": "2026-10-04T16:20:00Z", "addedEpoch": 1, "addedBy": "e5f6a7b8",
      "addSig": { "p256": "…(128 hex)…", "mldsa65": "…(6618 hex)…" },
      "name": "Alex's iPad",
      "wrap": "-----BEGIN AGE ENCRYPTED FILE-----\n…\n-----END AGE ENCRYPTED FILE-----\n" },
    { "role": "recovery", "key": "age1pq1…", "name": "Recovery kit", "added": "2026-10-04T16:20:00Z",
      "wrap": "-----BEGIN AGE ENCRYPTED FILE-----\n…" }
  ],
  "listTag": "…(64 hex digits)…",
  "epochLink": { "ed25519": "…(128 hex)…", "mldsa65": "…(6618 hex)…" },
  "epochAuthor": "a1b2c3d4",
  "epochReason": "remove",
  "parentList": ["…(64 hex digits: the parent list as the author saw it, sorted; absent at epoch 1)…"],
  "epochSig": { "p256": "…", "mldsa65": "…" },
  "markersTag": "…(64 hex digits)…",
  "author": "a1b2c3d4",
  "authorSig": { "p256": "…(128 hex)…", "mldsa65": "…(6618 hex)…" }
}
```

- `root`: the root fingerprint (§4.2). It never changes.
- `epoch`, `epochId`, `parent`: the epoch's number, its id (`HKDF(K_e, "sempere/1 epoch id")`, public
  by design: it is in every later chain) and its parent's id. `epochRecord` and `epochRecordHash` name
  the epoch's record and its SHA-256 (§5.2). Epoch 1 has a record too, with no parent and an empty
  sealed set, so every epoch looks the same.
- `keys`: exactly one entry with `role: "recovery"`, and any number of `role: "device"`. Every key is
  MLKEM768-X25519 (`age1pq1`), as format.md §2 requires today. §6.1 leaves room for a later hardware
  type.
- **Fingerprints.** A device's fingerprint is
  `SHA-256("sempere/1 device" ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65))`, binding its decryption
  key and its signing keys; the recovery key's is `SHA-256("sempere/1 recovery" ‖ lp(key))`. `lp(x)`
  is the 4-byte big-endian length of `x` followed by `x`, for every message in this document.
  (format.md §11.1's `fingerprint(r)` stays what capture keys use.)
- `sign` (devices only): the device's signing public keys (§4.1), uncompressed P-256 (65 bytes) and
  ML-DSA-65 (1952 bytes), lowercase hex. They never change for an entry: a device whose signing keys
  are lost leaves and joins again (§6.1).
- `id`: the first 8 hex digits of the device fingerprint. It is the `<device>` of revision names (§5)
  and of `summaries/<device>.sealed` (§12.5). **Ids are for file names and the interface only**: no
  security decision reads one. A join is refused if the id equals that of a fingerprint in the current
  list or in any `list` of the epoch record's `chain` (§5.2), which keeps every list since epoch 1,
  re-encryption included; the joining device then generates another key. Eight hex digits keep file
  names as they are, and within one vault's few dozen keys a collision is about one in 10^7.
- `kind` (`ipad`, `iphone`, `mac`, `cli`, or another lowercase word), `added`, `addedEpoch` and
  `addedBy` are fixed when the entry is added and covered by `addSig` (§4.1): **`addedBy` is the
  device whose signature `addSig` is**, or `recovery` when the entry signed itself. An entry whose
  `addSig` is its own **is a kit join, whatever the field says**: it must say `recovery`, and is
  tampered otherwise (§6.3).
- `name` (at most 40 characters, cleaned as `label` in §2) is the one field any listed device may
  change (a rename, §5.1). Names are plaintext, so storage can read them, as today (docs/security.md
  "What others can see"). Unlike today they are covered by `listTag` and `authorSig`, so storage cannot
  rename a device to mislead the user.
- `wrap`: an armored age file to `key` (one stanza) whose plaintext is an age identity file:

  ```
  # sempere vault key: vault 0d1c6a1e-…, epoch 3
  # sempere-epoch-key: …(64 hex digits of K_e)…
  AGE-SECRET-KEY-PQ-1…
  ```

  `age -i` reads this file as it is (lines starting with `#` are comments), so
  `age -d -i recovery.txt wrap.age > vault-keys.txt` gives a usable identity file. Sempere reads
  `K_e` from the second line and refuses the wrap unless the identity equals `V_e` derived from it.
- `epochAuthor`, `epochSig`: the device that created this epoch, and its signature over the epoch
  message (§4.1). They are the same in every `vault.json` of the epoch, as are `epochReason`,
  `parentList` and (in a `resolve` epoch) `rejected`, which carry the rest of what `epochSig` signs.
  The epoch's **first list** is the recovery entry and every device entry with `addedEpoch` below
  `epoch` (at epoch 1: the recovery entry and the creating device), so `epochSig` verifies from
  `vault.json` alone (§4.3 step 2; KH1 code review H2: of the two ways to get there, this one keeps the
  signed parent list, from which removals are computed, under the author's own signature).
- `author`, `authorSig`: the device that wrote this version of `vault.json` (the epoch's author, an
  approver, a renamer or a merger), and its signature over the manifest message (§4.1).
- Removed: `recipients`, `vaultSecret`, `recipientsTag`, `secretLink`, `rewrapPending`.
  `rewrap-journal.json` is gone too, except for the re-encryption journal of §7.
- `features` and `markersTag` stay as in format.md §2 and §2.1.

## 4. Authenticity

| Today (format.md) | Role | Replaced by |
| --- | --- | --- |
| `vaultSecret` (§2) | keys every tag and name, and is wrapped to all recipients | `K_e`, wrapped per key. Derived keys as in §2.2 |
| `recipientsTag` (§2.1) | the list under the secret | `listTag` = HMAC-SHA256(`listKey`, `listMessage`), with `listMessage` = `"sempere/1 list"` ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(epochRecordHash) ‖ lp(count) ‖ per entry in list order: lp(role) ‖ lp(key) ‖ lp(id) ‖ lp(sign.p256) ‖ lp(sign.mldsa65) ‖ lp(kind) ‖ lp(added) ‖ lp(addedEpoch) ‖ lp(addedBy) ‖ lp(addSig.p256) ‖ lp(addSig.mldsa65) ‖ lp(name) ‖ lp(SHA-256(wrap)). Absent values are empty strings; numbers are decimal ASCII. It covers names, signing keys and each wrap's digest, so a swapped wrap is detected by every device |
| `secretLink` (§2.1) | links a new secret to the one a device verified | `epochLink`: Ed25519 and ML-DSA-65 signatures by the keys derived from the parent's key, over `"sempere/1" ‖ 0 ‖ "epoch link" ‖ 0 ‖ vaultId ‖ 0 ‖ e ‖ 0 ‖ epochId(K_e)`. The derivation, encoding and both-must-verify rule are today's (so are the test vectors, re-labeled) |
| (none) | who made a change | `epochSig`, `authorSig`, `addSig` (§4.1) |
| (none) | which vault this is, before any key | `root` (§4.2), printed on the kit |
| `markersTag` | `format` and `features` | unchanged, under `markersKey` of `K_e` |
| body tag (§4), blob name (§8.1.2) | file authenticity | the same constructions, keyed by `tagKey` and `blobNameKey` of the epoch the file was written in |
| `rewrapPending` + `rewrapFinished` (§3.3.1) | bind and retire a rewrap journal | the same mechanism, renamed `reencryptPending`, used only by §7 |
| trust record `sempere-trust/2` | the last verified secret, list and markers | `sempere-trust/3`: vault id, `root`, the kept chain this device has verified (each epoch's number, id, parent, link keys, first list), the current list, markers, `reencryptFinished`, and the user's answers to fork questions (§5.6) |

### 4.1 Device signing pairs and authorship

Each device generates, next to its device key, a **P-256 ECDSA** pair and an **ML-DSA-65** pair. On
Apple devices both live in the Secure Enclave (`SecureEnclave.P256.Signing` and
`SecureEnclave.MLDSA65`, CryptoKit, iOS and macOS 26; verified against Apple's documentation on
2026-10-20), with the access class `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so that a
locked background run can still sign a union merge or a re-application (§5.1, §5.6). The CLI keeps
them in software next to its device key (§6.1). Two schemes, as for links, so a signature stays
unforgeable while either holds.

**What is signed.** Signatures are never over JSON. Each is over a byte string built from fields with
`lp()` (§3), so two implementations agree without a JSON canonicalization:

| Signature | Message (`"sempere/1 author "` ‖ kind ‖ …) | Made by |
| --- | --- | --- |
| `addSig` (per entry) | `entry` ‖ lp(vaultId) ‖ lp(addedEpoch) ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65) ‖ lp(kind) ‖ lp(added) ‖ lp(addedBy) | the approver, which must be listed in the `vault.json` of `addedEpoch` that first lists the entry; or the entry itself (a kit join, `addedBy: "recovery"`) |
| `epochSig` | `epoch` ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(parent) ‖ lp(reason) ‖ lp(recovery fingerprint) ‖ lp(rejected author, empty except in a `resolve` epoch) ‖ lp(n) ‖ the epoch's **first list**: n fingerprints, sorted ‖ lp(m) ‖ the parent list as the author saw it: m fingerprints, sorted | the epoch's author, which must be in the parent epoch's list; at epoch 1, the creating device, which must be in epoch 1's first list (there is no parent; the root anchors it) |
| `authorSig` | `manifest` ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(epochRecordHash) ‖ lp(SHA-256(listMessage)) ‖ lp(format) ‖ lp(k) ‖ the k distinct features, sorted | a device listed in this `vault.json` |

ECDSA signs the message with SHA-256 and stores `r ‖ s` (64 bytes); ML-DSA-65 signs the message
itself (pure, empty context), as links do. Both must verify. `authorSig` covers the record's hash, so
the epoch record needs no signature of its own. The non-ASCII, slash and emoji cases that defeat
JSON canonicalization only appear inside `lp()` fields here, as raw UTF-8; KH1's vectors include such
a name in Swift and TypeScript.

**Rules a reader checks**:

- an epoch's first list contains only fingerprints of its **parent's list**, plus at most one new
  recovery entry (a kit replacement or re-encryption): **no new device is ever introduced by an
  epoch**. New devices enter only by a same-epoch addition with an `addSig`. The parent's list is
  its first list **plus every addition made during the parent epoch**: an entry with
  `addedEpoch` = the parent whose `addSig` verifies under a device of the parent's first list, or of
  an addition already admitted this way (an approver added earlier in the same epoch). The additions
  of each epoch are carried in its chain entry (§5.2.1), because an entry whose device was later
  removed is no longer in any `keys[]`. A device that missed an addition therefore still verifies a
  removal whose first list carries the added device;
- **bound** (format.md §9 style): at most 256 additions per epoch, admitted in one pass in the order
  they are listed, each against the devices admitted before it; an addition whose approver is not yet
  admitted is rejected, so verification is linear and cannot recurse. The fuzz target covers it;
- an entry's **`addedBy` chain** is its approver, that approver's approver, and so on, through the
  `addSig`s in `keys[]` and the chain's `additions`, until it reaches an entry of epoch 1's first list
  or a kit join. It is finite, because every approver was admitted before the entry it approved. §5.6
  uses it to tell whether a device was added by a fork's author;
- an entry's `addSig` verifies as the table says. An entry that first appears in a `vault.json`
  without a valid `addSig` is tampered, and so is one whose `addedBy` names someone other than its
  signer;
- `epochSig` and `authorSig` verify under the `sign` keys of a device listed where the table says.

Authorship decides which fork is kept (§5.6) and who a device was added by (§6.4). Everything else
(what a file is, who may read) is decided by keys and sealed sets, as before. The private signing keys
never leave their device, so no key holder can sign as another device.

**Removals are computed, never read.** "The keys epoch `x` removed" is the fingerprints in both the
parent list as `x`'s author signed it **and** the parent list as this device verified it, minus `x`'s
first list. The record's informational `removed` field is not used. An author that omits a key from
its signed parent list only fails to remove it in the rules, and an author cannot claim to remove a
key it still lists.

### 4.2 The root fingerprint

`root = SHA-256("sempere/1" ‖ 0 ‖ "root" ‖ 0 ‖ vaultId ‖ 0 ‖ ed25519 ‖ mldsa65)`, over epoch 1's link
public keys (32 + 1952 bytes). It never changes, because the link chain always starts at epoch 1
(§5.2 `chain`). The kit prints it as 16 groups of 4 hex digits, each with the kit's line checksum
(DESIGN.md "Recovery"), and in the kit's second QR code (`sempere-root:<vaultId>:<hex>`). The
passphrase copy carries it too (§8.2). A chain is **rooted** when its epoch 1 entry hashes to the root
the device trusts, and every later link and `epochSig` verifies.

### 4.3 Checking `vault.json` (replaces format.md §2.1 "Checking")

A device unwraps its own entry. If the result does not parse, or the identity is not the one derived
from `K_e`, its wrap was tampered with. `root` must equal the trust record's root in every case, or
the file is tampered. Then:

1. **Same epoch and `epochId` as the trust record**, and `listTag`, `authorSig` and every new entry's
   `addSig` verify: **verified**. A new entry is admitted only against the list the device already
   verified (and entries admitted before it), never against other new entries' say-so (KH1 code
   review H1). A list that only gained entries under the same epoch is an addition;
   one whose entries changed only by `name` is a rename. A list that lost entries, or whose entry
   changed any other field, under the same epoch is **tampered**: a removal always changes the epoch
   (§5).
2. **A higher epoch.**
   - If the record is local: the device opens it with the unwrapped key and reads its `chain` (§5.2).
     It finds its pinned epoch there, then checks each later link under the previous entry's link
     keys, and each entry's `epochSig` under the `sign` keys of its parent list, up to `vault.json`'s
     own. The first link after the pinned epoch can only be made by a holder of the pinned key, so a
     `vault.json` built around an attacker's key fails here.
   - If the record has not arrived: the change is taken only when the epoch's `parent` is the pinned
     epoch, `epochLink` verifies **directly** under the pinned epoch's link keys, and `epochSig`
     verifies from `vault.json` (§3) by a device of the pinned list, over a first list within it. Otherwise
     the new epoch is **unverified-pending**: the device keeps reading, keeps writing locally under its
     pinned key, uploads nothing new, and pulls again. Writes made meanwhile are in its ledger and are
     caught up (§5.4) once the epoch verifies. The status line says "Waiting for a device-change record
     from <target>"; every device that holds a record pushes it to every target it has, and adding
     another target, or Export, is the way out if one target withholds it for good.
   - Then fork resolution (§5.6) runs over every epoch the device has seen.
3. **A lower epoch**, or the same epoch with another `epochId`: when it chains from an epoch the device
   holds, it joins the epoch tree, and §5.6 decides. Otherwise it is a rollback: tampering. Nothing is
   written, and the device keeps its own `vault.json`.
4. **No trust record** (a joining device): the chain must be rooted at the root the user supplied (kit
   QR or typed groups, the passphrase copy, or the reverse code of an approval, §6.2). A join without a
   root is refused in the app. The CLI's read-only `--recovery-key` mode takes the root from
   `--root` or the passphrase copy, otherwise warns and reads (it writes nothing).
5. **No entry for this device** on the kept chain: the device is **unlisted** (§5.5).

## 5. Changes to the list

### 5.1 Adding, renaming

**Adding.** An approving device appends an entry with a wrap of the current `K_e`, its own `addSig`
(`addedBy` = its id), `listTag` and `authorSig`. A joining device with the recovery key adds itself
the same way with a self-signed `addSig` and `addedBy: "recovery"` (§6.3). No file is touched and the
epoch does not change.

**Renaming.** Any listed device may change any entry's `name` (and only that), with a new `listTag`
and its own `authorSig`.

**Concurrent changes under one epoch merge.** Two verified `vault.json` with the same epoch and
`epochId` are merged by any listed device: the union of their entries, sorted by `key`. When the same
key appears on both sides with a different `name` (a rename on both sides), the entry with the smaller
SHA-256 of its `listMessage` encoding wins, and the user renames again if needed. Any other field of
an entry is fixed by `addSig`, so it cannot differ between two valid copies. An addition never drops a
key, so there is no "owed rotation". A merger signs the merged file as its `author`; `addedBy` stays
the original approver, checked by `addSig`, never by who wrote the file.

**Additions overtaken by a removal.** Each approving device records its approvals in its ledger until
it sees them on the kept chain's current list. If a new epoch does not carry an addition (A removes X
at `e+1` while B adds N at `e`), **B re-applies it** on top, with a new `addSig`. Only the approver
re-applies, and only while it is itself listed. Nothing else ever re-adds a key: not a merge, not a
fork rule (§5.6).

What a key holder that is about to be removed can do (review L5): until the removal reaches a device,
the soon-to-be-removed device X still holds `K_e` and may add entries under `e`. Each carries X's
`addSig` and shows "added by <X's name>". The next epoch's first list is a subset of its parent list
as its author saw it, so an entry the remover never saw is not carried, and X, no longer listed,
cannot re-apply it.

### 5.2 Removing a key (immediate)

On the removing device A, in this order, each step durable before the next. A holds the vault's write
lock (`VaultFileLock`) from step 3 to step 5, so no write lands between sealing and the new
`vault.json`.

1. **Preconditions**: the working copy is complete (format.md §1.2 rule 3) and `vault.json`
   verifies. Nothing about targets or re-encryption: a removal never waits for a network or for other
   devices, and it may happen while a re-encryption is running (§7.2).
2. **Best-effort pull**: A runs a download-only pass on every target it can reach within a short
   bound (10 s per target, cancellable by the user), and places what verifies under the current rules.
   An unreachable target is reported in the sheet ("iCloud Drive was not reachable: changes there
   since <time> from other devices will be caught up by them"). Then A catches up its own ledger
   (§5.4), so A itself has nothing unsealed from older epochs.
   - The pull also brings in whatever the device being removed uploaded up to that moment, and
     those files are sealed. That is consistent with "immediate": the removal takes effect at the seal,
     and the device held `K_e` until then.
   - The 10 s bound is only a quality knob **because ledger entries live until they are sealed**
     (§5.4): a writer A could not reach catches up its own files later. Shortening the ledger's lifetime
     would make this pull a correctness requirement. Do not change one without the other.
3. **New key and sealed set**: `K_{e+1}` = 32 random bytes. For every file in A's working copy that is
   accepted under `K_e` (or under an older key by §5.3): its path and the SHA-256 of its exact bytes.
   That covers revisions, blobs, notebook records, `inbox/` files and `settings.age`. Files set aside or
   pending are not included.
4. **Epoch record**, written **under its final name** `epochs/<e+1>-<first 16 hex of epochId>.epoch.age`,
   durably, before `vault.json` names it (§5.2.1 has the format). A crash after this step leaves an
   **orphan** record that no `vault.json` names. Orphans are ignored, never deleted and never fatal: the
   key inside is wrapped to nobody, so the record reveals nothing. Storage learns that a change was
   attempted (§9.3).
5. **`vault.json`** with `epoch = e+1`, its id, `parent`, the record's name and hash, a wrap of
   `K_{e+1}` to every remaining key, `listTag`, `epochLink`, `epochSig`, `markersTag` and `authorSig`,
   in one atomic write. **From this write on, A encrypts and tags every new file under `K_{e+1}`.**
6. **Caches and profiles**: per-epoch caches start empty (format.md §10). Capture profiles are
   refreshed at the next unlock (§5.7).

There is no journal, no rewrite pass, no late-file window and no clock. Propagation is ordinary sync
of two new files. Any device that holds a record a target lacks uploads it (write-once union), to
**every** target it syncs with, so a withheld record comes back.

#### 5.2.1 The epoch record

`epochs/<e>-<idprefix>.epoch.age`: `<e>` is the decimal epoch, `<idprefix>` the first 16 lowercase hex
digits of its `epochId`. Other names in `epochs/` are unknown files. The file is an age file to
`v_e`, whose plaintext is the body framing of format.md §4 with the label `epochs` in place of the note
id and the file name, tagged under `tagKey` of `K_e` (so `tail -c +38 | gunzip` reads it, as for a
revision). The JSON:

```json
{ "format": "sempere-epoch/1", "vaultId": "…", "root": "…", "epoch": 4, "epochId": "…",
  "parent": { "epoch": 3, "epochId": "…", "key": "…(64 hex: K_3)…",
              "identity": "AGE-SECRET-KEY-PQ-1…",
              "sealed": { "notes/<id>/<name>.delta.age": "<sha256 hex>", … } },
  "chain": [ { "epoch": 1, "epochId": "…", "linkPublicKeys": { "ed25519": "…", "mldsa65": "…" },
               "reason": "create", "list": ["<fingerprint>", …], "parentList": [],
               "author": { "key": "age1pq1…", "p256": "…", "mldsa65": "…" }, "epochSig": { … },
               "recovery": "<fingerprint>" },
             { "epoch": 2, "epochId": "…", "parent": "…", "linkPublicKeys": { … }, "link": { … },
               "reason": "remove", "list": [ … ], "parentList": [ … ], "author": { … }, "epochSig": { … },
               "recovery": "<fingerprint>", "rejected": "<fingerprint, resolve epochs only>",
               "additions": [ { "key": "age1pq1…", "sign": { … }, "kind": "iphone",
                                "added": "…", "addedEpoch": 2, "addedBy": "e5f6a7b8",
                                "addSig": { … } }, … ] },
             … up to and including this epoch … ],
  "created": "2026-10-20T16:20:00Z", "by": "a1b2c3d4", "reason": "remove",
  "removed": ["<fingerprint>", …] }
```

- `parent` carries the parent's key, identity and sealed set. A re-encryption epoch carries no `key`
  or `identity` there (§7). Epoch 1 has no `parent`.
- `chain` holds only public values, one entry per epoch on this epoch's ancestry from epoch 1, each
  with the first list and the signed parent list of §4.1, the author's public keys (whose
  fingerprint must be in the parent list), and `additions`: every same-epoch addition the next
  epoch's author saw during that epoch, with the fields its `addSig` covers (§4.1, "parent's list").
  About 11 KB per epoch plus about 9 KB per addition. It lets a device that missed several
  epochs check every link and signature (§4.3), and lets fork resolution compute removals (§5.6),
  even after re-encryption has deleted the older records.
- `reason`: `create`, `remove`, `recovery` (replacing the kit), `reencrypt`, `reapply` or `resolve`
  (§5.6). It and `removed` are shown in the device history and are informational: removals are
  computed (§4.1). The record's `reason` and `by` must equal its last chain entry's (KH1 code review
  M6), and readers use the chain entry.
- Each chain entry names the epoch's **recovery** fingerprint and, in a `resolve` epoch, the
  **rejected** author, both signed by `epochSig`, so every copy of the chain carries them (KH1 code
  review M1, M2). A `recovery` or `reencrypt` epoch replaces the recovery fingerprint (the new one is
  its only new key, the old one is gone); every other epoch keeps it. The recovery keys of fork
  resolution are the chain's `recovery` fields. When the removed device authored a recovery epoch, the
  removal sheet suggests replacing the kit.
- Readers bound the file (64 MiB on disk and after gunzip) and treat it as untrusted input (format.md
  §9); KH1 adds a fuzz target.

### 5.3 The acceptance rule

For a vault file `F` at path `p` (revision, blob, notebook record, inbox file, `settings.age`):

1. `F` decrypts under the current vault identity and its tag (or, for a blob, its name) verifies
   under the current epoch's keys: **accepted**.
2. Otherwise, `F` decrypts under the identity of an earlier epoch `j` on the device's kept chain
   (§5.6), verifies under `j`'s keys, and the record whose `parent` is `j` lists `p` with
   `SHA-256(F)`: **accepted**.
3. Otherwise, if that record has not arrived yet: **pending** (neither accepted nor set aside).
4. Otherwise, if it verifies under some epoch the device holds (on the kept chain or a discarded
   fork): **set aside** ("from before a device change"), with the reason. This includes a sealed path
   whose bytes differ.
5. Otherwise: unreadable. It is quarantined (format.md §9.1) and reported, as today.

The rule reads no device id, file name, `wall`, `hlc` or clock. A reader tries the current key first,
and older keys only on failure: at most one X-Wing decapsulation per epoch per file.

The sealed set is complete for A after its pull, not for the vault. Files that A could not reach
(written offline by C, still listed) are handled by their writers (§5.4). Files written under `K_e` by
the removed device X that A had not received are set aside everywhere, which is the point of the
removal.

### 5.4 Catch-up and the write ledger

**The ledger.** Device-local, outside the vault, per vault. One entry per file this device writes:
path, SHA-256, epoch, time, and the approvals of §5.1. It is stored with the working copy in the App
Group container, sealed with a key in a Keychain item of class
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (the class capture profiles already use), so the
widget extension can append while the device is locked. In the CLI it is sealed to the device key.

- **Intent first.** A writer appends the entry (path, SHA-256 of the final bytes, epoch) durably
  **before** it places the file in the working copy. A crash after the entry and before the file
  leaves an entry with no file, which is dropped at the next open; the reverse order could leave a
  file that no ledger knows.
- **Lifetime.** An entry lives until the record whose `parent` is its epoch seals its path with its
  digest, or until its re-encryption under a later epoch is recorded (the new entry then lives by the
  same rule). Uploads and acceptance on targets prune nothing. An entry whose file this device has
  itself deleted by compaction or thinning (format.md §5.3, §5.8.4) is dropped with the file.
- **Failure.** An unreadable ledger fails closed: catch-up stops and is reported, and nothing is
  re-encrypted or set aside on its account. Re-encryption (§7) writes its outputs as ledger entries
  too.
- **Restores.** A restore of a device backup onto the **same** device brings back its
  this-device-only Keychain items: it is the same device, with the same keys, id and ledger (at the
  backup's state; anything written after the backup is gone with that state, as for any restore). A
  restore onto **another** device has no keys: it joins as a new device with a fresh ledger, and the
  restored working copy is treated as a join source: what verifies is accepted by the usual rules, and
  local files that no target holds and no rule accepts are offered for export.

**Catch-up.** When a device C first verifies a `vault.json` of an epoch above its pinned one, it:

1. stops writing under the old key. Its next write is under the new one (J5a, §11.2);
2. for every ledger entry of an epoch `j` below the current one whose path is not sealed with that
   digest by the record whose `parent` is `j` (on the kept chain), **re-encrypts the file under the
   current key**: the same body (`gzip(JSON)`, blob content, inbox payload), a new file key and a tag
   under the new key. Revisions, notebook records and inbox files keep their names. A blob is
   renamed under the new `blobNameKey`, and its old name stays until GC;
3. replaces its local file with the re-encrypted copy only after the copy decrypts and its body
   equals the old one, then records the new entry;
4. uploads normally. On a target, an **accepted** copy replaces an **unaccepted** copy of the same
   path (an old-key copy that is not sealed, or a copy under a losing fork's key), after the
   receiver has set the unaccepted one aside. A current copy is preferred when the device has one;
   otherwise an accepted sealed copy is used, so a target left holding only a losing re-encryption's
   copies (§7.2) is repaired by any device that still has the old accepted bytes. This is the one
   replacement rule of the engine outside §7, and it never replaces an accepted file.

Files written under an old key by another listed device D that C holds are set aside on C until D
catches up; D's current copy then arrives and is accepted, and C's set-aside copy is marked
superseded (§5.8).

### 5.5 Unlisted and removed devices

A device X is **unlisted** when the kept chain (§5.6, over everything it has seen) ends in an epoch
that does not list it. Then X:

1. **never pins** an epoch that does not list it, and keeps its own `vault.json`;
2. stops uploading, but **keeps pulling** `vault.json` (every version and conflict copy the target
   offers) and `epochs/`, read-only, at the idle pace;
3. re-runs fork resolution on everything it pulls. If the kept chain changes to one that lists X (a
   real change discards a forged one), X takes it and resumes.

The screen says what X can know, and that it can change: **"This device is not on the newest device
list of <vault>. The change was made by <name> on <date>. If that is a mistake (for example a change
made on another device at the same time), this device will rejoin by itself when the vault shows
it."** The parent list supplies the names (§5.6). It offers:

- the count of its own changes that no other device has: ledger entries not sealed and not on any
  target as accepted files;
- **Export changes** (the notes those entries touch, as a copy of the vault with only them, or as
  PDFs, through the existing export paths), **Keep as a separate vault** (a copy re-created with new
  keys, as an import), and **Remove from this device**.

An unlisted device refuses every write to the vault (`VaultError.removedFromVault`, CLI exit code 8).
"Removed" is never final in the format: it is the state of a device whose kept chain omits it, and a
forged change seen first is undone when the real one arrives (§5.6, scenario "forged removal seen
first", §11.1).

**Removing a device warns when its last sync is stale.** Each device's published summaries file
(`summaries/<id>.sealed`, format.md §12.5) gains a `synced` timestamp (the end of its last complete
two-way run), authenticated under the current epoch. The sheet shows "Alex's iPhone last synced 12
days ago. Changes it made since then will not reach this vault. It will be told it was removed, and
can export them." It also says what the key change cannot do: **"It can still reach your storage.
Change the password of <WebDAV target>, or sign it out of iCloud, if you no longer control it."** When
the device approved other devices, the sheet lists them (from `addSig`) with **"Also remove the
devices <name> added"**, checked when the user marks the device as lost or stolen.

### 5.6 Forks: resolved over subtrees, never merged

Two devices that each make a new epoch from the same parent while they cannot see each other create a
**fork**. So does a removed device that makes an epoch from any epoch whose key it held, at any depth.
Records do not collide (their names carry the id), and `vault.json` versions conflict (format.md §1.3).
**Forks are never merged and no key is derived from two epochs.**

**The epoch tree.** Each device keeps the tree of every epoch it has verified (§4.3: link under the
parent key, `epochSig` by a device of the parent list, first list within the parent list plus at most
one recovery entry), from `vault.json` versions, conflict copies and records. For each epoch it knows
the author, the first list, and the removals computed as in §4.1. The **kept chain** is found from the
root down: at each epoch with more than one child, the rules below pick one child, comparing the
**subtrees** below the children (each child with all its descendants), never the children alone.

**Context and counted epochs (KH1 code review C1).** A removed device that appended one epoch under
an old honest stale fork, removing the real side's author, made that fork win by rule 1 on every
device. So:

- an epoch authored by a device that this device's **pinned chain** removed never enters the tree
  (unless it is on the pinned chain);
- two sides are compared over their **counted** epochs: each child counts; a descendant counts when
  its parent counts and no counted epoch of the other side removed its author (to a fixed point;
  undecided epochs do not count). "Removed by some epoch in S", "has descendants" and the
  re-application set below are over counted epochs only, so a removed device's epochs supply neither
  removals nor descendants to a side;
- walking down the kept chain, a child whose author the kept prefix removed, or whose author is in the
  re-application set, is dropped with its subtree, also when it is the only child.

**Pre-pass.** At a branch with several children, first discard every child whose author is removed by
some sibling's subtree, unless that child's own subtree removes that sibling's author in turn (a true
mutual pair, rule 2); only siblings that no other sibling discards this way discard others, and the
pass repeats until nothing changes (in the three-children case, X's fork removing B must not discard
B's honest side). A child discarded here has lost by rule 1. Then the remaining children are
compared in pairs, in `epochId` order, the winner of each pair going on. Rule outcomes are not
transitive, so the pre-pass makes rule 1 decisive whatever the pairing order: a removed device cannot
force a question (rule 2) against an honest sibling when another sibling already removes it. A side
counts as lost by rule 3 or 4, and is re-applied, whichever sibling it lost to.

For a branch point P with sides **S** and **T** (subtrees rooted at children `s` and `t`, authored by
`author(s)` and `author(t)`):

1. **A removed author loses.** If `author(s)` is removed by some epoch in **T** and `author(t)` is not
   removed by any epoch in **S**, then **T** wins (and the reverse). A removed device that forks from
   any older epoch, with any `epochId`, loses at the branch, because the real side's subtree contains
   its removal.
2. **Both authors removed by the other side** (mutual removal): **the user decides; nothing decides
   without asking.** (The second draft's "a third device decides" rule is dropped: a device that X
   added, carried into later epochs, could have decided it for X; round-3 M2.)
   - **Who is asked**: every device listed on at least one side (in P's list or added on either side
     after the branch) that is not one of the two authors. The CLI cannot ask: `sempere devices
     resolve --keep <epochId>` answers, `sempere sync --json` reports `forkQuestion` with both
     changes, and until then a CLI bridge keeps pulling but uploads nothing new.
   - **The question** shows both changes with names from **P's list** (never from either fork's own
     list): **"Two device changes were made at the same time. Which of these did you make?"**, each
     line reading "<author's name in P> removed <names in P> on <date>".
   - **The answer** is stored in the device's trust record, and from then on any fork authored by the
     rejected device loses at every branch on this device without asking again. It is published as a
     **`resolve` epoch** (`reason: "resolve"`, a fresh key) on top of the chosen side when the
     answering device is listed there, whose record names the rejected author. A resolve epoch may
     remove nothing; it is not a re-application, and the liveness check ignores it (J9).
   - **Who is bound**: other non-author devices still ask their own users, and show any resolve epoch
     they have seen as context ("Mac kept the change made on iPad"). The two **authors**, which are
     never asked, follow a resolve epoch whose author's `addedBy` chain (§4.1) passes through neither
     author, so a device X added cannot settle it for X. Two such resolve epochs that reject different
     authors are shown as a contradiction, and the author's user is asked (KH1 code review M4). An author on the losing side is then
     unlisted and told so (§5.5).
   - **Contradictions**: a device whose stored answer differs from a resolve epoch it sees shows both
     ("You kept the change made on iPad; Mac kept the change made on Phone") and lets the user revise
     the answer, in the prompt and later in Settings ▸ Vault ▸ Devices ▸ History. Until the answers
     agree, each device follows its own, and the status line says the devices disagree.

   Until the device has an answer, it treats both sides as unverified-pending (§4.3): it keeps
   writing locally under its pinned key and uploads nothing new. Authors keep their own side until a
   binding resolve epoch arrives (§5.5 rule 1).
3. **A stale side loses.** If neither author is removed by the other side, a side whose child has no
   descendants loses to a side that has descendants. An honest device that was offline and made a
   change from an old epoch therefore never replaces the chain that went on without it. Descendants
   are counted whoever wrote them, so a removed device can give its own side descendants; that only
   matters where rule 1 does not already discard its side (see "Residual").
4. **Otherwise** (honest concurrent changes, both stale or both continued): the child with the smaller
   `epochId` wins, and the user is told ("Two device changes were made at the same time; the one from
   Mac was applied first").

**Re-application.** When a side loses by rule 3 or 4 (never 1 or 2), the first listed device that sees
it writes **one** new removal epoch on top of the kept chain (`reason: "reapply"`, a fresh random key)
that removes every key removed by any epoch of the **whole losing subtree** that is still listed on
the kept chain. If no such key remains, it writes nothing. Two devices re-applying at once make a fork
of two re-applications with the same removals: rules 3 and 4 keep one, and the other's re-application
finds nothing left to remove and stops.

**Only removals are re-applied, and never of the recovery entry.** A losing side's recovery
replacement (`recovery` or `reencrypt`) is offered again to its initiator ("Replace the recovery kit
again"), and until then the kept chain's kit stays valid. A losing side's additions come back only
through their approvers (§5.1), who must be listed on the kept chain.

**What happens to files.** A losing side's records are set aside (kept for the history view). Files
under its keys are not accepted: they are set aside on every device. The honest writers on the losing
side catch up from their own ledgers into the kept chain (§5.4), so nothing of theirs is lost. A
removed device's files never become accepted through a fork.

**Why this holds (J10, §11.2).** Every key of every kept epoch is wrapped only to that epoch's list
and appears only in records of its descendants. An epoch's list never introduces a device (§4.1), and
re-application only removes. A coalition of removed devices therefore holds exactly the keys of the
epochs that listed one of its members, and can get none of its forks kept against a side that removes
them (rule 1, applied in the pre-pass), nor decided in its favor without a user's answer (rule 2),
and the user is asked in the parent's names, about changes the user made or did not make.

**Residual.**

- A device that has seen **neither** the real removal **nor** anything after it, and is shown only a
  fork that a removed device made, takes it and writes under its key until the real change reaches it.
  Rule 1 then discards the fork, and the device catches up, but what it wrote meanwhile was readable to
  the removed device. This is today's limit (format.md §2.1 "Limits"), narrowed: the removed device
  has to make and serve the fork before that device sees the real change.
- A removed device can make a mutual-removal fork (rule 2) and so make a device ask its user once
  before it uploads again. After the answer, that device discards every later fork by that author
  without asking. The cost is one question per device per removed attacker. It cannot avoid being
  named: the question uses P's list.
- **A still-listed device the attacker added** (a "puppet": X approved it before its removal, and the
  remover carried it) is an honest listed device to the rules. It can author epochs, answer fork
  questions and write resolve epochs; only the authors' binding rule ignores it. The removal sheet
  therefore offers **"Also remove the devices <X> added"** (§5.5), listed from `addSig`.
- On a device that has seen only a removed device's stale fork and that device's own descendants of
  it, rule 3 cannot help (rule 1 decides once the real removal arrives).
### 5.7 Inbox, settings, notebooks, summaries, `keys/`, blob collection

- **Quick capture**: a profile holds `v_e`, `epoch` and `deviceCaptureKey` under `K_e`, and seals to
  `v_e` alone. A profile from an older epoch keeps working while the device is locked. Its captures
  are in the device's ledger (the extension appends to it, §5.4), so they are re-encrypted at the next
  unlock. The profile is refreshed at that unlock.
- **`settings.age`**: an accepted old copy is read. The next write is under the current key. Devices
  keep their own merged copy (format.md §13.3), so a set-aside settings file loses nothing.
- **Notebook records** (§14): write-once, like revisions.
- **Published summaries** (§12): hints under the current epoch's key. Old ones are ignored and
  rewritten by their devices.
- **`keys/`**: holds only the passphrase copy of the recovery key (§8.2).
- **Blob collection** (format.md §8.1.6) gains two conditions. No blob is collected while any revision
  of its note is pending or set aside on this device and might reference it (a set-aside revision is
  read for references when its old key is available, and otherwise blocks collection of its note). No
  blob is collected in a run whose two sides hold different epochs (P4a's "lists differ" rule).

### 5.8 Set aside

P4a's late-file quarantine, renamed. It lives at `<state dir>/setaside/<vaultId>/…`, outside the
vault, and keeps every copy under a content-addressed name, at most 16 per path (P2/#52's rule). It
shows in Repair as "From before a device change", per item with its epoch, its reason (not sealed,
bytes differ, discarded fork), whether it is **superseded** (an accepted file with the same path and
body exists), and **Export** or **Keep** (re-encrypt under the current key on the user's word, with a
warning that it may come from a removed device). Nothing is deleted except by the user ("Clear
superseded" is one action). Writing a copy aside must be durable **before** the original is replaced
or removed from anywhere. A failure to set aside stops that replacement or removal.

## 6. Device keys, joining and the device list

### 6.1 Device keys

- **Apple devices.** The device key is an `XWingMLKEM768X25519.PrivateKey` (CryptoKit, format.md
  §3.1), generated on the device. Its 32-byte seed is stored as a Keychain generic password,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronizable, with an optional
  `.biometryCurrentSet` access control ("Require Face ID to open this vault", off by default).
  This-device-only items are restored only to the same device, never to another device and never
  through iCloud Keychain. There is no export of a device key in the app or the CLI. The signing pairs
  are Secure Enclave keys (§4.1), class `AfterFirstUnlockThisDeviceOnly`, so locked runs can sign.
- **Lost keys.** A device whose device key or signing keys are gone (a Face ID re-enrollment with
  `.biometryCurrentSet`, a Keychain reset) can no longer unwrap, or no longer change the list. It
  **leaves and joins again** as a new device: another device removes the old entry, and the device
  joins with a new key and id. No device may rewrite another entry's `sign` keys (they are fixed by
  `addSig`, §5.1).
- **Secure Enclave for the device key (verified 2026-10-20 against Apple's CryptoKit docs).**
  `SecureEnclave` offers `P256`, `MLKEM768`, `MLKEM1024`, `MLDSA65` and `MLDSA87` (iOS and macOS 26).
  It offers **no X25519 and no X-Wing**, and `HPKE.KEM` lists X-Wing as its only post-quantum KEM,
  with no ML-KEM-768 and P-256 hybrid. age's hardware-oriented type, `mlkem768p256tag` (recipient
  `age1tagpq1…`, HPKE KEM MLKEM768-P256 from draft-ietf-hpke-pq-03, c2sp.org/age), would fit an
  enclave pair, but we would have to compose the hybrid KEM combiner and the HPKE key schedule
  ourselves. That conflicts with "never hand-roll" (CLAUDE.md), so it is **deferred** (Revisit later,
  §15). Only the wraps in `vault.json` use device keys, so a later key type changes no file.
  Signatures need no combiner, so the signing pairs use the enclave now.
- **CLI.** The CLI is a device too. `sempere device init --vault V` generates its device key and
  signing pairs in `$XDG_STATE_HOME/sempere/devices/<vaultId>/` (mode 0600 in a 0700 folder; optionally
  passphrase-wrapped with `--passphrase`), then joins (§6.2). A copied state directory makes two
  installs share one set of keys. That is fine for the keys (both are the same device to the vault),
  and it is the user's own choice, as copying a key file is today. Read-only recovery with the
  recovery key alone (`--recovery-key FILE [--root HEX]`) needs no join and writes nothing.

### 6.2 Joining by approval

1. **New device N** opens the vault from a target ("Open Vault…", device-first-sync.md §8.1),
   generates its keys, and writes a join request `joins/<id>.join.json` to the targets it can reach:

   ```json
   { "format": "sempere-join/1", "vaultId": "…", "key": "age1pq1…",
     "sign": { "p256": "…", "mldsa65": "…" }, "name": "Alex's iPhone", "kind": "iphone",
     "created": "2026-10-20T16:20:00Z" }
   ```

   Readers bound the file at 16 KiB and treat it as untrusted input (format.md §9; fuzzed). A name is
   cleaned as in §3. N computes its **commitment**
   `c = SHA-256("sempere/1 join" ‖ lp(vaultId) ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65) ‖ lp(kind))`
   and shows **six words** (the first 66 bits of `c` in the BIP-39 English word list) and a **QR code
   of `vaultId` and `c`** (48 bytes, a version 3 code). The request itself is never in the QR code.
2. **An existing device E** shows "New device wants to join: <name>". The user either scans N's QR
   code or **types** N's six words on E (typing, not comparing, so a near match cannot be waved
   through). E reads the request from storage and checks it against the commitment. A mismatch means
   the request was replaced on the way, and E refuses it. A second preimage (a storage attacker's own
   key with the same words) costs about 2^66 key generations, or 2^256 against the QR code.
3. E adds N's entry with its own `addSig` (§5.1), deletes the request, and shows its **reverse code**:
   six words of `SHA-256("sempere/1 join reply" ‖ lp(vaultId) ‖ lp(c) ‖ lp(root))`, and a QR code of
   `(vaultId, root)`.
4. N sees its wrap and unwraps it. Before pinning anything it asks the user to **type** E's six words
   (or scan E's QR code), computes them from the root of the chain it was given, and refuses the vault
   on a mismatch.

What the reverse code stops: a **storage provider** serving N a vault of its own, which cannot have a
chain rooted at the real root. It does not stop a **removed device**, which holds a rooted chain up to
its removal and can show N a fork from there. N then sees the real change later, and fork resolution
(§5.6) discards the forged side; the §5.6 residual applies to what N wrote meanwhile.

Requests older than 7 days, and those of keys already listed, are deleted by any listed device.

### 6.3 Joining with the recovery kit or the passphrase

N scans the kit's two QR codes (key and root), or the user types the key and the root groups with
their line checksums, or enters only the passphrase: the passphrase copy carries the root (§8.2). N
unwraps the recovery entry, checks that the chain is rooted at that root (§4.3 step 4), adds its own
entry with a **self-signed** `addSig` and `addedBy: "recovery"`, and drops the recovery identity from
memory. The recovery key is never stored on a device.

**Kit joins are recognized by the signature, not the field.** An entry whose `addSig` is made by its
own signing keys is a kit join, whatever `addedBy` says (§3), and an entry that claims another
approver must carry that approver's signature. A kit finder cannot pass as "added by iPad".

**Every listed device alerts on a kit join**, as a notification and a banner that stays until it is
dismissed: "A device joined <vault> with the recovery kit: <name>, <date>. If this was not you, remove
it, then replace the recovery kit." The device list marks such devices (§6.4).

### 6.4 The device list (Settings ▸ Vault ▸ Devices)

| Row | Shows |
| --- | --- |
| each device | name (editable by any listed device, §5.1), kind icon, "This device", added on and by whom (from `addSig`; "with the recovery kit" in bold for a self-signed entry), "Last synced 3 hours ago" (§5.5) |
| recovery kit | "Recovery kit, created <date>", **Replace Recovery Kit** (§6.5; there is no "print again", since no device holds the recovery key), and the passphrase copy's state |
| actions | **Add Device** (how to join from the new device, and pending requests), **Remove** per device (§5.2, with the warnings of §5.5), **Re-encrypt Everything…** (§7) |
| history | every epoch's `reason`, author and date: "Old Mac removed by iPad on 20 Oct"; forks that lost, and the user's answers |

The CLI mirrors it: `sempere devices list|approve|remove|rename|resolve [--json]` (`resolve --keep
<epochId>` answers a fork question, §5.6),
`sempere recovery replace|passphrase`, `sempere vault reencrypt`.

### 6.5 Replacing the recovery kit

The kit is shown once, at creation, and never stored, so it cannot be printed again. **Replace
Recovery Kit**:

1. **lists every device** and highlights each kit join (a self-signed entry, §6.3) since the current
   kit was created. The user must **confirm or remove** each listed device before going on. A kit
   finder who joined quietly is therefore either removed in this change or kept by the user's explicit
   choice;
2. generates a new recovery identity `R'`, prints it (`sempere keys paper` layout, with the root), and
   asks the user to type a checksum line from the printout;
3. **removes `R` (and the devices the user removed) and adds `R'` as one removal** (§5.2,
   `reason: "recovery"`): a new epoch, because `R` opens the old wrap in any old copy of
   `vault.json`.

Files from before stay readable to `R` through old copies of `vault.json`. If that matters (the kit
was lost, not destroyed), use §7. The passphrase copy is rewritten for `R'` and the old one is
deleted (§8.2).

## 7. Re-encrypt everything

Use case: no device was compromised, but the printed kit is lost, and the owner wants nothing on
the storage to open with it any more. It is explicit, rare and slow, and the sheet says so: "Every
note and attachment will be encrypted again. This may take a while and uses network for every
file. Old backups and provider version history still open with the old kit."

### 7.1 Steps (initiating device A)

1. **Devices**: the sheet lists every device and requires the user to confirm or remove each, with
   kit-joined devices highlighted, as in §6.5 step 1.
2. **Preconditions**: as §5.2 steps 1 and 2, and every target reachable (with an override per target
   that is claimed and finished later, P4a C1).
3. **Claim**: write `reencrypt-journal.age` create-only to every target (P4a claims: `If-None-Match:
   *` or `link(2)`, a stale claim replaced after the in-flight day). A claim already there aborts.
   Only one re-encryption runs at a time.
4. **New epoch**: `K_m` and a new recovery identity `R'` (printed and confirmed as in §6.5). The epoch
   record has `reason: "reencrypt"` and the sealed set of §5.2, but its `parent` carries **no key**.
   The earlier keys go into the journal instead (§7.4), holding every earlier epoch key on the kept
   chain (needed to read and verify old files during the pass). `vault.json` binds it with `reencryptPending` (P4a's
   §3.3.1 binding, under `pendingKey` of `K_m`). The recovery entry is `R'`; devices removed in step 1
   are left out, and the others get new wraps.
5. **Pass**: for every file that is accepted under an epoch below `m`, write its re-encryption under
   the **current** epoch's key (`K_m`, or a later epoch's if a removal happened meanwhile, §7.2): a new
   file key, for blobs the new name, settings and inbox included. **Verify it** (it decrypts, its tag
   or name verifies, its body equals the old body), record it in the ledger, make it durable, and only
   then replace the old file (revisions, records and inbox: atomic rename over the same name; blobs:
   write the new name, then delete the old name). A file whose old copy does not verify is left,
   reported and set aside, never re-encrypted (P4a's "never launder").
6. **Propagate** per target with P4a's C5: (a) the epoch record, the journal and `vault.json`;
   (b) the rewritten files by rewrap-replace (P4a rules 1 to 4: the same `vault.json` on both sides,
   both copies verify, equal bodies, exactly one current copy, which wins; if the re-encryption later
   loses a fork, §5.4 step 4's "accepted replaces unaccepted" repairs these paths); (c) once A's sync
   state
   shows every file on that target accepted under an epoch at least `m`, the old epoch records and the
   old blob names are deleted there.
7. **Finish**: when every target is confirmed, `vault.json` is rewritten without `reencryptPending`,
   the journal is deleted with `If-Match`, and every device that saw the finish sets
   `reencryptFinished` in its trust record (P4a's "finished rotations", so a replayed journal is
   refused).

### 7.2 Several devices, some offline, and other changes

- **An online, listed device B** takes the new epoch (verified by the record's `chain`, §4.3; the old
  keys it needs for reading come from the journal while it is pending). It stops writing under old
  keys at once. Rewrap-replace brings it A's current copies, and B catches up its own unsealed files
  (§5.4). B's device-local keyring (P4a's `SecretKeyring`, renamed **epoch keyring**) keeps the old
  keys it held until its own catch-up ends, then forgets them.
- **An offline device D returns after the finish** (journal gone). D unwraps the current key. Its
  local old copies of sealed files are replaced by the current copies from targets (D checks body
  equality with the old keys in its own keyring). D re-encrypts its own unsealed files (ledger) and
  sets aside everything else. Then it deletes its local old epoch records and forgets the old keys.
- **A removal during the pass** is allowed (removals are immediate). It is an ordinary new epoch
  `m+1` whose record holds `K_m` as its parent key. The pass continues under `K_{m+1}`: its outputs are
  ledger entries of the passing device, so any written under `K_m` after the seal are caught up like
  any other own file. The journal stays bound by `reencryptPending`, re-derived under the new key in
  the new `vault.json`.
- **A re-encryption that meets an offline removal (a fork).** The two epochs share a parent, and §5.6
  decides. If the re-encryption side is kept, the removal is re-applied on top (§5.6
  "Re-application") and the pass goes on. If the removal side is kept (rule 3 or 4, or rule 1 when the
  initiator was removed), the re-encryption epoch loses and its journal is refused. Its removal of
  devices is re-applied when it lost by rule 3 or 4, but its recovery replacement is not (§5.6:
  re-application never touches the recovery entry), so the old kit stays valid until the run is
  repeated. Its initiator, if still listed, reports
  "Re-encryption was stopped by a device change made on <device> at the same time", and the sheet
  offers to run it again. Its new kit is void, and a new one is printed by the next run. Files the
  pass had re-encrypted under the discarded key are its initiator's ledger entries, so they come back
  under the kept chain by catch-up.
- **Resume**: the pass skips files already current (P4a "complete"), so a crash, a lock or a lost
  network resumes where it left off, on A or on any listed device that holds the journal ("Finish
  re-encryption" in Repair).
- **Progress**: "Re-encrypting: 1,240 of 8,912 files (this device); targets: iCloud Drive 80 %, NAS
  12 %". The count is derived from the files (current or not), not stored.

### 7.3 What it guarantees

After the finish, nothing **in the vault on a target or in a working copy** opens with `R` or with
any epoch key from before `m`: every file is under `K_m` or later, the old epoch records are gone, and
no wrap names `R`. It does not reach backups (`sempere backup` keeps old versions under `versions/`), a
provider's version history, a device's set-aside files, or copies a removed device kept. The sheet
says so.

### 7.4 The journal

`reencrypt-journal.age` at the vault root: an age file to `v_m` (the re-encryption epoch's vault
identity), whose plaintext is the body framing of format.md §4 with the label `reencrypt` and the file
name, tagged under `tagKey` of `K_m`, so `tail -c +38 | gunzip` reads it:

```json
{ "format": "sempere-reencrypt/1", "vaultId": "…", "epoch": 7, "epochId": "…",
  "keys": [ { "epoch": 6, "epochId": "…", "key": "…(64 hex)…", "identity": "AGE-SECRET-KEY-PQ-1…" },
            … every earlier epoch on the kept chain … ],
  "created": "2026-10-20T16:20:00Z", "by": "a1b2c3d4" }
```

`vault.json` binds it with `reencryptPending` = HMAC-SHA256(`pendingKey`,
`"sempere/1 reencrypt pending"` ‖ lp(vaultId) ‖ lp(SHA-256(journal bytes))), under the key of the
current epoch (re-computed by every later epoch's `vault.json` while the journal exists), with
format.md §3.3.1's accepting and finishing rules. Readers bound it like an epoch record and fuzz it.
Its format is frozen in KH1, because the kit's script reads it (§8.1).

## 8. The recovery key, the passphrase copy and stock `age`

### 8.1 Stock `age` recovery: kept, with one step more

The property is kept: with the kit, stock `age` 1.3+ and `jq`, `tail`, `gunzip`, every file opens.
What changes is that the kit's key opens the vault key first, and older epochs need one more `age
-d` each. The kit prints this script (POSIX sh, tested in CI against the reference `age`, like today's
pipeline). Everything it relies on is frozen in KH1 (§12): the record names and framing (§5.2.1), the
journal (§7.4), the wrap (§3) and the passphrase copy (§8.2).

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

Identities are appended through `prev.txt`, never by redirecting `age`'s output into the file it is
reading. A record that does not open (an orphan, or a fork that lost) only prints an error and adds
nothing, and repeated identities are harmless. The note and blob pipelines of format.md §4 and §8.1.7
are unchanged except for `-i vault-keys.txt`. CLAUDE.md's "Keep the stock-CLI recovery path working"
rule is updated in KH1 to this script.

### 8.2 The passphrase copy

`keys/recovery-<fingerprint>.key.age` (the recovery fingerprint of §3): the recovery identity,
age-encrypted with one scrypt stanza (format.md §3.2's file, renamed). Its plaintext is:

```
# created: 2026-10-20T16:20:00Z
# sempere-vault: 0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c
# sempere-root: …(64 hex digits)…
# public key: age1pq1…
AGE-SECRET-KEY-PQ-1…
```

`age -d` with the passphrase gives a file `age -i` reads directly (step 0 above). The root line lets
the passphrase alone, without the paper, verify a join (§6.3) and the CLI's `--recovery-key` mode
(§4.3). It is authenticated by the scrypt stanza's AEAD, and whoever could forge the file already
knows the passphrase and so holds `R`. The copy is optional and wraps only the recovery key: device
keys are never passphrase-wrapped into the vault.

**Does it undo post-quantum security?** No, but it caps the vault at the passphrase's strength
against anyone who has the storage, today or later. There is no public-key step in it, so Shor's
algorithm, the reason for ML-KEM, does not apply. A quantum computer could at best run Grover's
search over passphrases, a square-root speed-up in theory. Each Grover step would have to evaluate
scrypt (1 GiB of memory at work factor 20) reversibly inside the quantum computer, and Grover does
not parallelize well. For the foreseeable future, guessing on classical hardware is the real threat,
and it is the same today as in 30 years. "Harvest now" therefore gains an attacker nothing against
the passphrase copy that they did not already have. The copy is the weakest way in for anyone with
storage access, and its strength is the passphrase. Recommended (decided, §15):

- **Minimum strength about 70 bits** (`PassphraseStrength.storedKeyMinimumBits` 60 → 70), with no
  "insist" override for a copy kept in the vault. Six random words from a 7,776-word list is 77
  bits, and Apple's generated passwords are about 71.
- **scrypt work factor 20** for writers (2^20 × 1 KiB = 1 GiB, about 1 to 2 s on current iPads and
  Macs). 20 is the largest value format.md §3.2 requires every reader to accept, and stock `age`
  accepts it. 22 needs 4 GiB, more than an iPhone app may allocate. The writer range becomes 20…20,
  and readers keep "up to 20, may accept 22".
- **Superseded copies are deleted automatically.** A device deletes a `keys/` file on a target only
  when its own verified epoch is at least the target's `vault.json` epoch, and the file's fingerprint
  matches no key in either `vault.json`. The engine never brings such a file back. It is not data, and
  `vault.json` is the explanation of its deletion.
- **scrypt stays; no Argon2id.** age defines only scrypt for passphrases, and Argon2id would make the
  copy unreadable to stock `age -d` (step 0 of the script). It would also be a second locally
  implemented KDF (CLAUDE.md allows scrypt and PBKDF2 only, with RFC vectors). At 1 GiB scrypt is
  memory-hard enough that the passphrase, not the KDF, decides the outcome.

## 9. Sizes

### 9.1 Header size per file

An `mlkem768x25519` stanza is `-> mlkem768x25519 ` (18 bytes) + 1,494 base64 characters of the
1,120-byte encapsulation + newline, then a 43-character body line + newline: **1,556 bytes**. Every
age header adds `age-encryption.org/v1\n` (22) and the MAC line (48): **70 bytes**. The payload
nonce (16) and the per-64 KiB tags are unchanged.

| Listed keys (devices + paper) | Today: 70 + 1,556 × N | After: 70 + 1,556 |
| --- | --- | --- |
| 2 | 3,182 B | 1,626 B |
| 3 | 4,738 B | 1,626 B |
| 4 | 6,294 B | 1,626 B |
| 6 | 9,406 B | 1,626 B |

Most deltas are a few hundred bytes of compressed JSON, so today the header is most of the file.
For 20,000 files and 4 keys, headers go from about 126 MB to 33 MB. Adding a device no longer grows
every future file.

### 9.2 What grows instead

- `vault.json`: about 15 KB per device (the 1,959-character recipient, an armored one-stanza wrap of
  about 2.5 KB, 4 KB of signing keys and 6.8 KB of `addSig`, all in hex), plus about 7 KB each of
  `epochLink`, `epochSig` and `authorSig`. 4 devices and the kit come to about 85 KB, against about
  15 KB today. It is far below format.md §9's bounds, and it changes rarely. The cost that matters is
  different: every same-epoch rename or union merge writes a new `vault.json` with a new 7 KB
  `authorSig`, and in a provider folder each such write can become a conflict version. That is
  acceptable: renames and joins are rare, and conflict versions of `vault.json` are merged by §5.1.
- Epoch records: about 100 bytes per sealed file after gzip (path plus SHA-256), plus about 11 KB per
  epoch of chain. A removal in a 20,000-file vault writes a record of about 2 MB, once.

### 9.3 What `epochs/` and `joins/` show to storage

Storage sees how many epochs were made (including orphans and forks that lost), when, and roughly how
many files each sealed (from the record's size). It does not see who was removed (that is inside the
record). `vault.json` shows the epoch ids and the current list, as it shows the list today. Join
requests are plaintext: they show a new device's public keys, name and kind, as `vault.json` does once
it joins.

## 10. Threats

| Threat | What the attacker gets | What stops the rest | Residual |
| --- | --- | --- | --- |
| **Stolen device** (locked) | the encrypted working copy; the device key only if the passcode or Face ID is broken | Keychain this-device-only; signing keys in the Secure Enclave; "Require Face ID" option; remove it from another device: a new epoch at once | if unlocked by the thief: everything up to the removal. Files from before stay readable to it (old keys) unless §7 is run and the thief has no copy |
| **Removed device with modified software** (alone or with other removed devices) | the keys of the epochs that listed it; its working copy | §5.3: anything it writes after the change is set aside on every device (J3); it cannot unwrap a later key (J2); a fork it makes from any epoch loses by §5.6 rule 1 (in the pre-pass), or needs a user's answer (rule 2); it cannot avoid being named in the question, which uses the parent's list; epochs never add devices and re-application only removes (J10) | a device that has seen neither the real removal nor anything later can be shown its fork first (§5.6 "Residual"); it can force one question per device; additions under the old epoch attributed to it, shown as such (§5.1); **one still-listed device it added (a puppet) can author epochs and answer questions like any listed device**, which is why the removal sheet offers "also remove the devices it added" |
| **Removed device's storage credentials** | write access to the targets it was given | removal changes no file it can read later; the sheet tells the user to change the target's password (§5.5); every working copy is complete, so a file it deletes from a target is restored (not an explained deletion) | until the password changes, it can delete or withhold files on a target (denial of service, including withholding a record: §4.3 "unverified-pending"), and see metadata |
| **Hostile storage provider** | metadata (§9.3, security.md); every ciphertext | tags, names, `listTag`, author and entry signatures; the trust record pins the root and the chain (rollbacks refused); records bound by hash; joins rooted at the printed root, with codes both ways (§6.2, §6.3); §9.1 checks | it can withhold files or records (pending, never accepted or deleted; a withheld record keeps devices from uploading until another target or a device brings it) and delete things (devices re-upload). The reverse code stops a fake vault from storage, not a fork from a removed device (§6.2) |
| **Lost recovery kit** | whoever finds it can unwrap the key of any epoch the kit was listed in, from any copy of `vault.json`, and can join a device | a kit join is recognized by its self-signature and alerts every device (§6.3); Replace Recovery Kit and Re-encrypt require confirming or removing each kit-joined device (§6.5); Replace: nothing written after opens with it; Re-encrypt: nothing in the vault opens with it | backups, provider history and copies made before still open |
| **Leaked passphrase copy** (file and passphrase) | the recovery key: the same as a lost kit | 70-bit minimum and work factor 20 make offline guessing infeasible for a strong passphrase; the copy is deleted when superseded | a weak passphrase reused elsewhere; backups keep old copies |
| **Quantum adversary harvesting now** | ciphertexts and `vault.json` | every public-key encryption step is X-Wing (ML-KEM-768 + X25519); links and signatures are each classical + ML-DSA-65; the rest is 256-bit symmetric | the passphrase copy is as strong as the passphrase (§8.2). A future break of ML-KEM-768 *and* X25519 would expose everything, as today |

## 11. Tests

### 11.1 Fault injection and scenarios

- **`EpochFaults`** (core, test-only, the pattern of P4a's `RewrapFaults`): crash after the record is
  at its final name and before `vault.json` (an orphan: ignored, the next removal works); after
  `vault.json`; after the ledger intent and before the file is placed; during catch-up after file n
  (re-encrypted copy written, not verified; verified, not renamed; renamed, ledger not updated); in
  re-encryption after file n at each of those points, before the old blob name is deleted, before the
  journal is removed; in a re-application and a `resolve` epoch at the same points as a removal. After
  every crash: reopen, resume, check J1 to J10.
- **Engine faults** (`MemoryRemote` faults, the WebDAV mock, wsgidav behind `dav-fault-proxy.py`):
  `vault.json` arrives before its record (direct child of the pinned epoch: taken, old files pending;
  two epochs above: unverified-pending, no uploads, the status line names the target); a withheld record
  (re-uploaded by another device to every target); a cut upload of a re-encrypted file (old or new
  complete copy, never a mix); a target without strong ETags (nothing replaced, reported: P4a's
  `weakStamps`); **a set-aside write that fails** (disk full, permission): the replacement does not
  happen and the original stays; the remover's best-effort pull with one target unreachable; a locked
  run that must sign (union merge, re-application) with signing keys of class AfterFirstUnlock.
- **Scenarios** (`EpochScenarioTests`, one test each):
  - catch-up: an offline listed device catches up revisions, blobs, inbox, settings and notebook
    records; B uploads, A (not synced down from that target) removes X, and B's files come back from
    B's ledger; locked widget captures appended to the ledger, caught up at unlock; a same-device
    restore and a restore onto another device;
  - removed devices: X writes after the change; a stale removal shows the warning and the password
    advice; **forged removal seen first**: C sees only X's fork omitting C, is unlisted (stops
    uploading, keeps pulling), and resumes when the real change arrives;
  - list changes: concurrent additions (union); a rename on both sides of the same entry (smaller
    digest wins); an addition overtaken by a removal (re-applied by its approver only); an addition by
    X under the old epoch (shown as X's, not carried by the remover, never re-applied);
  - **`addedBy`**: an entry whose `addedBy` names iPad but is self-signed (tampered, or a kit join if it
    says `recovery`); an entry whose `addSig` is by a device not in that `vault.json`; a merged
    `vault.json` written by C keeps the approver's `addedBy`;
  - forks, honest: two concurrent removals from the same epoch (rule 4 and re-application, including
    two re-appliers at once, the second writing nothing); **an honest fork at a non-frontier level**:
    B, offline since `j−1`, removes a key from `j−1` while the chain went on to `e+1` (rule 3: B's side
    loses, its removals are re-applied on top, keys removed at `j+1…e` stay removed);
  - forks, adversarial: removed X forks from `K_e`, adds nothing and seals its own files (rule 1); **X
    forks from an older epoch `j < e+1` with a ground `epochId` smaller than the real `j`'s** (rule 1
    over the subtree: the real side contains X's removal); X's fork removes every other device (rule 1,
    nothing re-applied); two removed devices fork together, from different epochs (rule 1; no kept
    epoch's key derivable by them); **mutual removal**: X's fork removes the real branch author (rule 2
    always asks, every non-author device listed on either side, with names from the parent list even
    when X's fork swaps the names; the answer becomes a `resolve` epoch that binds the authors; a
    second mutual fork by X is discarded without asking); **three children** at one branch: the real
    removal of X, an honest stale fork by B, and X's fork with a ground id that removes B (the pre-pass
    discards X's fork by rule 1, no question is asked, and B's side is re-applied); **a puppet**: N_x,
    added by X and carried into `e+1`, writes a resolve epoch for X's side (the authors are not bound by
    it; other devices still ask; the removal sheet offered to remove N_x with X); **a resolve by a
    device added after the branch** (asked, its answer binds the authors); **contradicting answers** on
    two devices (both shown, one revised, the devices converge); a CLI bridge with a pending question
    (`forkQuestion` in `sync --json`, uploads held, `devices resolve --keep` releases them);
  - **an offline device verifies a removal whose first list carries a device added while it was
    away** (the addition is admitted from the parent's chain entry; the removal verifies);
  - **a losing re-encryption** whose initiator was removed: a target holding only its copies is
    repaired by a device that still has the accepted old bytes (§5.4 step 4);
  - recovery: kit replacement with a kit-joined device highlighted, which the user removes; the alerts on
    every device after a kit join; a kit join that claims `addedBy: "<iPad>"` (refused);
  - joins: by approval with typed words, and with QR commitments, in both directions; a request replaced
    on the way (refused on E); storage serves N a fake `vault.json` and chain (refused on N by the reverse
    code); with the kit and root; with only the passphrase (root from the copy); a wrong root (refused);
  - storage: swaps a wrap, renames a device, rolls back `vault.json`, changes `root`, deletes an epoch
    record, re-serves a superseded passphrase copy (deleted again only under §8.2's rule), plants a
    malformed join request, epoch record or journal (fuzzed readers, typed errors);
  - re-encryption: one device offline until after the finish; a crash and resume on another device; a
    removal during the pass; a re-encryption fork against an offline removal, both outcomes (§7.2);
  - recovery script: the kit's script on a fixture with two removals, an orphan record, a lost fork and
    an unfinished re-encryption, with the printed key and with the passphrase copy;
  - blob collection: a blob referenced only by a set-aside or pending revision is not collected;
  - seed 88's blob-before-revision ordering, kept as an engine regression test.

### 11.2 Property test (`EpochInterleavingTests`, seeded, in `scripts/sync-stress.sh`)

Three to five devices, two targets, random edits with attachments and captures, adds, renames,
removals, recovery replacements, re-encryptions, joins, offline periods, crashes at the fault points
above, locked runs, a hostile target that serves old copies or drops records, and **adversarial removed
devices**: after its removal, a device may keep writing under the keys it holds, make forks from any
epoch it held with ground `epochId`s (alone or with other removed devices), make mutual-removal forks,
plant requests and delete from targets. A scripted user answers fork questions truthfully. The oracle
records every write: who wrote it, its epoch, and whether its writer had been removed at that moment.

| # | Invariant (checked after every step and at quiescence) | Mutation that must make it fail |
| --- | --- | --- |
| J1 | **No loss**: every body written by a device that is listed at quiescence is accepted on every listed device and target, or, while catch-up is pending, still in its writer's working copy and ledger | ledger pruned on upload; the remover skips its pull and the writer's ledger is ignored |
| J2 | **Revocation**: for every coalition of removed devices, no file written after a member's removal was seen by its writer opens with any key the coalition holds | a writer keeps a cached `K_e` after taking `e+1`; a merge key derived from two forks |
| J3 | **No injection**: no body first written by a removed device after its removal is ever accepted by a listed device, for any coalition, unless the user chose Keep on that set-aside file (the oracle records it). No fork exemption | old-key files accepted without the sealed-set check; catch-up by device id instead of the ledger; a losing fork's sealed set honored |
| J4 | **Convergence**: with faults off and two runs per device, all listed devices and targets hold the same kept chain, list and accepted file set | the fork tie-break by local arrival order instead of `epochId`; pairs of more than two children compared in arrival order |
| J5a | **Immediacy (writes)**: no device writes under epoch `j` after it has **verified** a `vault.json` of an epoch above `j` | the capture profile not refreshed and not caught up |
| J5b | **Immediacy (uploads)**: no device uploads a new file under epoch `j` after it has merely **seen** a `vault.json` of an epoch above `j` (verified or unverified-pending) | uploads allowed while unverified-pending |
| J6 | **Set aside is monotone**: nothing leaves the set-aside store without a user action, and every replaced or removed unaccepted file is in it first | set-aside write failure ignored |
| J7 | **Re-encryption completeness**: after a finish and quiescence, no file on a target or in a working copy opens with an epoch key from before the re-encryption or the old recovery key | old blob names never deleted; old epoch records kept |
| J8 | **Body integrity**: no path ever holds two different bodies in the vault | a re-encryption that replaces before verifying, with a crash between |
| J9 | **Liveness**: every re-encryption journal finishes or is reported within a bounded number of runs once targets are reachable; every fork is resolved or put to the user; re-application ends (no `reapply` epoch is written that removes nothing; `resolve` epochs are exempt) | the "skip complete files" check inverted; a re-application written when nothing is left to remove |
| J10 | **Key reach**: for every epoch on any device's kept chain and every coalition of removed devices, the principals able to derive that epoch's key are exactly the keys listed in it or in a later kept epoch (devices and recovery keys) | siblings compared instead of subtrees (the ground-id fork from an older epoch wins); a stale side with no descendants allowed to win by `epochId`; additions re-applied from a losing side; an epoch whose first list introduces a device accepted; `addedBy` taken from the field instead of `addSig`; names in the fork question taken from the forks' own lists; the pre-pass skipped (pairs in `epochId` order only); the authors bound by a resolve epoch written by a device one of them added |

Each mutation is a test-only switch. `EpochMutationTests` runs every mutation for a few seeds and
requires it to fail, so no invariant is vacuous (P4a's round-1 finding). Quick mode: 3 seeds × 40
steps in `swift test`. Long mode: 100 seeds × 120 steps, one process per seed and also one process
for all seeds.

## 12. Phased plan

Sizes as in device-first-sync.md §10: S < 300 changed lines, M 300 to 1,000, L > 1,000.

| # | PR | Size | Depends on | Test gate |
| --- | --- | --- | --- | --- |
| **KH1** | **Key schedule, identities, signatures, fork rules and the frozen kit.** Pure types and functions, no `Vault` wiring: `VaultEpochKey` (`K_e` → identity seed → vault identity, the §2.2 derivations); wraps; `vault.json` model with `keys[]`, fingerprints, `listMessage`/`listTag`, `epochLink`, `root`; the three signature messages of §4.1 (`lp()` encoding, no JSON canonicalization) and their checks (`addSig` ⇒ `addedBy`, self-signed ⇒ kit join, first lists within the parent list **including the parent's carried additions**, the 256-addition bound); the epoch record model, chain check and computed removals; **fork resolution as a pure function** over an epoch tree (§5.6: the pre-pass, rules 1 to 4, subtrees, pairwise order, re-application set, user answers and resolve epochs as input, the authors' binding rule); join commitment, words and reverse code; trust record v3. Shared vectors `Fixtures/epoch-vectors.json`: seed → identity → derived keys → tags, links, root, fingerprints, all three signatures (including a device name with non-ASCII, a slash and an emoji), join words; **negative vectors** (a broken link, a wrong root, a signature by an unlisted key, an `addedBy` that is not the signer, an epoch introducing a device); **fork-tree vectors** (the §11.1 fork scenarios as trees, with the expected kept chain and re-application set, including: three children where a mutual pair meets a decisive sibling (pre-pass); a removal whose first list carries a device added during the parent epoch; a resolve epoch by a device not in P's list; a resolve by a puppet, which does not bind the authors). Mirrored in `web/src/vault/`. format.md: §2, §2.1, §3, §4, §8.1.2, §11.1 rewritten, and **new sections for `epochs/` (§5.2.1 here), the re-encryption journal (§7.4), the passphrase copy's plaintext (§8.2) and the signature messages (§4.1)**. The kit layout (key, root) and the recovery script (§8.1) frozen; CLAUDE.md's recovery rule updated | M to L | — | vectors from two implementations (Swift, TypeScript); `age` interop: a file to `v_e` opens with `age -d -i` the wrap's plaintext; enclave signatures verify in software (Mac test behind `#if canImport(CryptoKit)`); the recovery script on a hand-built fixture (two epochs, an orphan, a lost fork, a journal, the passphrase copy); fuzz targets for the `vault.json`, epoch record, journal and join request readers |
| KH2 | **Single-epoch vaults.** `Vault.create`/`open` on the new manifest: one stanza per file to `v_e`, tags and blob names under derived keys, recovery entry, passphrase copy (work factor 20, 70 bits, root inside), add and rename (signed), union merge, CLI `devices list/approve/rename`, `device init`, `--recovery-key [--root]` read-only; old vault format removed (no migration); fixtures regenerated; web viewer reads the new format | L | KH1 | full `swift test`; the kit's recovery script in CI on a generated fixture; web goldens |
| KH3 | **Removal and the acceptance rule.** Epoch records (final name first), sealed sets, §5.2 under the write lock, §5.3, the set-aside store (moved from P4a's quarantine), the write ledger (intent first, lifetime, App Group, AfterFirstUnlock key), catch-up (§5.4), unlisted devices (§5.5), recovery kit replacement with the device review, blob-collection conditions (§5.7); CLI `devices remove`, `recovery replace` | L | KH2 | `EpochFaults` (core points), the scenarios that need no sync over in-process devices sharing a folder, J1, J2, J3, J5a, J6, J8 |
| KH4 | **Engine.** Sync of `epochs/` (to every target), `joins/`, `keys/` deletions (§8.2's rule); the remover's best-effort pull; pending-until-record and unverified-pending (J5b); current-replaces-unaccepted (§5.4 step 4); the epoch tree and KH1's fork function applied, with re-application and `resolve` epochs; unlisted devices keep pulling; `synced` timestamps | L | KH3, P3 | engine faults, every scenario, `EpochInterleavingTests` J1 to J6 and J8 to J10 with mutation checks; 60 seeds in sync-stress |
| KH5 | **App.** Device keys in the Keychain and signing pairs in the Secure Enclave, join by approval (typed words both ways, QR commitments) and by kit or passphrase with the root, kit-join alerts, device list and history, removal with the stale and password warnings, the unlisted-device screen with Export, fork notices and the "Which of these did you make?" question, set-aside view in Repair, recovery kit replacement; delete remembered-key and key-replace UI | L | KH4, P5 | Mac Catalyst unit tests (gate); `scripts/app.sh test-mac-smoke` with the new sheets; owner device checks below |
| KH6 | **Re-encrypt everything.** §7 on P4a's coordinator, claims, journal binding, rewrap-replace and keyring; removals during the pass; forks against it; CLI `vault reencrypt [--resume]`, app sheet with the device review and progress | L | KH4 (app part: KH5) | `EpochFaults` re-encryption points, J7 and J9, the F11 cut-upload test over wsgidav, 60 seeds in sync-stress |
| (later) | Secure Enclave device keys (`mlkem768p256tag`), when CryptoKit offers that hybrid in HPKE | M | KH5 | Revisit later, §15 |

Critical path: KH1 → KH2 → KH3 → KH4 → KH5. KH6 follows KH4 alongside KH5. KH1 is pure functions,
vectors and text, so the cryptography, the fork rules and everything the printed kit depends on are
reviewed and frozen before anything stores data under them, and KH2's writers and the web viewer port
start from its vectors. The parts of KH1 the round-2 review found unaffected by its blockers (the key
schedule, derivations, wraps, `listTag`, `epochLink`, root, trust record and the positive vectors) can
be written first, in the same PR.

Owner device checks that remain: join an iPhone by approval and an iPad by the kit; remove a device
while a third is in airplane mode with new notes, then reconnect it; an unlisted iPad's screen and
Export; re-encrypt everything with one device offline overnight.

## 13. What this means for PR #57 (P4a) and device-first-sync.md

### 13.1 Superseded, carried over

| In #57 | Fate |
| --- | --- |
| `KeyChangePolicy` (modes, `lateFileWindowDays`, `changedAt`), `lateFileDeadline`, compromised-mode "push first", C0's "synced within a minute" | **obsolete**: every change is immediate (decision 1) |
| R3 with `ownDevices` (device ids) | **obsolete**: catch-up uses the write ledger (§5.4) |
| `rotationOwed`, `adoptConcurrentChange`, `keepThisList` | **obsolete**: additions merge as a union; removals are epochs; forks are never merged (§5.6) |
| `OutgoingKeyGuard` (F4) | **obsolete**: device keys are never replaced. A device leaves and joins again with a new key |
| rewrapping every file on add or remove; `rekeyBlobs`; blob renames at removal | **obsolete** for add and remove; kept only in §7 |
| `rewrap-journal.json` binding (`rewrapPending`, finished-rotation record), claims, stale-claim removal, never uploading a refused journal | **carried over** to `reencrypt-journal.age` (§7) |
| `KeyChangeCoordinator` (ledger that fails closed, C5 per target, fault points) | **carried over** as the re-encryption coordinator |
| rewrap-replace rules 1 to 4, `weakStamps`, per-pair settled state | **carried over** to §7 step 6; a narrower rule (current replaces unaccepted) for §5.4 |
| `SecretKeyring` + sealers + `SealedFileKeyringStore` (0600, locked updates, set aside when unreadable) | **carried over** as the epoch keyring (§7.2), and its store pattern for the write ledger |
| late-file quarantine `late/`, `LateFiles.list/adopt/export` | **carried over** as the set-aside store (§5.8) |
| `RewrapFaults`, `KeyChangeScenarioTests` harness, `KeyChangeInterleavingTests` world and oracle, `KeyChangeOverFaultProxyTests` | **carried over** as `EpochFaults`, `EpochScenarioTests`, `EpochInterleavingTests` (§11), with adversarial removed devices added |
| no blob collection while the two sides hold different lists | **carried over** (§5.7) |
| `incomingManifestProblem`: a same-secret shrink is refused | **carried over** as §4.3 step 1 |

Recommendation: do not merge #57. Close it once KH3 lands, and cherry-pick the carried-over files
into KH3, KH4 and KH6. The engine fixes it found that are independent of keys (seed 88, failed
quarantine) land on `main` separately, as the #57 agent is already doing.

### 13.2 The review findings of #57

| Finding | Fate |
| --- | --- |
| **seed 88**: a revision uploaded while its blob's upload failed, so the attachment ends only in quarantine | **still applies.** It is an engine ordering bug (format.md §8.1.4 step 4 on the remote side), not a key-change one. It is being fixed on `main` separately and stays a regression test (§11.1). One trigger disappears: removals no longer rename blobs |
| **device-id spoofing** bypasses R3's "own" check | **disappears.** Provenance is the device-local ledger of exact bytes, and ids are for names and the interface only (§3, §5.4, J3) |
| **durable owed rotation** (lost at a crash or ledger repair) | **disappears.** There is no owed state: a removal is complete when `vault.json` is written (§5.2), and additions never drop keys. Re-application of a losing fork (§5.6) is recomputed by any listed device from the epoch tree, so it needs no durable state either |
| **quarantine failure** ignored | **still applies**, to the set-aside store: a copy is durable aside before anything is replaced or removed, and a failure stops it (§5.8, J6). Fixed on `main` separately |
| **shared device ids** (two installs with one id) | **disappears.** The id comes from the device's fingerprint, its keys are this-device-only, and ids decide nothing (§3). A same-device restore is the same device; a restore onto another device has no key and joins as a new device (§5.4 "Restores") |
| **clock issues** (window ends, `changedAt`, slack) | **gone** with immediate changes: no rule reads a clock |
| late-file window without a real-time end; R3 laundering; I1/I6 vacuous | gone, gone, and replaced by J1 to J10 with required failing mutations |
| leftover claims block forever | changes: claims exist only for re-encryption, with P4a's stale-claim removal |

### 13.3 device-first-sync.md

§6 (the F1 to F19 review) applies only to re-encryption from now on: rows F4, F7, F9, F10, F17, F18
and F19 are replaced by §5 here, while F1 to F3, F5, F6 and F11 to F16 apply to §7 with "change" read
as "re-encryption". In §10, P4a is replaced by KH1 to KH4 (with KH6 for its rewrite machinery); P4
keeps `keys/`, `inbox/` and `summaries/<device>` sync but not rewrap-replace; P10 is replaced by KH5.
That document's status and §10 point here.

## 14. Alternatives considered

- **A symmetric vault key in a custom stanza** (`-> sempere-vk <id>` sealing the file key with
  ChaCha20-Poly1305). Smaller headers (about 100 bytes), but stock `age` cannot read any file.
  Rejected (the stock-recovery rule).
- **The vault key as an scrypt passphrase** (the only symmetric stanza age has). It works with stock
  `age`, but each file needs the key typed and an scrypt run. Rejected.
- **File keys derived from the vault key and the file name** (no stanza at all). This breaks age
  entirely. Rejected.
- **Merging forks**, by user choice or with a key derived from both forks (the first draft). A removed
  device could make a fork that adds its own key or seals its files, and two removed devices could
  derive the merged key together (review C1, H1). Rejected: forks are never merged (§5.6).
- **Authorship without device signatures**, from link keys only (the first draft). Links show that a
  holder of the parent key made a change, which every removed device was. Rejected: rule 1 of §5.6
  needs to know which device made each fork.
- **Comparing only the two children of a branch** (the second draft). A removed device could fork
  from an older epoch with a ground `epochId`, and an honest stale fork could bring back keys removed
  after its branch point (round-2 C1'). Rejected: subtrees are compared (§5.6).
- **Signing canonical JSON** (the second draft). JSON encoders differ on escapes and numbers, so two
  implementations would disagree (round-2 M2'). Rejected: `lp()`-encoded messages (§4.1).
- **A hidden epoch record renamed after `vault.json`** (the second draft). A crash plus the
  temporary-file cleaner could lose the record (round-2 M1'). Rejected: final name first (§5.2).
- **An epoch hint in each file** (an extra stanza or a name field), to avoid trying older keys. It
  would tell storage which files predate a removal, and the saving is one decapsulation per epoch on
  failure. Rejected.
- **Trust on first use for joins** (the first draft). A provider could serve a joining device a vault
  of its own and read what it writes. Rejected: the root fingerprint and the reverse code (§6.2,
  §6.3).

## 15. Decisions and "Revisit later"

Each item was decided by its recommendation: **Decided (recommended, owner pre-approved
2026-10-20).** Items a review changed are marked **(revised after review)** or **(revised after
round 2)**; their recommendation is again the decision.

| # | Question | Decision |
| --- | --- | --- |
| K1 | Wrap or derive the file key? | Wrap: a fresh age file key per file, in one stanza to the vault identity. **(revised after review)** The identity's seed is derived from the vault key by HKDF (§2.1) |
| K2 | Secure Enclave? | **(revised after review)** Device signing pairs (P-256, ML-DSA-65) in the enclave now, **(revised after round 2)** with class AfterFirstUnlockThisDeviceOnly so locked runs can sign. The device's decryption key stays a software X-Wing key in a this-device-only Keychain item, because the enclave has no X-Wing and HPKE has no ML-KEM + P-256 hybrid (§6.1) |
| K3 | Passphrase KDF and parameters | scrypt stays; writer work factor 20; minimum about 70 bits with no override; superseded copies deleted only under §8.2's rule. **(revised after round 2)** The copy carries the vault id and root |
| K4 | Forks | **(revised after round 3)** Never merged; resolved at each branch over subtrees, after a pre-pass that applies rule 1 to all siblings: a removed author loses; mutual removal is always put to every non-author device listed on either side ("Which of these did you make?", names from the parent list), answered by a signed `resolve` epoch that binds the authors unless a device one of them added wrote it, with contradictions shown and revisable; a stale side loses; otherwise the smaller `epochId`. Only removals are re-applied, from the whole losing subtree, in one epoch (§5.6) |
| K5 | Join verification | **(revised after review, and after round 2)** Typed six words or a QR code of the 32-byte commitment in both directions, and every chain rooted at the printed root fingerprint (§4.2, §6.2) |
| K6 | Device names | Plaintext as today, authenticated by `listTag` and `authorSig`. **(revised after round 2)** A rename on both sides: the smaller digest wins (§5.1) |
| K7 | Set-aside files | Never deleted automatically; "Clear superseded" is one user action (§5.8) |
| K8 | Sealed set contents | Path and SHA-256 of the exact bytes of every accepted file under the parent key, after a best-effort pull (§5.2) |
| K9 | #57 | Not merged; carried-over parts move into KH3, KH4 and KH6 (§13.1) |
| K10 | Kit joins | **(revised after round 2)** Recognized by a self-signed `addSig`, never by the `addedBy` field; loud alerts on every device, and the device review before Replace Kit and Re-encrypt (§6.3, §6.5, §7.1) |
| K11 | Device id length | Keep 8 hex digits: ids are for names and the interface only, and joins refuse a collision with any fingerprint in the chain's lists (§3) |
| K12 | Signed bytes | **(round 2)** `lp()`-encoded messages, never JSON, so no canonicalization is needed (§4.1) |
| K13 | Epoch record order | **(revised after round 2)** Final name first; an orphan is ignored, never deleted (§5.2) |

**Revisit later** (irreversible or user-visible):

1. **The recovery kit's printed contents** (§4.2, §8.1): the key, the root fingerprint and the script,
   with what the script depends on (record names and framing, the journal, the wrap, the passphrase
   copy). Paper cannot be updated, so they are frozen in KH1, before the first kit a user prints from a
   release build.
2. **Secure Enclave device keys** (§6.1), once CryptoKit (or swift-crypto) offers the MLKEM768-P256
   HPKE KEM for enclave keys. A new key type for new joins only; no file changes.
3. **Plaintext device names** in `vault.json` and join requests (§3, §9.3). They could move into an
   encrypted record if the owner wants storage not to see them; doing that later changes only those
   files.
4. **The fork question's wording** (§5.6 rule 2.2), which users see only in an attack or a rare
   accident. It should be checked with the owner on a device before KH5 ships.

## 16. Reviews of 2026-10-20 and what changed

### 16.1 Round 1

An independent review of the first draft found two critical, four high, seven medium and several low
findings. Each is addressed here:

| Finding | Change |
| --- | --- |
| C1 removed device admitted through a fork merge; its sealed set laundered | forks never merged; device signatures; a removed author's fork is never kept (§4.1, §5.6); J3 without a fork exemption |
| H1 merge key derivable by two removed devices | no merge key at all (§5.6); J10 over coalitions |
| H2 "combine" forced; forged removal stops a device | rules instead of a forced merge; unlisted devices keep pulling and never pin an epoch that removed them (§5.5); round 2 completed both |
| C2 ledger pruning strands files | entries live until sealed or re-encrypted; the remover pulls from every reachable target first (§5.2, §5.4) |
| H3 joins trust the first vault they see | root fingerprint on the kit, chains rooted; codes both ways (§4.2, §6.2, §6.3) |
| H4 a kit finder joins quietly | alerts on every device; device review before Replace Kit and Re-encrypt (§6.3, §6.5, §7.1); round 2 keyed them on the signature |
| M1 `vault.json` before its record | taken only on a direct link, otherwise unverified-pending; withheld records re-uploaded (§4.3, §5.2) |
| M2 ledger ordering, key class, restores | intent first; AfterFirstUnlock key in the App Group; restore cases corrected (§5.4) |
| M3 blob collection | not while a set-aside or pending revision may reference the blob (§5.7) |
| M4 re-encryption meets an offline removal | both outcomes specified; removals allowed during the pass; the pass writes ledger entries (§7.2) |
| M5 passphrase-copy deletion; kit script | deletion only from a device at the target's epoch or later; step 0; appends through a temporary file (§8) |
| M6 removed devices keep storage credentials | threat row; the removal sheet's password advice (§5.5, §10) |
| M7 tests and vectors | scenarios in §11.1; KH1 vectors include negative chains, signing keys and the root (§12) |
| L1 orphan record visible | first a hidden record; round 2 (M1') went back to final-name-first, since an orphan is harmless |
| L2 `K_e` used raw as the X-Wing seed | seed derived by HKDF (§2.1) |
| L4 device ids | ids are for names and the interface only; 8 digits kept (§3, K11) |
| L5 any `K_e` holder can add or rename under `e` | first guessed wrong; fixed in round 2 (below) |
| L6 a same-key field conflict in a union | first guessed wrong; fixed in round 2 (below) |
| L7 writes between sealing and `vault.json` | the remover holds the write lock from step 3 to step 5, after its own catch-up (§5.2) |
| L8 what `epochs/` reveals | §9.3 |

### 16.2 Round 2

The second review (at `8102151`) found one critical, two high, eight medium and six low findings,
named the two round-1 items that had been guessed (L5, L6), and judged KH1 ready to start once its fork
function, join codes and frozen kit followed the fixes. Each is addressed here:

| Finding | Change |
| --- | --- |
| **C1'** fork resolution compared siblings: a removed device forks from an older epoch with a ground id, and an honest stale fork can bring removed keys back | resolution at each branch over **subtrees**: rule 1 looks for the author's removal anywhere in the other subtree; a side with no descendants loses to one with descendants (rule 3); the whole losing subtree's removals are re-applied in one epoch (§5.6). Scenarios "X forks from an older epoch with a ground id" and "honest fork at a non-frontier level" (§11.1); J10 mutations "siblings compared" and "stale side wins by id" (§11.2) |
| **H1'** `addedBy` unauthenticated; re-application of additions; kit-join alert bypassed | per-entry `addSig`; `addedBy` must be its signer, and a self-signed entry is a kit join whatever the field says (§3, §4.1, §6.3); epochs never introduce devices; re-application only removes, and approvers re-apply their own additions (§5.1, §5.6) |
| **H2'** mutual-removal prompt names from the forks; answer not propagated; wrong question | names from the parent list; a third listed device that continued one side decides without asking (rule 2.1); otherwise "Which of these did you make?", stored and published as a signed `resolve` epoch; a rejected author's later forks lose without asking (§5.6) |
| M1' hidden record + temp cleaner can lose the record | final name first; an orphan is ignored, never deleted (§5.2); fault point "after the record, before `vault.json`" (§11.1) |
| M2' signed bytes not defined for two implementations | every signature is over an `lp()`-encoded message, never JSON (§4.1); KH1 vectors with a non-ASCII, slash and emoji name in Swift and TypeScript (§12) |
| M3' join QR does not fit | the QR holds the vault id and the 32-byte commitment; E reads the request from storage and checks it (§6.2) |
| M4' passphrase join needs the kit | the passphrase copy's plaintext carries the vault id and root (§8.2); `--recovery-key` reads it too (§4.3) |
| M5' unverified-pending can last; §5.5 vs §11.1 contradict | status text, records pushed to every target, another target or Export as the way out (§4.3, §5.2); "removed" is the state of a device whose kept chain omits it, stated as reversible on screen, and the scenario says the same (§5.5, §11.1) |
| M6' signing keys when locked, lost, copied | class AfterFirstUnlockThisDeviceOnly; lost keys mean leave and join again, and `sign` keys are fixed by `addSig`; a copied CLI state directory is one device (§4.1, §6.1) |
| M7' removals read from the record; epoch 1 signer; `root` not compared | removals computed from the signed parent list and the first list (§4.1); epoch 1 signed by its creator, in its first list (§4.1); `root` compared in every case (§4.3) |
| M8' KH1 does not freeze what the kit needs | KH1 adds format.md sections for `epochs/` (§5.2.1), the journal (§7.4), the passphrase plaintext (§8.2) and the signature messages (§4.1); the script prints the journal step unconditionally, guarded by the file's presence (§8.1, §12) |
| L1' J5 weakened to uploads | J5a (no writes after verifying) and J5b (no uploads after seeing) (§11.2) |
| L2' two re-appliers make an extra epoch each time | a re-application with nothing left to remove writes nothing (§5.6); J9 checks it |
| L3' the pull seals the removed device's last uploads; the 10 s bound's dependency | both stated in §5.2 step 2 |
| L4' the reverse code was overclaimed | scoped: it stops storage, not a removed device's rooted fork (§6.2, §10) |
| L5' the id check named a history the chain did not carry | the chain now carries every epoch's first list, so the check against "the current list and every list in the chain" is real (§3, §5.2.1) |
| L6' `authorSig` cost on every rename or merge | stated and accepted (§9.2) |
| L5 (round 1) any `K_e` holder can add or rename under `e` | additions carry the approver's `addSig` and show who added them; the next epoch carries only what its author saw; a removed approver's additions are never re-applied (§5.1) |
| L6 (round 1) a rename on both sides of one entry | the entry with the smaller digest wins and the user renames again (§5.1) |

### 16.3 Round 3

The third review (at `df28555`) judged the design ready for implementation, with no critical or high
finding left. Its six medium and five low findings are applied here. M1, the M3 pre-pass and their
vectors are part of KH1's pure functions; M2, M4, M5 and M6 are KH4 and KH5 behavior, written into the
design now.

| Finding | Change |
| --- | --- |
| M1 "first list within the parent list" rejected honest removals after an addition the verifier missed | the parent's list is its first list plus every addition made during the parent epoch, admitted by `addSig`; each chain entry carries its epoch's `additions` (§4.1, §5.2.1); KH1 verification and vectors; scenario "an offline device verifies a removal whose first list carries a device added while it was away" (§11.1) |
| M2 rule 2.1 could be decided by a still-listed puppet | rule 2.1 dropped (the owner's choice): mutual removal always asks (§5.6); the removal sheet offers "also remove the devices <X> added" (§5.5); the puppet line in §5.6 "Residual" and §10 |
| M3 pairing order let X force a question despite a decisive sibling | pre-pass before pairing: a child whose author a sibling's subtree removes is discarded (rule 1) unless the pair is mutual; a side lost by rule 3 or 4 is re-applied whichever sibling it lost to (§5.6); fork-tree vector and scenario "three children" |
| M4 who is asked, who is bound | every non-author device listed on either side is asked; a resolve epoch binds the authors unless its author's `addedBy` chain passes through one of them; CLI `sempere devices resolve --keep <epochId>` and `forkQuestion` in `sync --json` (§5.6, §6.4) |
| M5 contradicting answers split devices | a contradicting resolve epoch is shown, and the stored answer can be revised in the prompt or in the device history (§5.6) |
| M6 a target keeps a losing re-encryption's copies | "accepted replaces unaccepted", current preferred (§5.4 step 4, §7.1 step 6); scenario "a losing re-encryption" (§11.1) |
| L1 `addSig` recursion unbounded | at most 256 additions per epoch, admitted in one linear pass; in the fuzz target (§4.1) |
| L2 a resolve epoch may remove nothing | `resolve` is its own reason, exempt from J9's "no epoch removes nothing" (§5.6, §11.2) |
| L3 rule 3 counts a removed device's own descendants | stated in §5.6 rule 3 and "Residual" |
| L4 §10's removed-device row | one question per device, named from the parent list, and the puppet line (§10) |
| L5 missing fork-tree vectors | three children with a mutual pair and a decisive sibling; an addition carried into a removal; a resolve by a device not in P's list; a puppet's resolve (§12 KH1) |

### 16.4 KH1 code review

The independent review of KH1's code (#63 merged; #65 fixed before merging) found one critical, two
high, six medium and five low findings. The design changes they made are written above:

| Finding | Change |
| --- | --- |
| C1 a removed device hijacks the kept chain by appending under an old honest stale fork | §5.6: the pinned chain as context, counted epochs per pair of sides, pruning on the kept prefix |
| H1 additions admitted against the `vault.json` itself | §4.3 step 1: only against the verified list |
| H2 `epochSig` not verifiable from `vault.json` | §3: `epochReason`, `parentList` (and `rejected`) in `vault.json`; the first list derived from `addedEpoch` |
| M1 which fingerprint is the recovery key | §5.2.1: `recovery` in each chain entry, signed; replaced by recovery and re-encryption epochs |
| M2 a resolve epoch's rejected author unsigned and dropped from chain copies | §4.1, §5.2.1: `rejected` in `epochSig` and in chain entries |
| M4 two binding resolve epochs that disagree settled silently | §5.6: a contradiction and a question |
| M6 the record's `reason`/`by` not tied to its chain entry | §5.2.1 |
