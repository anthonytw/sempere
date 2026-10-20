### Changed

- Vaults live on the device, inside the app, on the iPad, iPhone and Mac alike, so a vault always opens
  with everything it had, online or not. New Vault creates the vault there (there is no location to
  choose any more). Open Vault… copies a vault folder (from Files, iCloud Drive, a backup or an export)
  onto the device and opens the copy; the folder itself is only read. The copy is compared byte for byte
  with the original before it appears, an interrupted copy leaves nothing behind, and a vault that is not
  completely downloaded is refused with the reason; a vault already on the device opens its copy. Vaults opened in place
  by earlier builds are not carried over: open them again with Open Vault… to copy them in.

### Added

- Restore from Backup restores into the app as well. When that vault is on the device already, it asks
  whether to replace it; the copy is replaced only once the restored one is complete.
- The welcome screen lists the vaults on this device, the most recently opened first, with Delete from
  This Device… (after a confirmation).
- `sempere store list|path|create|import|restore|remove`: the same vault store from the command line
  (`--store DIR`, `$SEMPERE_STORE`, default `$XDG_DATA_HOME/sempere/vaults`; on a Mac the app's own store
  is in its container). `store import` copies a vault in with the same checks as the app.
