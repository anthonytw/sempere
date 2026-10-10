# Security review, October 2026

An independent review, made on 2026-10-08, of the work merged in the week of 2026-10-05:

- #98: authenticated recipients (`recipientsTag`, `secretLink`, trust records);
- #97 and #105: `sync webdav --push-only` and TLS server trust;
- #94: read-only access to vaults of a newer format;
- #93: video items;
- #89 and #106: quick voice capture.

The web viewer PRs #99 (passkey) and #100 (cache and summaries) were reviewed from their branches while
they were open. Their findings are posted as comments on those PRs and summarised at the end. #99 and #100
merged during the review, so their findings became open items on `main` (P1–P3, P4–P5); P1 is fixed in
#114, P3 and P5 in #130.

Method: the code was read against `DESIGN.md`, `docs/format.md` (§2.1, §3.3, §7, §8.2.7, §9, §11),
`docs/quick-capture.md` and `docs/web-viewer.md` "Threat model". Each finding marked *reproduced* was run
against the real APIs or the built `sempere` binary on a copy of the fixtures. Each fixed finding has a
regression test. The recipients tests were run against `main` and fail there; the others encode the
reproduced inputs.

Severity is from the user's point of view:

- **High**: someone who should not can read notes, or plant content that passes as authentic.
- **Medium**: a documented guarantee does not hold, or a crash or lasting damage is caused by untrusted input.
- **Low**: defence in depth, or a narrow precondition.
- **Info**: worth knowing; no change needed now.

File:line references are to this branch.

## Summary

