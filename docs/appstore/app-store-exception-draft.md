# GPL section 7 additional permission (App Store exception) — DRAFT, NOT APPLIED

> **For the maintainer and a lawyer to decide. Not legal advice. Nothing here changes the
> licence:** `LICENSE` and `LICENSE-EXCEPTION` stay as they are until the maintainer decides
> otherwise in a separate change.

## Where things stand

The repository already carries an additional permission, `LICENSE-EXCEPTION` (maintainer
decision recorded in `docs/HANDOFF.md`, background in `docs/legal/app-store-exception.md`).
It was written before the App Store submission was planned in detail. This page is a
candidate revision of it for a lawyer to review, with the reasons for each change, so the
maintainer can choose between:

1. keeping `LICENSE-EXCEPTION` as it is;
2. replacing it with the text below (or a lawyer's version of it) before the first release.

Because contributors license their work under the project's terms (inbound = outbound,
`CONTRIBUTING.md`), a narrower or reworded permission can be adopted for new releases while
earlier releases keep the one they shipped with. Widening it later would need the agreement of
the contributors whose code it covers; doing it before outside contributions arrive is easiest.

## What the candidate changes, and why

| Point | Current `LICENSE-EXCEPTION` | Candidate | Why |
| --- | --- | --- | --- |
| Which GPL terms it relaxes | "to the extent those terms and rules would otherwise conflict with the conditions of the GNU GPL" | Names them: section 10 (no further restrictions), section 6's Installation Information and the requirement to pass on the licence, section 3 (technical measures) | The known conflicts are the store's usage rules and licence agreement, its signing and FairPlay encryption, and device limits. Naming them makes the scope easier to read and harder to stretch. |
| Installation Information (GPL §6, "User Products") | Not mentioned | Waived for store copies, on condition that the source builds with the platform maker's free tools and can be installed on the user's own device with them | iPads and Macs are User Products; the store's signing keys cannot be handed out. Xcode lets anyone install their own build on their own device with a free Apple account; to be checked: that the app needs no entitlement a free account lacks, and that `README.md` says how. |
| The store's licence agreement | Covered implicitly by "terms and usage rules" | Explicit: the store copy may carry the store's licence agreement or the developer's custom one (`docs/appstore/eula.md`), as long as it does not limit rights in the source | The custom agreement is drafted to defer to the GPL; the permission should say that agreements may not restrict the source. |
| Where the source must be | "a public location that you identify in the work's listing or description" | The same, and also named inside the app (About) | Users meet the app, not the listing; the About screen now links the source. |
| Which services | Services "operated by the maker of the platform the work runs on" | Unchanged | Keeps third-party stores (which could add other restrictions) out. A lawyer may wish to name Apple's services explicitly instead. |

## Candidate text

```text
Additional permission under GNU GPL version 3 section 7 (the "App Store exception")

This permission is granted by the copyright holders of Sempere ("the Program"), which is
licensed under the GNU General Public License, version 3 or (at your option) any later
version (the "GPL").

1. Definitions. A "Distribution Service" is an application distribution service operated by
   the maker of the platform on which the conveyed work runs (for example Apple's App Store
   and TestFlight). "Service Terms" are the terms, usage rules and licence agreements under
   which a Distribution Service delivers applications to its users, and the technical
   measures it applies to them (such as code signing and encryption of the delivered copy).

2. Permission. If you convey a covered work in object code form through a Distribution
   Service, you may do so subject to the Service Terms, notwithstanding:
   (a) the requirement of GPL section 10 not to impose further restrictions on the exercise
       of the rights granted by the GPL;
   (b) the requirements of GPL section 6 to convey the object code under the GPL and to
       provide Installation Information for a User Product; and
   (c) GPL section 3, as far as the Distribution Service's technical measures are concerned,
   but only to the extent that the Service Terms conflict with those requirements.

3. Conditions. This permission applies only if:
   (a) the Corresponding Source of the work, under the GPL with this permission, is made
       available at no charge, at the same time, from a public network location that is
       identified in the work's listing on the Distribution Service and within the work
       itself;
   (b) that Corresponding Source can be built, and the result installed on the recipient's
       own device, with tools the platform maker makes available to the public at no charge;
       and
   (c) neither the Service Terms nor any licence agreement you add restrict anyone's rights
       under the GPL with respect to the Corresponding Source.

4. Scope. This permission does not relicense the Program's source code, and it does not
   apply to third-party code that is part of a covered work but not part of the Program,
   which stays under its own licence. When you modify the Program you may extend this
   permission to your version, but you are not obliged to. As GPL section 7 allows, you may
   remove this permission from your copy of a covered work, or from any part of it.

SPDX: GPL-3.0-or-later WITH LicenseRef-Sempere-App-Store-Exception
```

## Questions for the lawyer

- Is waiving section 6's Installation Information for store copies acceptable under section 7
  (which allows additional permissions, i.e. exceptions to the licence's conditions), and is
  condition 3(b) (free tools let the user install their own build) the right counterweight?
- Does section 3 need to be named at all, given that the app's own technical measures
  (encryption of notes) are not a technical protection measure in the GPL's sense?
- Should the permission name Apple's services rather than define "Distribution Service"?
- Should the SPDX `LicenseRef` change name (for example `-2`) if the text changes, so the two
  versions are distinguishable?
- Is an in-app source link (condition 3(a)) satisfied by the About screen's link
  (Settings ▸ About ▸ Source Code)?

## Checklist (needs the maintainer)

- [ ] Decide: keep `LICENSE-EXCEPTION`, or adopt a reviewed version of this text.
- [ ] If adopting: replace `LICENSE-EXCEPTION`, update `docs/legal/app-store-exception.md`,
      `CONTRIBUTING.md` and the README's licence line in one PR, before the first release.
- [ ] Have the custom licence agreement (`docs/appstore/eula.md`) reviewed together with it.
