# Key hierarchy: vault keys, device keys and one recovery key (design)

Status: **design, 2026-10-20, revised after an independent review (§16).** It follows the owner's
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
  the Secure Enclave on Apple devices). It signs every `vault.json` and epoch record the device
  writes. Its public keys are in the device's entry.
- **Forks are never merged.** When two epochs share a parent, fixed rules keep one, and the user is
  told. A fork whose author the other fork removed is never kept. The changes of an honest
  discarded fork are re-applied on top as a new removal, with a fresh key. A removed device can
  therefore never get a key admitted, nor get its files sealed, through a fork (§5.6).
- **Joining is verified both ways.** The kit prints the vault's **root fingerprint**, and every
  chain is checked from it. An approval join exchanges typed codes in both directions (§6).
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
| epoch record | `epochs/<e>-<idprefix>.epoch.age`: the parent key, the sealed set, the link chain, the author's signature |
| fork | two epochs with the same parent epoch (§5.6) |
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
  "epochRecord": "epochs/3-5b0e6f1a2c3d4e5f.epoch.age",
  "epochRecordHash": "…(64 hex digits)…",
  "keys": [
    { "role": "device", "key": "age1pq1…(1959 characters)…", "id": "a1b2c3d4",
      "sign": { "p256": "…(130 hex)…", "mldsa65": "…(3904 hex)…" },
      "name": "Alex's iPad", "kind": "ipad", "added": "2026-10-04T16:20:00Z", "addedBy": "e5f6a7b8",
      "wrap": "-----BEGIN AGE ENCRYPTED FILE-----\n…\n-----END AGE ENCRYPTED FILE-----\n" },
    { "role": "recovery", "key": "age1pq1…", "name": "Recovery kit", "added": "2026-10-04T16:20:00Z",
      "wrap": "-----BEGIN AGE ENCRYPTED FILE-----\n…" }
  ],
  "listTag": "…(64 hex digits)…",
  "epochLink": { "ed25519": "…(128 hex)…", "mldsa65": "…(6618 hex)…" },
  "markersTag": "…(64 hex digits)…",
  "author": "a1b2c3d4",
  "authorSig": { "p256": "…(128 hex)…", "mldsa65": "…(6618 hex)…" }
}
```

- `root`: the root fingerprint (§4.2). It never changes.
- `epoch` is a decimal integer, at least 1. `epochRecord` and `epochRecordHash` name the epoch's
  record and its SHA-256 (§5.2). Epoch 1 has a record too, with no parent and an empty sealed set,
  so every epoch looks the same.
- `keys`: exactly one entry with `role: "recovery"`, and any number of `role: "device"`. Every key is
  MLKEM768-X25519 (`age1pq1`), as format.md §2 requires today. §6.1 leaves room for a later hardware
  type.
- `sign` (devices only): the device's signing public keys (§4.1), uncompressed P-256 (65 bytes) and
  ML-DSA-65 (1952 bytes), lowercase hex.
- `id`: the first 8 hex digits of `SHA-256(key)` (the fingerprint of format.md §11.1). It is the
  `<device>` of revision names (§5) and of `summaries/<device>.sealed` (§12.5). **Ids are for file
  names and the interface only**: no security decision reads one (§5.3, §5.4). A join is refused if
  the id equals that of any key listed now or in the chain's history, and the joining device then
  generates another key. Eight hex digits keep file names as they are; within one vault's few dozen
  keys, a collision is about one in 10^7, and the join check catches it.
- `name` (at most 40 characters, cleaned as `label` in §2), `kind` (`ipad`, `iphone`, `mac`, `cli`,
  or another lowercase word) and `added` are shown in the device list. They are plaintext, so
  storage can read them, as today (docs/security.md "What others can see"). Unlike today, they are
  covered by `listTag`, so storage cannot rename a device to mislead the user. `addedBy` is the
  approving device's id, or `recovery`.
- `wrap`: an armored age file to `key` (one stanza) whose plaintext is an age identity file:

  ```
  # sempere vault key: vault 0d1c6a1e-…, epoch 3
  # sempere-epoch-key: …(64 hex digits of K_e)…
  AGE-SECRET-KEY-PQ-1…
  ```

  `age -i` reads this file as it is (lines starting with `#` are comments), so
  `age -d -i recovery.txt wrap.age > vault-keys.txt` gives a usable identity file. Sempere reads
  `K_e` from the second line and refuses the wrap unless the identity equals `V_e` derived from it.
- `author`, `authorSig`: the id of the device that wrote this `vault.json`, and its signatures
  (§4.1). A `vault.json` whose signature does not verify under the `sign` keys of an entry listed in
  that file, or (for a change of list) in the parent epoch's list, is tampered.
- Removed: `recipients`, `vaultSecret`, `recipientsTag`, `secretLink`, `rewrapPending`.
  `rewrap-journal.json` is gone too, except for the re-encryption journal of §7.
- `features` and `markersTag` stay as in format.md §2 and §2.1.

## 4. Authenticity

