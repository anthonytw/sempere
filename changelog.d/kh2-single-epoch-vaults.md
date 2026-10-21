### Changed

- Vaults use the new key hierarchy (docs/design/key-hierarchy.md, phase KH2): one vault key per epoch,
  wrapped to each device and to a printed recovery key; every file is encrypted to the vault's own
  identity, in one stanza. The device that creates a vault is its home and the only one that approves
  and renames devices. Older vaults do not open: this is the pre-release format, with no migration.
- CLI: `vault init` makes this machine the vault's home and writes a new recovery key
  (`--recovery-out`, or `--recovery-key`), with an optional passphrase copy of it in the vault
  (`--recovery-passphrase`, at least about 70 bits). Device keys stay on the machine
  (`$XDG_STATE_HOME/sempere/devices/`).
- CLI: `keys paper` prints the kit for the recovery key only; the kit holds the vault's root and the
  stock-tools recovery script.
- App: a new vault makes this device its home and shows its recovery key once (save, share or print
  the kit); the passphrase is now for the recovery key's copy in the vault. Unlocking with the
  recovery key or its passphrase opens the vault read-only. Managing devices and keys in the app
  (adding, removing, replacing, joining another device) is not available in this build; the CLI
  joins devices.

### Added

- CLI: `device init` and `device confirm` join a machine to a vault with six typed words each way;
  `devices list`, `devices approve` and `devices rename` on the home device.
- CLI: `--recovery-key FILE [--root HEX]` reads a vault with the recovery key (or its passphrase copy),
  read-only.

### Fixed

- Backups copy the notebook records (`notebooks/`), so a restore keeps empty notebooks.

### Removed

- Settings: the two "rewrap attachments" settings (they have no effect under the key hierarchy).

- CLI: `vault recipients`, `vault markers`, the rewrap commands, `keys export` and the stored key files
  in `keys/`. Removing devices and replacing keys come back as new epochs (phases KH3 to KH5).
