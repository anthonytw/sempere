# Key hierarchy: vault keys, device keys and one recovery key (design)

Status: **design, 2026-10-20.** It follows the owner's decisions of 2026-10-20 (below). Each open
question was settled by its recommendation, which the owner pre-approved
("Decided (recommended, owner pre-approved 2026-10-20)", §15). It replaces the key-change part of
`docs/design/device-first-sync.md` (§6 and the P4a, P4 and P10 rows of §10; see §13 here).
No code changes with this document. The normative text goes into `docs/format.md` in phase KH1 (§12).

Owner's decisions (2026-10-20):

1. **Every key change is immediate.** There is no late-file window and there are no routine or
   compromised modes. Files under an old key from other devices that arrive after a change are set
   aside, never deleted.
2. **A key hierarchy.** Each file has its own file key, wrapped to a vault key. The vault key is
   wrapped once per listed key. Adding a device wraps the vault key to it and rewraps no file.
   Removing a device creates a new vault key for every file written afterward, and old files stay as
   they are. The vault records, authenticated under the new key, the set of files that existed at the
   moment of the change.
3. **Per-device keys only**, plus exactly one recovery key (the printed kit). A device's private key
   never leaves it. Keys are never copied between devices, and vault keys are never synced through
   iCloud Keychain.
4. **"Re-encrypt everything"** is a separate, explicit and rarer operation: a new vault key and a new
   recovery key, then every existing file re-encrypted.
5. **Removed devices** detect their removal, stop syncing, keep their data readable and offer to
   export what they did not sync. Removing a device warns when its last sync is stale.
6. **No backward compatibility** before v1. The format may change freely, and the owner re-imports.

## 0. Summary

- **The vault key is an age identity.** Each *epoch* of the vault has a 32-byte secret `K_e`. It is
  the seed of an age MLKEM768-X25519 identity (format.md §3.1), the **vault identity**, and every
  other vault key is derived from it with HKDF. Every vault file is an ordinary age file with
  exactly **one** `mlkem768x25519` stanza, addressed to the vault identity, under a fresh file key.
  A file's header is therefore one stanza whatever the number of devices: about 1.6 KB, against
  4.7 KB for three devices and a paper key today (§9).
- **`vault.json` wraps `K_e` once per listed key**: one entry per device key and one for the
  recovery key. Each wrap is a small age file to that key. Adding a device appends a wrap, rewraps
  nothing, and keeps the epoch.
- **Removing a key starts a new epoch.** The device that removes it writes a new `K_{e+1}` and a
  write-once **epoch record** `epochs/<e+1>-<id>.epoch.age`, encrypted to the new vault identity.
  The record holds `K_e` (so that old files stay readable to current keys) and the **sealed set**:
  the path and SHA-256 of every file under `K_e` that the remover held. From that moment every
  write on any device that has seen the change uses `K_{e+1}`.
- **The acceptance rule.** A file that opens under the current key is accepted. A file that opens
  only under an older key `K_j` is accepted if and only if its exact bytes are in the sealed set of
  the record that closed `j`. Anything else under an old key is **set aside**: kept, never deleted,
  never placed. Device ids and file names decide nothing.
- **Catch-up by provenance.** Each device keeps a device-local **write ledger**: the path and
  SHA-256 of every file it wrote. A still-listed device that was offline during a change re-encrypts
  under the current key exactly the files of its ledger that the change did not seal, and nothing
  else. Another device's files are never "adopted" on its behalf.
- **Authenticity.** `recipientsTag`, `secretLink` and the vault secret become a `listTag`, an
  `epochLink` and HKDF keys of `K_e` (§4). The trust record pins the epoch.
- **Device keys and joining.** Each device generates its own MLKEM768-X25519 key and keeps it in the
  Keychain (this device only). A new device asks to join. An existing device approves it after
  both screens show the same six words, or the new device approves itself with the recovery kit or
  the passphrase copy (§6). The Secure Enclave does support ML-KEM-768, but not X-Wing or an HPKE
  hybrid that age accepts, so it is deferred (§6.1).
- **One recovery key**, printed as today's kit. The optional passphrase copy wraps the recovery key
  (scrypt, work factor 20, at least about 70 bits, superseded copies deleted). Stock-`age` recovery
  still works, with one extra `age -d` per epoch (§8).
- **Re-encrypt everything** (§7) starts a new epoch with a new recovery key, then rewrites every
  file under it, verifying each replacement before the old copy goes. It reuses P4a's journal,
  claims, coordinator, rewrap-replace rules and fault suites.
- **PR #57** (P4a) is mostly superseded. Its late-file windows, modes and policy fields, its owned-
  file rule based on names, the owed rotation and the outgoing-key guard all disappear. Its journal
  binding, claims, coordinator ledger, keyring store, rewrap-replace and fault and property harness
  carry over to re-encryption and catch-up (§13).

## 1. Terms

