# Changelog fragments

One file per change: `changelog.d/<branch-or-topic>.md`. Never edit `CHANGELOG.md` in a PR.

```markdown
### Fixed

- Settings: App Language opens Sempere's page in the system Settings.
```

- Heading: `### Added`, `### Changed`, `### Fixed` or `### Removed` (one or more per file).
- Under it, the bullets exactly as they should read in `CHANGELOG.md` (wrapped lines indent two spaces).
- Nothing user-visible (docs, tests, tooling)? No fragment.

`scripts/changelog-collect.py` folds the fragments into `[Unreleased]` and deletes them. It runs at
release time and before a TestFlight build ([docs/releasing.md](../docs/releasing.md)), not in PRs.
