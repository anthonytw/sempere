### Fixed

- Sync: a new folder sync target is now named “<vault>.sempere-vault” instead of “<vault>.sempere”: iCloud Drive
  kept `….sempere` sync folders as packages on some accounts, even new ones, and synced the whole vault as one item.
  The new extension is declared a plain folder (never a package), and Sempere opens a `….sempere-vault` folder like a
  `….sempere` one. A folder that holds the vault is taken as the target whatever its name, and a folder picked to hold
  the copy joins the vault's copy already in it whatever that copy is named (devices whose vaults are named
  differently meet in one folder; two copies there are refused with a request to choose one). Existing `….sempere`
  targets keep working unchanged, and the vaults kept in the app stay `….sempere`. Every device of a vault should run
  this version before a `….sempere-vault` folder is added on any of them. How to Fix… shows shorter steps when the
  folder has no conflicting versions to merge back. The CLI’s `store target add --folder` follows the same rule.
