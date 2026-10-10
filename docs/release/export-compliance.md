# Export compliance (encryption)

> **The decision, made by the maintainer (`docs/HANDOFF.md`):** Sempere is mass-market software
> using standard, published encryption at full strength. In App Store Connect it is "exempt",
> and France is left out of availability until the ANSSI declaration
> (`docs/appstore/france-declaration.md`) is approved. This page records the research behind that
> decision, the exact answers to give, and what changes if France is added.
>
> This is a summary of public rules, not legal advice. Apple's own wording is: "it's your
> responsibility to review the Export Administration Regulation", and "you're responsible for all
> liabilities associated with misinterpretation of export regulations or claiming exemption
> inaccurately" ([A2]). If in doubt, ask BIS or a lawyer.

## Summary of the answers

| Question | Answer |
| --- | --- |
| `ITSAppUsesNonExemptEncryption` (Info.plist) | **`NO`**, in `Apps/Sempere/SempereInfo.plist`, while France is excluded. Builds then skip the per-build encryption question. |
| `ITSEncryptionExportComplianceCode` | **Not set.** Apple issues one only after it approves uploaded documentation; here that means the French declaration. |
| App Store Connect: type of encryption | "Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system" (not proprietary, not "none") |
| App Store Connect: available in France? | **No.** Leave France out of Pricing and Availability. |
| Documentation upload (CCATS, French declaration) | **None** while France is excluded. A CCATS is only for proprietary algorithms ([A1]). |
| US classification | **ECCN 5D992.c**, mass-market encryption software (Category 5 Part 2, Note 3), self-classified under **License Exception ENC § 740.17(b)(1)** |
| Annual self-classification report (BIS) | **Not required.** Since the rule of 29 March 2021, finished end-user mass-market software needs none. Reports remain for mass-market components, chips, chipsets and their executable software ([E3], [E4]). |
| CCATS / BIS classification request | Not required: the item is self-classified ([E1]). |
| Encryption registration (ERN) | Does not exist any more: BIS removed it in 2016 ([E5]). |
| BIS/NSA e-mail for the public source code (§ 742.15(b)) | Not required: since 2021 it applies only to *non-standard* cryptography ([E3], [E4]). |
| France | An ANSSI declaration is needed before supplying the app in France (`docs/appstore/france-declaration.md`). |

## "Non-exempt" means two different things

The task brief called the app "non-exempt encryption under US EAR". Apple's key uses the word in a
narrower sense, and the two readings give different answers, so they are kept apart here.

- **Under the EAR, the app is not exempt; it is authorised.** It implements encryption beyond
  what the OS provides. It is therefore subject to the EAR as 5D992.c mass-market software, and
  it is exported under License Exception ENC § 740.17(b)(1) by self-classification. That
  authorisation needs no filing for this kind of item (table above). The EAR's "exclusions"
  (Note 4 to Category 5 Part 2) do not apply: the app's primary function is information
  security for the user's data, not authentication, copy protection or the like.
- **For Apple, "exempt" means "no documentation to upload".** Apple's key description reads:
  set it to `NO` "if your app doesn't use encryption, or if it only uses forms of encryption that
  are exempt from export compliance documentation requirements" ([A3]). Apple's documentation
  table ([A1]) gives three cases:

  | Encryption algorithm in use | Required documentation |
  | --- | --- |
  | Limited to that within the Apple operating system | No documentation required |
  | An industry standard algorithm, not provided within the Apple operating system | Upload your French encryption declaration¹ |
  | Proprietary algorithms not accepted by international standard bodies (IEEE, IETF, ITU) | Upload your US CCATS and your French encryption declaration¹ |

  ¹ "French encryption declaration form is only required if you're distributing your app on the
  App Store in France."

  Sempere falls in the middle row (see the table of algorithms below). With France excluded, no
  documentation is required, so `NO` is the correct value for Apple's key. **If France is ever
  added, it becomes `YES`**, together with the `ITSEncryptionExportComplianceCode` Apple issues
  once it approves the declaration.

