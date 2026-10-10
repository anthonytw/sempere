# App Store submission (iPad, iPhone and Mac)

What the maintainer needs to submit Sempere to the App Store on iPadOS/iOS and macOS (Mac
Catalyst, universal purchase), prepared without touching App Store Connect. Everything here is
a draft for the maintainer to confirm. **TODO(maintainer)** marks a decision or a check only
the maintainer can make. Nothing was sent to Apple.

Related pages:

- [export-compliance.md](export-compliance.md): the encryption answers and Info.plist key.
- [`../appstore/screenshots.md`](../appstore/screenshots.md): the generated screenshots.
- [`../appstore/france-declaration.md`](../appstore/france-declaration.md): the ANSSI
  declaration, for later.
- [`../privacy/index.html`](../privacy/index.html): the privacy policy, as a GitHub Pages page.
  [`../appstore/privacy-policy.md`](../appstore/privacy-policy.md) is the same text, at the URL
  App Store Connect has today.
- `scripts/release-check.sh`: the automated checks (below).

Facts this page relies on (`docs/HANDOFF.md`): App Store Connect app "Sempere", id 6819333304,
iOS + macOS, bundle id `io.github.anthonytw.sempere`, team set only on the maintainer's Mac,
availability everywhere except France.

## 1. Release checks (`scripts/release-check.sh`)

```bash
scripts/release-check.sh          # exit 0 = ok
scripts/release-check.sh --list   # also every required-reason API use, as file:line
scripts/test-release-check.sh     # the checker's own tests (mutated copies of the project)
```

The script needs only bash and python3, so it runs on Linux. CI runs it, and its tests, in the
`release` job: on every PR that touches `Apps/`, the `Sources/` targets the app links, the scripts,
the privacy policy or `ci.yml`, and always on `main`. It takes seconds and needs no Mac. It fails when:

