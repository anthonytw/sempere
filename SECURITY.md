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
| Full + release | 2026-11 | 1.1 | [2026-11-1.1](docs/audits/2026-11-1.1.md) |

The first audit, a full audit of 1.1, was also 1.1's release audit; its fixes shipped in 1.1.0.

## Verifying releases

The tarballs of v1.0.0 and v1.0.1 carry GitHub build provenance attestations:
`gh attestation verify FILE --repo anthonytw/sempere`. Later releases are built on the maintainer's Mac and carry
none. From 1.1.0 on, each release's tag and its `SHA256SUMS` (the checksums of the tarballs) are signed by the
maintainer, the person, with their own SSH key on their own account after the build: `SHA256SUMS.sig`. To check a
download, take the public key from this repository (`packaging/allowed_signers`, never from the release itself):

```
maintainer namespaces="git,file" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKpJBs4KAzf5EO5EadPEzOliAJDlItvTr7OtnnAeUCI3
fingerprint SHA256:u94X5C2t2zAT9krLN4+LLwC3UI/z8d0v0tmuq6y90fM (awertz@pm.me)
```

Compare that fingerprint in three places, not one: this file, the footer of every GitHub release's notes, and the
project website's security page. A change of key changes all three, and the notes of the release that rotates it say
so; a fingerprint that differs between them is a reason to stop and write to the address above. In this repository the
key is under code-owner review (`.github/CODEOWNERS`), so only the maintainer can change `packaging/allowed_signers`.

Then:

```
shasum -a 256 -c SHA256SUMS        # sha256sum -c on Linux
ssh-keygen -Y verify -f packaging/allowed_signers -I maintainer -n file -s SHA256SUMS.sig < SHA256SUMS
```

To check a release tag the same way (`git show origin/main:packaging/allowed_signers > signers` in a clone):
`git -c gpg.ssh.allowedSignersFile=signers tag -v vX.Y.Z`.