The earlier draft of this page (formerly `docs/appstore/export-compliance.md`) said to set `YES`.
That draft predates the decision to exclude France and read "non-exempt" in the EAR sense.
Build 2 was answered in App Store Connect as exempt, and the key has been `NO` since #55. This
page replaces that draft.

## What the app does cryptographically

The app encrypts the user's own notes in the open **age** format (`Sources/Age`). The format,
its STREAM chunking, its HPKE recipient stanzas and scrypt are the app's own code. The primitives
come from **swift-crypto**, which on Apple platforms is a thin layer over CryptoKit (BoringSSL is
compiled only off Apple platforms). Using CryptoKit primitives does not make this "encryption
within the operating system" in Apple's sense: the app implements the age protocol on top of
them, so the middle row of Apple's table applies.

| Purpose | Algorithm | Standard |
| --- | --- | --- |
| Recipient keys (vault encryption), post-quantum hybrid | ML-KEM-768 + X25519 (X-Wing; age `MLKEM768-X25519`) through HPKE | FIPS 203, RFC 7748, RFC 9180, C2SP age |
| Payload and file-key encryption | ChaCha20-Poly1305, chunked STREAM | RFC 8439 |
| Key derivation | HKDF-SHA-256 | RFC 5869 |
| Header and per-vault integrity tags | HMAC-SHA-256 | RFC 2104, FIPS 180-4 |
| Passphrase-protected key files | scrypt, local implementation tested with the RFC vectors | RFC 7914 |
| Legacy vaults (read for migration only) | X25519 | RFC 7748 |

Every algorithm is published by a recognised standards body (IETF, NIST) or is the C2SP age
specification built from them, used at full standard strength. There is no proprietary or
non-standard cryptography, no key escrow and no user-configurable key length. Encryption
protects the user's own data at rest, on storage the user chooses. Its only network
code is a WebDAV client (vaults on a server the user sets up) built on `URLSession`, so its TLS
is the OS's; iCloud Drive and Files providers are the system's too.

Other OS-provided protection the app relies on: the Keychain and Face ID / Touch ID (vault keys
the user chooses to remember), and data protection classes on files in the app container. These
belong to the "within the Apple operating system" row and add nothing to the answers.

## Why mass market (5D992.c)

Note 3 to Category 5 Part 2 ("cryptography note") applies, and its conditions hold:

1. **Generally available to the public:** sold, or here given away, from stock through the App
   Store without restriction.
2. **The cryptographic functionality cannot easily be changed by the user:** the algorithms
   and sizes are fixed in the code.
3. **Installed by the user without further substantial support from the supplier.**
4. **Details of the item are accessible and will be provided on request:** the source code and
   `docs/format.md` are public.

Without Note 3, the item would be 5D002. With it, the item is 5D992.c, and § 740.17(b)(1) lets the
exporter self-classify it with no BIS submission. After the 2021 rule, an annual
self-classification report is required only for the (b)(1) items the rule kept it for:
components, chips, chipsets, electronic assemblies, field-programmable logic and their
executable software ([E3], [E4]). Sempere is none of those.

Keep this page and the algorithm table as the classification record. BIS may ask for it, and
ANSSI's file references it.

## The open-source path (CLI, source code)

The source code and the CLI release binaries are published on GitHub. Under § 742.15(b),
publicly available encryption source code is not subject to the EAR. Since 2021, the e-mail
notification to BIS and the NSA is needed only for "non-standard cryptography"; nothing here is
non-standard ([E3], [E4]). Object code built from that published source follows it (§ 734.3(b)(3),
§ 742.15(b)).

This path covers the CLI on GitHub Releases. The App Store binary is not relied on here: it is
covered by the mass-market self-classification above whatever reading of "published" one takes.
BIS's guidance on free apps also starts from the mass-market classification ([E2]).

## Sanctions are separate

Authorisation under ENC does not cover embargoed destinations (Country Groups E:1/E:2) or denied
parties. App Store availability already excludes the embargoed territories, and the developer
sells to no one directly. No action is needed beyond not adding such territories.

## App Store Connect: the exact steps

With `ITSAppUsesNonExemptEncryption = NO` in the Info.plist, App Store Connect asks nothing per
build. If it asks anyway (a build without the key, or a new platform version), the questions as
reported by developers in 2025–2026 are below. Check the wording on screen, since Apple changes it.