| Check | Why |
| --- | --- |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` differ between any targets or configurations, are not dotted integers, or an Info.plist hard-codes another value | An extension's `CFBundleShortVersionString`/`CFBundleVersion` must equal its app's, or the upload is rejected. The test targets are held to the same value. |
| `DEVELOPMENT_TEAM` (or a `DevelopmentTeam` target attribute) has a value anywhere under `Apps/` | The team is the maintainer's; it is passed on the command line (`docs/HANDOFF.md`), never committed. |
| `Apps/Sempere/SempereApp/PrivacyInfo.xcprivacy` or `Apps/Sempere/SempereWidgets/PrivacyInfo.xcprivacy` is missing or not a plist; tracking is on; tracking domains or collected data types are not empty | They back the "Data Not Collected" label (section 3). |
| A reason code is not one of Apple's for its category | Catches typos, which App Store Connect rejects. |
| A shipping target's sources (its folders plus the `Sources/` targets of the package products it links) call a required-reason API whose category its manifest does not declare | The manifest must follow the code. The scan uses the patterns in the script; a declared category with no use found is a warning. |
| A package product is linked that the script does not know | A new dependency must be mapped to its sources and its own privacy manifest checked. |
| An entitlements file has a key outside the allow-list, a referenced entitlements file is missing, or the Mac build has no sandbox | Section 6. |
| `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = YES`, a Mac-only bundle id, the app's bundle id changed, or an extension id not prefixed by the app's | Universal purchase needs one bundle id (section 6). |
| `ITSAppUsesNonExemptEncryption` is missing or not a boolean | [export-compliance.md](export-compliance.md). A `YES` without `ITSEncryptionExportComplianceCode` is a warning. |
| Networking (`URLSession`, `URLRequest`, Network.framework, sockets, CFNetwork streams, WebKit, Safari views, CloudKit, Multipeer, `FoundationNetworking`) in any non-test folder of `Apps/Sempere` or a `Sources/` target the app links, outside `NETWORK_ALLOWED` (the WebDAV client and `SempereApp/MathModels.swift`) | The privacy policy names the only connections the app makes (section 3, "Network code, exactly"). An allow-listed file with no networking left is a warning. Not caught: `Data(contentsOf:)` or `AVPlayer` on a remote URL (code review). |
| `MathModelCatalog.entries` is not `[]` | That makes the allowed model downloader reachable; the privacy documents call it inert. |
| A package pinned with an exact version in `project.pbxproj` resolves to another version in the project's `Package.resolved` (or that file is missing) | The version the privacy review looked at is the one that ships (SwiftMath, section 2). |
| With `--checkouts DIR` (CI's `app` job, after the packages resolve): SwiftMath uses networking, a required-reason API that neither its manifest nor the app's declares, or its checkout is not the pinned revision | Section 2, "Dependencies". The step prints its findings on one line. |

What it cannot check: the archive's own privacy report (Xcode → Organizer → the archive →
Generate Privacy Report), which also covers the binary's frameworks and SwiftMath's compiled form.
Run that once per release (checklist, section 8).

The CLI's release (`.github/workflows/release.yml`, [docs/releasing.md](../releasing.md)) has its
own guard: `scripts/changelog-section.sh` refuses a CHANGELOG section that still holds
`TODO(user)` or has no date in its heading.

## 2. Privacy manifests

Two bundles ship: the app and the widget extension (iOS only; `platformFilter = ios`). Each has
a `PrivacyInfo.xcprivacy` in its folder-synchronized group, which Xcode copies as a resource.

### App (`Apps/Sempere/SempereApp/PrivacyInfo.xcprivacy`)

- `NSPrivacyTracking` = false, `NSPrivacyTrackingDomains` empty, `NSPrivacyCollectedDataTypes`
  empty.
- `NSPrivacyAccessedAPICategoryUserDefaults`, reason **CA92.1**: the app reads and writes only
  its own defaults, with no app-group suite (`suiteName` appears nowhere).
- `NSPrivacyAccessedAPICategoryFileTimestamp`, reasons **C617.1** (files inside the app's
  container) and **3B52.1** (files the user granted access to through the document picker).

Not used, so not declared: **DiskSpace** (no `volumeAvailableCapacity…`, `NSFileSystemFreeSize`
or `statfs`), **SystemBootTime** (no `systemUptime` or `mach_absolute_time`; elapsed times use
Swift's `ContinuousClock`, which is not in Apple's list) and **ActiveKeyboards** (no
`activeInputModes`).

Every use, at commit time (regenerate with `scripts/release-check.sh --list`; line numbers move,
the files rarely do):

| Category | File:lines | What it does | Reason |
| --- | --- | --- | --- |
| FileTimestamp | `Apps/Sempere/SempereApp/BlobCache.swift:134,137,254,265,296` | Modification dates of the decrypted-attachment cache files: evict the least recently used, drop files of an earlier launch, touch a file on use | C617.1 |
| FileTimestamp | `Apps/Sempere/SempereApp/DrawingCache.swift:185,222,226` | The same for the encrypted per-page drawing cache | C617.1 |
| FileTimestamp | `Apps/Sempere/SempereApp/RenderCache.swift:233,291,295` | The same for the sealed image/PDF preview cache | C617.1 |
| FileTimestamp | `Apps/Sempere/SempereApp/AppModel+Windows.swift:248,250` | Purges drag-out PDF exports older than ten minutes from `$TMPDIR/SempereExport` | C617.1 |
| FileTimestamp | `Sources/Sempere/FileIO.swift:233,234` | `fstat` on every vault file opened for reading, to refuse anything but a regular file (`openRegularFile`); vault files are in folders the user picked, or in the app's own Documents | 3B52.1, C617.1 |
| FileTimestamp | `Apps/Sempere/SempereApp/DebugProbe.swift:47,48` | `lstat` to see iCloud's dataless flag; `#if DEBUG` only, not in release builds | (debug) |
| UserDefaults | `Apps/Sempere/SempereApp/DeviceSettings.swift:75,84,152,156,162,167,219,223,227,228,233,271,275,299,306,313` | Per-device settings (recording, transcription, new-note title, …) | CA92.1 |
| UserDefaults | `Apps/Sempere/SempereApp/SettingsView.swift:44,45,205,224` | `@AppStorage` bindings of the Settings screen | CA92.1 |
| UserDefaults | `Apps/Sempere/SempereApp/NoteCanvasView.swift:10,13,145,146,147,150`, `RootView.swift:14,19,20`, `NoteWindowView.swift:15` | Column layout, Keep Screen On, palette visibility and size, eraser radius, page strip | CA92.1 |
| UserDefaults | `Apps/Sempere/SempereApp/EraserPreference.swift:30,35,67`, `EraserGeometry.swift:125,130` | Eraser mode and size; removes PencilKit's own saved eraser from the app's defaults | CA92.1 |
| UserDefaults | `Apps/Sempere/SempereApp/ToolPalette.swift:16,21`, `AppCommands.swift:145` | Tool palette shown or hidden | CA92.1 |
| UserDefaults | `Apps/Sempere/SempereApp/PaperPreference.swift:13,20`, `PageLayoutChoice.swift:34,38`, `MathEditor.swift:25,31` | Defaults for new notes (paper, pages or pageless) and the last equation style | CA92.1 |
| UserDefaults | `Apps/Sempere/SempereApp/RecordingPreferences.swift:17,25,44,49`, `PageRecognizer.swift:34,40`, `ImagePreparation.swift:17`, `KeepScreenOn.swift:13`, `AppModel+Thinning.swift:18,21,268,270` | Recording, handwriting recognition, photo privacy, Keep Screen On and version-thinning settings | CA92.1 |
| UserDefaults | `Apps/Sempere/SempereApp/BlobCache.swift:53`, `DrawingCache.swift:45`, `RenderCache.swift:53` | Cache size limits | CA92.1 |

