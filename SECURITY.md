# Security policy

Sempere is encryption software; please report vulnerabilities privately.

## Reporting

Use GitHub's private vulnerability reporting: open
<https://github.com/anthonytw/sempere/security/advisories/new> (Security tab →
"Report a vulnerability"). Only you and the repository's maintainers see the report. Do not open a public
issue or pull request for a security problem. Include the affected component (`Sources/Age`,
vault format, CLI, app, web viewer), the version or commit, and steps or a synthetic test vault
that reproduce it. Never include real keys or notes.

## What happens next

This is a volunteer-run project, so these are aims, not promises:

1. **Acknowledge.** You get a reply on the report within a week, saying whether it reproduces
   and how serious it looks (the severity scale of `docs/security-review-2026-10.md`: someone
   can read notes or plant content that passes as authentic; a documented guarantee does not
   hold; defence in depth).
2. **Fix.** The fix is developed in the advisory's private fork, with a regression test, and
   you are asked to check it if you wish. Fixes are prioritised by impact.
3. **Publish.** Once a fixed release is out, the advisory is published as a GitHub Security
   Advisory. For a serious issue (anything that exposes note content or keys, or lets someone
   plant content that passes as authentic) a CVE is requested through GitHub. The timing is
   agreed with you; the default is publication with the fixed release.
4. **Tell users.** The release notes and `CHANGELOG.md` say who is affected (which versions,
   platforms and settings), what could happen, and what to do (update; and, if keys or
   content may be exposed, for example rotate the vault's key with `sempere vault recipients
   replace`). The advisory links to them.

You are credited in the advisory and the release notes unless you prefer not to be.

## Scope

In scope: breaking confidentiality or integrity of notes (age implementation, vault tag,
key handling, passphrase-wrapped keys), recovering plaintext or keys from vault files,
planting notes that decrypt without a key holder's cooperation, parser crashes or resource
exhaustion on hostile vault, `.note` or PDF input, and the release pipeline's integrity.

Out of scope: threats that need the unlocked device or the user's identity file, the
metadata a storage provider can see by design (file names, sizes and times; see `DESIGN.md`),
and age's own non-goals (no signatures). What the encryption protects and what it does not is
summarised in [`docs/security.md`](docs/security.md).

## Supported versions

Only the latest release and `main`. The on-disk format is versioned (`docs/format.md`);
fixes never silently change it.

## Verifying releases

Release tarballs carry GitHub build provenance attestations:
`gh attestation verify FILE --repo anthonytw/sempere`, plus `SHA256SUMS`.