| Today (format.md) | Role | Replaced by |
| --- | --- | --- |
| `vaultSecret` (§2) | keys every tag and name, and is wrapped to all recipients | `K_e`, wrapped per key. Derived keys as in §2.2 |
| `recipientsTag` (§2.1) | the list under the secret | `listTag` = HMAC-SHA256(`listKey`, `"sempere/1" ‖ 0 ‖ "list" ‖ 0 ‖ vaultId ‖ 0 ‖ root ‖ 0 ‖ epoch ‖ 0 ‖ epochRecordHash` ‖ for each entry in list order: `0 ‖ role ‖ 0 ‖ key ‖ 0 ‖ id ‖ 0 ‖ sign.p256 ‖ 0 ‖ sign.mldsa65 ‖ 0 ‖ name ‖ 0 ‖ kind ‖ 0 ‖ added ‖ 0 ‖ addedBy ‖ 0 ‖ SHA-256(wrap)`). It covers names, signing keys and each wrap's digest, so a swapped wrap is detected by every device, not only by the one it was made for |
| `secretLink` (§2.1) | links a new secret to the one a device verified | `epochLink`: Ed25519 and ML-DSA-65 signatures by the keys derived from `K_{e-1}`, over `"sempere/1" ‖ 0 ‖ "epoch link" ‖ 0 ‖ vaultId ‖ 0 ‖ e ‖ 0 ‖ epochId(K_e)`. The derivation, encoding and both-must-verify rule are today's (so are the test vectors, re-labeled) |
| (none) | who made a change | `authorSig` on `vault.json` and on each epoch record (§4.1) |
| (none) | which vault this is, before any key | `root` (§4.2), printed on the kit |
| `markersTag` | `format` and `features` | unchanged, under `markersKey` of `K_e` |
| body tag (§4), blob name (§8.1.2) | file authenticity | the same constructions, keyed by `tagKey` and `blobNameKey` of the epoch the file was written in |
| `rewrapPending` + `rewrapFinished` (§3.3.1) | bind and retire a rewrap journal | the same mechanism, renamed `reencryptPending`, used only by §7 |
| trust record `sempere-trust/2` | the last verified secret, list and markers | `sempere-trust/3`: vault id, `root`, `epoch`, `epochId`, the link public keys of that epoch, the list (keys, signing keys, names), markers, and `reencryptFinished` |

### 4.1 Device signing pairs and authorship

Each device generates, next to its device key, a **P-256 ECDSA** pair and an **ML-DSA-65** pair. On
Apple devices both live in the Secure Enclave (`SecureEnclave.P256.Signing` and
`SecureEnclave.MLDSA65`, CryptoKit, iOS and macOS 26; verified against Apple's documentation on
2026-10-20), with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The CLI keeps them in software next
to its device key (§6.1). Two schemes, as for links, so a signature stays unforgeable while either
holds.

The device signs, with both, `SHA-256("sempere/1" ‖ 0 ‖ "author" ‖ 0 ‖ kind ‖ 0 ‖ bytes)`, where
`kind` is `vault.json` (and `bytes` is the canonical JSON of the file without `authorSig`: sorted keys,
no whitespace) or `epoch` (and `bytes` is the epoch record's plaintext before the signature field,
§5.2). Both signatures must verify. The signer must be a device entry of:

- the same `vault.json`, for a change within an epoch (an addition, a rename, a markers change);
- the **parent** epoch's list, for a new epoch (the remover is in the list it changes).

Authorship decides only one thing: which fork is kept (§5.6). Everything else (what a file is, who may
read) is decided by keys and sealed sets, as before. Signatures by a key holder who is not the
author's device are impossible, since the private signing keys never leave their device.

### 4.2 The root fingerprint

`root = SHA-256("sempere/1" ‖ 0 ‖ "root" ‖ 0 ‖ vaultId ‖ 0 ‖ ed25519 ‖ mldsa65)`, over epoch 1's link
public keys (32 + 1952 bytes). It never changes, because the link chain always starts at epoch 1
(§5.2 `chain`). The kit prints it as 16 groups of 4 hex digits, each with the kit's line checksum
(DESIGN.md "Recovery"), and in the kit's second QR code (`sempere-root:<vaultId>:<hex>`). A chain is
**rooted** when its epoch 1 entry hashes to the root the device trusts, and every later link verifies.

### 4.3 Checking `vault.json` (replaces format.md §2.1 "Checking")

A device unwraps its own entry. If the result does not parse, or the identity is not the one derived
from `K_e`, its wrap was tampered with. Then:

1. **Same epoch and `epochId` as the trust record**, `listTag` and `authorSig` verify: **verified**. A
   list that only gained entries under the same epoch is an addition. A list that lost entries under
   the same epoch is **tampered**: a removal always changes the epoch (§5).
2. **A higher epoch.**
   - If the record is local: the device opens it with the unwrapped key and reads its `chain` (§5.2).
     It finds its pinned epoch there, then checks each later link under the previous entry's public
     keys, up to `vault.json`'s own `epochLink`, and each record's `authorSig`. The first link after
     the pinned epoch can only be made by a holder of the pinned key, so a `vault.json` built around an
     attacker's key fails here.
   - If the record has not arrived: the change is taken only when `epochLink` verifies **directly**
     under the pinned epoch's link keys (the epoch is one above the pinned one) and `authorSig`
     verifies under a key of the pinned list. Otherwise the new epoch is **unverified-pending**: the
     device keeps reading, keeps writing locally under its pinned key, uploads nothing new, and pulls
     again. Writes made meanwhile are in its ledger and are caught up (§5.4) once the epoch verifies.
   - Then fork resolution (§5.6) applies against every other epoch with the same parent that the
     device has seen.
3. **A lower epoch**, or the same epoch with another `epochId`: a fork (§5.6) when it chains from an
   epoch the device holds, otherwise a rollback: tampering. Nothing is written, and the device keeps
   its own `vault.json`.
4. **No trust record** (a joining device): the chain must be rooted at the root the user supplied
   (kit QR or typed groups, or the reverse code of an approval, §6.2). A join without a root is
   refused in the app. The CLI's read-only `--recovery-key` mode warns and reads (it writes nothing).
5. **No entry for this device**, with a chain that verifies: the device is **unlisted**, which is
   not yet "removed" (§5.5).

## 5. Changes to the list

### 5.1 Adding a device

An approving device (or the joining device itself, with the recovery key, §6.3) appends an entry
with a wrap of the current `K_e`, rewrites `listTag` and signs. No file is touched and the epoch does
not change. Concurrent additions under one epoch merge as a union: two `vault.json` with the same
epoch and `epochId` whose lists differ only by entries one side has and the other lacks (each entry
added by a device of that list) are merged by any listed device into the union, sorted by `key`, and
signed by it. An addition never drops a key, so there is no "owed rotation".