| Term | Meaning |
| --- | --- |
| epoch `e` | a period with one vault key. Epoch 1 starts when the vault is created; each removal of a listed key, re-encryption or merge (§5.6) starts the next |
| `K_e` | the epoch's 32 random bytes. It is the seed of the vault identity and the HKDF input of every other key of the epoch |
| vault identity `V_e` | the age MLKEM768-X25519 identity whose seed is `K_e` (`AGE-SECRET-KEY-PQ-1…`), and its recipient `v_e` (`age1pq1…`) |
| device key | an MLKEM768-X25519 key pair one device generated. Its private half never leaves the device |
| recovery key `R` | the one MLKEM768-X25519 identity printed in the recovery kit. It is never stored on a device |
| wrap | `K_e` encrypted to one listed key (an age file), in `vault.json` |
| epoch record | `epochs/<e>-<idprefix>.epoch.age`: the earlier key(s) and the sealed set |
| sealed set | the paths and SHA-256 digests of the files under the previous key that the change kept |
| write ledger | device-local: every file this installation wrote (path, SHA-256, epoch) |
| set aside | kept in device-local storage outside the vault (P4a's quarantine), listed in the app, never deleted without the user |

## 2. Vault identity and derived keys

### 2.1 Why the vault key is an age identity

The owner asked for a symmetric vault key that either wraps or derives each file key, staying close
to age. age has exactly one symmetric recipient, scrypt, and the spec (c2sp.org/age, "scrypt
recipient stanza") requires it to be the **only** stanza of a file. Its passphrase is also read
interactively. A vault key used as an scrypt "passphrase" would work in stock `age`, but only by
typing 77 characters per file. A custom symmetric stanza type (`-> sempere-vk …`) would break stock
recovery altogether.

The native MLKEM768-X25519 identity *is* a 32-byte symmetric secret: age defines the identity as a
seed that expands to the key pair. So the vault key is that seed:

- **Each file key is wrapped to the vault key.** The file key is a fresh 16-byte age file key, sealed
  in one `mlkem768x25519` stanza to `v_e` (HPKE, format.md §3.1). It is not derived from the vault
  key. Derivation would take the file key out of the age header and break `age -d`.
- **Stock `age` reads every file** with the vault identity (`age -d -i vault-key.txt FILE.age`),
  and the vault identity itself is one `age -d` away from the recovery key (§8).
- **Writers that hold only `v_e` can encrypt.** Quick capture already seals without the secret
  (format.md §11). Its profile now holds `v_e` instead of the recipient list.
- **Cost.** One X-Wing encapsulation per write and one decapsulation per read, a fraction of a
  millisecond each, against N encapsulations per write today.
- **Post-quantum.** Every public-key step is X-Wing, as today. Everything else is symmetric
  (ChaCha20-Poly1305, HMAC and HKDF over SHA-256), which Grover only halves.

`K_e` feeds two functions: X-Wing's key generation, which expands the seed with SHAKE256
(draft-connolly-cfrg-xwing-kem, "Key generation"), and HKDF-SHA256 with Sempere's `info` strings
below. The two are different hash constructions with disjoint inputs, and each is a standard
pseudorandom function of a uniform 32-byte key. That is the same reuse argument format.md already
makes for `vaultSecret` (one secret, many HKDF labels).

### 2.2 Derivations

With `K_e` as HKDF-SHA256 input key material (RFC 5869, empty salt, `L = 32` unless stated). These
replace every use of `vaultSecret` in format.md:

| Key | `info` | Replaces |
| --- | --- | --- |
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
  "epoch": 3,
  "epochRecord": "epochs/3-5b0e6f1a2c3d4e5f.epoch.age",
  "epochRecordHash": "…(64 hex digits)…",
  "keys": [
    { "role": "device", "key": "age1pq1…(1959 characters)…", "id": "a1b2c3d4",
      "name": "Alex's iPad", "kind": "ipad", "added": "2026-10-04T16:20:00Z", "addedBy": "e5f6a7b8",
      "wrap": "-----BEGIN AGE ENCRYPTED FILE-----\n…\n-----END AGE ENCRYPTED FILE-----\n" },
    { "role": "recovery", "key": "age1pq1…", "name": "Recovery kit", "added": "2026-10-04T16:20:00Z",
      "wrap": "-----BEGIN AGE ENCRYPTED FILE-----\n…" }
  ],
  "listTag": "…(64 hex digits)…",
  "epochLink": { "ed25519": "…(128 hex)…", "mldsa65": "…(6618 hex)…" },
  "markersTag": "…(64 hex digits)…"
}
```

- `epoch` is a decimal integer, at least 1. `epochRecord` and `epochRecordHash` name the epoch's
  record and its SHA-256 (§5.2). Epoch 1 has a record too, with no previous key and an empty sealed
  set, so every epoch looks the same.
- `keys`: exactly one entry with `role: "recovery"`, and any number of `role: "device"`. Every key is
  MLKEM768-X25519 (`age1pq1`), as format.md §2 requires today. §6.1 leaves room for a later
  hardware type.
- `id`: a device's id is the first 8 hex digits of `SHA-256(key)` (the fingerprint of format.md
  §11.1). It is the `<device>` of revision names (§5) and of `summaries/<device>.sealed` (§12.5).
  Deriving it from the key means that a new key is always a new id. A join is refused if the id
  collides with a listed one, and the joining device then generates another key.
- `name` (at most 40 characters, cleaned as `label` in §2), `kind` (`ipad`, `iphone`, `mac`, `cli`,
  or another lowercase word) and `added` are shown in the device list. They are plaintext, so
  storage can read them, as today (docs/security.md "What others can see"). Unlike today, they are
  covered by `listTag`, so storage cannot rename a device to mislead the user. `addedBy` is the
  approving device's id, or `recovery`.
- `wrap`: an armored age file to `key` (one stanza) whose plaintext is an age identity file:

  ```
  # sempere vault key: vault 0d1c6a1e-…, epoch 3
  AGE-SECRET-KEY-PQ-1…
  ```

  So `age -d -i recovery.txt wrap.age > vault-key.txt` gives a file that `age -i` reads directly.
  The vault id and the epoch in the comment are informational. The binding is `listTag` and the
  trust record (§4).
- Removed: `recipients`, `vaultSecret`, `recipientsTag`, `secretLink`, `rewrapPending`.
  `rewrap-journal.json` is gone too, except for the re-encryption journal of §7.
- `features` and `markersTag` stay as in format.md §2 and §2.1.

## 4. Authenticity: what replaces recipientsTag, secretLink and the vault secret

| Today (format.md) | Role | Replaced by |
| --- | --- | --- |
| `vaultSecret` (§2) | keys every tag and name, and is wrapped to all recipients | `K_e`, wrapped per key. Derived keys as in §2.2 |
| `recipientsTag` (§2.1) | the list under the secret | `listTag` = HMAC-SHA256(`listKey`, `"sempere/1" ‖ 0 ‖ "list" ‖ 0 ‖ vaultId ‖ 0 ‖ epoch ‖ 0 ‖ epochRecordHash` ‖ for each entry in list order: `0 ‖ role ‖ 0 ‖ key ‖ 0 ‖ id ‖ 0 ‖ name ‖ 0 ‖ kind ‖ 0 ‖ added ‖ 0 ‖ addedBy ‖ 0 ‖ SHA-256(wrap)`). It covers names and each wrap's digest, so a swapped wrap is detected by every device, not only by the one it was made for |
| `secretLink` (§2.1) | links a new secret to the one a device verified | `epochLink`: Ed25519 and ML-DSA-65 signatures by the keys derived from `K_{e-1}`, over `"sempere/1" ‖ 0 ‖ "epoch link" ‖ 0 ‖ vaultId ‖ 0 ‖ e ‖ 0 ‖ epochId(K_e)`. The derivation, encoding and both-must-verify rule are today's (and so are the test vectors, re-labeled). A merge epoch (§5.6) carries one link per parent, as an array |
| `markersTag` | `format` and `features` | unchanged, under `markersKey` of `K_e` |
| body tag (§4), blob name (§8.1.2) | file authenticity | the same constructions, keyed by `tagKey` and `blobNameKey` of the epoch the file was written in |
| `rewrapPending` + `rewrapFinished` (§3.3.1) | bind and retire a rewrap journal | the same mechanism, renamed `reencryptPending`, used only by §7 |
| trust record `sempere-trust/2` | the last verified secret, list and markers | `sempere-trust/3`: vault id, `epoch`, `epochId`, the link public keys of that epoch, the list's keys and names, markers, and `reencryptFinished` |

**Checking `vault.json`** (replaces format.md §2.1 "Checking"). A device unwraps its own entry. If
the result does not parse as an MLKEM768-X25519 identity, its wrap was tampered with. Then:

1. Same `epoch` and `epochId` as the trust record, and `listTag` verifies: **verified**. A list that
   only gained entries under the same epoch is an addition. A list that lost entries under the same
   epoch is **tampered**: a removal always changes the epoch (§5).
2. A higher epoch: the device opens the current epoch record with the unwrapped key and reads its
   `chain` (§5.2): for every earlier epoch, its number, `epochId`, link public keys and the
   `epochLink` that led out of it. It finds its pinned epoch there, then checks each later link
   under the previous entry's public keys, up to `vault.json`'s own `epochLink`. If every link
   verifies, the list is **verified**. The first link after the pinned epoch can only be made by a
   holder of the pinned key, so a `vault.json` built around an attacker's key fails here. Unlike
   today (§2.1 step 3), a device that missed several changes is not left with "unconfirmed",
   because the chain is in the vault, and it survives re-encryption (§7), which deletes old records.
3. A lower epoch, or the same epoch with a different `epochId`: **rolled back** or **forked**. A
   fork is handled by §5.6. A rollback is tampering: nothing is written, and the device keeps its
   own `vault.json`.
4. No trust record: first use (TOFU), as today (§2.1 step 4, "Limits").
5. **No entry for this device**, while `epochLink` chains from an epoch this device holds: the
   device was **removed** (§5.5). Without a verifying chain, the missing entry is tampering.

## 5. Changes to the list

### 5.1 Adding a device or replacing nothing

An approving device (or the joining device itself, with the recovery key, §6.3) appends an entry
with a wrap of the current `K_e` and rewrites `listTag`. No file is touched and the epoch does not
change. Concurrent additions under one epoch merge as a union: two `vault.json` with the same epoch
and `epochId` whose lists differ only by entries that one side has and the other lacks are merged by
any key holder into the union, sorted by `key`. An addition never drops a key, so there is no "owed
rotation" (#57's same-secret drop cannot happen: dropping a key is a removal, §5.2).

### 5.2 Removing a key (immediate)

On the removing device A, in this order, each step durable before the next:

1. **Preconditions**: the working copy is complete (format.md §1.2 rule 3), `vault.json` verifies,
   and no re-encryption journal is pending (§7). Nothing about targets: a removal never waits for
   other devices or a network.
2. **New key**: `K_{e+1}` = 32 random bytes.
3. **Sealed set**: for every vault file that opens under `K_e` (or is accepted under an older key by
   §5.3) in A's working copy, its path and the SHA-256 of its exact bytes. That covers revisions,
   blobs, notebook records, `inbox/` files and `settings.age`. Files that A has set aside are not
   included.
4. **Epoch record** `epochs/<e+1>-<first 16 hex of epochId>.epoch.age`: an age file to `v_{e+1}`,
   body-framed as format.md §4 with the label `epochs` and the file name, tagged under `tagKey` of
   `K_{e+1}`:

   ```json
   { "format": "sempere-epoch/1", "vaultId": "…", "epoch": 4,
     "parents": [ { "epoch": 3, "epochId": "…", "key": "AGE-SECRET-KEY-PQ-1…",
                    "sealed": { "notes/<id>/<name>.delta.age": "<sha256 hex>", … } } ],
     "chain": [ { "epoch": 1, "epochId": "…", "linkPublicKeys": { "ed25519": "…", "mldsa65": "…" } },
                { "epoch": 2, "epochId": "…", "linkPublicKeys": { … }, "link": { "ed25519": "…", "mldsa65": "…" } },
                { "epoch": 3, "epochId": "…", "linkPublicKeys": { … }, "link": { … } } ],
     "created": "2026-10-20T16:20:00Z", "by": "a1b2c3d4",
     "reason": "remove", "removed": ["<fingerprint>", …] }
   ```

   `chain` holds only public values (about 5.3 KB per epoch, mostly the ML-DSA-65 key and
   signature), so that a device that missed several epochs can check every link (§4 step 2) even
   after re-encryption has deleted the older records.

   `reason` is `create`, `remove`, `recovery` (replacing the recovery kit), `reencrypt` or `merge`.
   It and `removed` are shown in the device history. The record is written once, synced like any
   write-once file, and never changed.
5. **`vault.json`** with `epoch = e+1`, the record and its hash, a wrap of `K_{e+1}` to every
   remaining key, `listTag`, `epochLink` and `markersTag`, in one atomic write. **From this write
   on, A encrypts and tags every new file under `K_{e+1}`.** The order (record before `vault.json`)
   means a reader never sees an epoch whose record is missing locally. A target may still deliver
   them out of order. A receiver that has the new `vault.json` and not yet its record treats files
   under `K_e` as *pending* (neither accepted nor set aside) until the record arrives.
6. **Caches and profiles**: per-epoch caches start empty (format.md §10). Capture profiles are
   refreshed at the next unlock (§5.7).

A removal is atomic in effect: before step 5 nothing has changed, and after it the change is
complete on A. There is no journal, no rewrite pass, no late-file window and no clock. Propagation
is ordinary sync of two new files.

### 5.3 The acceptance rule

For a vault file `F` at path `p` (revision, blob, notebook record, inbox file, `settings.age`):

1. `F` decrypts under the current vault identity and its tag (or, for a blob, its name) verifies
   under the current epoch's keys: **accepted**.
2. Otherwise, `F` decrypts under the identity of an earlier epoch `j` that the chain from the
   current epoch reaches (§4 step 2), and verifies under `j`'s keys, and the record that closed `j`
   lists `p` with `SHA-256(F)`: **accepted**. A record closes `j` if `j` is among its `parents`.
3. Otherwise, if it verifies under some epoch the device holds: **set aside** ("from before a device
   change"), with the reason. This also covers a sealed path whose bytes differ.
4. Otherwise: unreadable. It is quarantined (format.md §9.1) and reported, as today.

The rule needs nothing but the vault's own authenticated records. It reads no device id, file name,
`wall`, `hlc` or clock. A reader tries the current key first, and older keys only on failure: at
most one X-Wing decapsulation per epoch per file, and in practice a handful of epochs.

The sealed set is complete for A, not for the vault. Files that A had not received (written offline
by C, still listed) are handled by their writers (§5.4). Files written under `K_e` by the removed
device X that A had not received are set aside everywhere, which is the point of the removal.

### 5.4 Catch-up: still-listed devices that were offline

Device C was offline (or on a target A does not use) while A removed X. C has written files under
`K_e` that A never sealed. When C first takes `vault.json` of epoch `e+1` (verified, §4), it:

1. stops writing under `K_e`. Its next write is under `K_{e+1}`. This is invariant J5 (§11.2);
2. reads its **write ledger** (below) and, for every entry of an epoch `j < e+1` whose path is not
   sealed with that digest by the record closing `j`, **re-encrypts the file under `K_{e+1}`**: the
   same body (`gzip(JSON)`, blob content, inbox payload), a new file key and a tag under the new key.
   Revisions, notebook records and inbox files keep their names. A blob is renamed under the new
   `blobNameKey`, and its old name stays until GC (format.md §8.1.6, with "no journal" replaced by
   "no blob of this note is pending or set aside");
3. replaces its local file with the re-encrypted copy only after the copy decrypts and its body
   equals the old one, then records the new digest in its ledger (old entry kept until §5.4 ends);
4. uploads normally. On a target, a current copy replaces an **unaccepted** copy of the same path
   (an old-key copy that is not sealed), after the receiver has set the old one aside. This is the
   one replacement rule of the engine outside §7. It never replaces an accepted file.

**The write ledger** is device-local, outside the vault, per vault: one entry per file this
installation wrote (path, SHA-256, epoch, time), sealed with a key kept in the Keychain (app) or
next to the CLI's device key, and stored with the working copy in the App Group container, so that
quick-capture writes from the widget extension are recorded too. Entries are pruned once the file is
accepted on every target this device syncs with, or after the next epoch change seals them. An
unreadable ledger fails closed: catch-up stops and reports it, and nothing is re-encrypted or set
aside on its account. The ledger proves provenance by content, never by name: a file whose bytes
this installation did not write is never re-encrypted by it, whatever its name says.

Files written under `K_e` by another listed device D that C holds (received through a target A does
not see) are set aside on C until D catches up. D's current copy then arrives and is accepted, and
C's set-aside copy is marked superseded (§5.8).

### 5.5 Removed devices

Device X finds a `vault.json` whose chain verifies from an epoch X holds and that has no entry for
X (§4 step 5). X then:

- **stops syncing** with every target: no uploads, no downloads, no mutable-file writes. It keeps its
  own `vault.json`, so its working copy still opens with its key;
- shows **"This device was removed from <vault> by <name> on <date>"**, with the count of its own
  changes that no other device has: write-ledger entries that were not sealed and are not on any
  target as accepted files;
- offers **Export changes** (the notes those entries touch, as a copy of the vault with only them,
  or as PDFs, through the existing export paths), **Keep as a separate vault** (a copy re-created
  with new keys, as an import), and **Remove from this device**;
- refuses every write to the vault from then on (`VaultError.removedFromVault`, CLI exit code 8).

A forged removal needs an `epochLink` under an epoch X holds, so only a holder of that epoch's key
can produce one: a listed device, or the removed device of an earlier change, which could only
target devices that never saw that change. The state is non-destructive. "Check again" re-reads
`vault.json` from the targets.

**Removing a device warns when its last sync is stale.** Each device's published summaries file
(`summaries/<id>.sealed`, format.md §12.5) gains a `synced` timestamp (the end of its last complete
two-way run), authenticated under the current epoch. The sheet shows "Alex's iPhone last synced 12
days ago. Changes it made since then will not reach this vault. It will be told it was removed, and
can export them." When there is no timestamp, it says "never synced with a target this device
knows".

### 5.6 Two changes at once (forks)

Two devices that each remove a key while they cannot see each other create two epochs `e+1` with
different ids (fork *a* by A, fork *b* by B). Epoch records do not collide, since their names carry
the id. `vault.json` conflicts (format.md §1.3). A device listed in both forks:

1. shows both changes ("iPad removed Alex's Phone on …; Mac removed Old Mac on …") and asks to
   **combine them**, which is the only choice offered while both verify. Combining is never done
   without the user, because a removed device holding `K_e` could have made one fork itself to
   carry its own files in a sealed set;
2. writes a **merge epoch** `m = e+2` with `K_m = HKDF-SHA256(ikm = K_a ‖ K_b (ordered by epochId),
   info = "sempere/1 merge key")`, so that every device that combines the same two forks gets the
   same key and the merges converge. The list is the keys present in both forks, plus keys added in
   either fork after `e`. A key removed by either fork stays removed. The record has two `parents`
   (each with its key and sealed set) and `vault.json` carries two `epochLink`s. Two `vault.json`
   with the same epoch, `epochId` and list are the same (the wraps differ in bytes): the smaller
   SHA-256 is kept, so devices never fight over the file;
3. devices that wrote under a fork run catch-up (§5.4) into `m`.

A removal that meets an addition (A removes X at `e+1`, B adds N at `e`): `e+1` wins (it is linked
from `e`). B re-applies its addition on top, because each approving device records the additions it
made in its ledger until it sees them in the current list. N catches up its own writes.

### 5.7 Inbox, settings, notebooks, summaries, `keys/`

- **Quick capture**: a profile holds `v_e`, `epoch` and `deviceCaptureKey` under `K_e`, and seals to
  `v_e` alone. A profile from an older epoch keeps working while the device is locked. Its captures
  are in the device's ledger (the extension writes through the App Group), so they are re-encrypted
  at the next unlock (§5.4). The profile is refreshed at that unlock.
- **`settings.age`**: an accepted old copy is read. The next write is under the current key. Devices
  keep their own merged copy (format.md §13.3), so a set-aside settings file loses nothing.
- **Notebook records** (§14): write-once, like revisions.
- **Published summaries** (§12): hints under the current epoch's key. Old ones are ignored and
  rewritten by their devices.
- **`keys/`**: holds only the passphrase copy of the recovery key (§8.2).

### 5.8 Set aside

P4a's late-file quarantine, renamed. It lives at `<state dir>/setaside/<vaultId>/…`, outside the
vault, and keeps every copy under a content-addressed name, at most 16 per path (P2/#52's rule). It
shows in Repair as "From before a device change", per item with its epoch, its reason (not sealed,
or bytes differ), whether it is **superseded** (an accepted file with the same path and body exists),
and **Export** or **Keep** (re-encrypt under the current key on the user's word, with a warning that
it may come from a removed device). Nothing is deleted except by the user ("Clear superseded" is
one action). Writing a copy aside must be durable **before** the original is replaced or removed
from anywhere. A failure to set aside stops that replacement or removal (#57's "quarantine failure"
finding, §13).

## 6. Device keys, joining and the device list

### 6.1 Device keys

- **Apple devices.** `XWingMLKEM768X25519.PrivateKey` (CryptoKit, format.md §3.1), generated on the
  device. Its 32-byte seed is stored as a Keychain generic password,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronizable, with an optional
  `.biometryCurrentSet` access control ("Require Face ID to open this vault", off by default). This-
  device-only items are encrypted with keys entangled with the device's UID inside the Secure
  Enclave's key hierarchy. They are not restored to another device from a backup and are never in
  iCloud Keychain. There is no export of a device key in the app or the CLI.
- **Secure Enclave (verified 2026-10-20 against Apple's CryptoKit docs).** `SecureEnclave` offers
  `P256`, `MLKEM768`, `MLKEM1024`, `MLDSA65` and `MLDSA87` (iOS/macOS 26). It offers **no X25519 and
  no X-Wing**, and `HPKE.KEM` lists X-Wing as its only post-quantum KEM, with no ML-KEM-768 and
  P-256 hybrid. age's hardware-oriented type, `mlkem768p256tag` (recipient `age1tagpq1…`,
  HPKE KEM MLKEM768-P256 from draft-ietf-hpke-pq-03, c2sp.org/age), would fit an enclave key pair
  (ML-KEM-768 plus P-256), but we would have to compose the hybrid KEM combiner and the HPKE key
  schedule ourselves from enclave primitives. That conflicts with "never hand-roll" (CLAUDE.md), so
  it is **deferred** (Revisit later, §15). The format leaves room for it: a device entry may later
  name an `age1tagpq1` key, and only the wraps in `vault.json` use device keys, so no file would
  change.
- **CLI.** The CLI is a device too. `sempere device init --vault V` generates a key in
  `$XDG_STATE_HOME/sempere/devices/<vaultId>.key` (mode 0600 in a 0700 folder; optionally
  passphrase-wrapped with `--passphrase`), then joins (§6.2). Read-only recovery with the recovery key
  alone (`--recovery-key FILE`) needs no join and writes nothing.

### 6.2 Joining by approval

1. **New device N** opens the vault (from a target: "Open Vault…", device-first-sync.md §8.1),
   generates its key, and writes a join request `joins/<id>.join.json` (plaintext: the key, a
   proposed name and kind, the time) to the targets it can reach. It shows **six words**: the
   first 66 bits of `SHA-256("sempere/1 join" ‖ 0 ‖ vaultId ‖ 0 ‖ key)` in the BIP-39 English
   list, and also a QR code of its key (1216 bytes binary, a version 25 to 30 code).
2. **An existing device E** sees "New device wants to join: <name>". The user either scans N's QR
   code (no comparison needed) or compares the six words that E computes from the request. A
   mismatch means the request was replaced on the way: refuse. 66 bits makes a second preimage
   (a storage attacker's own key with the same words) cost about 2^66 X-Wing key generations.
3. E adds N's entry (§5.1) and deletes the request. N sees its wrap, unwraps it, pins the epoch in
   its trust record (first use), and syncs.

Requests are plaintext and authenticated by nothing but the comparison. A request never changes the
vault by itself. Requests older than 7 days, and those of keys already listed, are deleted by any key
holder.

### 6.3 Joining with the recovery kit or the passphrase

N scans the kit's QR code or types its key (with the kit's line checksums, DESIGN.md "Recovery"), or
enters the passphrase of `keys/recovery-<fingerprint>.key.age`. It unwraps the recovery entry,
verifies `vault.json` (first use), adds its own entry with `addedBy: "recovery"`, and drops the
recovery identity from memory. The recovery key is never stored on a device. Every device's list
shows such joins: "Joined with the recovery kit on <date>".

### 6.4 The device list (Settings ▸ Vault ▸ Devices)

| Row | Shows |
| --- | --- |
| each device | name (editable by any key holder: a list change under the same epoch), kind icon, "This device", added on and by whom, "Last synced 3 hours ago" (§5.5) |
| recovery kit | "Recovery kit, created <date>", **Replace Recovery Kit** (§6.5; there is no "print again", since no device holds the recovery key), and the passphrase copy's state |
| actions | **Add Device** (shows how to join from the new device and lists pending requests), **Remove** per device (§5.2, with the stale-sync warning of §5.5), **Re-encrypt Everything…** (§7) |
| history | every epoch record's `reason`, `by` and date: "Old Mac removed by iPad on 20 Oct" |

The CLI mirrors it: `sempere devices list|approve|remove|rename [--json]`,
`sempere recovery replace|passphrase`, `sempere vault reencrypt`.

### 6.5 Replacing the recovery kit

The kit is shown once, at creation, and never stored, so it cannot be printed again. **Replace
Recovery Kit** generates a new recovery identity `R'`, prints it (`sempere keys paper` layout), and
asks the user to confirm a checksum line from the printout. Then it **removes `R` and adds `R'` as
one removal** (§5.2, `reason: "recovery"`): a new epoch, because `R` opens the old wrap in any old
copy of `vault.json`. Files from before stay readable to `R` through old copies of `vault.json`.
If that matters (the kit was lost, not destroyed), use §7. The passphrase copy is rewritten for
`R'` and the old one is deleted (§8.2).

## 7. Re-encrypt everything

Use case: no device was compromised, but the printed kit is lost, and the owner wants nothing on
the storage to open with it any more. It is explicit, rare and slow, and the sheet says so: "Every
note and attachment will be encrypted again. This may take a while and uses network for every
file. Old backups and provider version history still open with the old kit."

### 7.1 Steps (initiating device A)

1. **Preconditions**: as §5.2 step 1, and every target reachable (with an override per target that
   is claimed and finished later, P4a C1).
2. **Claim**: write `reencrypt-journal.age` create-only to every target (P4a claims: `If-None-Match:
   *` or `link(2)`, a stale claim replaced after the in-flight day). A claim already there aborts.
3. **New epoch**: `K_m` and a new recovery identity `R'` (printed and confirmed as in §6.5). The epoch
   record has `reason: "reencrypt"` and the sealed set of §5.2, but its `parents` carry **no key**.
   The earlier keys go into the journal instead:
   `reencrypt-journal.age`, an age file to `v_m`, body-framed and tagged under `K_m`, holding every
   earlier epoch key the chain reaches (needed to read and verify old files during the pass).
   `vault.json` binds it with `reencryptPending` (P4a/§3.3.1 binding, HKDF of `K_m`). The recovery
   entry is `R'`. Devices are kept, with new wraps.
4. **Pass**: for every file that is accepted under an earlier epoch, write its re-encryption under
   `K_m` (a new file key; for blobs, the new name; settings and inbox included), **verify it** (it
   decrypts under `v_m`, its tag or name verifies, and its body equals the old body), make it durable,
   and only then replace the old file (revisions, records and inbox: atomic rename over the same
   name; blobs: write the new name, then delete the old name). A file whose old copy does not verify
   is left, reported and set aside, never re-encrypted (P4a's "never launder").
5. **Propagate** per target with P4a's C5: (a) the epoch record, the journal and `vault.json`;
   (b) the rewritten files by rewrap-replace (P4a rules 1 to 4: the same `vault.json` on both sides,
   both copies verify, equal bodies, exactly one current copy, which wins); (c) once A's sync state
   shows every file on that target current, the old epoch records and the old blob names are deleted
   there.
6. **Finish**: when every target is confirmed current, `vault.json` is rewritten without
   `reencryptPending`, the journal is deleted with `If-Match`, and every device that saw the finish
   sets `reencryptFinished` in its trust record (P4a's "finished rotations", so a replayed journal is
   refused).

### 7.2 Several devices, some offline

- An **online, listed device B** takes the new epoch (verified by the record's `chain`, §4 step 2;
  the old keys it needs for reading come from the journal while it is pending). It stops writing under old
  keys at once. Rewrap-replace brings it A's current copies, and B runs §5.4 for its own unsealed
  files. B's device-local keyring (P4a's `SecretKeyring`, renamed **epoch keyring**) keeps the old
  keys it held until its own catch-up ends, then forgets them.
- An **offline device D returns after the finish** (journal gone). D unwraps `K_m`. Its local old
  copies of sealed files are replaced by the current copies from targets (D verifies body equality
  with the old keys in its own keyring). D re-encrypts its own unsealed files (ledger) and sets aside
  everything else. Then it deletes its local old epoch records and forgets the old keys.
- **Resume**: the pass skips files already current (P4a "complete"), so a crash, a lock or a lost
  network resumes where it left off, on A or on any listed device that holds the journal ("Finish
  re-encryption" in Repair). A second re-encryption or removal waits until the journal is gone
  (removal: refused with "Re-encryption in progress: n of N files done").
- **Progress**: "Re-encrypting: 1,240 of 8,912 files (this device); targets: iCloud Drive 80 %, NAS
  12 %". The count is derived from the files (current or not), not stored.

### 7.3 What it guarantees

After the finish, nothing **in the vault on a target or in a working copy** opens with `R` or with
any epoch key from before: every file is under `K_m`, the old epoch records are gone, and no wrap
names `R`. It does not reach backups (`sempere backup` keeps old versions under `versions/`), a
provider's version history, a device's set-aside files, or copies a removed device kept. The sheet
says so.

## 8. The recovery key, the passphrase copy and stock `age`

### 8.1 Stock `age` recovery: kept, with one step more

The property is kept: with the kit, stock `age` 1.3+ and `jq`, `tail`, `gunzip`, every file opens.
What changes is that the kit's key opens the vault key first, and older epochs need one more `age
-d` each. The kit prints this script (POSIX sh, tested in CI against the reference `age` like today's
pipeline):

```sh
# 1. The current vault key, from the recovery entry.
jq -r '.keys[] | select(.role == "recovery") | .wrap' vault.json \
  | age -d -i recovery.txt > vault-keys.txt
# 2. Earlier vault keys (only after a device was removed): newest record first.
for f in $(ls epochs | sort -t- -k1,1nr); do
  age -d -i vault-keys.txt "epochs/$f" | tail -c +38 | gunzip \
    | jq -r '.parents[].key // empty' >> vault-keys.txt
done
# 3. Any note, as before.
age -d -i vault-keys.txt notes/ID/NAME.delta.age | tail -c +38 | gunzip | jq .
```

The note and blob pipelines of format.md §4 and §8.1.7 are unchanged except for `-i vault-keys.txt`.
While a re-encryption is unfinished (§7), the earlier keys are in `reencrypt-journal.age` instead
of the records, and the kit's script adds the same three-command step for that file.
CLAUDE.md's "Keep the stock-CLI recovery path working" rule is updated in KH1 to this script. A
device key works in step 1 too (`select(.key == "<its recipient>")`), but device keys are not
exportable, so in practice recovery uses the kit.

### 8.2 The passphrase copy

`keys/recovery-<fingerprint>.key.age`: the recovery identity, age-encrypted with one scrypt stanza
(format.md §3.2's file, renamed). It is optional and it wraps only the recovery key: device keys
are never passphrase-wrapped into the vault.

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
- **Superseded copies are deleted automatically**: when the recovery key is replaced (§6.5, §7),
  the copy for the old fingerprint is deleted on the working copy and on every target. It is not
  data, and a sync never brings back a `keys/` file whose fingerprint is not the current recovery
  key's: the engine deletes it as an explained deletion, with `vault.json` as the explanation.
- **scrypt stays; no Argon2id.** age defines only scrypt for passphrases, and Argon2id would make the
  copy unreadable to stock `age -d` (the stock recovery path for a passphrase kit). It would also be
  a second locally implemented KDF (CLAUDE.md allows scrypt and PBKDF2 only, with RFC vectors).
  scrypt at 1 GiB is memory-hard enough that the passphrase, not the KDF, decides the outcome.

## 9. Header size per file

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

What grows instead:

- `vault.json`: about 4.5 KB per listed key (a 1,959-character recipient and an armored one-stanza
  wrap of about 2.4 KB). 4 devices plus the kit come to about 23 KB, close to today's.
- Epoch records: about 100 bytes per sealed file after gzip (path plus SHA-256). A removal in a
  20,000-file vault writes a record of about 2 MB, once.

## 10. Threats

| Threat | What the attacker gets | What stops the rest | Residual |
| --- | --- | --- | --- |
| **Stolen device** (locked) | the encrypted working copy; the device key only if the passcode or Face ID is broken | Keychain this-device-only (UID-bound); "Require Face ID" option; remove it from another device: a new epoch at once, every later file under `K_{e+1}` | if unlocked by the thief: everything up to the removal. Files from before stay readable to it (old keys) unless §7 is run and the thief has no copy |
| **Removed device with modified software** | old epoch keys, its working copy | §5.3: anything it writes after the change is set aside on every device, never placed (J3); it cannot unwrap `K_{e+1}` (J2); a fork it forges needs the user to combine it (§5.6) | it can still forge an epoch change, linked from the epoch it held, for a device that has seen **neither** the real removal **nor** any later epoch, and that device might write under its key until it sees the real one (format.md §2.1 "Limits", unchanged). It can deny service by planting join requests or a fake removal notice for others (§5.5) |
| **Hostile storage provider** | metadata (security.md); every ciphertext | tags, names and `listTag` under `K_e`; trust record pins the epoch (rollbacks refused); epoch records bound by hash; §9.1 checks; join requests need a matching six-word code | it can withhold files or records (they stay *pending*, never accepted or deleted); delete things (devices re-upload); serve a fake vault to a brand-new device with no trust record (TOFU), which then reads nothing of the real vault |
| **Lost recovery kit** | whoever finds it can unwrap `K_e` from any copy of `vault.json` up to the replacement, and so read files from then | Replace Recovery Kit (§6.5): a new epoch, so nothing written after opens with it; Re-encrypt Everything (§7): nothing in the vault opens with it | backups, provider history and copies made before still open |
| **Leaked passphrase copy** (file and passphrase) | the recovery key, so the same as a lost kit | 70-bit minimum and work factor 20 make offline guessing infeasible for a strong passphrase; the copy is deleted when superseded | a weak passphrase chosen elsewhere; backups keep old copies |
| **Quantum adversary harvesting now** | ciphertexts and `vault.json` | every public-key step is X-Wing (ML-KEM-768 + X25519), links are Ed25519 + ML-DSA-65, the rest is 256-bit symmetric | the passphrase copy is as strong as the passphrase (§8.2). A future break of ML-KEM-768 *and* X25519 would expose everything, as today |

## 11. Tests

### 11.1 Fault injection

- **`EpochFaults`** (core, test-only, the pattern of P4a's `RewrapFaults`): crash after step 4 (record
  written, `vault.json` not yet), after step 5, during the ledger update; during catch-up after file
  n (re-encrypted copy written, not verified; verified, not renamed; renamed, ledger not updated); in
  re-encryption after file n at each of those points, before the old blob name is deleted, before the
  journal is removed. After every crash: reopen, resume, check J1 to J9.
- **Engine faults** (`MemoryRemote` faults, the WebDAV mock, wsgidav behind `dav-fault-proxy.py`):
  `vault.json` arrives before its record (files under the old key stay pending, never set aside); a
  cut upload of a re-encrypted file (old or new complete copy, never a mix); a target without strong
  ETags (nothing replaced, reported: P4a's `weakStamps`); **a set-aside write that fails** (disk
  full, permission): the replacement does not happen and the original stays.
- **Scenarios** (`EpochScenarioTests`, one test each): offline listed device catches up (revisions,
  blobs, inbox, settings, notebook records); removed device writes after the change; stale removal
  warning; concurrent additions (union); concurrent removals (fork, combine, convergence of two
  combiners); removal meets an addition; recovery kit replacement; join by approval (words match;
  request replaced on the way and refused); join with the kit and with the passphrase; storage swaps
  a wrap, renames a device, rolls back `vault.json`, deletes an epoch record, re-serves a superseded
  passphrase copy; re-encryption with one device offline until after the finish; re-encryption
  crash and resume on another device; seed 88's blob-before-revision ordering, kept as an engine
  regression test.

### 11.2 Property test (`EpochInterleavingTests`, seeded, in `scripts/sync-stress.sh`)

Three to four devices, two targets, random edits with attachments and captures, adds, removals,
recovery replacements, re-encryptions, joins, offline periods, crashes at the fault points above,
locked runs, and a hostile target that serves old copies or drops records. The oracle records every
write: who wrote it, its epoch, and whether its writer had been removed at that moment.

| # | Invariant (checked after every step and at quiescence) | Mutation that must make it fail |
| --- | --- | --- |
| J1 | **No loss**: every body written by a device that is listed at quiescence is accepted on every listed device and target, or, while catch-up is pending, still in its writer's working copy | catch-up skips ledger entries; sealed set built from targets instead of the working copy |
| J2 | **Revocation**: no file written after a device saw the removal of X opens with any key X held | a writer keeps a cached `K_e` after taking `e+1`; a wrap to X left in the new list |
| J3 | **No injection**: no body first written by X after X's removal is ever accepted by a listed device, unless the user chose Keep or combined a fork (the oracle records both) | old-key files accepted without the sealed-set check; catch-up by device id instead of the ledger |
| J4 | **Convergence**: with faults off and two runs per device, all listed devices and targets hold the same epoch, list and accepted file set | the fork merge key made random instead of derived; additions merged by last writer |
| J5 | **Immediacy**: no device writes under epoch `j` after it has taken a `vault.json` of epoch `> j` | the capture profile not refreshed and not caught up |
| J6 | **Set aside is monotone**: nothing leaves the set-aside store without a user action, and every replaced or removed unaccepted file is in it first | set-aside write failure ignored (#57's finding) |
| J7 | **Re-encryption completeness**: after a finish and quiescence, no file on a target or in a working copy opens with an earlier epoch key or the old recovery key | old blob names never deleted; old epoch records kept |
| J8 | **Body integrity**: no path ever holds two different bodies in the vault | a re-encryption that replaces before verifying, with a crash between |
| J9 | **Liveness**: every re-encryption journal finishes within a bounded number of runs once targets are reachable | the "skip complete files" check inverted |

Each mutation is a test-only switch. The suite runs every mutation for a few seeds and requires it to
fail (`EpochMutationTests`), so no invariant is vacuous (P4a's round-1 finding). Quick mode: 3 seeds
× 40 steps in `swift test`. Long mode: 100 seeds × 120 steps, one process per seed and also one
process for all seeds.

## 12. Phased plan

Sizes as in device-first-sync.md §10: S < 300 changed lines, M 300 to 1,000, L > 1,000.

| # | PR | Size | Depends on | Test gate |
| --- | --- | --- | --- | --- |
| **KH1** | **Key schedule and format text.** `VaultEpochKey` (seed → vault identity, §2.2 derivations), `vault.json` model with `keys[]`, wraps, `listTag`, `epochLink`, trust record v3 (types and pure functions only, no `Vault` wiring); shared vectors `Fixtures/epoch-vectors.json` (seed → identity → derived keys → tags and links), mirrored in `web/src/vault/`; format.md §2, §2.1, §3, §4, §8.1.2, §11.1 rewritten; CLAUDE.md's recovery rule updated | S to M | — | vectors from two implementations (Swift, TypeScript); `age` interop: a file to `v_e` opens with `age -d -i` the wrap's plaintext; fuzz target for the new `vault.json` reader |
| KH2 | **Single-epoch vaults.** `Vault.create`/`open` on the new manifest: one stanza per file to `v_e`, tags and blob names under derived keys, recovery entry, passphrase copy of the recovery key (work factor 20, 70 bits), add device (wrap only), CLI `devices list/approve/rename`, `device init`, `--recovery-key` read-only; old vault format removed (no migration); fixtures regenerated; web viewer reads the new format | L | KH1 | full `swift test`; stock-age recovery script in CI on a fixture; web goldens |
| KH3 | **Removal and the acceptance rule.** Epoch records, sealed sets, §5.2 (immediate), §5.3, set-aside store (moved from P4a's quarantine), write ledger, catch-up (§5.4), removed state (§5.5), recovery kit replacement, CLI `devices remove`, `recovery replace` | L | KH2 | `EpochFaults` (core points), scenarios without sync, J1, J2, J3, J5, J6, J8 over in-process devices sharing a folder |
| KH4 | **Engine.** Sync of `epochs/`, `joins/`, `keys/` deletions; pending-until-record; current-replaces-unaccepted (§5.4 step 4); fork detection and combine (§5.6); removed devices stop; `synced` timestamps | M to L | KH3, P3 | engine faults, every scenario, `EpochInterleavingTests` J1 to J6 and J8 with mutation checks; 60 seeds in sync-stress |
| KH5 | **App.** Device keys in the Keychain, join by approval (words, QR) and by kit or passphrase, device list and history, removal with the stale warning, removed-device screen with Export, set-aside view in Repair, recovery kit replacement; delete remembered-key and key-replace UI | L | KH4, P5 | Mac Catalyst unit tests (gate); `scripts/app.sh test-mac-smoke` with the new sheets; owner device checks below |
| KH6 | **Re-encrypt everything.** §7 on P4a's coordinator, claims, journal binding, rewrap-replace and keyring; CLI `vault reencrypt [--resume]`, app sheet with progress | L | KH4 (app part: KH5) | `EpochFaults` re-encryption points, J7 and J9, the F11 cut-upload test over wsgidav, 60 seeds in sync-stress |
| (later) | Secure Enclave device keys (`mlkem768p256tag`), when CryptoKit offers that hybrid in HPKE | M | KH5 | Revisit later, §15 |

Critical path: KH1 → KH2 → KH3 → KH4 → KH5. KH6 follows KH4 alongside KH5. KH1 is pure functions
and text, so the reviewer can check the cryptography before anything stores data under it, and
KH2's file writers and the web viewer port can start from its vectors in parallel.

Owner device checks that remain: join an iPhone by approval and an iPad by the kit; remove a device
while a third is in airplane mode with new notes, then reconnect it; a removed iPad's screen and
Export; re-encrypt everything with one device offline overnight.

## 13. What this means for PR #57 (P4a) and device-first-sync.md

### 13.1 Superseded, carried over

| In #57 | Fate |
| --- | --- |
| `KeyChangePolicy` (modes, `lateFileWindowDays`, `changedAt`), `lateFileDeadline`, compromised-mode "push first", C0's "synced within a minute" | **obsolete**: every change is immediate (decision 1) |
| R3 with `ownDevices` (device ids) | **obsolete**: catch-up uses the write ledger (§5.4) |
| `rotationOwed`, `adoptConcurrentChange`, `keepThisList` | **obsolete**: additions merge as a union; removals are epochs; forks combine (§5.6) |
| `OutgoingKeyGuard` (F4) | **obsolete**: device keys are never replaced. A device leaves and joins again with a new key |
| rewrapping every file on add or remove; `rekeyBlobs`; blob renames at removal | **obsolete** for add and remove; kept only in §7 |
| `rewrap-journal.json` binding (`rewrapPending`, finished-rotation record), claims, stale-claim removal, never uploading a refused journal | **carried over** to `reencrypt-journal.age` (§7) |
| `KeyChangeCoordinator` (ledger that fails closed, C5 per target, fault points) | **carried over** as the re-encryption coordinator |
| rewrap-replace rules 1 to 4, `weakStamps`, per-pair settled state | **carried over** to §7 step 5; a narrower rule (current replaces unaccepted) for §5.4 |
| `SecretKeyring` + sealers + `SealedFileKeyringStore` (0600, locked updates, set aside when unreadable) | **carried over** as the epoch keyring (§7.2), and its store pattern for the write ledger |
| late-file quarantine `late/`, `LateFiles.list/adopt/export` | **carried over** as the set-aside store (§5.8) |
| `RewrapFaults`, `KeyChangeScenarioTests` harness, `KeyChangeInterleavingTests` world and oracle, `KeyChangeOverFaultProxyTests` | **carried over** as `EpochFaults`, `EpochScenarioTests`, `EpochInterleavingTests` (§11) |
| no blob collection while the two sides hold different lists | **carried over** (different epochs or lists) |
| `incomingManifestProblem`: a same-secret shrink is refused | **carried over** as §4 step 1 |

Recommendation: do not merge #57. Close it once KH3 lands, and cherry-pick the carried-over files
into KH3, KH4 and KH6. The engine fixes it found that are independent of keys (seed 88, failed
quarantine) land on `main` separately, as the #57 agent is already doing.

### 13.2 The review findings

| Finding | Fate |
| --- | --- |
| **seed 88**: a revision uploaded while its blob's upload failed, so the attachment ends only in quarantine | **still applies.** It is an engine ordering bug (format.md §8.1.4 step 4 on the remote side), not a key-change one. It is being fixed on `main` separately and stays a regression test (§11.1). One trigger disappears: removals no longer rename blobs |
| **device-id spoofing** bypasses R3's "own" check | **disappears.** Provenance is the device-local ledger of exact bytes. Names and ids decide nothing (§5.3, §5.4, J3) |
| **durable owed rotation** (lost at a crash or ledger repair) | **disappears.** There is no owed state: a removal is complete when `vault.json` is written (§5.2), and additions never drop keys |
| **quarantine failure** ignored | **still applies**, to the set-aside store: a copy is durable aside before anything is replaced or removed, and a failure stops it (§5.8, J6). Fixed on `main` separately |
| **shared device ids** (two installs with one id) | **disappears.** The id is the key's fingerprint, the key is this-device-only, and a restored install has no key and joins as a new device (§3, §6.1) |
| **clock issues** (window ends, `changedAt`, slack) | **gone** with immediate changes: no rule reads a clock |
| late-file window without a real-time end; R3 laundering; I1/I6 vacuous | gone, gone, and replaced by J1 to J9 with required failing mutations |
| leftover claims block forever | changes: claims exist only for re-encryption, with P4a's stale-claim removal |

### 13.3 device-first-sync.md

§6 (the F1 to F19 review) applies only to re-encryption from now on: rows F4, F7, F9, F10, F17, F18
and F19 are replaced by §5 here, while F1 to F3, F5, F6, F11 to F16 apply to §7 with "change" read as
"re-encryption". In §10, P4a is replaced by KH1 to KH4 (with KH6 for its rewrite machinery); P4 keeps
`keys/`, `inbox/` and `summaries/<device>` sync but not rewrap-replace; P10 is replaced by KH5. That
document's status and §10 get a pointer here in this PR.

## 14. Alternatives considered

- **A symmetric vault key in a custom stanza** (`-> sempere-vk <id>` sealing the file key with
  ChaCha20-Poly1305). Smaller headers (about 100 bytes), but stock `age` cannot read any file.
  Rejected (the stock-recovery rule).
- **The vault key as an scrypt passphrase** (the only symmetric stanza age has). It works with stock
  `age`, but each file needs the key typed and an scrypt run. Rejected.
- **File keys derived from the vault key and the file name** (no stanza at all). This breaks age
  entirely. Rejected.
- **Per-device signatures on epoch changes** instead of links derived from the old key. They do not
  help against the main threat (a removed device was on the old list, so its signature verifies), and
  they add a signing key per device. Rejected for now. The epoch record's `by` is informational.
- **An epoch hint in each file** (an extra stanza or a name field), to avoid trying older keys. It
  would tell storage which files predate a removal, and the saving is one decapsulation per epoch on
  failure. Rejected.
- **Automatic fork merging.** It converges without the user, but it would accept a removed device's
  forged fork. Rejected (§5.6).

## 15. Decisions and "Revisit later"

Each item was decided by its recommendation: **Decided (recommended, owner pre-approved
2026-10-20).**

| # | Question | Decision |
| --- | --- | --- |
| K1 | Wrap or derive the file key? | Wrap: a fresh age file key per file, in one stanza to the vault identity, whose seed is the vault key (§2.1) |
| K2 | Secure Enclave? | Not now: CryptoKit has enclave ML-KEM-768 and P-256 but no X-Wing and no hybrid HPKE; software X-Wing keys in this-device-only Keychain items (§6.1) |
| K3 | Passphrase KDF and parameters | scrypt stays; writer work factor 20; minimum about 70 bits with no override; superseded copies deleted (§8.2) |
| K4 | Forks of two removals | The user combines them; the merge key is derived so combiners converge (§5.6) |
| K5 | Join verification | Six BIP-39 words (66 bits) or a QR scan of the new device's key (§6.2) |
| K6 | Device names | Plaintext as today, now authenticated by `listTag` (§3) |
| K7 | Set-aside files | Never deleted automatically; "Clear superseded" is one user action (§5.8) |
| K8 | Sealed set contents | Path and SHA-256 of the exact bytes of every file under the old key (§5.2) |
| K9 | #57 | Not merged; carried-over parts move into KH3, KH4 and KH6 (§13.1) |

**Revisit later** (irreversible or user-visible):

1. **The recovery kit's printed steps** (§8.1). Paper cannot be updated, so the script must be final
   before the first kit a user prints from a release build. Freeze it with KH2's CI test.
2. **Secure Enclave device keys** (§6.1), once CryptoKit (or swift-crypto) offers the
   MLKEM768-P256 HPKE KEM for enclave keys. This is a new key type for new joins only; no file
   changes.
3. **Plaintext device names** in `vault.json` (§3). They could move into an encrypted record if the
   owner wants storage not to see them; doing that later changes only `vault.json`.
