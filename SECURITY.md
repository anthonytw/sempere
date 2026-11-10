# Security policy

Sempere is encryption software; please report vulnerabilities privately.

## Reporting

Use GitHub's private vulnerability reporting: open
<https://github.com/anthonytw/sempere/security/advisories/new> (Security tab →
"Report a vulnerability"). Only you and the repository's maintainers see the report. Do not open a public
issue for a security problem. Include the affected component (`Sources/Age`,
vault format, CLI, app, web viewer), the version or commit, and steps or a synthetic test vault
that reproduce it. Never include real keys or notes.

## What happens next

This is a volunteer-run project, so these are aims, not promises:

1. **Acknowledge.** You get a reply on the report within a week, saying whether it reproduces
   and how serious it looks (severity, highest first: someone
   can read notes or plant content that passes as authentic; a documented guarantee does not
   hold; defense in depth).
2. **Fix.** The fix is developed in the advisory's private fork, with a regression test, and
   you are asked to check it if you wish. Fixes are prioritized by impact.
3. **Publish.** Once a fixed release is out, the advisory is published as a GitHub Security
   Advisory. For a serious issue (anything that exposes note content or keys, or lets someone
   plant content that passes as authentic) a CVE is requested through GitHub (see [Audits](#audits) for which findings get one). The timing is
   agreed with you; the default is publication with the fixed release.
4. **Tell users.** The release notes and `CHANGELOG.md` say who is affected (which versions,
   platforms and settings), what could happen, and what to do (update; and, if keys or
   content may be exposed, for example move the notes to a new vault until key replacement ships
   in a later version). The advisory links to them.

You are credited in the advisory and the release notes unless you prefer not to be.

## Scope

In scope: breaking confidentiality or integrity of notes (age implementation, vault tag,
key handling, passphrase-wrapped keys), recovering plaintext or keys from vault files,
planting notes that decrypt without a key holder's cooperation, parser crashes or resource
exhaustion on hostile vault, `.note` or PDF input, and the release pipeline's integrity.

Out of scope: threats that need the unlocked device or the user's identity file, the
metadata a storage provider can see by design (file names, sizes and times; see `DESIGN.md`),
and age's own non-goals (no signatures). What the encryption protects and what it does not is
summarized in [`docs/security.md`](docs/security.md).

## Supported versions

Only the latest release and `main`. The on-disk format is versioned (`docs/format.md`);
fixes never silently change it. Fixes for findings of a security audit (below) follow the same
disclosure path as an outside report: private first, published with the fixed release.

## Audits

Besides taking reports, the project audits itself on a schedule and publishes what it found.

- **A release audit for every minor release** (1.1, 1.2, ...): the changes since the last audited version, reviewed
  before the App Store build is submitted. A patch release gets one only if it touches security-relevant code.
- **A full audit every six months** (aimed at April and October): every area of the code on `main`, plus a refresh of
  the dependencies. When a full audit falls near a release, one report covers both.
- **Reports are published after the fixes ship**, in [`docs/audits/`](docs/audits/README.md): what was checked,
  what was found, what was fixed, and which documented claims were checked against the code. Until a fix is in a
  release, its details stay in a private security advisory. A finding that cannot ship within 90 days is published
  with its details withheld (id, severity, area, advisory link). An audit that finds nothing is still published.
- **The reviewers are AI models** working from the source, with a second model checking each finding. They can miss
  things. A clean report is evidence, not proof, and it is not a third-party audit or a certification.

Severity, highest first. GitHub advisories use Critical, High, Moderate and Low; Medium here is GitHub's Moderate.

| Rating | Meaning |
| --- | --- |
| Critical | Someone without a key reads notes or recovers a key, or plants content that passes as authentic, remotely or from storage alone |
| High | The same, but it needs a precondition an attacker can plausibly get (a removed device, one captured file, a hostile WebDAV host) |
| Medium | A documented guarantee fails in a narrower case; notes or metadata reach a party the documents say cannot see them; hostile input crashes or exhausts the app |
| Low | Defense in depth, a missing hardening step, a document that overstates, an unlikely local-only leak |
| Info | An observation or a test gap; no action required |

A CVE is requested (through GitHub) for every published advisory rated High or Critical, and for a Medium that breaks a
stated guarantee in released versions. Low, Info, hardening and findings only in unreleased code get none.

| Audit | Date | Version | Report |
| --- | --- | --- | --- |

No audit is published yet. The first, a full audit of 1.1, is planned before 1.1 is submitted to the App Store; its row goes here when its fixes have shipped.

## Verifying releases

Release tarballs carry GitHub build provenance attestations:
`gh attestation verify FILE --repo anthonytw/sempere`, plus `SHA256SUMS`.
