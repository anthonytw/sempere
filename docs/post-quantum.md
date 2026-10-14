# Post-quantum recipients

Why and how Sempere uses the age MLKEM768-X25519 recipient type. The
normative text is `format.md` §2 and §3.1 (only MLKEM768-X25519 recipients),
§3.2 (key file names), §3.3.1 (rewrap).

## Threat

"Harvest now, decrypt later": someone copies vault files today (a cloud
provider, a stolen backup) and keeps them until a cryptographically relevant
quantum computer can solve the X25519 discrete log. Every age file's
symmetric parts are already fine against that (ChaCha20-Poly1305 with
256-bit keys, HKDF/HMAC-SHA-256, scrypt; Grover only halves their security
level). What breaks is the X25519 stanza that wraps each file's 128-bit file
key: recover the X25519 shared secret and you have the file key.

## Choice: age's native hybrid type, nothing proprietary

The age format spec, maintained at C2SP, added a native hybrid post-quantum
recipient type with age v1.3.0 ([c2sp.org/age], section "The MLKEM768-X25519
(i.e. X-Wing) hybrid post-quantum recipient type"; [age v1.3.0 release]):

| | |
|---|---|
| identity | 32 random bytes, Bech32 HRP `AGE-SECRET-KEY-PQ-` (77 characters) |
| recipient | X-Wing public key, 1216 bytes, Bech32 HRP `age1pq` (1959 characters, no 90-character limit) |
| stanza | `-> mlkem768x25519 <base64 enc, 1120 bytes>` + 32-byte body |
| wrap | HPKE (RFC 9180) SealBase, KEM MLKEM768-X25519 (id 0x647a, [draft-ietf-hpke-pq-03] / [filippo.io/hpke-pq], i.e. [X-Wing]), KDF HKDF-SHA256, AEAD ChaCha20-Poly1305, `info = "age-encryption.org/mlkem768x25519"`, empty aad |
| checks | exactly one argument after the type, canonical base64 of exactly 1120 bytes, body exactly 32 bytes before any decryption; an X25519 share giving the all-zero secret is a header failure |

It is hybrid: an attacker must break both ML-KEM-768 (FIPS 203) and X25519.
Everything in it is a published standard or IETF draft with independent
implementations, which keeps the app in the US "mass market, standard
encryption" export category. The same spec also defines `mlkem768p256tag`
(ML-KEM + P-256, for hardware tokens); Sempere does not need it.

Alternatives considered: a custom ML-KEM stanza (incompatible with `age`,
breaks the stock-CLI recovery path); an age plugin (needs a plugin binary
for recovery, and the native type supersedes it); ML-KEM-1024 (no age stanza type exists; ML-KEM-768 is NIST
category 3 and what age, Apple and the IETF hybrids chose).

## Libraries: no lattice code of our own

`Sources/Age/MLKEM768X25519.swift` only frames stanzas; X-Wing and HPKE come
from swift-crypto 4's `Crypto` module (Apache-2.0):

| Platform | Implementation |
|---|---|
| iPadOS 26+, Mac Catalyst 26+, macOS 26+ | CryptoKit (`XWingMLKEM768X25519`, `HPKE` with it), which swift-crypto re-exports on Apple platforms ([Apple: quantum-secure workflows], [WWDC25 session 314]) |
| Linux (CLI) | swift-crypto 4.x's own `XWingMLKEM768X25519` over vendored BoringSSL (`crypto/xwing`), in swift-crypto 4.0.0 and later |

On Apple platforms before 26, or a build with an SDK older than Xcode 26
(Swift < 6.2), `postQuantumAvailable` is false and PQ operations throw
`AgeError.postQuantumUnavailable`. PQ keys still parse as recipients there,
so a vault can be opened and listed. The app's deployment target is iPadOS
27, so the app always has the type.

swift-crypto 4.0–4.3 declare tools version 6.0; 4.4+ need 6.1. A Swift 6.0
toolchain resolves to 4.3.x, newer ones to the latest 4.x.

## Validation

- All 19 CCTV `hybrid*` vectors ([C2SP CCTV age]) pass, in
  `Tests/AgeTests/CCTVTests.swift` (all 147 vectors run, none skipped).
- The spec's example identity derives the spec's example recipient.
- Interop with the reference CLI, `age` v1.3.2 from the official GitHub
  release: `age-keygen -pq` keys parse and derive the same recipient; files
  `age` encrypts (binary and armored, 0 B to 200 KB, one or several PQ
  recipients) decrypt here, and files we encrypt decrypt with `age -d`;
  mixed X25519 + PQ files decrypt with `age` under either key;
  the stock-CLI recovery pipeline works on a vault. CI installs that
  release on Linux and macOS and sets `SEMPERE_REQUIRE_AGE_PQ`, so the
  interop tests fail rather than skip there.
- Malformed stanzas (argument count, enc length, non-canonical base64, body
  length, low-order X25519 share, random bit flips) never crash and fail as
  header errors or "no match".

## Mixed recipient sets

The spec says a file SHOULD NOT be encrypted to both PQ and classic
recipients (the classic stanza voids the protection), and `age` refuses to
encrypt such a mix. `AgeFile.encrypt` refuses it too unless
`allowMixedPostQuantum: true`, which only the Age module's interop tests
pass. A vault lists only PQ recipients, so its files are never mixed.

## Policy: post-quantum only

Vaults take only MLKEM768-X25519 recipients. `sempere keys generate` and the app's "generate
a key" make only post-quantum keys (no classic option); `Vault.create`,
`addRecipient` and the target of `replaceRecipient` throw
`VaultError.classicRecipient` ("create a new key") for an `age1...` key, and
so do `vault init`, `recipients add` / `replace` (exit 2) and the app's
"use an existing recipient".

**A vault never lists a classic key.** `Vault.readManifest` refuses a
`vault.json` (of this major) that lists any recipient other than
MLKEM768-X25519 as damaged (`manifestCorrupt`, exit 1 in the CLI, an error in
the app and the web viewer), so nothing is ever read under, or encrypted to,
a classic key; `Vault.encrypt` checks the recipients again before each file.
A classic identity offered to unlock fails with `VaultError.classicIdentity`
("create a new key"). The Age module itself keeps full X25519 support, as the
age spec requires.

This is safe to make the only option because the vectors and interop pass
on every platform the project ships to, and the costs are small: about
1.2 KB more per file header, and `age` ≥ 1.3 for stock-CLI recovery (Ubuntu
24.04's package is 1.1.1, so the recovery notes point at the official
release).

## Replacing a key

```bash
sempere keys generate --out ~/.config/sempere/new.key
sempere vault recipients replace age1pq1old... ~/.config/sempere/new.key \
    --vault notes.sempere --identity ~/.config/sempere/key.txt \
    --store-key ~/.config/sempere/new.key   # only if you unlock with a passphrase
```

A rewrap gives every file a fresh file key and re-encrypts its payload;
removal and replacement also rotate the vault secret. An interrupted
`replace` needs both keys to finish (`rewrap-resume --identity OLD
--identity NEW`): keep the old key until no rewrap is pending. The app
finishes an interrupted key change on a screen of its own before it shows
any note.

## Residual risk

- **Removing a key does not revoke** what its holder already decrypted.
- Passphrase-wrapped key files (`keys/*.key.age`) use scrypt. After a
  `replace` the old key file stays in `keys/` until deleted, and is only as
  safe as its passphrase. It is not offered for passphrase unlocking
  (only key files of current recipients are), so a vault unlocked by
  passphrase needs the new key stored too (`--store-key`).

## Recovery kit and QR codes

The PQ *identity* stays short: 77 characters (`AGE-SECRET-KEY-PQ-1` + 58),
3 more than a classic identity, so a paper key or QR code of the identity stays small (all
uppercase Bech32 is QR alphanumeric; a version 3 code at level M holds
exactly 77 such characters). The *recipient* is 1959
characters: do not print it as a QR code; derive it from the identity. Key
file names under `keys/` use a SHA-256 hash of the recipient (`format.md` §3.2).

[c2sp.org/age]: https://github.com/C2SP/C2SP/blob/main/age.md
[age v1.3.0 release]: https://github.com/FiloSottile/age/releases/tag/v1.3.0
[draft-ietf-hpke-pq-03]: https://datatracker.ietf.org/doc/html/draft-ietf-hpke-pq-03
[filippo.io/hpke-pq]: https://filippo.io/hpke-pq
[X-Wing]: https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/
[C2SP CCTV age]: https://github.com/C2SP/CCTV/tree/main/age
[Apple: quantum-secure workflows]: https://developer.apple.com/documentation/cryptokit/enhancing-your-app-s-privacy-and-security-with-quantum-secure-workflows
[WWDC25 session 314]: https://developer.apple.com/videos/play/wwdc2025/314/
