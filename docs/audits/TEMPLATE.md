# Security and privacy audit: <version> (<kind: full | release | full + release>)

| | |
| --- | --- |
| Run | <YYYY-MM> (started <date, ET>, published <date, ET>) |
| Code audited | <tag or SHA>, from <last audited tag> (release audits) |
| Method | AI reviewers in lanes, independent verification (see "Method"); not a third-party audit |
| Result | <N Critical, N High, N Medium, N Low, N Info>; <N fixed, N open> |
| Advisories | <GHSA links, or none> |

## Summary

Three to six sentences: what was checked, what mattered, what changed. Say plainly if nothing was found.
A clean report is evidence, not proof.

## Scope

The lanes run (A to G) and their paths; for a release audit, the diff and the path-to-lane result
(`docs/audits/README.md` "Path to lane").

### Out of scope, and why

Each excluded area, with the reason (not reachable, owner device-only, third-party service, not yet built).
Also the "Not a finding" list: documented non-goals considered and left alone (`SECURITY.md` "Scope").

## Method

Models per lane and for verification; the commit pinned; tools and versions (swift, node, jq, curl, fuzz settings and
duration, the `check-security.sh` result, the date of the `npm audit` and OSV runs); what was run and what was only read.
Limits: what an AI source review cannot show.

## Findings

| ID | Severity | Lane | Title | Component | Status | Fixed in |
| --- | --- | --- | --- | --- | --- | --- |

One subsection per finding: the claim it breaks, the attack (who, with what access), the evidence, the fix, who is
affected (versions, platforms) and what users should do. A withheld finding shows id, severity, area and advisory link
only. Each severity carries one line of reasoning.

## Not confirmed

Candidate findings the verifier could not confirm, with the reason.

## Claims ledger

| Claim (document and sentence) | Verdict | Evidence (test or `file:line`) |
| --- | --- | --- |

Verdicts: holds with test X; holds, no test (name the test added or the follow-up); does not hold; cannot check.

## Privacy review

What leaves the device (each connection, with the policy line that names it); logging; telemetry (none); metadata in
vault files and file names compared with `docs/security.md` "What others can see"; the privacy manifests and the App
Store labels.

## Dependencies and release integrity

Swift and npm packages with versions; advisories found; the pins (`Package.resolved`, the lockfile, the Actions);
`gh attestation verify` run on the current release, summarized; the allow-list review (`scripts/security-allow.txt`).

## Follow-ups

Tests to add, documents to change and items for the next run, measured against the previous report: is each earlier
finding still fixed, and does it have a regression test?

## Reports from outside the audit

Advisories received since the last run, and what became of each.