| ID | Severity | Area | Finding | Status |
| --- | --- | --- | --- | --- |
| R4 / W1 | High | recipients, sync | Planted `rewrap-journal.json` makes forged revisions and blobs verify (reproduced over WebDAV) | Fixed |
| R1 | High | recipients | Subset search under an attacker's secret: a one-tap repair keeps the attacker's key | Fixed |
| R2 | High (design) | recipients | A trust record's `linkKey` can forge a `secretLink`; docs said it "holds no secret" | Fixed (#115: signed links) |
| R3 | Medium | recipients | A replaced secret with a stripped or bogus tag could be confirmed or repaired | Fixed |
| C1 | Medium | capture | A capture-key holder can add a transcript to an existing voice note | Fixed |
| W3 | Medium | sync | A locked sync accepts a `vault.json` with a swapped secret | Fixed |
| W4 | Medium | WebDAV | UTF-16 PROPFIND bypasses the pre-checks; FoundationXML segfaults (reproduced) | Fixed |
| N1 | Medium | newer format | `blobs repair` renames and deletes blobs of a note with newer revisions (reproduced) | Fixed |
| V1 | Medium | video | A huge `duration` traps Markdown and HTML exports and the player title (reproduced) | Fixed |
| P1 | Medium | app keys (#99) | "New Key…" and adding a pasted recipient need no owner check, unlike "Save Key…" | Fixed (#114) |
| W2 | Medium | sync | Downloaded revisions and blobs are placed unverified; one junk snapshot blocks every edit to a note | Fixed (#114) |
| V2 | Low | video | Location kept with a second `moov`, a top-level `udta` or a truncated trailing `meta` (reproduced) | Fixed |
| N2 | Low | newer format | `inbox capture` and `inbox transcript` write into a read-only vault's `inbox/` (reproduced, CLI) | Fixed (CLI; app in #114) |
| C2 | Low | capture | Forged captures choose any notebook and title, and are written as the adopting device | Title and notebook bounded (#114); attributed to their device (#125) |
| C3 | Low | capture | A removed device's captures are adopted while its rewrap is unfinished | Fixed (#125) |
| C4 | Low | capture | Anyone holding the locked iPad (after first unlock) can add voice notes | Docs fixed |
| C5 | Low | capture | Inbox files are decrypted fully before the tag check, and failing ones are re-read forever | Fixed (#114) |
| R5 | Low | recipients | The trust store fails open: an unreadable record reads as "first use" | Fixed (#114) |
| W5 | Low | sync | No overall bound on notes, entries, bytes or time per sync run | Fixed (#114) |
| N3 | Low (design) | newer format | `format` and `features` in `vault.json` are not authenticated | Fixed (#125: `markersTag`) |
| P3 | Low | web passkey (#99) | The remembered record is chosen by the vault id of an unauthenticated `vault.json` | Fixed (#130: bound to the vault's location) |
| P5 | Low | CLI (#100) | `vault summaries --plaintext --out` writes the file world-readable | Fixed (#130) |
| P4 | Low | web (#100) | Cached ciphertext from before a rewrap stays openable by a removed key | Fixed (#125) |
| C8 | Info | capture | A comment in `QuickCapture.swift` names the wrong protection class | Fixed (#125) |
| R6, C6, C7, C9, N4, N5, V3, W6 | Info | various | See below | — |

## Fixed in this PR

### R4 / W1 (High): a planted `rewrap-journal.json` gave the attacker an accepted second secret

`Vault.open` decrypted `previousVaultSecret` from any `rewrap-journal.json` and accepted it as the
outgoing secret. Revision tags (`NoteStore`), blob names (`BlobStore`) and capture tags fall back to that
secret during a rewrap.

The attack needs only the public keys. Anyone who can write the vault folder (iCloud Drive, a shared folder,
or a WebDAV server through a normal two-way sync, even a locked one) encrypts a secret of their own to the
public keys and plants a journal holding it, then plants revisions or blobs tagged under it. Readers accept
them as authentic. A WebDAV PoC showed `forged revision accepted: true` and the title replaced. `vault info`
then suggests `rewrap-resume`, which re-tags the forgeries under the real secret, so they become permanent.

This defeats DESIGN.md "every plaintext carries an HMAC … to stop someone with write access to the storage
from planting a note". The web viewer had the same flaw.

**Fix:**
- `Vault.readJournal` (`Sources/Sempere/Vault.swift:864`) accepts the journal's secret only when it equals
  the current one (a change interrupted before `vault.json` was written), or when `vault.json`'s
  `secretLink` verifies a rotation from it to the current secret. Otherwise the journal is reported as
  unreadable and `resumeRewrap` refuses it.
- The web viewer does the same: `verifySecretLink` in `web/src/vault/vault.ts:219`.
- `format.md` §3.3.1 is updated.
- Tests: `RecipientsAuthTests.testAPlantedJournalSecretIsNotAccepted`, and `web/test/blobs.test.ts` (a
  journal without a link is ignored).

A side effect: a journal written before §2.1 has no `secretLink`, so files it left un-rewrapped report
failing tags. That needs an interrupted rotation from before #98, which is unlikely before 1.0.

### R1 (High): the subset search trusted an attacker-chosen secret

`RecipientsAuth.evaluate` ran the "up to three entries deleted" search under whatever secret `vault.json`
carried, before it compared that secret with the trust record.

The attack: an attacker writes recipients `[A, B, X, Y]`, a secret S′ of their own encrypted to all four,
and a tag over `[A, B, X]` under S′. The device then:
- reports a `tagMismatch` with `restore = [A, B, X]` and lists only Y as unexpected;
- offers the app's one-tap Remove (or plain `sempere vault recipients repair`), which writes `[A, B, X]`
  with a fresh secret and rewraps every note to X.

**Fix:**
- `evaluate` (`Sources/Sempere/RecipientsAuth.swift:120`) decides first whether the secret is the record's
  or linked to it. A secret that is neither is `secretUnconfirmed` whatever the tag says: no restore list,
  and repair refuses.
- The subset search now runs only under an accepted secret, or with no record (first use, which already
  trusts the whole list; §2.1 "Limits").
- `format.md` §2.1 "Checking" is updated.
- Test: `testSubsetSearchNeverRunsUnderAnUnconfirmedSecret`.

### R3 (Medium): a replaced secret with a stripped or bogus tag

With no tag, `evaluate` returned `tagRemoved` without looking at the secret. A tag that did not verify gave
`tagMismatch`. That allowed two attacks:
- `confirmRecipients` accepted `tagRemoved`, re-tagged the list under the attacker's secret and moved the
  trust record to it. That is the "step 1" the `secretUnconfirmed` rule was written to stop.
- A repair adopted the attacker's secret as the outgoing one, laundering files tagged under it.

**Fix:**
- Both cases are now `secretUnconfirmed` (same change as R1).
- `confirmRecipients` (`Vault.swift:840`) requires a tag that is present and verifies before it confirms an
  unconfirmed secret.
- Test: `testAReplacedSecretWithTheTagStrippedIsNeitherConfirmedNorRepaired`.

### W3 (Medium): a locked sync replaced the vault's secret

Without the key, `incomingManifestProblem` accepted an incoming `vault.json` with the same keys and any
tag, without comparing `vaultSecret`. A server swapped in its own secret with a dummy tag. The PoC showed:
- `vault.json` downloaded;
- on the next open, the list read as tampered and every revision failed its tag.

The local copy lost the real secret. For a device without a trust record, this is the path to the R1 and
R3 attacks over WebDAV.

**Fix:**
- Without the key, an incoming manifest is taken only with the same keys, the same sealed secret and the
  same tag. Adding a tag to an untagged list is still allowed (`RecipientsAuth.swift:427`).
- Test: `testIncomingManifestIsCheckedBeforeReplacingTheLocalOne`. It also no longer accepts a changed tag
  while locked.

### R2 (High, design): the trust record holds a forging key

`secretLink` is an HMAC, so the record's `linkKey`, which verifies links, also makes them. Whoever can
read a device's record and write the vault folder can link a secret of their own (with their key in the
list), and that device accepts it as a rotation.

The app kept records in Application Support, which iCloud Backup includes. A backup without Advanced Data
Protection is readable by the same provider that hosts the iCloud Drive vault. The CLI wrote the record
with the umask and only then set mode 0600. `format.md` said "it holds no secret".

**Mitigation in this PR:**
- `FileRecipientsTrustStore.save` (`RecipientsAuth.swift:398`) creates records 0600 (`O_EXCL`), in a 0700
  folder, and renames them into place.
- The app excludes its `Trust` folder from backups (`AppModel+Loading.swift`).
- `format.md` §2.1 now says the record is private.
- Test: `testTrustRecordRoundTripsAndRejectsMalformedFiles` checks the modes.

**Fix (PR #115, maintainer decision 2026-10-08):** the link is asymmetric and hybrid.
- Two key pairs are derived from the vault secret with HKDF under their own labels: Ed25519 (RFC 8032 seed)
  and ML-DSA-65 (FIPS 204 `KeyGen_internal` from a 32-byte seed). `secretLink` holds both signatures, by
  the outgoing secret's keys, over the same link message as before (vault id, `secretId(new)`); it is
  valid only when both verify (`Sources/Sempere/SecretLink.swift`, `web/src/vault/link.ts`).
- Trust records are `sempere-trust/2` and hold only the two public keys: reading one no longer helps
  forge a link. ML-DSA comes from swift-crypto (BoringSSL on Linux, CryptoKit on Apple OSes 26+), the web
  viewer's from `@noble/post-quantum` 0.7.1 and `@noble/curves` 2.4.0 (pure JavaScript, inside the CSP).
- Migration in place (`format.md` §2.1 "Upgrading to signed links"): a legacy HMAC record confirms only
  the secret it was made for (never a rotation, since whoever read it could forge a legacy link) and is
  replaced by a signed one at the device's first write; `sempere vault link upgrade` and the app (after
  unlock) retire the vault's legacy link (re-signing it when an unfinished rewrap still holds the outgoing
  secret) and add the `signed-secret-link` feature, so older writers stop. A signed record never accepts a
  legacy link. The legacy form is still checked for a rewrap journal's previous secret (R4), where the
  reader holds both secrets and a forger would need `secretId(current)`.
- Tests: `SecretLinkTests` (shared vectors made by noble and by swift-crypto, forgery with the public
  record, one-signature-only links, downgrades, the migration), `CLISecretLinkTests`, the app's
  `RecipientsAlertTests.unlockUpgradesToSignedSecretLinks`, `web/test/link.test.ts`.
- Remaining: a device whose record was still legacy when someone read it stays exposed until its first
  write with this version; a removed device, which held the outgoing secret, can still sign a link for
  devices that have not seen its removal (`format.md` §2.1 "Limits", unchanged).

### C1 (Medium): a transcript could be added to an existing voice note

The capture key is on every capturing device, readable after first unlock, and capture ids are in the clear
in `inbox/` file names. Adoption added any transcript that verified under the capture key to a recording
that had none. So a holder of the key could put attacker-chosen text into a real voice note. They could also
plant a transcript first, so the real one was silently skipped (`CaptureWriter.store` keeps the existing
file). This contradicted `quick-capture.md`: "cannot change existing notes".

**Fix:**
- The transcript file's payload, empty until now, is the SHA-256 of the capture's audio, which only whoever
  had the audio knows.
- Adoption adds a transcript only to the recording with that audio, and deletes a transcript that is
  unbound or bound to other audio once the note exists. The app transcribes the recording itself then.
- Code:
  - `CaptureWriter.seal(transcript:capture:audio:)` and `readCapture` in `Sources/Sempere/CaptureInbox.swift`;
  - `CaptureAdoption.ops` and `consumed`;
  - `sempere inbox transcript --audio FILE`;
  - the app's `QuickCapture.seal`.
- Docs: `format.md` §11.2 and §11.3, and `docs/cli.md`.
- Tests: `CaptureInboxTests.testATranscriptBoundToOtherAudioIsNeverAdopted`,
  `testAnUnboundTranscriptIsNotAdopted`, and `CLIInboxTests` (`--audio` is required).

Transcripts sealed by builds from before this change are not adopted; the app transcribes the recording
again.

### W4 (Medium): UTF-16 PROPFIND bodies bypassed the pre-checks

The PROPFIND pre-checks searched raw bytes for `<!DOCTYPE` and `<?`. UTF-16LE text is valid UTF-8 byte by
byte (ASCII plus NULs), and libxml2 decodes it from the declaration. A data-less processing instruction in
UTF-16 crashed FoundationXML with SIGSEGV on Linux (reproduced), and a DTD got past the check too.

**Fix:**
- A body with a NUL byte is refused (`Sources/SempereWebDAV/WebDAVClient.swift:431`). XML 1.0 forbids
  U+0000, so this rules out UTF-16 and UTF-32.
- Test: `UntrustedWebDAVTests.testUTF16BodiesAreRefused`.

### N1 (Medium): `blobs repair` ignored the read-only latch

`repairBlobs` checked `requireWritable` before `blobInventory`, but the inventory is what reads the note's
revisions and sets the latch. With a `sempere/1` manifest and a newer revision in the note, `blobs repair`
renamed and deleted blobs (reproduced). That contradicts §7.3, which says such a reader "repairs no blob".

**Fix:**
- `requireWritable` again after the inventory (`Sources/Sempere/BlobCollection.swift:371`), as
  `collectBlobs` already did.
- Test: `CLIReadOnlyTests.testNewerRevisionInAVersionOneVault` (exit 7).

### N2 (Low): captures written into a read-only vault

`sempere inbox capture` and `inbox transcript` stored files in `inbox/` of a vault whose `vault.json` names
a newer format (reproduced). §7.3 says such a reader "writes nothing to … `inbox/`".

**Fix (CLI):**
- Both commands refuse with exit 7 before reading the profile (`Sources/SempereCLI/Inbox.swift:126,196`).
- Test: `CLIReadOnlyTests.testWritesExitSixAndChangeNothing`.

**App (fixed in #114):** `QuickCapture.deliver` and `flushQueue` (`Apps/Sempere/SempereApp/QuickCapture.swift`)
still write into such a vault. They should queue locally while the manifest is read-only.

### V1 (Medium): a huge video duration trapped

`ExportVideos.clock` and the player title converted the stored `duration` with `Int(d.rounded())`.
Validation only requires a duration that is finite and ≥ 0, and `VideoProbe` can report about 1.8e19 s. A
revision from any recipient, or the user's own odd file, therefore crashed Markdown and HTML exports on
every device (reproduced: SIGILL), against §9 "never by crashing".

**Fix:**
- Clamp to 1e9 s, as `Transcript.clock` does (`Sources/SempereRender/ExportVideos.swift:39`,
  `Apps/Sempere/SempereApp/VideoViews.swift:56`).
- Test: `VideoExportTests.testHugeDurationsDoNotTrap`.

### V2 (Low): metadata stripping missed three layouts

The location stayed in the stored clip (reproduced with `+48.8584+002.2945`) in three layouts:
- a second `moov` (only the first is walked);
- a top-level `udta` with `©xyz`;
- a trailing top-level `meta` whose size ran past the end. It was dropped from the box list instead of
  being refused.

These are the user's own files, so this is a privacy promise not kept rather than an attack.

**Fix:**
- More than one `moov` is refused, and a top-level `udta` is blanked like `meta`
  (`Sources/Sempere/VideoProbe.swift:153,160`).
- At the top level, only `mdat` (or a first box, which is "not a video") may be cut short (`:218`).
- `format.md` §8.2.7 is updated.
- Test: `VideoTests.testLocationOutsideTheWalkedBoxesIsNeverKept`.

## Fixed in the follow-up (#114)

Each fix has a regression test; the names are given.

### P1: owner check for key changes and the recovery kit

`AppModel.addDeviceKey` and `generateDeviceKey` (New Key…, a pasted public key) now call
`requireOwner` first, the same `OwnerAuthenticator` check as Save Key… (Face ID or Touch ID when
enrolled, no passcode fallback after a lockout; the passcode or the Mac's password only without
biometrics). The key window's Recovery Kit… (`recoveryKitPDF`), which prints the secret key, asks too.
A failed, cancelled or overtaken check (another vault opened, or this one locked, meanwhile:
`KeyError.vaultChanged`) changes nothing. The policy is the one Save Key… already had; the maintainer may
still choose another. Tests: `OwnerCheckTests` (app).

### W2: downloads are checked before they are placed

- `Vault.checkIncomingRevision` / `checkIncomingBlob` (`Sources/Sempere/IncomingCheck.swift`): unlocked,
  exactly the checks of a read (decrypt, tag, note and name; a blob decrypted whole with framing, padding,
  hash and keyed name). Locked, the age structure only (a header that parses, stanza types and count of
  the vault's recipients, a payload). A first pull with `--identity` checks under the `vault.json` it
  pulls, and a `vault.json` replaced during the run (a rotation) is re-opened before the files after it
  are checked.
- A file that fails is quarantined outside the vault (`<sync state>.quarantine/<path>`, 0600), listed in
  `SyncReport.quarantined` (exit 1), and not fetched again while it, the local `vault.json` and the lock
  state are unchanged (`--retry-quarantined`). Nothing is deleted.
- **One bad file never blocks a note:** `nextSeq` skips a snapshot whose tag does not verify. It
  decrypted with the device's key but was not framed under the vault secret, so no writer made it and its
  coverage is void; skipping it can never reuse a `seq`. A snapshot that does not decrypt may be a real
  one and still stops it. That is the case the review left to the maintainer, and it is unchanged; with
  the sync check it can no longer come from a WebDAV server while unlocked, and locked runs refuse
  anything that is not well-formed age to the vault's recipients.
- format.md §9.1 is new; docs/io.md and docs/cli.md describe it.
- Tests: `IncomingCheckSyncTests` (forged snapshot, replayed name, locked structure, planted blob,
  rotation arriving in the same run), `VaultStoreTests.testForgedSnapshotNeverBlocksNextSeq`.

### W5: bounds per sync run

`SyncLimits`: 100 000 note folders, 10⁶ listed entries, 64 GiB downloaded and 12 hours by default,
`--max-notes`, `--max-entries`, `--max-download-mib`, `--max-minutes`. Reaching one stops the run with an
error naming the flag (`stoppedEarly`); what was done is recorded and the next run continues. Tests:
`IncomingCheckSyncTests.testTooManyNotes…`, `…DownloadBudget…`, `…EntryAndTimeLimits`,
`CLIWebDAVTests.testRunLimitsAreValidated`.

### N2 (app): no captures into a read-only vault

`QuickCapture.deliver` and `flushQueue` write into `inbox/` only when `vault.json` does not mark the vault
as newer (`acceptsCaptures`); otherwise the sealed note stays in the local queue. Test:
`QuickCaptureTests.aReadOnlyVaultGetsNoCaptures` (app).

### C5: inbox tag first, per-kind bounds, back-off

- `verifyInboxFile` streams each inbox file through age and the tag's HMAC in constant memory; only a file
  that verifies is read whole. Its size is checked first against its kind: 256 MiB of plaintext for a
  capture, about 64 MiB for a transcript (one JSON line and a hash).
- `InboxBackoff`: a file that fails is not read again for an hour, then twice as long after each failure
  up to a week, unless it changes (CLI `$XDG_STATE_HOME/sempere/inbox-backoff.json`, app next to its
  device state). I/O failures are not recorded. `inbox import --retry` (or naming the capture) reads it
  now. The app no longer clears a capture's failure report at the end of the same pass.
- Tests: `CaptureInboxTests.testFailingInboxFilesBackOff`, `…testInboxFileSizeIsBoundedByItsKind`,
  `CLIInboxTests.testCaptureNeedsAProfileAndForgeriesAreRefused`.

### R5: the trust store fails closed

`RecipientsTrustStore.record(for:)` throws for a record that exists but does not read (or names another
vault). The list is then `tampered(.recordUnreadable)` unless it already failed its tag, writes exit 6,
and the record is not replaced; `recipients confirm` (app: Trust This List in the recipients alert)
writes it again, only for a list whose tag verifies. A record that cannot be saved now stops the write
and is retried by the next one. Tests: `RecipientsAuthTests.testUnreadableTrustRecordFailsClosed`,
`…testTrustRecordSaveFailureStopsTheWrite`, `CLIRecipientsAuthTests.testUnreadableTrustRecordFailsClosed`.

### C2 (part): bounded title and notebook

Adoption writes a capture's title and notebook as at most 300 characters (and 1200 Unicode scalars), control characters replaced by
spaces (`CaptureAdoption.boundedName`). Still open then: the capturing device was not stored (fixed in
#125), and the notebook is still the manifest's (a policy choice). Test:
`CaptureInboxTests.testCaptureTitleAndNotebookAreBounded`.

### C3: left open (fixed in #125, below)

Restricting old-key captures to the names present at the rotation needs that list authenticated: the
journal is plaintext that a removed device (which holds the old capture key) could also edit, so the list
would have to be MACed under the new secret. That is a format change to the journal and the rewrap, not a
small fix; the window stays documented in `quick-capture.md`.

## Fixed in the follow-up (#130)

### P3: a remembered key is bound to where the vault was opened

The unlock screen looked a passkey record up by the `vaultId` of a `vault.json` that no key had opened
yet, so any address (a `?vault=` link, say) could claim the id of a vault the user remembered and be
offered "Unlock with passkey"; the remembered key then opened the attacker's vault (its own secret,
encrypted to the user's public recipient), which looked like the user's own. Records are now
`version: 2` and carry the vault's location: its normalised base URL (`HTTPSource.label`), or `local:`
for a folder opened from this computer. The location is bound into the HKDF info and the AES-GCM AAD
(length-prefixed fields, label `sempere-viewer/2`), so a record edited to name another location, or
downgraded to version 1, does not decrypt. `PasskeyVault.unlock(vaultId, location, use)` refuses a record
of another location before any prompt (`otherLocation`); the card names the remembered address and offers
no passkey there. Version 1 records still open (the card says the key will be tied to this address) and
are sealed again for the location once their key has unlocked the vault there, under the same passkey,
salt and PRF output with a fresh IV; a key that does not open the vault leaves the record as it was.
`docs/web-viewer.md`'s claim that the record is "keyed by the vault id the user's unlock already
accepted" is replaced by the actual rule. At the remembered address the server is trusted as for a
pasted key (the key stays in the tab's memory). The two Info items are fixed too: remembering again
signals the replaced passkey unknown, and the `sempere-viewer` database is created only by the first
remembered key. Tests: `web/test/passkey.test.ts` ("remembered keys are bound to the vault's location",
including a version 1 record built with the old construction, and "IndexedDB storage of remembered keys",
on `fake-indexeddb`); `web/scripts/smoke-passkey.mjs` passes in Chromium with a virtual authenticator.

### P5: the plaintext summaries file is owner-only

`vault summaries --plaintext --out FILE` writes a temporary file next to `FILE` created `0600` with
`O_EXCL`, flushes it and renames it over `FILE` (`writePrivateFile`), so the titles and text are never in a
file others can open, and an existing file (of any mode, or a symlink) is replaced rather than rewritten.
The sealed file keeps the umask's mode: the web server publishes it. Test:
`CLISummariesTests.testPlaintextFileIsOwnerOnly` (fails on the old code with mode 0644).

## Fixed in the second follow-up (#125)

Each fix has a regression test that encodes the attack and expects it refused.

### C2: captures are attributed to the device that sealed them

- **Device capture keys** (`format.md` §11.1): `deviceCaptureKey(r) = HKDF(vaultSecret, "sempere/1 device
  capture key" ‖ 0x00 ‖ fingerprint(r))`, with `fingerprint(r)` the SHA-256 hex of the recipient key, as in
  key file names (§3.2). A profile holds only the key of the recipient its device unlocked with
  (`Vault.captureProfile`, `CaptureProfile.recipient`), so one device's profile cannot seal a capture that
  verifies as another's. The manifest names the fingerprint (`recipient`), which must be that of the key
  that verified the file.
- **The reader's key ring** (`Vault.captureKeyRing`, `format.md` §11.2): the tag is streamed once under the
  vault capture key and the device capture key of every recipient of a list that checks (`readCapture` now
  refuses a tampered list, `untrustedRecipients`); the key that verifies attributes the file. The work is
  at most four streamed HMACs per capture: the reader tries the vault capture keys and the keys of the device
  the manifest claims (a bounded byte scan of its first line before the tag, `CaptureFile.claimedDevices`); the
  claim only picks keys, the tag and the parsed `recipient` decide. Transcripts (bounded, no claim) take the
  whole ring.
- **Stored on adoption:** `captured: {device, recipient}` on the recording (`format.md` §8.3.1), immutable,
  read leniently (a malformed value is absent). Older readers keep it as an unknown field (§7.5).
  The delta is still the adopter's: revision names carry a per-device `seq` that concurrent adopters, or the
  capturing device itself, would also use, and the capturing device holds no secret to tag a revision with
  (`format.md` §11.3 says why). This is the one point where the task as written ("instead of writing the
  capture as the adopting device") is met through `captured` rather than the revision's `device`.
- **Transcripts** are adopted only from the device the capture (or the adopted recording's `captured`) is
  attributed to, on top of C1's audio binding.
- **Shown:** `sempere inbox list` and `import` (`from iPad (device 0b0b0b0b)`, `--json`: `device`,
  `recipient`, `capturedBy`), the app's recording menu ("Voice note from iPad", "… from a device no longer in
  this vault", "… from an unverified device").
- **Compatibility:** files sealed with the vault capture key (profiles made before) are still adopted, as
  **unattributed** (`captured.recipient` absent); the app replaces such a profile at the next unlock
  (`refreshQuickCaptureProfile`), the CLI with `inbox enable`.
- Tests: `CaptureAttributionTests` (`testCapturesAreAttributedToTheDeviceThatSealedThem`,
  `testAProfileCannotImpersonateAnotherDevice`, `testATranscriptFromAnotherDeviceIsNeverAdopted`,
  `testCapturesOfProfilesMadeBeforeAttributionAreUnattributed`, `testMalformedAttributionReadsAsAbsent`),
  `CLIInboxTests.testCapturesAreAttributedAndARemovedDevicesAreRefused`, the app's
  `QuickCaptureTests.enablingStoresAProfileWithoutTheIdentityAndRefreshFollowsKeyChanges` and
  `RecipientsAlertTests.capturedByNamesTheDevice`.
- The notebook is still the manifest's (bounded, #114): confining it is a policy choice left to the
  maintainer. `device` inside a recipient is the profile's own claim (a recipient may be several devices).

### C3: a removed device's captures are refused, also during its rewrap

- A recipient no longer listed has no key in the ring, under the current secret or the outgoing one, so its
  captures never verify: those sealed after its removal (with its old profile) and those it sealed before
  and that still wait (the rotation re-tags only files of listed devices, `rewrapInbox`). They are reported
  (`badTag`, whose text now names this case) and kept, and back off like other failing files.
- Unattributed files under the outgoing secret's vault capture key, which a removed device also holds, are
  re-tagged only by the run that rotated the secret (`rewrapInbox(legacyPrevious:)`, `finishRewrap(rotating:)`),
  never by a resumed one, and never adopted under it.
- Remaining (documented in `format.md` §11.1 and `docs/quick-capture.md`): a removed device that held the
  vault secret itself, not only a profile, knows the outgoing secret and can seal captures attributed to a
  listed device until the rewrap finishes, as it can tag revisions during that window (§3.3.1). The
  review's journal-list proposal would close that for captures only; it was not needed for the case the
  finding describes (a lost or removed capturing device, which holds a profile).
- Tests: `CaptureAttributionTests.testARemovedDevicesCapturesAreRefusedWhileItsRewrapIsUnfinished` (fails
  with the old key ring), `testTheRotationKeepsOnlyCapturesOfListedDevicesAndWaitingUnattributedOnes`,
  `testProfilesAndReadsNeedTheAuthenticatedList`, `CLIInboxTests.testCapturesAreAttributedAndARemovedDevicesAreRefused`.

### N3: `format` and `features` are authenticated

- **`markersTag`** (`format.md` §2.1 "Version markers"): HMAC under `HKDF(vaultSecret, "sempere/1 markers
  key")` over `vaultId`, `format` and the distinct `features` sorted by UTF-8 bytes (a NUL never verifies).
  Every write of `vault.json` tags what it writes (`Vault.writeManifest(…, secret:)`), with the new
  `markers-tag` feature so older writers stop. Writers refuse to re-tag markers that changed on disk since
  they opened the vault (`markersIntact`).
- **Checked with the list** (`RecipientsAuth.markersProblem`), once it checks: `markersMismatch` (does not
  verify), `markersRemoved` (gone while the feature or the trust record says it was there),
  `markersRolledBack` (verifies, but names a lower major or fewer features than the trust record:
  an older `vault.json` put back). Each is a `tampered` status, so every write path refuses it (exit 6)
  and every report shows it. Reading works; newer markers still make the vault read-only.
- **Trust records** keep the last verified markers (`markers`, optional in `sempere-trust/2`), never fewer.
- **Old vaults** are tagged by their first write, by the app right after unlock (`upgradeMarkers`), or by
  `sempere vault markers tag`; readers never tag. `vault markers repair` writes the larger of the markers on
  disk and in the record, and refuses a result this version could not write.
- **Sync** (`incomingManifestProblem`): unlocked, the incoming file is checked like an open (plus the
  markers may not go down); locked, tagged markers may not change at all, untagged ones only grow.
- **The committed fixtures** `sample.sempere` and `newer.sempere` carry a markers tag (vault.json only).
- **Web viewer:** checks and reports the tag (`checkRecipients`), knows the feature.
- Limit: readers older than this change ignore the tag and can still be downgraded; a device with no
  trust record cannot tell a vault stripped of both tag and feature from one written before them.
- `recipients confirm` refuses each markers reason, and when it confirms a list problem it restores
  markers that do not check (as a repair) instead of accepting them (found by the external review of #125;
  `MarkersAuthTests.testConfirmNeverClearsTamperedMarkers`, `CLIMarkersTests.testRecipientsConfirmRefusesEveryMarkersProblem`).
- Tests: `MarkersAuthTests` (known-answer vector computed independently from the spec, also in
  `web/test/markers.test.ts`; downgraded format, stripped tag, replayed manifest, repair, first-write
  tagging, sync), `CLIMarkersTests`, `RecipientsAlertTests.markersAlertPointsToTheMarkersRepair`.

### P4: the web cache follows the vault's key state

`cacheNamespace` (`web/src/vault/cache.ts`) adds a hash of the sealed `vaultSecret` and of the rewrap journal
to the vault's URL and id; every recipient change re-seals the secret, and the journal comes and goes with a
rewrap. Opening the vault drops every copy cached under an earlier key state of the same vault
(`dropOtherNamespaces`), including caches written before this change. Test: `web/test/cache.test.ts`
("drops copies cached under an earlier key state").

### C8: comment fixed

The code was right (`completeUntilFirstUserAuthentication`, which a Lock Screen voice note needs to be read
back from closed files and sealed before any unlock); the class comment of `QuickCapture` now says so.

## Open findings (reported, not fixed in the review PR)

The original text of each finding follows; those fixed since say so in their heading.

### W2 (Medium): downloaded files are placed without verification (fixed in #114, above)

`WebDAVSync` (revisions, `WebDAVSync.swift` around the download path) and `BlobSync` check only the age
magic, and the listed size for blobs, before linking a downloaded file in as write-once.

Two attacks follow:
- **Blocked note.** A server can add `notes/<id>/<name>.snapshot.age` holding junk. Every later edit to that
  note fails, because `nextSeq(noteId:device:)` cannot read the snapshot's coverage
  (reproduced: "edit FAILED"). Sync never removes the file, since unreadable files are kept.
- **Poisoned blob copy.** The server can do the same with a blob name it has seen, before another device
  downloads that blob.

**Proposed fix:**
- When the vault is unlocked, decrypt and verify each download (tag, note id and name; for a blob, its
  framing and hash) before it is linked in. Refuse the ones that fail.
- When it is locked, download into a quarantine outside `notes/`, or not at all.

Changing `nextSeq` to skip unreadable snapshots would trade this DoS for a risk of reusing a seq, so it is a
decision for the maintainer.

### C2 (Low): forged captures are indistinguishable from real ones (fixed in #114 and #125, above)

The manifest supplies `title` and `notebook` (`CaptureInbox.swift`, `CaptureAdoption.ops`). The title is
bounded only by the 64 MiB line limit. `manifest.device` is checked but not stored, and the delta is written
as the adopting device. The threat table claimed forged notes "show up in the inbox notebook, attributed to
a device id"; it now describes what happens.

**Proposed fix:**
- Cap the title (for example at 300 characters).
- Store the capturing device id on the recording.
- Optionally confine adopted captures to the notebook the adopting device configured.

### C3 (Low): a removed device's captures during an unfinished rewrap (fixed in #125, above)

`readCapture` and `rewrapInbox` accept the previous secret's capture key for as long as the journal exists.
The journal stays while any file fails, for example evicted iCloud files.

**Proposed fix:** record the inbox file names in the journal when the secret rotates, and accept or re-tag
old-key files only from that list. `quick-capture.md` now states the window.

### C4 (Low): Lock Screen capture

Anyone holding the iPad after its first unlock can add voice notes from the widget, Control Center, the
Action button or Siri. This is the feature; the threat table now has a row for it. Optional: a setting that
requires authentication (`authenticationPolicy`) for the intents.

### C5 (Low): inbox files are read whole before the tag check (fixed in #114, above)

`readCapture` and `rewrapInbox` decrypt each inbox file (up to 257 MiB) into memory before verifying the
tag. A file that fails is kept and processed again at every unlock.

Anyone who can write the folder can therefore cost every device about 0.5–0.8 GB of peak memory per unlock
for each 256 MiB junk file, without any key.

**Proposed fix:**
- Stream the decryption and the HMAC.
- Use a much smaller cap for `transcript` files.
- Quarantine files that keep failing.

### R5 (Low): the trust store fails open (fixed in #114, above)

`FileRecipientsTrustStore.record` returns nil for an unreadable or malformed file, so `evaluate` treats the
open as a first use and the next write replaces the record. `rememberRecipients` ignores save errors and
does not retry them. This needs local tampering or a future record format.

**Proposed fix:** return an "unreadable" state that counts as tampered.

### W5 (Low): no bound per sync run (fixed in #114, above)

Each request is bounded by size and time, but a run is not:
- the number of note folders and entries is unlimited, and every listing stays in memory;
- the total bytes downloaded are unlimited, so a server can fill the disk with new note ids;
- there is no overall deadline.

**Proposed fix:** caps per run, and an overall deadline.

### N3 (Low, design): `format` and `features` are not authenticated (fixed in #125, above)

`recipientsTag` covers the vault id and the keys only. A folder attacker can set `format` back to
`sempere/1` and remove unknown features, so an old client opens the vault writable until it reads a marked
(tagged) revision. That stays within §7.3's per-note minimum, and no data loss was found.

**Options:**
- Document this under §2.1 "Limits".
- Bind the markers into the tag (a format change).
- Have `rewrapNotes` stop on marked revisions.

### Info

- **R6:** readers keep no trust record ("reads never write"), so a device that only read a vault for months
  is still at first use on its first write.
- **C6:** adoption runs AVFoundation and Speech automatically on audio a capture-key holder chose. This is
  attack surface only; no bug is known.
- **C7:** `sempere inbox list` and `inbox import` print manifest titles unsanitised, so a capture-key holder
  can send terminal escape sequences. Other commands print note titles the same way.
- **C8 (fixed in #125):** a comment in `QuickCapture.swift` near line 116 says the plaintext uses `completeUnlessOpen`; the
  code uses `completeUntilFirstUserAuthentication`, as documented.
- **C9:** the capture-profile Keychain query does not set `kSecUseDataProtectionKeychain`, unlike
  `VaultKeyStore`. On Mac Catalyst it may land in the file-based keychain, where `kSecAttrAccessible` is
  ignored. Adding the flag means existing items have to move.
- **N4:** `snapshot(loaded:)` and `compact(noteId:loaded:)` do not latch on `loaded.newer` themselves, as
  `planCompaction` does. This is safe today because every caller loaded the note through the same `Vault`.
- **N5:** Swift treats `"format": null` in a revision as absent; the web viewer rejects it. Both fail safe.
- **V3:** `ByteEdit.init` is public, and `apply` traps when the replacement length differs from the range.
  Only `strippingEdits` builds edits today. Posters and playback run AVFoundation on clips from other
  recipients; that is the accepted Apple-only surface.
- **W6:** `WebDAVClient` echoes the base URL in one error. A URL with credentials but no host prints them,
  though they were typed on the command line anyway.

## Checked and found sound

- **Constant-time comparisons:**
  - recipients tag and link: `RecipientsAuth.constantTimeEqual`, after `unhex` (64 lowercase digits only);
  - capture tag: `CaptureFile.constantTimeEqual`;
  - body tags and blob names: `HMAC.isValidAuthenticationCode`;
  - local caches: ChaChaPoly AEAD;
  - the new journal check and the web `verifySecretLink`: constant-time loops.
  
  Every remaining `==` is on public values or content hashes.
- **Domain separation:**
  - HKDF from the vault secret, empty salt, with these info labels:
    - `sempere/1 recipients key`
    - `sempere/1 secret link key`
    - `sempere/1 secret id`
    - `sempere/1 capture key`
    - `sempere/1 summary-cache key` and `sempere/1 summary-cache name`
    - `sempere/1 <purpose> key|entry|name` (`LocalCacheKey`). Purposes are hyphenated lowercase words, and
      `recipients`, `capture` and `summary-cache` are reserved.
  - HMAC keyed by the raw secret:
    - body tags: `sempere/1 ‖ 0 ‖ noteId ‖ 0 ‖ filename …`;
    - blob names: `sempere/1 ‖ 0 ‖ blob ‖ 0 ‖ digest`.
  - No two derivations share key and label.
  - The tag message is unambiguous: NUL-separated, keys validated as Bech32 with no duplicates, and the
    vault id canonical.
  - #99's passkey wrap uses its own label (`sempere-viewer/1 passkey key-wrap`), and #100's summaries their
    own (`sempere/1 published summaries key`).
- **Every encryption to the recipients is gated:**
  - revisions, blobs, compaction and blob repair go through `requireWritable`;
  - recipient changes check `requireTrustedRecipients` and then `requireWritable`;
  - capture profiles are made only from a list that checks, and captures are sealed to the profile's list;
  - the inbox rewrap runs only inside a recipient change.
- **Rollback and replay:**
  - An old `vault.json` from before a removal fails against a record at the newer secret.
  - A rollback under the same secret can only drop keys added later (documented in §2.1 "Limits").
  - A removed device can still forge links for devices that have not seen its removal (documented).
- **Path traversal (WebDAV):**
  - Note ids must be lowercase UUIDs.
  - Revision names must round-trip through `RevisionName`, and blob names through `BlobName`.
  
  So `..`, `.`, `%2e%2e`, backslashes, NUL, Unicode normalisation and case variants never become paths.
  `keys/` and `inbox/` are never synced. Hrefs are filtered by base prefix and depth, outgoing segments are
  percent-encoded, and push-only deletions go through `safeComponent`.
- **Capture ids:** `CaptureFile.parse` accepts only `<36-char lowercase UUID>.<capture|transcript>.age`.
- **Write-once:**
  - Downloads are linked in with `link(2)` and never overwrite.
  - Only `vault.json` and the journal are replaced (both now checked, W3 and R4).
  - Push-only never writes locally.
- **TLS and credentials:**
  - #105 changes only server trust to `.performDefaultHandling` (system validation), never "accept any".
    Linux libcurl verifies certificates by default.
  - Redirects are not followed.
  - Plain `http` is allowed only to localhost, credentials in the URL are refused, and the password comes
    from an environment variable, never argv.
- **Resource limits per request:** response bodies are capped while streaming, and `Content-Range` is
  validated.
- **`VideoProbe`:** boxes are checked with subtraction (no overflow), 64-bit and zero sizes are handled,
  depth is at most 8, at most 20,000 boxes, and leaf reads are at most 4 KiB. It is fuzzed (`VideoTests`).
- **Newer formats:**
  - The latch is shared across `Vault` copies.
  - Every write path checks `requireWritable` (N1 was the exception).
  - Blob collection scans references structurally, so it keeps blobs only newer revisions reference.
  - A leniently decoded state is never written back.
- **Secrets in logs and temp files:**
  - Capture, inbox and speech code does not log.
  - `Perf` and `NSLog` lines carry counts and 8-hex id prefixes only.
  - Temporary blob files are 0600 `O_EXCL` and removed on failure (`FileIO.writeNewFile`).
  - Sync temporary files hold ciphertext only.
- **Keychain classes:**
  - vault key on this device: `WhenUnlockedThisDeviceOnly` + `.biometryCurrentSet` (or `.userPresence`);
  - vault key in iCloud Keychain: `WhenUnlocked`, synchronizable, with the app's `LAContext` gate (a
    documented trade-off);
  - capture profile: `AfterFirstUnlockThisDeviceOnly`, which Lock Screen capture needs; it holds no
    reading key.

## Web viewer PRs (comments posted on the PRs)

**#99 (passkey), merged during the review:**
- P1, Medium: "New Key…" (and adding a pasted recipient) adds a recipient without the owner check that
  guards "Save Key…". On an unlocked iPad, anyone can create a key the vault is then encrypted to, which
  reads future notes too.
  - Where: `AppModel.generateDeviceKey` and `addDeviceKey` (`Apps/Sempere/SempereApp/AppModel+Keys.swift`).
  - Not fixed here: requiring an `OwnerAuthenticator` there changes every key-management path and its app
    tests (which cannot run outside the macOS CI job), and the policy (Face ID only? the passcode on a Mac
    without Touch ID?) is the maintainer's call. The paper recovery kit (`recoveryKitPDF`) has the same gap.
- P2, Low: the share sheet's Copy puts the key file on the general pasteboard.
- P3, Low: the remembered record is chosen by an unauthenticated vault id; the doc says otherwise. Fixed
  in #130 (above).
- Info: the IndexedDB database is created before the user opts in; old passkeys are not signalled unknown
  when a key is remembered again (both fixed in #130); #99 and #100 contradict each other in
  `docs/web-viewer.md`.
- The PRF, HKDF, AES-GCM and AAD handling is sound, and nothing is stored in plaintext.

**#100 (cache and summaries), merged during the review:**
- P4, Low (fixed in #125): cached ciphertext from before a rewrap stays openable by a removed key
  (`web/src/vault/cache.ts`, namespace without a recipients fingerprint).
- P5, Low: `vault summaries --plaintext --out` writes the file world-readable
  (`Sources/SempereCLI/Summaries.swift`). Fixed in #130 (above).
- Info: summary rows hide damaged revisions until the note is opened.
- Fixed by R4: summaries sealed under the journal's previous secret were accepted during a rewrap. The web
  viewer now derives the previous summaries key only from a journal secret that `secretLink` links.
- Summaries are encrypted. `vault.json` and the journal are never cached. Nothing decrypted is persisted.

## Audit 2026-10 stage 4 (2026-10-10)

Fixes of verified findings from the pre-release audit's stage 4. Each test fails on the base
(96abc5aa) and passes after.

### S0, S1, S4 (High): a removed device could bring its old secret back with a rewrap journal

`readJournal` accepted any journal whose previous secret `secretLink` linked to the current one, and the
signed link stays in `vault.json` until the next rotation. A removed device, which holds the outgoing
secret, could therefore plant a journal (or replay the genuine one) after its removal finished: every
previous-secret fallback (revisions, blobs, `settings.age`, captures, the web viewer's blob names and
summaries) accepted its forgeries, and a resume re-tagged them under the current secret.

**Fix** (`format.md` §3.3.1 "Accepting the journal", `Sources/Sempere/RewrapBinding.swift`):
- Format (additive): the rotation's `vault.json` write carries `rewrapPending`, an HMAC under the new
  secret over the journal's SHA-256, and the `rewrap-pending` feature (older writers stop); step 4 removes
  the field in a tagged write before deleting the journal. While the vault binds journals (field, feature,
  recorded feature, or markers that do not check), a journal counts only when the field verifies over its
  bytes. Older readers ignore the field; older vaults still open (the link check alone, plus the marker).
- Device-local, no format change: the trust record's `rewrapFinished`, set when the device saves its
  record (or opens with a record of the same secret) while nothing is pending, and when it finishes the
  rewrap itself; it never goes back for the same secret. Then no journal with another previous secret is
  accepted (no fallback, no resume). A lost record falls back to the link and binding checks.
- Sync: `incomingManifestProblem` refuses a `vault.json` that, under the same secret, brings back or
  changes `rewrapPending` (a put-back copy), locked or not.
- Web viewer: `journalSecretAccepted` in `web/src/vault/vault.ts` (link + binding; it keeps no record).
- Tests: `RewrapJournalBindingTests` (`testARemovedDeviceCannotReopenItsSecretWithAPlantedJournal`,
  `testAReplayedJournalOfAFinishedRotationIsRefused`, `testAStrippedFeatureStillRequiresABinding`,
  `testUnboundVaultsAreProtectedByTheFinishedMarker`, `testTheFinishedMarkerIsMonotonic`, the shared vector
  in `testRewrapPendingIsHMACOverVaultIdAndJournalDigest`), `JournalSyncTests.testAJournalThisDeviceRefusesIsNotTaken`,
  `web/test/journal.test.ts`.
- Remaining (`format.md` §3.3.1 "Limits"): a device with no trust record that is given both the
  `vault.json` of step 2 and the genuine journal accepts the outgoing secret, as during the rotation; the
  web viewer keeps no record, so the same holds there.

### S9 (Low): a two-way sync replaced an unfinished local journal

`WebDAVSync.accept` wrote any server journal over the local one, which may be the only copy of the
outgoing secret. **Fix:** `Vault.incomingJournalProblem`: a local journal is replaced only when this device
refuses it and accepts the server's; locked, the server's copy becomes a conflict copy; unlocked, a journal
this device refuses is `rejected`, not written. Test: `JournalSyncTests.testTheServerCannotReplaceAnUnfinishedLocalJournal`.

### S19 (Low): a planted journal blocked every recipient change

Any `rewrap-journal.json` blocked recipient changes, repairs and blob collection, and held the app in its
migration screen; nothing removed it. **Fix:** `Vault.discardRefusedJournal` (CLI `vault rewrap-discard`,
`--json`) moves a journal this device refuses to `rewrap-journal.refused.json` (read by nothing) (never one it accepts or cannot read now, never with a list
that does not check); the app does it quietly at unlock and in the migration screen, and opens the vault
normally when a refused journal is left; `vault info` says "REFUSED journal"; the CLI's errors and blob
collection name `rewrap-discard`; a server journal this device refuses no longer holds blob pruning back.
Tests: `RewrapJournalBindingTests.testARefusedJournalCanBeDiscardedAndAnAcceptedOneCannot`,
`testAnUnreadableJournalIsKept`, `CLIRewrapDiscardTests`.

### S2 (Medium): a WebDAV server could make two-way-sync clients delete saved versions

`syncNote` judged a revision the server no longer listed only by snapshot coverage (with its age forced
away), so a server without any key could make every syncing device delete checkpoints, the created anchor
and the history a checkpoint needs. **Fix:** such a deletion is followed only when a compactor or thinner
of this format could have made it: never a checkpoint or the created anchor
(`CompactionPlanner.neverDeleted`), never a set that leaves a complete checkpoint incomplete
(`CompactionPlanner.deletionKeepsCheckpoints`, the check `plan` uses), and nothing in a note with an
unreadable revision; anything else is uploaded again. Age is not judged (thinning everything except
checkpoints is legitimate), so a server can still drop covered non-checkpoint history after the newest
checkpoint, as that thinning would. Tests: `RemoteDeletionTests.testTheServerCannotDeleteACheckpoint`,
`testTheServerCannotDeleteTheHistoryACheckpointNeeds` (fail on the base), and
`testAnExplainedDeletionStillPropagates`, `testAThinningByAnotherDeviceReachesThisOne` (legitimate
deletions still propagate).

### S5 (Low): key copies in `keys/` accepted any non-empty passphrase

The passphrase-wrapped key copy is on the sync storage, so whoever can read the storage can guess its
passphrase offline (scrypt, work factor 18); the app and CLI accepted any non-empty one. **Evaluation:** the
verifier's fix is sound; a strength floor is the part that matters (raising the work factor is capped by the
readers' memory limit, §3.2, and does not replace it). **Fix:** `PassphraseStrength` (Sources, no word list:
letter runs priced as Diceware words, l33t substitutions folded into words, repeats and sequences one bit)
with a 60-bit floor for a stored copy. The app's New Vault and Upgrade Vault sheets refuse a weaker one and
say why (footnote: the copy is on the storage and can be guessed offline); the CLI's `vault init` and
`recipients add`/`replace --store-key` refuse it with exit 2 unless `--allow-weak-passphrase`.
`format.md` §3.2 and `security.md` say so. The library call (`Vault.writeIdentityFile`) still accepts any
non-empty passphrase (tests, the demo vault). Tests: `PassphraseStrengthTests`,
`CLICommandTests` (weak refused, exit 2).
