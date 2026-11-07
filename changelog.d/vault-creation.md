### Changed

- CLI: `store create`, `store import --name` and `store restore --name` also refuse a vault name holding a Unicode
  line or paragraph separator (U+2028, U+2029), as the app's New Vault always did. `vault init` and `store create`
  make vaults with the app's own vault creation.

### Fixed

- New Vault explains every vault name it cannot use (a backslash, a name ending in `.SEMPERE`, more than 255 bytes)
  in the app's words, instead of an English error from the vault store; Restore from Backup no longer offers to
  restore under such a name, which then failed.
