### Fixed

- Sync: a new folder sync target is now a plain folder with no extension, “<vault> Sempere Vault”, instead of
  “<vault>.sempere”: iCloud Drive kept `….sempere` sync folders as packages on some accounts, even new ones, and
  synced the whole vault as one item. A folder that holds the vault is taken as the target whatever its name, Open
  Vault… finds such a folder by its contents, and existing `….sempere` targets keep working unchanged. Every device
  of a vault should run this version before a plain folder is added on any of them. How to Fix… shows shorter steps
  when the folder has no conflicting versions to merge back. The CLI’s `store target add --folder` follows the
  same rule.
