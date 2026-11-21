### Changed

- CLI: `sempere share` refuses a share passphrase that is the vault's own (the variable the vault's passphrase comes
  from, or the same passphrase), with exit 2: the recipient learns the share passphrase.