1. "What type of encryption algorithms does your app implement?" → **Standard encryption
   algorithms instead of, or in addition to, using or accessing the encryption within Apple's
   operating system.**
2. "Is your app going to be available on the App Store in France?" → **No.**
3. Save. No documentation is requested. The build becomes available for TestFlight and review.

Pricing and Availability: every territory except France (already set, `docs/HANDOFF.md`). The
same Info.plist and answers cover the Mac (Catalyst) build: one app record, one bundle and one
encryption answer for both platforms.

### When France is added

1. Get the ANSSI declaration (`docs/appstore/france-declaration.md`) and upload it under App
   Information → App Encryption Documentation.
2. When Apple approves it, it shows a key value. Add to `Apps/Sempere/SempereInfo.plist`:

   ```xml
   <key>ITSAppUsesNonExemptEncryption</key>
   <true/>
   <key>ITSEncryptionExportComplianceCode</key>
   <string>(the value Apple shows)</string>
   ```

3. Add France to availability. `scripts/release-check.sh` warns about a `YES` without a code,
   because such builds would ask the question every time.

## Sources

Apple:

- [A1] App Store Connect Help, "Export compliance documentation for encryption", the table of
  required documentation. <https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption>
- [A2] App Store Connect Help, "Overview of export compliance" (the two paths; France; the
  liability wording). <https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance>
- [A3] Apple Developer Documentation, "Complying with encryption export regulations" and the
  `ITSAppUsesNonExemptEncryption` key. <https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>,
  <https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption>
  (the session that wrote this page could not render these two pages; the key description is
  quoted from earlier copies. Re-read them before relying on the wording.)

US (BIS, EAR):

- [E1] 15 CFR § 740.17 (License Exception ENC), § 742.15 (encryption items), § 734.3(b)(3)
  (published software), Supplement No. 1 to Part 774, Category 5 Part 2 (Notes 3 and 4).
  <https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-740/section-740.17>,
  <https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-742/section-742.15>
- [E2] BIS, "Encryption items not subject to the EAR" (the publicly available path, and the
  free-app example that starts from a 5D992.c classification).
  <https://www.bis.gov/learn-support/encryption-controls/encryption-items-not-subject-to-ear>
- [E3] BIS final rule of 29 March 2021, "Wassenaar Arrangement 2019 Plenary Decisions…;
  Revisions to Encryption Provisions", 86 FR 16482 (FR Doc. 2021-06253). It removed the
  self-classification report for most mass-market items and the § 742.15(b) notification for
  standard cryptography.
  <https://www.federalregister.gov/documents/2021/03/29/2021-06253>
- [E4] Law-firm summaries of [E3]: Thompson Hine, "BIS eliminates most mass market encryption
  reporting obligations"
  <https://www.thompsonhine.com/publications/bis-eliminates-most-mass-market-encryption-reporting-obligations>;
  Jones Day, "Commerce reduces requirements relating to mass-market encryption items and
  publicly available software"
  <https://www.jonesday.com/en/insights/2021/04/commerce-reduces-requirements-relating-to-massmarket-encryption-items-and-publicly-available-software>;
  Venable <https://www.venable.com/insights/publications/2021/03/export-administration-rules-are-revised-to-elim>;
  Baker McKenzie
  <https://sanctionsnews.bakermckenzie.com/bis-updates-reporting-requirements-relating-to-mass-market-encryption-items-and-publicly-available-software-and-also-updates-certain-classifications/>.
- [E5] BIS final rule of 15 September 2016 (81 FR 64656), which removed encryption registration
  (ERN) and folded mass-market items into § 740.17(b)(1).

France: ANSSI, "Contrôle relatif à un moyen de cryptologie", <https://cyber.gouv.fr>, and
`docs/appstore/france-declaration.md`.

The network policy of the session that wrote this page blocked ecfr.gov, bis.gov,
federalregister.gov and the law-firm sites. The EAR points above come from search-result
summaries of those pages and from the cited rules, not from a fresh read of the current eCFR
text. Before relying on them, read [E1] and [E3] once (TODO(maintainer)).
