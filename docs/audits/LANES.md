# Audit lanes

One lane is one reviewer with one brief. A lane reads the code, the specification and the claims for its area, and
returns findings in the schema below. The runbook is [`README.md`](README.md); change a brief by PR. Briefs name files
and symbols, not line numbers, which move.

## Rules for every lane

- Read-only: change nothing in the repository. Write findings, and any reproduction, in the run folder
  (`data/audits/<run>/`), never in the repository.
- Check the previous reports first: did each earlier finding in your area stay fixed, and does it have a regression test?
- Rate by the documented guarantees (`docs/security.md`, `SECURITY.md`, the lane's documents), not by taste. A rating
  is an argument about a sentence. State which documented guarantee or hard rule (`CLAUDE.md` "Hard rules") breaks, or
  "none: new risk".
- Out of scope per `SECURITY.md` "Scope" (needs the unlocked device or the identity file; metadata a storage provider
  sees by design; age's own non-goals): do not report as a finding; list it under "Not a finding" with the reason.
- Never put a real key or real notes in a finding. Use synthetic vaults.
- If you cannot check a claim, say "cannot check" and why.

## Finding schema

One JSON object per finding; a lane writes an array to `findings/<lane>.json`. The verifier adds `verdict` and
`verifier_notes`; the coordinator writes the report table from these files.

| Field | Content |
| --- | --- |
| `id` | lane letter and number, `A-03` |
| `lane` | `A` to `G` |
| `title` | one line, neutral wording (no exploit detail in anything that may become public) |
| `severity` | Critical, High, Medium, Low or Info (`SECURITY.md` "Audits") |
| `confidence` | high, medium or low |
| `component` | `path:line` (and symbol) |
| `claim` | the documented guarantee or hard rule it breaks, or "none: new risk" |
| `attack` | who can do what, with what access |
| `evidence` | a reproduction or a test name; for a read-only observation, the code path |
| `fix` | a proposal |
| `status` | open, fixed in PR or release, accepted risk, or not confirmed |

## A. Crypto, format and parsers

**Covers:** `Sources/Age`, `Sources/Sempere/Epoch*.swift`, `JoinCodes.swift`, the scrypt and PBKDF2 implementations and
their vectors, the vault tag, file framing and padding, the limits of every parser on hostile input (vault files and the
importers: Notability, `.note`, PDF), the fuzz targets, and the kit's frozen recovery script.
**Starts from:** `docs/format.md` (normative), `docs/design/key-hierarchy.md`, `docs/post-quantum.md`,
`docs/import-notability.md`.
**Questions:** can any check (tag, signature, epoch, home-device signing, sealed set) be skipped, reordered or
replayed? Is any cipher or MAC hand-rolled, or any primitive used outside swift-crypto besides scrypt and PBKDF2? Do
the vectors cover every path? Does hostile input exhaust memory, time or stack (lengths, counts, nesting, zip and
inflate ratios) or crash? Does `EpochChainTests.testFrozenRecoveryScriptOpensEveryEpoch` still guard the recovery
path? Run the deep fuzz (`SEMPERE_FUZZ_LONG=1 swift test --filter Fuzz`) and record the duration.

## B. Keys, device and CLI

**Covers:** Keychain classes and access control, the Secure Enclave signing keys, the Face ID gate, key lifetime in
memory, plaintext at rest (the attachment cache, voice notes before sealing, Mac window titles), join approval words,
takeover; and the `sempere` CLI's files (key files mode 0600, temporary files, secrets on stdin and stdout, `--root`,
path traversal in exports and backups).
**Starts from:** `docs/security.md` "The keys" and "What the encryption does not protect", `docs/cli.md`.
**Questions:** which `kSecAttrAccessible` class guards each key, and does it match the document? Does a secret reach a
log, a pasteboard, a share sheet, a temporary file or a window title? Can an export or backup write outside its target
or follow a link? Does a removed device keep any ability? Device-only questions (a locked watch's Keychain, Face ID)
are listed as "owner-verified" with a device-check card.

## C. Capture keys

**Covers:** the capture profile, inbox acceptance, transcript binding, suspension after removal, the widgets and, from
1.1, the Apple Watch path: how the profile reaches the watch (the age-sealed provisioning payload), the watchOS Keychain
class, plaintext audio on the watch until sealed, the transfer back to the phone (metadata checks, routing by vault,
ledger entries under the file's epoch), and what a stolen watch can do.
**Starts from:** the table in `docs/quick-capture.md`, and `docs/design/1.1-watch.md` once it exists.
**Questions:** for each attacker in the table (stolen unlocked phone, stolen watch, a removed capture key, a hostile
WebDAV host), does the table's claim hold in the code? What can a capture key write, and what can it never read?

## D. Sync and WebDAV

**Covers:** `SempereWebDAV`, `SempereSync`, TLS trust and the pinning delegate, credentials in headers and the Keychain,
redirects, hostile listings and manifests, cut and replayed uploads, set-aside files.
**Starts from:** `docs/io.md` "Sync engine and transports".
**Questions:** can a hostile server make the client write outside the vault, loop, exhaust memory, downgrade to plain
HTTP, leak the credential to another origin on a redirect, or get a forged or replayed file accepted? What happens to a
half-uploaded file after a crash?

## E. Web viewer

**Covers:** the CSP and Trusted Types, the DOM builder (no markup), the SVG allow-list, `blob:` handling, pdf.js
hardening, the key worker, bounded work, the hosting recommendation (headers, origins), and the npm packages.
**Starts from:** `docs/web-viewer.md`.
**Questions:** does the built page ship the CSP the document fixes? Can a note's content reach `innerHTML`, `eval`, a
`javascript:` URL or an uncontrolled `blob:`? Does a hostile PDF or vault run script or exhaust memory? Where do keys
live, and for how long? Read the changelogs and maintainers of the six runtime packages and ask whether each is still
needed.

## F. Supply chain and release

**Covers:** `Package.resolved`, `web/package-lock.json`, the GitHub Actions pins and permissions, `release-*.sh`,
signing, attestations (`gh attestation verify`), `SHA256SUMS`, the Homebrew formula and the tap, entitlements, privacy
manifests, and the Gitea mirror (what it receives).
**Starts from:** `docs/releasing.md`, `SECURITY.md` "Verifying releases", `scripts/check-security.sh`.
**Questions:** run `scripts/check-security.sh` and review `scripts/security-allow.txt`; refresh the Action pins; run
`npm audit` and the OSV query; confirm the weekly workflow is enabled. Does a release script run anything it downloaded
or accept an unverified input? Is every entitlement and every privacy-manifest reason still needed? What does the
mirror receive, and could an embargoed branch reach it?

## G. Privacy and claims ledger

**Covers:** everything that leaves the device (every `URLSession` site, widgets, Watch, Spotlight, share sheets,
pasteboard, crash logs); logging (`PerfSink` call sites; nothing secret); telemetry (none); metadata in vault files and
file names (`docs/format.md` section 1: size classes, timestamps, device names, `vault.json`); the privacy policy and the
App Store labels against the code. Then one pass over every sentence of `SECURITY.md`, `docs/security.md`, the privacy
policy and the threat tables of `docs/quick-capture.md` and `docs/web-viewer.md`: each claim gets a verdict.
**Starts from:** `docs/appstore/privacy-policy.md`, `docs/security.md` "What others can see", and those documents.
**Verdicts:** holds with test X; holds, no test (becomes a test task in the report); does not hold; cannot check.
**Questions:** is the privacy policy's "no data collected, WebDAV the only connection" true of every code path? Does
any file name or size reveal more than `docs/security.md` says? The ledger is the cheapest way to catch drift: the
documents are public promises.
