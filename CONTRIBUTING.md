# Contributing to Sempere

**Issues are welcome. Pull requests from outside the repository are not accepted.** The maintainer
writes and merges all the code, which keeps the licensing simple: the project is GPL-3.0-or-later
with an App Store exception (`LICENSE`, `LICENSE-EXCEPTION`), and code from other authors would
complicate that exception. A pull request from someone else is closed without review; that is
about the policy, not the idea.

Everyone is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Bug reports

Open an issue with:

- what you did, what you expected and what happened (a screenshot or the exact message helps);
- the app (iPad, iPhone, Mac, `sempere` CLI or web viewer) and its version, shown in Settings ▸ About
  or by `sempere --version`, and the OS version;
- whether the vault syncs, and with what (iCloud Drive, another Files provider, WebDAV).

Never paste keys, recovery kits, passphrases or note contents. If a vault is needed to reproduce the
problem, make a new one with made-up notes. If the problem might let someone read or alter notes, do
not file an issue: use [SECURITY.md](SECURITY.md).

## Feature requests

Open an issue that says the problem first (what you are trying to do and what gets in the way), then
the change you imagine. Requests that fit the design (`DESIGN.md`: keys you hold, files you can read
without Sempere, no accounts, no telemetry) are easier to take on. Not every request is accepted, and
the roadmap is the maintainer's.

## Suggesting a translation

English and Spanish ship (`docs/localization.md`). To suggest a language or a correction, open an
issue with:

- the language (and region, if it matters);
- for a correction, the string as the app shows it and your wording; for a new language, the
  translation of the strings you can cover, or say you can review one;
- how your language says *vault*, *notebook*, *tag* and *page*, since the maintainer fixes a glossary
  for each language first.

The maintainer applies the strings to the catalogs and checks them, so you do not need Xcode.
Interface text only: note content, the CLI's messages and the on-disk format are not localized.

## Building from source

The source is public so you can read it, audit it and build it yourself. Swift 6.0 or newer (CI uses
6.4); `Sources/` builds on Linux and macOS. `swift build --build-tests && swift test`; the app needs
Xcode 27 or newer. `CLAUDE.md` lists the commands and the repository's rules.
