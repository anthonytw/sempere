### Added

- CLI: `sempere vault conflicts` reports whether iCloud Drive holds a vault folder as a package and lists the
  folder's conflict versions with the files only they hold; `--merge` copies back the missing write-once files
  (each checked under the vault's key, quarantined if it fails, nothing overwritten), settles `settings.age` and
  `vault.json` by the usual rules, then marks the versions resolved and clears the Finder's bundle flag.
- Sync Targets warns when iCloud Drive syncs a sync folder as one package or keeps conflicting versions of the
  whole folder, with the steps to move to a plain folder.

### Fixed

- Sync: a Finder bundle flag on a vault or sync folder that cannot be cleared is now logged instead of failing
  silently, and `store sync` / `sync folder` warn about a target folder held as a package.
