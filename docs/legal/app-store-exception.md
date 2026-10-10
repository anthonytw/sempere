# License and App Store distribution

> Not legal advice. The maintainer decided the policy below; a lawyer should still read
> `LICENSE-EXCEPTION` before the first App Store release.

## Decision

Sempere is licensed **GPL-3.0-or-later with an App Store exception**: the GNU GPL version 3
(`LICENSE`) plus an *additional permission* under GPLv3 section 7 (`LICENSE-EXCEPTION`).
There is **no contributor licence agreement**. Contributors keep their copyright and license
their contributions under the same terms as the project (inbound = outbound, see
`CONTRIBUTING.md`), certified with the Developer Certificate of Origin sign-off.

The App Store listing is named **Sempere**; Sempere is the project, format and CLI name.

## Why an exception is needed

The FSF and others hold that Apple's App Store terms (usage rules, device limits, no way to pass
on the freedoms of GPLv3 sections 6 and 10) are a "further restriction" that GPLv3 does not
allow when *someone other than the copyright holder* distributes GPL code there. A sole
copyright holder is not bound by their own licence and can ship, but every outside contribution
adds a holder whose code could then only be distributed under the plain GPL. Precedent: VLC for
iOS was pulled from the App Store in January 2011 after a contributor complained, and returned
after relicensing with contributor consent.

GPLv3 section 7 lets the copyright holders add *additional permissions* that loosen the licence
for everyone (the GCC Runtime Library Exception and the OpenSSL linking exceptions are the
established pattern). With the exception in place, every contribution arrives already licensed
for App Store distribution, so no relicensing right has to be collected from contributors, and
any third party may ship a fork there under the same conditions.

## What the exception does and does not do

- It lets anyone convey an *object code* build through an application distribution service
  under that service's terms, as long as the complete Corresponding Source stays available
  under the GPL (with the exception) from a public location named in the listing, and the
  permission is not used to restrict anyone's GPL rights in the source.
- It does **not** relicense the source, allow closed-source builds, or let anyone change the
  licence later. The maintainer has no right beyond other contributors' to do those things.
- Recipients may remove the exception from their copy, as section 7 allows.
- It does not by itself decide whether Apple's terms satisfy its conditions in every case; the
  proviso (source stays public, no new restrictions on source) is what keeps it within the spirit
  of the GPL. A lawyer may wish to narrow or reword it.
- It covers only this repository's code. Dependencies keep their licences; they must be
  App-Store-compatible (swift-crypto and swift-argument-parser are Apache-2.0; the app's
  equation typesetter SwiftMath is MIT, with OpenType math fonts under the SIL Open Font
  License or the GUST Font License).

## Consequences for the project

- Every file's effective licence is `GPL-3.0-or-later WITH LicenseRef-Sempere-App-Store-Exception`.
  The root `README.md` and `LICENSE-EXCEPTION` state it; per-file headers are not required.
- Code copied in from elsewhere must be under a licence compatible with GPL-3.0-or-later *and*
  with App Store distribution (MIT, BSD, Apache-2.0, ISC). Code under GPL-only without this
  permission, or AGPL, cannot be accepted: the exception could not apply to it.
- Release tarballs and the Homebrew package ship `LICENSE` and `LICENSE-EXCEPTION`.
- The App Store listing and the in-app About screen (Settings ▸ About ▸ About Sempere ▸ Source
  Code) link to the source repository (the exception's condition 1). A revised exception for a
  lawyer to review is drafted, not applied, in `docs/appstore/app-store-exception-draft.md`.