`@SceneStorage` (`RootView.swift:24`) is state restoration, not `UserDefaults`, and is not a
required-reason API.

Package code linked into the app (`Sources/Age`, `Sempere`, `SempereRender`, `SemperePDF`,
`SempereSpeech`, `CZlib`) uses only the `fstat` above. The other file-attribute reads in
`Sources/` (`attributesOfItem(…)[.size]` in `BlobCollection.swift`, `Backup.swift`,
`Thinning.swift`) read sizes, not timestamps; they are covered by the same declaration anyway.

### Widget extension (`Apps/Sempere/SempereWidgets/PrivacyInfo.xcprivacy`)

No required-reason API, no tracking, no collected data, so `NSPrivacyAccessedAPITypes` is an
empty array. The extension links no package product. Its code (`SempereWidgets/`,
`SempereShared/`) builds the widget, the control and the Live Activity views, and runs App
Intents in the app's process. `release-check.sh` scans the same folders and fails if that
changes.

### Dependencies

- **swift-crypto 4.5.2** ships a `PrivacyInfo.xcprivacy` in each target (`Crypto`,
  `CCryptoBoringSSL`, …), each with no API types, no tracking and no collected data. On Apple
  platforms `Crypto` is a layer over CryptoKit, and the BoringSSL targets are not built there.
