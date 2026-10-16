## What and why

<!-- One or two sentences. -->

## Tests run

<!-- The targeted tests you ran beyond the PR gate (scripts/local-ci.sh: package tests, Mac Catalyst
unit tests, iOS compile check) and their results, one per line, for example:
- `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/MacWindowUITests`: passed
- `scripts/app.sh test-phone`: passed
or "None beyond the gate: <why>". The "PR lists tests run" check fails while this section is empty. -->

## Checks

- [ ] `swift build --build-tests && swift test` pass (and `scripts/check-portability.sh`)
- [ ] `docs/format.md` updated first if the on-disk format changed
- [ ] `changelog.d/<topic>.md` fragment added for user-visible changes (not `CHANGELOG.md`)
- [ ] I have read [CONTRIBUTING.md](../CONTRIBUTING.md). My commits are signed off (`git commit -s`, Developer Certificate of Origin), and I license my contribution under the project's terms: GPL-3.0-or-later with the [App Store exception](../LICENSE-EXCEPTION). I keep my copyright; there is no CLA.
