# Sempere licence agreement (App Store) — DRAFT

> **Draft for the maintainer and a lawyer. Not legal advice. Not in use yet.** Until the
> maintainer pastes a reviewed version into App Store Connect (App Information ▸ License
> Agreement ▸ Edit ▸ custom licence), the App Store applies Apple's standard licence
> agreement. Placeholders: `TODO(user)`. Checklist: `docs/release/app-store.md`
> ("License agreement") and the First release rows of `docs/ROADMAP.md`.

How this text was built:

- **Sections 1–3** are the GNU GPL v3 terms that matter to someone who installs the app,
  restated in plain words: the source is free software (GPL v3 or later, with the App Store
  exception in `LICENSE-EXCEPTION`), sections 15 (no warranty) and 16 (limitation of
  liability) in plain form, and section 17 (how to read 15–16 where local law limits them).
  The GPL itself stays the licence of the source; nothing here may take away a right it gives
  (the exception's condition 2).
- **Section 4** carries the minimum terms Apple requires in a custom licence agreement
  (Apple's "Instructions for Minimum Terms of Developer's End-User License Agreement": the
  agreement is with the developer, not Apple; support; warranty and refunds; product claims;
  intellectual property claims; legal compliance; contact; third-party terms; Apple as third-party
  beneficiary). A lawyer should check them against Apple's current wording.
- Wording rule (maintainer, 2026-10-09): plain and calm, never alarming or legalistic; describe
  what the app does and its limits, never promise outcomes.

---

## Sempere licence agreement

This agreement is between you and Anthony Wertz ("the developer") and covers the Sempere app
you get from the App Store (the "App"). By installing or using the App you accept it.

### 1. Free software

Sempere is free software. Its source code is published at
<https://github.com/anthonytw/sempere> under the GNU General Public License, version 3 or (at
your option) any later version, with an additional permission that allows distribution
through the App Store (the "App Store exception"). You may use, study, share and change that
source code under those terms; the full texts are in the App (Settings ▸ About ▸ About Sempere ▸ License) and
in the repository. Third-party components keep their own licences, listed in Settings ▸ About ▸ About Sempere ▸
Acknowledgments.

This agreement covers the copy of the App you received from the App Store. It does not limit
any right the GNU GPL gives you over the source code. If a term here conflicts with a right
the GNU GPL gives you, the GNU GPL prevails.

### 2. No warranty

The App is provided "as is", without warranty of any kind, express or implied, including
any implied warranty of merchantability or fitness for a particular purpose, to the extent
the law allows. You bear the whole risk as to the quality and performance of the App. If it
turns out to be defective, you bear the cost of any servicing, repair or correction.

In plain terms: Sempere is built with care and its design is documented in the open, but
nobody promises that it is free of errors or that it will keep your notes safe in every
case. In particular:

- Your notes are encrypted with a key that you hold. If every copy of that key (and of any
  passphrase-protected copy) is lost, nobody can open the notes, including the developer.
- Keep backups of your vault and keep your recovery kit somewhere safe. The App helps you do
  both, but whether they exist and work is up to you.

### 3. Limitation of liability

To the extent the law allows, the developer, and anyone else who changes or distributes the
App as the GNU GPL permits, is not liable to you for damages of any kind arising from the use
of the App or your inability to use it, including general, special, incidental or
consequential damages, and including loss of data or data being rendered inaccurate, even if
told that such damages were possible.

Where the law of your country does not allow these exclusions or limits, they apply as far as
that law allows, and a court should apply the local law that most closely approximates a
complete waiver of liability, as section 17 of the GNU GPL asks. Nothing in this agreement
limits liability that cannot be limited by law, or rights you have as a consumer that cannot be
waived. `TODO(user)`: a lawyer to confirm this paragraph for the EU and the UK.

### 4. Terms for apps distributed through the App Store

a. **Who this agreement is with.** This agreement is between you and the developer only,
   not Apple. The developer, not Apple, is responsible for the App and its content.

b. **Licence.** You may use the App on any Apple-branded device you own or control, as the
   App Store's Usage Rules allow, and, as section 1 says, under the GNU GPL for the source
   code.

c. **Support.** The developer is solely responsible for any maintenance and support of the
   App, as far as this agreement or the law requires any. Apple has no obligation to provide
   maintenance or support for the App. Support is offered on a volunteer basis through the
   project's issue tracker: <https://github.com/anthonytw/sempere/issues>.

d. **Warranty.** The App comes with no warranty (section 2). If any warranty applies under
   the law and the App fails to conform to it, you may notify Apple, and Apple will refund
   the purchase price, if any. To the maximum extent the law allows, Apple has no other
   warranty obligation with respect to the App, and any other claims, losses, liabilities,
   damages, costs or expenses attributable to a failure to conform to a warranty are the
   developer's responsibility, as far as this agreement does not exclude them.

e. **Product claims.** The developer, not Apple, is responsible for addressing any claims by
   you or a third party relating to the App or your possession or use of it, including
   product liability claims, claims that the App fails to conform to a legal or regulatory
   requirement, and claims under consumer protection, privacy or similar laws. This
   agreement limits the developer's liability as far as the law allows (section 3).

f. **Intellectual property.** If a third party claims that the App or your possession and
   use of it infringes their intellectual property rights, the developer, not Apple, is
   solely responsible for the investigation, defence, settlement and discharge of that claim.

g. **Legal compliance.** You represent that you are not located in a country subject to a
   U.S. Government embargo or designated by the U.S. Government as a "terrorist supporting"
   country, and that you are not listed on any U.S. Government list of prohibited or
   restricted parties. The App contains encryption; see `docs/release/export-compliance.md`
   in the repository for its classification.

h. **Contact.** Questions, complaints or claims about the App: `TODO(user)`: a postal
   address and an e-mail address (or the support page of the project website). Security
   problems: <https://github.com/anthonytw/sempere/security/advisories/new>.

i. **Third-party terms.** You must comply with any third-party terms that apply when you use
   the App (for example your storage provider's terms). The App itself requires no account
   with the developer or any third party.

j. **Third-party beneficiary.** Apple and its subsidiaries are third-party beneficiaries of
   this agreement, and on your acceptance of it Apple will have the right (and will be deemed
   to have accepted the right) to enforce it against you as a third-party beneficiary.

### 5. General

`TODO(user)`: governing law and venue (or none, leaving it to the consumer's local law), and
whether to keep a severability clause. If a part of this agreement is held unenforceable, the
rest stays in effect.