- **SwiftMath 1.7.3** (app only): pinned with an exact version in `project.pbxproj`, resolved to
  1.7.3 (revision `fa8244ed`) in the project's own
  `Sempere.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (the root
  `Package.resolved` is the CLI package's and does not list it); `release-check.sh` fails if the
  two disagree. Its manifest and API use are checked from its sources: CI's `app` job runs
  `release-check.sh --checkouts .build/xcode/SourcePackages/checkouts` once the packages are
  resolved, which prints whether SwiftMath ships a `PrivacyInfo.xcprivacy`, lists the
  required-reason categories its sources use, fails on networking in it or on a category that
  neither its manifest nor the app's declares (it is linked statically, so the app's manifest
  covers it), and checks the checkout is the pinned revision. Read that line in the `app` log
  when bumping it; the archive's privacy report (step 8 below) is the final word. Result for
  1.7.3 (CI of #130): `privacy manifest absent; required-reason APIs: none; networking: none`,
  so it needs no manifest of its own and adds nothing to the app's.
- Apple frameworks (PencilKit, Vision, Speech, AVFoundation, PDFKit) are covered by Apple.

## 3. App Privacy ("nutrition label")

**"Do you or your third-party partners collect data from this app?" → No.** The product page
then shows **Data Not Collected**.

Apple's definition: data is "collected" when it is transmitted off the device in a way that lets
the developer or its third-party partners access it for longer than needed to service the
request in real time. Sempere has no server and no account, contains no analytics, advertising
or crash-reporting SDK. What leaves the device goes only where the user puts it, encrypted with the
user's key, which the developer never has.

**Network code, exactly.** The shipping app (every non-test folder of `Apps/Sempere` and the
`Sources/` targets it links) has networking in two places:

- WebDAV vaults (`SempereApp/WebDAVRemote.swift` and the `SempereWebDAV` target it links,
  `docs/io.md` "WebDAV vaults in the app"): it connects only to the server URL the user enters,
  over HTTPS (plain HTTP to the device itself only; a self-signed certificate only after the user
  pins it), with the user's own credentials, and uploads the user's already encrypted vault files
  there (push-only). The developer runs no server and receives nothing. This is why the Mac build
  has `network.client`.
- `SempereApp/MathModels.swift`, the handwritten-math model downloader (`URLSessionModelFetcher`,
  an HTTPS `GET` of a model's manifest and files, each checked against the SHA-256 the catalogue
  pins). It is inert: it runs only from a Download button in Settings → Handwritten Math, one per
  `MathModelCatalog.entries` entry, and that catalogue is empty
  (`Sources/SempereRender/MathModel.swift`), so the button never appears and there is no URL to
  fetch. "Add Model from Files" in the same section copies a model folder or zip the user picks
  (`MathModelImport`, #127): a local file, no connection.

`scripts/release-check.sh` fails on networking anywhere else in those folders (`NETWORK_ALLOWED`)
and on a non-empty catalogue. Offering a model is a release decision that changes these answers:
name the download host in the privacy policy (both copies) and here, and update DESIGN.md
"Network"; the answer to the question above stays No (the request carries no user data and
nothing is kept by the developer), but the review notes must mention the download.


| Apple data type | Why it is not collected |
| --- | --- |
| Contact info, contacts, financial, health, location, sensitive info, purchases, browsing history, identifiers | Never read by the app, or never leaves the device. Photo location metadata is stripped by default (photo privacy setting); when the user turns that off, it stays inside their own encrypted vault. |
| User content: handwriting, text, photos, video, audio, PDFs, equations | Stored only in the user's vault: a folder on the device or one the user picks (iCloud Drive or any Files provider), encrypted on the device before writing. The developer cannot read it and receives nothing. |
| User content: voice transcripts, handwriting recognition | Computed on the device (Speech's `SpeechTranscriber`, Vision) and stored in the vault. No server recognition (`Sources/SempereSpeech`). The system may download an on-device speech model from Apple, which is the OS's own traffic and carries no user data. |
| Usage data, diagnostics | No analytics or crash SDK. Timing signposts (`Perf`) stay in the device log; the debug timing log exists only in debug builds. Crash reports that users choose to share with developers go through Apple's own system, not the app. |
| Search history | Recent searches are sealed per vault in Application Support, on the device only (`RecentActivity`). |

Storage providers (Apple for iCloud Drive, others through Files) hold ciphertext on the user's
behalf under their own terms. This is not collection by the developer. If a third-party library
that sends data anywhere is ever added, this answer changes.

Other privacy settings: **Tracking: No** (no App Tracking Transparency prompt,
`NSUserTrackingUsageDescription` not needed). **Account creation: none**, so the account
deletion requirement does not apply. **Privacy Policy URL:** section 5.

The permission prompts the app can show, all for local features (Info.plist build settings in
`project.pbxproj`): camera (photos and video into notes; iPad/iPhone only), microphone
(recording), speech recognition (on-device transcription), Face ID (remembered keys), Live
Activities (a voice note in progress), notifications (the optional backup reminder, Settings →
Backups; local, no push). Photos are picked with the system picker, which needs no
permission.

## 4. Age rating

Answer **None** or **No** to everything; the result should be **4+**. App Store Connect → App
Information → Age Rating (the questionnaire as updated in 2025; check the wording on screen).

| Section | Item | Answer | Why |
| --- | --- | --- | --- |
| In-app controls | Parental Controls | No | None in the app. |
| In-app controls | Age Assurance | No | No age check (no account, no content from others). |
| Capabilities | Unrestricted Web Access | No | No web view or in-app browser. The app opens no links; files come only from the system pickers. |
| Capabilities | User-Generated Content | No | Users write their own private notes. Nothing is shared with, or shown to, other users through the app. |
| Capabilities | Social Media / disabled under 13 | No | None. |
| Capabilities | Messaging and Chat | No | None. |
| Capabilities | Advertising | No | None. |
| Mature themes | Profanity or Crude Humor; Horror/Fear; Alcohol, Tobacco or Drugs | None | The app ships no content of its own. |
| Medical or wellness | Medical or Treatment Information; Health or Wellness Topics | None | Same. |
| Sexuality or nudity | all three | None | Same. |
| Violence | all four | None | Same. |
| Chance-based | Gambling; Simulated Gambling; Contests; Loot Boxes | None / No | Same. |

"Made for Kids": No (a general productivity app; the Kids category has its own rules).

## 5. URLs, categories and other App Information

| Field | Value |
| --- | --- |
| Privacy Policy URL | Today: `https://github.com/anthonytw/sempere/blob/main/docs/appstore/privacy-policy.md` (kept up to date by this PR). After GitHub Pages is on (Settings → Pages → Deploy from branch `main`, folder `/docs`): `https://anthonytw.github.io/sempere/privacy/`, the static page `docs/privacy/index.html`. TODO(maintainer): switch the URL once Pages serves it. |
| Support URL | `https://github.com/anthonytw/sempere/issues` (required; a public page where users can reach the developer). |
| Marketing URL | `https://github.com/anthonytw/sempere` (optional). |
| Primary category | Productivity (`LSApplicationCategoryType = public.app-category.productivity`, required for the Mac build). |
| Secondary category | TODO(maintainer): Education, Utilities or none. |
| Copyright | `2026 Anthony Wertz` (App Store Connect adds ©). TODO(maintainer): confirm. |
| Price | Free, no in-app purchases, no ads (TODO(maintainer): confirm). |
| License agreement | Apple's standard EULA until the maintainer applies the custom one drafted in [`docs/appstore/eula.md`](../appstore/eula.md) (the GPL's no-warranty and liability terms in plain form, plus Apple's minimum terms; it needs a lawyer's review and its `TODO(user)` fields). The source license (GPL-3.0-or-later with the App Store exception, `LICENSE-EXCEPTION`) is what allows distribution under Apple's terms; the description mentions it. A revised exception is drafted, not applied, in [`docs/appstore/app-store-exception-draft.md`](../appstore/app-store-exception-draft.md). |