Each approving device records its approvals in its ledger until it sees them in the current list. If
a removal epoch overtakes an addition (B adds N at `e` while A removes X at `e+1`), B re-applies the
addition on top. Only the approver re-applies, and only while it is listed: an addition approved by
a device that has since been removed is never re-applied.

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
3. **New key and sealed set**: `K_{e+1}` = 32 random bytes. For every file in A's working copy that is
   accepted under `K_e` (or under an older key by §5.3): its path and the SHA-256 of its exact bytes.
   That covers revisions, blobs, notebook records, `inbox/` files and `settings.age`. Files set aside
   or pending are not included.
4. **Epoch record**, written under a hidden name (`.sempere-tmp-…`, format.md §1.1), so that no sync
   sees it before step 5. Its final name is `epochs/<e+1>-<first 16 hex of epochId>.epoch.age`. It is
   an age file to `v_{e+1}`, body-framed as format.md §4 with the label `epochs` and the final file
   name, tagged under `tagKey` of `K_{e+1}`:

   ```json
   { "format": "sempere-epoch/1", "vaultId": "…", "root": "…", "epoch": 4,
     "parent": { "epoch": 3, "epochId": "…", "key": "…(64 hex: K_3)…",
                 "identity": "AGE-SECRET-KEY-PQ-1…",
                 "sealed": { "notes/<id>/<name>.delta.age": "<sha256 hex>", … } },
     "chain": [ { "epoch": 1, "epochId": "…", "linkPublicKeys": { "ed25519": "…", "mldsa65": "…" } },
                { "epoch": 2, "epochId": "…", "linkPublicKeys": { … }, "link": { … } },
                { "epoch": 3, "epochId": "…", "linkPublicKeys": { … }, "link": { … } } ],
     "created": "2026-10-20T16:20:00Z", "by": "a1b2c3d4",
     "reason": "remove", "removed": ["<fingerprint>", …], "added": [],
     "authorSig": { "p256": "…", "mldsa65": "…" } }
   ```

   `chain` holds only public values (about 5.3 KB per epoch), so that a device that missed several
   epochs can check every link (§4.3) after re-encryption has deleted the older records. `reason` is
   `create`, `remove`, `recovery` (replacing the kit), `reencrypt` or `reapply` (§5.6). It and
   `removed`, `added` are shown in the device history. `authorSig` covers everything before it.
5. **`vault.json`** with `epoch = e+1`, the record's final name and hash, a wrap of `K_{e+1}` to every
   remaining key, `listTag`, `epochLink`, `markersTag` and `authorSig`, in one atomic write; then the
   record is renamed to its final name. **From this write on, A encrypts and tags every new file under
   `K_{e+1}`.** At open, a hidden record that the local `vault.json` names is renamed into place (a
   crash between the two writes), and one that it does not name is deleted (a crash before step 5:
   nothing changed).
6. **Caches and profiles**: per-epoch caches start empty (format.md §10). Capture profiles are
   refreshed at the next unlock (§5.7).

There is no journal, no rewrite pass, no late-file window and no clock. Propagation is ordinary sync
of two new files. Any device that holds a record a target lacks uploads it (write-once union), so a
withheld record comes back.

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

1. stops writing under the old key. Its next write is under the new one (J5, §11.2);
2. for every ledger entry of an epoch `j` below the current one whose path is not sealed with that
   digest by the record whose `parent` is `j` (on the kept chain), **re-encrypts the file under the
   current key**: the same body (`gzip(JSON)`, blob content, inbox payload), a new file key and a tag
   under the new key. Revisions, notebook records and inbox files keep their names. A blob is
   renamed under the new `blobNameKey`, and its old name stays until GC;
3. replaces its local file with the re-encrypted copy only after the copy decrypts and its body
   equals the old one, then records the new entry;
4. uploads normally. On a target, a current copy replaces an **unaccepted** copy of the same path (an
   old-key copy that is not sealed), after the receiver has set the old one aside. This is the one
   replacement rule of the engine outside §7, and it never replaces an accepted file.

Files written under an old key by another listed device D that C holds are set aside on C until D
catches up; D's current copy then arrives and is accepted, and C's set-aside copy is marked
superseded (§5.8).

### 5.5 Unlisted and removed devices

A device X that finds itself **unlisted** (§4.3 step 5):

1. **never pins** an epoch that does not list it, and keeps its own `vault.json`;
2. stops uploading, but **keeps pulling** `vault.json` (every version and conflict copy the target
   offers) and `epochs/`, read-only;
3. checks every fork of that epoch (§5.6). If the kept fork lists X, X is not removed: it takes that
   fork and resumes. If every fork that verifies omits X, and resolution keeps one of them, X is
   **removed**.

A removed device:

- shows **"This device was removed from <vault> by <name> on <date>"**, with the count of its own
  changes that no other device has: ledger entries not sealed and not on any target as accepted
  files;
- offers **Export changes** (the notes those entries touch, as a copy of the vault with only them, or
  as PDFs, through the existing export paths), **Keep as a separate vault** (a copy re-created with
  new keys, as an import), and **Remove from this device**;
- refuses every write to the vault (`VaultError.removedFromVault`, CLI exit code 8);
- keeps pulling `vault.json` at the idle pace, so a removal that a later fork resolution reverses is
  noticed ("Check again" does it at once).

A forged removal needs a signed epoch from a device of the parent list and a link under the parent
key. Fork resolution (§5.6) discards it as soon as the real change is seen, and the unlisted state
above never acts on it alone.

**Removing a device warns when its last sync is stale.** Each device's published summaries file
(`summaries/<id>.sealed`, format.md §12.5) gains a `synced` timestamp (the end of its last complete
two-way run), authenticated under the current epoch. The sheet shows "Alex's iPhone last synced 12
days ago. Changes it made since then will not reach this vault. It will be told it was removed, and
can export them." It also says what the key change cannot do: **"It can still reach your storage. Change
the password of <WebDAV target>, or sign it out of iCloud, if you no longer control it."**

### 5.6 Forks: never merged

Two devices that each change the list while they cannot see each other create two epochs with the
same parent (fork *a* by A, fork *b* by B). Their records do not collide (the names carry the id), and
`vault.json` conflicts (format.md §1.3). **Forks are never merged and no key is derived from two
forks.** Every device applies the same rules to the forks it has seen, in order:

1. **Validity.** A fork counts only if its link verifies under the parent key and its `authorSig`
   verifies under a device of the parent list.
2. **A removed author loses.** A fork whose author's key the other fork removed is **never kept**.
   This discards any fork a removed device made for itself after its removal was written elsewhere.
3. **Both authors removed by the other** (A removed X, and X's fork removed A): no rule can tell which
   device the user still has. A device listed in both asks: "iPad removed Phone, and Phone removed
   iPad at the same time. Which device do you still have?" Until the user answers, that device treats
   both as unverified-pending (§4.3): it writes locally under its pinned key and uploads nothing new.
   A and X each keep their own fork (rule 1 of §5.5: neither pins an epoch that removed it).
4. **Otherwise** (honest concurrent changes): keep the fork with the smaller `epochId`, and tell the
   user ("Two device changes were made at the same time; the one from Mac was applied first").
5. **Re-apply** the discarded fork's changes, unless rule 2 or 3 discarded it: the first listed device
   that sees both writes a new removal epoch on top of the kept fork (`reason: "reapply"`, a fresh
   random key) that removes every key the discarded fork removed, and adds the keys it added (these
   additions are safe because rule 2 did not apply: their author is still listed). If two devices do
   this at once, rules 1 to 4 apply to the two re-applications, which make the same list, so the
   discarded one changes nothing and the process ends.

What happens to files:

- The discarded fork's record is set aside (kept for the history view). Files under its key are not
  accepted: they are set aside on every device.
- The honest writers of the discarded fork (A, if B's fork is kept) catch up from their own ledgers
  into the kept chain (§5.4): their files come back under the current key, and nothing of theirs is
  lost.
- A removed device's files never become accepted through a fork: its fork is discarded by rule 2 or
  3, and its sealed set with it.

Why the rules are safe (J10, §11.2): every key of every kept epoch is wrapped only to that epoch's
list and appears only in records of its descendants. A coalition of removed devices holds exactly the
keys of the epochs that listed one of its members, never a key derived from two forks.

Residual: a device that has seen **neither** the real removal **nor** anything after it, and is shown
only a fork that a removed device made (a valid signature by that device, from the parent epoch), takes
it and writes under its key until the real change reaches it. Rule 2 then discards the fork and the
device catches up, but what it wrote meanwhile was readable to the removed device. This is today's limit
(format.md §2.1 "Limits"), narrowed: the removed device has to make and serve the fork before that
device sees the real change.

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
  are Secure Enclave keys (§4.1).
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
  signing pairs in `$XDG_STATE_HOME/sempere/devices/<vaultId>/` (mode 0600 in a 0700 folder;
  optionally passphrase-wrapped with `--passphrase`), then joins (§6.2). Read-only recovery with the
  recovery key alone (`--recovery-key FILE [--root HEX]`) needs no join and writes nothing.

### 6.2 Joining by approval

1. **New device N** opens the vault from a target ("Open Vault…", device-first-sync.md §8.1),
   generates its keys, and writes a join request `joins/<id>.join.json` to the targets it can reach:

   ```json
   { "format": "sempere-join/1", "vaultId": "…", "key": "age1pq1…",
     "sign": { "p256": "…", "mldsa65": "…" }, "name": "Alex's iPhone", "kind": "iphone",
     "created": "2026-10-20T16:20:00Z" }
   ```

   Readers bound the file at 16 KiB and treat it as untrusted input (format.md §9); a name is
   cleaned as in §3. N shows its **six words**: the first 66 bits of
   `SHA-256("sempere/1 join" ‖ 0 ‖ vaultId ‖ 0 ‖ key ‖ 0 ‖ sign.p256 ‖ 0 ‖ sign.mldsa65)` in the
   BIP-39 English word list, and a QR code of the request (about 3.2 KB, a version 40 code at level L;
   the words are the fallback where a camera is not available).
2. **An existing device E** shows "New device wants to join: <name>". The user either scans N's QR
   code or **types** N's six words on E (typing, not comparing, so a near match cannot be waved
   through). E checks them against the request. A mismatch means the request was replaced on the way,
   and E refuses it. A second preimage (a storage attacker's own key with the same words) costs about
   2^66 key generations.
3. E adds N's entry (§5.1), deletes the request, and shows its **reverse code**: six words of
   `SHA-256("sempere/1 join reply" ‖ 0 ‖ vaultId ‖ 0 ‖ key_N ‖ 0 ‖ root)`, and a QR code of
   `(vaultId, root)`.
4. N sees its wrap and unwraps it. Before pinning anything, it asks the user to **type** E's six words
   (or scan E's QR code), computes them from the root of the chain it was given, and refuses the vault
   on a mismatch. A storage provider that served N a fake vault cannot produce a chain rooted at the
   real root, so N never writes to a vault that is not the real one.

Requests older than 7 days, and those of keys already listed, are deleted by any listed device.

### 6.3 Joining with the recovery kit or the passphrase

N scans the kit's two QR codes (key and root), or the user types the key and the root groups with
their line checksums, or enters the passphrase of `keys/recovery-<fingerprint>.key.age` together with
the root from the kit. N unwraps the recovery entry, checks that the chain is rooted at that root
(§4.3 step 4), adds its own entry with `addedBy: "recovery"`, signs, and drops the recovery identity
from memory. The recovery key is never stored on a device.

**Every listed device alerts on a kit join**, as a notification and a banner that stays until it is
dismissed: "A device joined <vault> with the recovery kit: <name>, <date>. If this was not you,
remove it, then replace the recovery kit." The device list marks such devices (§6.4).

### 6.4 The device list (Settings ▸ Vault ▸ Devices)

| Row | Shows |
| --- | --- |
| each device | name (editable by any listed device: a list change under the same epoch), kind icon, "This device", added on and by whom ("with the recovery kit" in bold), "Last synced 3 hours ago" (§5.5) |
| recovery kit | "Recovery kit, created <date>", **Replace Recovery Kit** (§6.5; there is no "print again", since no device holds the recovery key), and the passphrase copy's state |
| actions | **Add Device** (how to join from the new device, and pending requests), **Remove** per device (§5.2, with the warnings of §5.5), **Re-encrypt Everything…** (§7) |
| history | every epoch record's `reason`, author and date: "Old Mac removed by iPad on 20 Oct"; discarded forks too |

The CLI mirrors it: `sempere devices list|approve|remove|rename [--json]`,
`sempere recovery replace|passphrase`, `sempere vault reencrypt`.

### 6.5 Replacing the recovery kit

The kit is shown once, at creation, and never stored, so it cannot be printed again. **Replace
Recovery Kit**:

1. **lists every device** and highlights each one that joined with the recovery kit since the
   current kit was created. The user must **confirm or remove** each listed device before going on.
   A kit finder who joined quietly is therefore either removed in this change or kept by the user's
   explicit choice;
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
   The earlier keys go into the journal instead: `reencrypt-journal.age`, an age file to `v_m`,
   body-framed and tagged under `K_m`, holding every earlier epoch key on the kept chain (needed to
   read and verify old files during the pass). `vault.json` binds it with `reencryptPending` (P4a's
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
   both copies verify, equal bodies, exactly one current copy, which wins); (c) once A's sync state
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
  decides. If the re-encryption fork is kept, the removal is re-applied on top (§5.6 rule 5) and the
  pass goes on. If the removal fork is kept (rule 4, or rule 2 when the initiator was removed), the
  re-encryption epoch is discarded and its journal refused. Its initiator, if still listed, reports
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

## 8. The recovery key, the passphrase copy and stock `age`

### 8.1 Stock `age` recovery: kept, with one step more

The property is kept: with the kit, stock `age` 1.3+ and `jq`, `tail`, `gunzip`, every file opens.
What changes is that the kit's key opens the vault key first, and older epochs need one more `age
-d` each. The kit prints this script (POSIX sh, tested in CI against the reference `age`, like today's
pipeline):

```sh
# 0. Only if you use the passphrase copy instead of the printed key:
#    age -d keys/recovery-<fingerprint>.key.age > recovery.txt
# 1. The current vault key, from the recovery entry.
jq -r '.keys[] | select(.role == "recovery") | .wrap' vault.json \
  | age -d -i recovery.txt > vault-keys.txt
# 2. Earlier vault keys (only after a device change): newest record first.
for f in $(ls epochs | sort -t- -k1,1nr); do
  age -d -i vault-keys.txt "epochs/$f" | tail -c +38 | gunzip \
    | jq -r '.parent.identity // empty' > prev.txt
  cat prev.txt >> vault-keys.txt
done
# 3. Any note, as before.
age -d -i vault-keys.txt notes/ID/NAME.delta.age | tail -c +38 | gunzip | jq .
```

A record that does not open (a discarded fork) only prints an error and adds nothing. While a
re-encryption is unfinished (§7), the earlier keys are in `reencrypt-journal.age` instead of the
records, and the kit adds the same three commands for that file. The note and blob pipelines of
format.md §4 and §8.1.7 are unchanged except for `-i vault-keys.txt`. CLAUDE.md's "Keep the stock-CLI
recovery path working" rule is updated in KH1 to this script.

### 8.2 The passphrase copy

`keys/recovery-<fingerprint>.key.age`: the recovery identity, age-encrypted with one scrypt stanza
(format.md §3.2's file, renamed). It is optional and it wraps only the recovery key: device keys are
never passphrase-wrapped into the vault.

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

- `vault.json`: about 8.5 KB per device (the 1,959-character recipient, an armored one-stanza wrap
  of about 2.5 KB, and 4 KB of signing keys in hex), plus about 7 KB of `authorSig` and 7 KB of
  `epochLink`. 4 devices and the kit come to about 50 KB, against about 15 KB today. It changes
  rarely.
- Epoch records: about 100 bytes per sealed file after gzip (path plus SHA-256), plus 5.3 KB per
  epoch of chain. A removal in a 20,000-file vault writes a record of about 2 MB, once.

### 9.3 What `epochs/` and `joins/` show to storage

Storage sees how many list changes there were, when, and roughly how many files each sealed (from
the record's size). It does not see who was removed (that is inside the record). Join requests are
plaintext: they show a new device's public keys, name and kind, as `vault.json` does once it joins.

## 10. Threats

| Threat | What the attacker gets | What stops the rest | Residual |
| --- | --- | --- | --- |
| **Stolen device** (locked) | the encrypted working copy; the device key only if the passcode or Face ID is broken | Keychain this-device-only; signing keys in the Secure Enclave; "Require Face ID" option; remove it from another device: a new epoch at once | if unlocked by the thief: everything up to the removal. Files from before stay readable to it (old keys) unless §7 is run and the thief has no copy |
| **Removed device with modified software** (alone or with other removed devices) | the keys of the epochs that listed it; its working copy | §5.3: anything it writes after the change is set aside on every device (J3); it cannot unwrap a later key (J2); a fork it makes is discarded by §5.6 rule 2 or 3, and never merged (J10) | a device that has seen neither the real removal nor anything later can be shown its fork first (§5.6 "Residual"); it can plant join requests (refused without the typed words) |
| **Removed device's storage credentials** | write access to the targets it was given | removal changes no file it can read later; the sheet tells the user to change the target's password (§5.5); every working copy is complete, so a file it deletes from a target is restored (not an explained deletion) | until the password changes, it can delete or withhold files on a target (denial of service), and see metadata |
| **Hostile storage provider** | metadata (security.md, §9.3); every ciphertext | tags, names, `listTag`, author signatures; trust record pins the epoch (rollbacks refused); records bound by hash; joins rooted at the printed root and checked both ways (§6.2, §6.3); §9.1 checks | it can withhold files or records (they stay pending, never accepted or deleted) and delete things (devices re-upload) |
| **Lost recovery kit** | whoever finds it can unwrap the key of any epoch the kit was listed in, from any copy of `vault.json`, and can join a device | every device alerts on a kit join (§6.3); Replace Recovery Kit and Re-encrypt list kit-joined devices and require confirming or removing them (§6.5); Replace: nothing written after opens with it; Re-encrypt: nothing in the vault opens with it | backups, provider history and copies made before still open |
| **Leaked passphrase copy** (file and passphrase) | the recovery key: the same as a lost kit | 70-bit minimum and work factor 20 make offline guessing infeasible for a strong passphrase; the copy is deleted when superseded | a weak passphrase reused elsewhere; backups keep old copies |
| **Quantum adversary harvesting now** | ciphertexts and `vault.json` | every public-key encryption step is X-Wing (ML-KEM-768 + X25519); links and authorship are each classical + ML-DSA-65; the rest is 256-bit symmetric | the passphrase copy is as strong as the passphrase (§8.2). A future break of ML-KEM-768 *and* X25519 would expose everything, as today |

## 11. Tests

### 11.1 Fault injection and scenarios

- **`EpochFaults`** (core, test-only, the pattern of P4a's `RewrapFaults`): crash after the hidden
  record (step 4), between `vault.json` and the record's rename (step 5), after the ledger intent and
  before the file is placed; during catch-up after file n (re-encrypted copy written, not verified;
  verified, not renamed; renamed, ledger not updated); in re-encryption after file n at each of those
  points, before the old blob name is deleted, before the journal is removed. After every crash:
  reopen, resume, check J1 to J10.
- **Engine faults** (`MemoryRemote` faults, the WebDAV mock, wsgidav behind `dav-fault-proxy.py`):
  `vault.json` arrives before its record (directly linked: taken, old files pending; two epochs above:
  unverified-pending, no uploads); a withheld record (re-uploaded by another device); a cut upload of a
  re-encrypted file (old or new complete copy, never a mix); a target without strong ETags (nothing
  replaced, reported: P4a's `weakStamps`); **a set-aside write that fails** (disk full, permission):
  the replacement does not happen and the original stays; the remover's best-effort pull with one
  target unreachable.
- **Scenarios** (`EpochScenarioTests`, one test each):
  - catch-up: an offline listed device catches up revisions, blobs, inbox, settings and notebook
    records; **C2**: B uploads, A (not synced down from that target) removes X, and B's files come back
    from B's ledger; locked widget captures appended to the ledger, caught up at unlock; a same-device
    restore and a restore onto another device;
  - removed devices: X writes after the change; a stale removal shows the warning and the password
    advice; the unlisted device keeps pulling and resumes when the fork that listed it is kept;
  - list changes: concurrent additions (union); an addition overtaken by a removal (re-applied by its
    approver only);
  - forks: two honest removals (rule 4 and re-application, including two re-appliers at once); **C1**:
    removed X forges a fork from `K_e` that adds a key of its own and seals its files (discarded by
    rule 2, nothing of it accepted, its key never wrapped); **H1**: two removed devices, removed from
    different devices, both fork (no kept epoch's key derivable by them); **H2**: X's fork removes
    everyone else (discarded); a forged fork omitting C, seen by C before the real change (C stays
    unlisted, not removed, and resumes); mutual removal (rule 3 asks, nothing uploaded meanwhile);
  - recovery: kit replacement with a kit-joined device highlighted, which the user removes; the
    alerts on every device after a kit join;
  - joins: by approval with typed words in both directions; a request replaced on the way (refused on
    E); **H3**: storage serves N a fake `vault.json` and chain (refused on N by the reverse code); with
    the kit and root; with the passphrase and root; a wrong root (refused);
  - storage: swaps a wrap, renames a device, rolls back `vault.json`, deletes an epoch record,
    re-serves a superseded passphrase copy (deleted again only under §8.2's rule), plants a malformed
    join request or epoch record (fuzzed readers, typed errors);
  - re-encryption: one device offline until after the finish; a crash and resume on another device; a
    removal during the pass; **M4**: a re-encryption fork against an offline removal, both outcomes;
  - blob collection: a blob referenced only by a set-aside or pending revision is not collected;
  - seed 88's blob-before-revision ordering, kept as an engine regression test.

### 11.2 Property test (`EpochInterleavingTests`, seeded, in `scripts/sync-stress.sh`)

Three to five devices, two targets, random edits with attachments and captures, adds, removals,
recovery replacements, re-encryptions, joins, offline periods, crashes at the fault points above,
locked runs, a hostile target that serves old copies or drops records, and **adversarial removed
devices**: after its removal, a device may keep writing under the keys it holds, make forks (alone
or with other removed devices), plant requests and delete from targets. The oracle records every
write: who wrote it, its epoch, and whether its writer had been removed at that moment.

| # | Invariant (checked after every step and at quiescence) | Mutation that must make it fail |
| --- | --- | --- |
| J1 | **No loss**: every body written by a device that is listed at quiescence is accepted on every listed device and target, or, while catch-up is pending, still in its writer's working copy and ledger | ledger pruned on upload (C2); the remover skips its pull and the writer's ledger is ignored |
| J2 | **Revocation**: for every coalition of removed devices, no file written after a member's removal was seen by its writer opens with any key the coalition holds | a writer keeps a cached `K_e` after taking `e+1`; a merge key derived from two forks |
| J3 | **No injection**: no body first written by a removed device after its removal is ever accepted by a listed device, for any coalition, unless the user chose Keep on that set-aside file (the oracle records it). No fork exemption | old-key files accepted without the sealed-set check; catch-up by device id instead of the ledger; a discarded fork's sealed set honored |
| J4 | **Convergence**: with faults off and two runs per device, all listed devices and targets hold the same kept chain, list and accepted file set | the fork tie-break by local arrival order instead of `epochId` |
| J5 | **Immediacy**: no device uploads a file under epoch `j` after it has verified a `vault.json` of an epoch above `j` | the capture profile not refreshed and not caught up |
| J6 | **Set aside is monotone**: nothing leaves the set-aside store without a user action, and every replaced or removed unaccepted file is in it first | set-aside write failure ignored |
| J7 | **Re-encryption completeness**: after a finish and quiescence, no file on a target or in a working copy opens with an epoch key from before the re-encryption or the old recovery key | old blob names never deleted; old epoch records kept |
| J8 | **Body integrity**: no path ever holds two different bodies in the vault | a re-encryption that replaces before verifying, with a crash between |
| J9 | **Liveness**: every re-encryption journal finishes or is reported within a bounded number of runs once targets are reachable, and every fork is resolved or put to the user | the "skip complete files" check inverted; re-application not written |
| J10 | **Key reach**: for every epoch on any device's kept chain and every coalition of removed devices, the principals able to derive that epoch's key are exactly the keys listed in it or in a later kept epoch (devices and recovery keys) | the discarded fork's additions re-applied when its author was removed (rule 2 skipped); a key wrapped to a device listed only in a discarded fork |

Each mutation is a test-only switch. `EpochMutationTests` runs every mutation for a few seeds and
requires it to fail, so no invariant is vacuous (P4a's round-1 finding). Quick mode: 3 seeds × 40
steps in `swift test`. Long mode: 100 seeds × 120 steps, one process per seed and also one process
for all seeds.

## 12. Phased plan

Sizes as in device-first-sync.md §10: S < 300 changed lines, M 300 to 1,000, L > 1,000.

| # | PR | Size | Depends on | Test gate |
| --- | --- | --- | --- | --- |
| **KH1** | **Key schedule, identities and format text.** Pure types and functions, no `Vault` wiring: `VaultEpochKey` (`K_e` → identity seed → vault identity, the §2.2 derivations), the wrap plaintext, the `vault.json` model with `keys[]`, `listTag`, `epochLink`, `root`, author signatures (P-256 + ML-DSA-65 over the canonical forms of §4.1), the epoch record model and chain check, fork rules 1 to 4 as a pure function, join codes, trust record v3. Shared vectors `Fixtures/epoch-vectors.json`: seed → identity → derived keys → tags, links, root fingerprint, device signatures, join and reply words, and **negative vectors** (a chain with a broken link, a wrong root, a signature by an unlisted key, a fork with a removed author), mirrored in `web/src/vault/`. format.md §2, §2.1, §3, §4, §8.1.2, §11.1 rewritten; the kit layout (with the root) and the recovery script frozen; CLAUDE.md's recovery rule updated | M | — | vectors from two implementations (Swift, TypeScript); `age` interop: a file to `v_e` opens with `age -d -i` the wrap's plaintext; enclave signatures verify in software (Mac test behind `#if canImport(CryptoKit)`); fuzz targets for the `vault.json`, epoch record and join request readers |
| KH2 | **Single-epoch vaults.** `Vault.create`/`open` on the new manifest: one stanza per file to `v_e`, tags and blob names under derived keys, recovery entry, passphrase copy of the recovery key (work factor 20, 70 bits), add device (wrap only, signed), CLI `devices list/approve/rename`, `device init`, `--recovery-key [--root]` read-only; old vault format removed (no migration); fixtures regenerated; web viewer reads the new format | L | KH1 | full `swift test`; the kit's recovery script in CI on a fixture; web goldens |
| KH3 | **Removal and the acceptance rule.** Epoch records (hidden then renamed), sealed sets, §5.2 under the write lock, §5.3, the set-aside store (moved from P4a's quarantine), the write ledger (intent first, lifetime, App Group, AfterFirstUnlock key), catch-up (§5.4), unlisted and removed states (§5.5), recovery kit replacement with the device review, blob-collection conditions (§5.7); CLI `devices remove`, `recovery replace` | L | KH2 | `EpochFaults` (core points), the scenarios that need no sync over in-process devices sharing a folder, J1, J2, J3, J5, J6, J8 |
| KH4 | **Engine.** Sync of `epochs/`, `joins/`, `keys/` deletions (§8.2's rule); the remover's best-effort pull; pending-until-record and unverified-pending; current-replaces-unaccepted (§5.4 step 4); forks (§5.6) with re-application; unlisted devices keep pulling; `synced` timestamps | L | KH3, P3 | engine faults, every scenario, `EpochInterleavingTests` J1 to J6, J8 and J10 with mutation checks; 60 seeds in sync-stress |
| KH5 | **App.** Device keys in the Keychain and signing pairs in the Secure Enclave, join by approval (typed words both ways, QR) and by kit or passphrase with the root, kit-join alerts, device list and history, removal with the stale and password warnings, the removed-device screen with Export, fork notices and the mutual-removal question, set-aside view in Repair, recovery kit replacement; delete remembered-key and key-replace UI | L | KH4, P5 | Mac Catalyst unit tests (gate); `scripts/app.sh test-mac-smoke` with the new sheets; owner device checks below |
| KH6 | **Re-encrypt everything.** §7 on P4a's coordinator, claims, journal binding, rewrap-replace and keyring; removals during the pass; forks against it; CLI `vault reencrypt [--resume]`, app sheet with the device review and progress | L | KH4 (app part: KH5) | `EpochFaults` re-encryption points, J7 and J9, the F11 cut-upload test over wsgidav, 60 seeds in sync-stress |
| (later) | Secure Enclave device keys (`mlkem768p256tag`), when CryptoKit offers that hybrid in HPKE | M | KH5 | Revisit later, §15 |

Critical path: KH1 → KH2 → KH3 → KH4 → KH5. KH6 follows KH4 alongside KH5. KH1 is pure functions,
vectors and text, so the cryptography (including the fork rules and the printed kit) is reviewed and
frozen before anything stores data under it, and KH2's writers and the web viewer port start from
its vectors.

Owner device checks that remain: join an iPhone by approval and an iPad by the kit; remove a device
while a third is in airplane mode with new notes, then reconnect it; a removed iPad's screen and
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
| **durable owed rotation** (lost at a crash or ledger repair) | **disappears.** There is no owed state: a removal is complete when `vault.json` is written (§5.2), and additions never drop keys. Re-application of a discarded fork (§5.6 rule 5) is recomputed by any listed device from the two records, so it needs no durable state either |
| **quarantine failure** ignored | **still applies**, to the set-aside store: a copy is durable aside before anything is replaced or removed, and a failure stops it (§5.8, J6). Fixed on `main` separately |
| **shared device ids** (two installs with one id) | **disappears.** The id is the key's fingerprint and the key is this-device-only. A same-device restore is the same device; a restore onto another device has no key and joins as a new device (§5.4 "Restores") |
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
  holder of the parent key made a change, which every removed device was. Rejected: rule 2 of §5.6
  needs to know which device made each fork.
- **An epoch hint in each file** (an extra stanza or a name field), to avoid trying older keys. It
  would tell storage which files predate a removal, and the saving is one decapsulation per epoch on
  failure. Rejected.
- **Trust on first use for joins** (the first draft). A provider could serve a joining device a vault
  of its own and read what it writes. Rejected: the root fingerprint and the reverse code (§6.2,
  §6.3).

## 15. Decisions and "Revisit later"

Each item was decided by its recommendation: **Decided (recommended, owner pre-approved
2026-10-20).** Items the review changed are marked **(revised after review)**; their recommendation
is again the decision.

| # | Question | Decision |
| --- | --- | --- |
| K1 | Wrap or derive the file key? | Wrap: a fresh age file key per file, in one stanza to the vault identity. **(revised after review)** The identity's seed is derived from the vault key by HKDF, not the key itself (§2.1) |
| K2 | Secure Enclave? | **(revised after review)** Device signing pairs (P-256, ML-DSA-65) in the enclave now. The device's decryption key stays a software X-Wing key in a this-device-only Keychain item, because the enclave has no X-Wing and HPKE has no ML-KEM + P-256 hybrid (§6.1) |
| K3 | Passphrase KDF and parameters | scrypt stays; writer work factor 20; minimum about 70 bits with no override; superseded copies deleted only under §8.2's rule |
| K4 | Forks | **(revised after review)** Never merged. A removed author loses, mutual removal asks the user, otherwise the smaller `epochId` is kept and the other fork's changes are re-applied with a fresh key (§5.6) |
| K5 | Join verification | **(revised after review)** Typed six words (66 bits) or QR in both directions, and every chain rooted at the printed root fingerprint (§4.2, §6.2) |
| K6 | Device names | Plaintext as today, now authenticated by `listTag` (§3) |
| K7 | Set-aside files | Never deleted automatically; "Clear superseded" is one user action (§5.8) |
| K8 | Sealed set contents | Path and SHA-256 of the exact bytes of every accepted file under the parent key, after a best-effort pull **(revised after review)** (§5.2) |
| K9 | #57 | Not merged; carried-over parts move into KH3, KH4 and KH6 (§13.1) |
| K10 | Kit joins | **(revised after review)** Loud alerts on every device, and the device review before Replace Kit and Re-encrypt (§6.3, §6.5, §7.1) |
| K11 | Device id length | Keep 8 hex digits: ids are for names and the interface only, and joins refuse a collision (§3) |

**Revisit later** (irreversible or user-visible):

1. **The recovery kit's printed contents** (§4.2, §8.1): the key, the root fingerprint and the
   script. Paper cannot be updated, so they are frozen in KH1, before the first kit a user prints from
   a release build.
2. **Secure Enclave device keys** (§6.1), once CryptoKit (or swift-crypto) offers the MLKEM768-P256
   HPKE KEM for enclave keys. A new key type for new joins only; no file changes.
3. **Plaintext device names** in `vault.json` and join requests (§3, §9.3). They could move into an
   encrypted record if the owner wants storage not to see them; doing that later changes only those
   files.

## 16. Review of 2026-10-20 and what changed

An independent review of the first draft found two critical, four high, seven medium and several low
findings. Each is addressed here:

| Finding | Change |
| --- | --- |
| C1 removed device admitted through a fork merge; its sealed set laundered | forks never merged; device signatures; a removed author's fork is never kept (§4.1, §5.6); J3 without a fork exemption |
| H1 merge key derivable by two removed devices | no merge key at all (§5.6); J10 over coalitions |
| H2 "combine" forced; forged removal stops a device | rules instead of a forced merge; mutual removal asks the user; unlisted devices keep pulling and never pin an epoch that removed them (§5.5) |
| C2 ledger pruning strands files | entries live until sealed or re-encrypted; the remover pulls from every reachable target first (§5.2, §5.4) |
| H3 joins trust the first vault they see | root fingerprint on the kit, chains rooted; typed words both ways (§4.2, §6.2, §6.3) |
| H4 a kit finder joins quietly | alerts on every device; device review before Replace Kit and Re-encrypt (§6.3, §6.5, §7.1) |
| M1 `vault.json` before its record | taken only on a direct link, otherwise unverified-pending; withheld records re-uploaded (§4.3, §5.2) |
| M2 ledger ordering, key class, restores | intent first; AfterFirstUnlock key in the App Group; restore cases corrected (§5.4) |
| M3 blob collection | not while a set-aside or pending revision may reference the blob (§5.7) |
| M4 re-encryption meets an offline removal | both outcomes specified; removals allowed during the pass; the pass writes ledger entries (§7.2) |
| M5 passphrase-copy deletion; kit script | deletion only from a device at the target's epoch or later; step 0 for the passphrase copy; appends through a temporary file (§8) |
| M6 removed devices keep storage credentials | threat row; the removal sheet's password advice (§5.5, §10) |
| M7 tests and vectors | every scenario in §11.1; KH1 vectors include negative chains, signing keys and the root (§12) |
| L1 orphan record visible | record hidden until `vault.json` is written (§5.2) |
| L2 `K_e` used raw as the X-Wing seed | seed derived by HKDF (§2.1) |
| L4 device ids | ids are for names and the interface only; 8 digits kept (§3, K11) |
| L5, L6 underspecified items | join request format and bounds (§6.2); the epoch record's fields, signature and naming (§5.2) |
| L7 writes between sealing and `vault.json` | the remover holds the write lock from step 3 to step 5, after its own catch-up (§5.2) |
| L8 what `epochs/` reveals | §9.3 |