`docs/privacy/` is plain HTML because `docs/.nojekyll` turns Jekyll off for the whole folder.
Some docs (e.g. `docs/import-notability.md`) contain `{{`, which Liquid would choke on, failing
the Pages build. With Jekyll off, the Markdown docs are served as raw files, which does not
matter: only the privacy page is meant to be read there.

## 6. Mac App Store (Mac Catalyst, universal purchase)

### What universal purchase needs, and the project's state

| Requirement | State |
| --- | --- |
| One App Store Connect record with both platforms | Done: app 6819333304 has iOS and macOS. |
| The Mac build has the **same bundle id** as the iOS one | Yes. `PRODUCT_BUNDLE_IDENTIFIER = io.github.anthonytw.sempere` for both, no `[sdk=macosx*]` override, and `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER` unset (Xcode's "Use iPad bundle identifier"). `release-check.sh` fails otherwise. |
| Catalyst enabled for the app target | `SUPPORTS_MACCATALYST = YES`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO` (the Mac gets the Catalyst build, not the iPad binary). |
| App category set (required on the Mac) | `public.app-category.productivity`. |
| App Sandbox (required on the Mac App Store) | `Apps/Sempere/Sempere.entitlements`, through `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`. |
| Same version string on both platforms (recommended, not required) | `MARKETING_VERSION` 0.1 for every target. Each platform has its own App Store version in App Store Connect; build numbers are per platform. The upload script's `manageAppVersionAndBuildNumber` assigns them. |
| Mac-only extensions | None. The widget extension is iOS only (`platformFilter = ios`, `SUPPORTS_MACCATALYST = NO`), so the Mac bundle carries no `.appex`. |
| Mac app icon | The asset catalog has one 1024 px "universal / ios" icon, which Xcode also uses for the Catalyst build. TODO(maintainer): look at the icon in the Mac TestFlight build (Dock, Finder, Launchpad); add a macOS variant only if it looks wrong. |
| Hardened runtime | Not required for the Mac App Store (it is for notarised Developer ID builds). |

### Entitlements

The iPad/iPhone app (`SempereiOS.entitlements`) and the widget extension
(`SempereWidgets.entitlements`) have one entitlement, the App Group
`group.io.github.anthonytw.sempere`. It holds only the quick voice note status the widgets
and the Control Center control show (`VoiceNoteStatusStore`, a few dozen bytes: the phase
and a recording's start time; no key, no vault, no note; `docs/quick-capture.md`). The App
ID and the widget's App ID need the App Groups capability with that group in the developer
portal (automatic signing registers it). Nothing else: the Keychain uses the app's default
access group, folders come through the document picker, and there is no iCloud container
(vaults are user-picked folders, `docs/HANDOFF.md`). The Mac build has the first six below
and no App Group (the Catalyst build has no widgets); the seven are exactly
`release-check.sh`'s allow-list, and the App Group may only name that one group:

| Entitlement | Why it is needed | What breaks without it |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | Required for every Mac App Store app. | Upload is rejected. |
| `com.apple.security.files.user-selected.read-write` | Vaults are folders the user picks in the open panel (`fileImporter` / document picker); the app reads and writes encrypted revisions and blobs there, and saves exports where the user chooses. | Opening, creating or exporting into any folder outside the container. |
| `com.apple.security.files.bookmarks.app-scope` | Recent vaults are reopened from security-scoped bookmarks across launches (`VaultLibrary`). | Reopening the last vault after a relaunch without picking it again. |
| `com.apple.security.print` | Printing the recovery kit (the key's paper copy). | The print panel; the sandbox refuses to print. |
| `com.apple.security.device.audio-input` | Recording audio into notes and quick voice notes. | The microphone is silent under the sandbox. |
| `com.apple.security.network.client` (Mac build only; iOS needs no entitlement) | WebDAV vaults: the app connects to the WebDAV server the user configures (`docs/io.md`, "WebDAV vaults in the app"). | Open from WebDAV and every push on a Mac: the sandbox refuses outgoing connections. |
| `com.apple.security.application-groups` (iOS app and widget extension only) | The widgets and the control read the quick voice note status the app writes (`VoiceNoteStatusStore`). | The widgets show the plain record button whatever the state (no Stop, no "Set Up"). |

Deliberately absent:

- `device.camera`: the camera is offered on iPad and iPhone only (`InsertOptions.camera`).
- iCloud containers.
- `keychain-access-groups`: the default access group is enough.
- `application-groups` on the Mac, and any group but `group.io.github.anthonytw.sempere`:
  the intents run in the app's process; the group carries only the widgets' status.
- `files.downloads`, `personal-information.*`, `cs.*`.

Adding any entitlement means editing the allow-list in `scripts/release-check.sh` and this
table, in the same PR.

### The menu-bar bundle

The Mac build embeds `Contents/PlugIns/SempereStatusItem.bundle`, a small AppKit bundle that draws
the menu-bar icon (`docs/mac.md` "Menu-bar item"). It is signed with the app by Xcode (the embed
phase has `CodeSignOnCopy`), has no entitlements of its own (it runs in the app's sandbox), no
network code and no required-reason API, so it carries no privacy manifest and
`release-check.sh` lists no entry for it. Its bundle id `io.github.anthonytw.sempere.statusitem`
sits under the app's, as the script requires. Check on the first archive that it validates: a
macOS-SDK bundle inside a Catalyst app is the documented way to reach AppKit
(Apple's "Mac Catalyst" guidance), but it has not been through App Review yet. If App Review
objects, turn the item off by removing the embed phase: the app does not depend on it.

### Building and uploading the Mac version

The maintainer's upload script handles both platforms (`docs/HANDOFF.md`:
`~/.claude/scripts/sempere-testflight.sh mac|both`). The Mac archive uses
`-destination 'generic/platform=macOS,variant=Mac Catalyst'`. In App Store Connect, the Mac
build appears under the macOS platform of the same app.

## 7. App Review

### Notes for the reviewer (paste into App Review Information → Notes)

```
Sempere is a handwriting notes app that encrypts notes on the device with a key the user
creates. There is no account, no sign-in and no server, so no demo account is needed.

To try it (about one minute):
1. On the welcome screen tap "New Vault…".
2. Keep the name, choose Location "On This Device" and Key "Generate on this device",
   then tap Create.
3. The app shows the new secret key once. Tap "Copy Key" (optional), then "I Saved the Key".
   The vault opens, unlocked.
4. Tap "New Note" (the pencil-and-square button above the list), create it, and write
   with Apple Pencil or a finger. The Insert button adds photos, PDFs, text boxes,
   equations and audio recordings.
5. Settings (gear in the sidebar; Sempere > Settings… on the Mac) has the recording,
   transcription, photo-privacy and version-history options.

Optional: after unlocking with a key, the app offers to remember it in the Keychain behind
Face ID / Touch ID. The Lock Screen / Control Center "Voice Note" widget records into the
vault without unlocking; open the app once afterwards to see the voice note in the list.

On iPhone the app reads notes and lets you annotate them; writing long notes is meant
for iPad and Mac.

Permissions are asked only when a feature needs them: camera (photo/video into a note,
iPad and iPhone), microphone (recording), speech recognition (on-device transcription),
Face ID (remembered keys). Nothing is sent to the developer; the only connections the app makes
are to a WebDAV server the user configures (Open from WebDAV), to upload the encrypted vault. (It
also contains a downloader for an optional on-device handwriting-to-math model, but this version
offers no model, so it never connects.)

Encryption: the open "age" format (ML-KEM-768 + X25519, ChaCha20-Poly1305, HKDF, scrypt)
for the user's own data. Standard published algorithms, mass-market; the app is not
offered in France.

Source code (GPL-3.0-or-later with an App Store exception):
https://github.com/anthonytw/sempere
```

Never give the reviewer a real vault or key. If one is ever needed (it should not be: the flow
above creates one in seconds), use a vault made for the purpose, on a simulator or by the CLI
(`sempere keys generate --out FILE`, then `sempere vault init PATH --recipient age1pq1…`), whose key has never protected anything else. The fixture vault
`Tests/SempereTests/Fixtures/sample.sempere` with `sample.key` is public and throwaway, and would
also do.

TODO(maintainer): check each step against the build being submitted (button names, Insert
menu, iPhone behaviour), and that the welcome screen leads with "New Vault…".

### Contact information

App Review Information needs a name, phone and e-mail. These are the maintainer's
(TODO(maintainer); already set through the API per `docs/HANDOFF.md`). "Sign-in required": No.

### Guidelines worth pre-empting

- **2.1 (completeness):** submit only a build whose listed features work on a device. The
  ROADMAP still marks several features "not yet tried on the iPad".
- **2.3 (accurate metadata):** the description and screenshots must show only features in that
  build (section 8).
- **4.2 / 4.0 on iPhone:** the iPhone app is a reader with annotation. The notes say so; if the
  reviewer objects, the fallback is iPad + Mac only (`TARGETED_DEVICE_FAMILY = 2`), which is
  a product decision (TODO(maintainer)).
- **5.1.1 (privacy):** no account, so no account deletion. A privacy policy URL is required
  even with no data collected.
- **Encryption:** answered by the Info.plist key; reviewers sometimes still ask. The notes
  above answer it.

## 8. Listing drafts (English)

Limits: name 30 characters, subtitle 30, promotional text 170, keywords 100 (comma-separated, no
spaces needed), description 4000. Spanish drafts wait for the Spanish localization (#92, open at
the time of writing): once it merges, add an `es-ES` / `es-MX` localization of these fields in
App Store Connect and in this section.

**Name (30):** `Sempere`. If App Store Connect refuses the bare name: `Sempere: Encrypted Notes` (24).

**Subtitle (30):**

- `Encrypted handwriting notes` (27), recommended
- `Private ink, your own keys` (26)

**Promotional text (170):**

```
Handwritten notes encrypted with keys only you hold. No account, no server of ours, no
tracking. Your vault is a folder you choose: on device, iCloud Drive or Files.
```

(165 characters on one line; it can be changed at any time without review.)

**Keywords (100):**
`private,pencil,notebook,pdf,annotate,e2ee,sketch,journal,offline,voice,lecture,study,ink,vault`
(94). Words already in the name or subtitle ("encrypted", "handwriting", "notes") count anyway,
so they are left out. No competitor names (Apple rejects them).

**Description (under 4000):**

```
Sempere is a handwriting notes app for iPad, Mac and iPhone that keeps your notes yours.

YOUR KEYS, YOUR NOTES
Every note is encrypted on your device with the open age format, to a key you create and back
up yourself, with a printable recovery kit. Unlock with Face ID or Touch ID once the key is
saved in your Keychain. There is no account and no server of ours: nobody but you, not even the
developer, can read what you write.

SYNC IS A FOLDER
A vault is a folder of encrypted files. Keep it on your device, in iCloud Drive or with any Files
provider, and let the service you already use move it. Edits from several devices merge, even
while a note is open; sync never creates conflict copies.

REAL INK
Write with Apple Pencil using the system tools: pens, marker, pencil, lasso, ruler, and an object
eraser with sizes. Strokes stay vectors. Choose paper (ruled, grid, dots, and more), pages or one
endless page, and reorder, add or delete pages.

MORE THAN INK
Add photos, video, PDFs to annotate, text boxes in any language, and LaTeX equations. Record
audio while you write and tap your ink to hear what was said at that moment; transcripts are
made on your device.

FIND ANYTHING
Handwriting search reads your notes on the device, then highlights the matching words on the
page. Notebooks nest, tags filter, and search covers titles, tags and PDF text too.

QUICK VOICE NOTES
Record from the Lock Screen, Control Center or the Action button without unlocking your vault.
The note is sealed straight into your vault's inbox.

NOTHING IS LOST QUIETLY
Every change is kept in a history you can browse and restore from. Save versions you want to
keep; older ones thin out on a schedule you choose.

READABLE WITHOUT THE APP
Your notes are standard age files. With your key and free tools you can decrypt them, and
the open-source command-line tool exports PDF, SVG, PNG, Markdown and HTML on Mac and Linux.

ON THE MAC
The same app with menus, keyboard shortcuts, several windows and drag and drop to the Finder.

PRIVATE BY DESIGN
No ads, no analytics, no tracking, no subscription. Sempere collects no data.

OPEN SOURCE
Sempere is free software (GPL-3.0-or-later with an App Store exception) and comes with no
warranty. Read the code at github.com/anthonytw/sempere. Your key is the only way into your
notes: keep the recovery kit and a backup, because if every copy of the key is lost, nobody can
recover them.
```

TODO(maintainer): trim to the submitted build. These features are on `main`, but
`docs/ROADMAP.md` says they have not been tried on an iPad or a real Mac yet: continuous page
scrolling (#80), merging changes into an open note (#91), cached attachments (#84), equations
(#96), the Mac drag to the Finder and state restoration. (Several ROADMAP rows still show 🔀 for
PRs that have since merged: #79, #84, #88, #91, #94, #96.) Apple rejects descriptions of
missing features.

**What's New (first version):**

```
First release. Handwritten notes encrypted with your own keys, kept in a folder you choose.
No account, no tracking.
```

### Screenshots

Generated from the synthetic demo vault, never from real notes:
`scripts/screenshots.sh`, or the CI dispatch `gh workflow run CI --ref main -f screenshots=true`
and the `appstore-screenshots` artifact. Details: [`../appstore/screenshots.md`](../appstore/screenshots.md).

| Set | Size | Shots (in order; the first three show in search) |
| --- | --- | --- |
| iPad 13" (required; scaled for every iPad) | 2064 × 2752 | `01-write`, `02-sketch`, `03-notes`, `04-tags`, `05-paper`, `06-unlock` |
| iPhone 6.9" (required, because `TARGETED_DEVICE_FAMILY = 1,2`) | 1320 × 2868 | `01-write`, `02-sketch`, `03-notes`, `04-tags`, `05-library`, `06-unlock` |
| Mac (one of 1280×800, 1440×900, 2560×1600, 2880×1800) | 2880 × 1800 | the iPad six, three columns (best effort on CI: look at each one) |

Captions are added in App Store Connect, not drawn in. Ideas, in order: "Your handwriting,
encrypted" · "Sketch on any paper" · "Every note at hand" · "Notebooks and tags" · "Paper your
way" · "Only your key opens it". Look at every PNG before uploading: the demo ink is
deliberately not legible text.

App preview videos: none (optional).

## 9. The maintainer's manual steps in App Store Connect

In order; none of this can be done from the repository.

**Once (app level):**

1. [ ] App Information: name, subtitle, categories, content rights ("does not contain
   third-party content"), age rating questionnaire (section 4).
2. [ ] App Privacy: "Data Not Collected" (section 3); Privacy Policy URL (section 5).
3. [ ] Turn on GitHub Pages (repository Settings → Pages → `main` / `/docs`), check
   `https://anthonytw.github.io/sempere/privacy/`, then switch the Privacy Policy URL to it.
4. [ ] Pricing and Availability: Free; every territory except France (and no embargoed
   territories). Check "Make available on Mac" settings: with a native Catalyst build, the iPad
   app is not offered on Apple silicon Macs as "Designed for iPad". If it still shows up on a
   Mac (TestFlight installed the iPad build on one in build 7), untick "iPhone and iPad Apps on
   Apple Silicon Macs" there; no build setting does it (`LSRequiresIPhoneOS` does not), and the
   app copes with either build restoring the other's windows (docs/mac.md "Windows restored
   from another build").
5. [ ] License Agreement (needs the maintainer): have `docs/appstore/eula.md` reviewed, fill its
   `TODO(user)` fields, and paste it under App Information ▸ License Agreement (custom); decide on
   `docs/appstore/app-store-exception-draft.md` at the same time (`LICENSE-EXCEPTION` stays until then).
6. [ ] Export compliance: nothing to upload while France is excluded
   ([export-compliance.md](export-compliance.md)). Read the EAR sources once (its TODO).

**Per version (iOS, then macOS):**

7. [ ] Run `scripts/release-check.sh` on the commit to be archived (CI runs it on `main`).
8. [ ] Archive and upload iOS and Mac builds (`sempere-testflight.sh both`); TestFlight-test
   both on hardware (iPad on 26.7.1; a Mac).
9. [ ] In Xcode's Organizer, Generate Privacy Report for each archive; check it lists only
   UserDefaults (CA92.1) and FileTimestamp (C617.1, 3B52.1), plus empty manifests for
   swift-crypto (SwiftMath 1.7.3 ships none and needs none: section 2).
10. [ ] iOS version page: screenshots (iPad 13", iPhone 6.9"), promotional text, description,
   keywords, support and marketing URLs, What's New, build, copyright, App Review
   Information (contact, notes from section 7, no sign-in), version release (manual or
   automatic).
11. [ ] macOS version page: the same text fields (they are per platform), Mac screenshots,
    the Mac build, the same review notes.
12. [ ] Submit both for review. They are reviewed separately and can be released separately.

**Later:** France (export-compliance.md, "When France is added"); the Spanish localization of
the listing (after #92).
