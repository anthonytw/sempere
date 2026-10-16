### Changed

- WebDAV vaults in the app: consecutive pushes and fetches reuse one network connection to the server
  instead of opening a new TLS connection each time, so a push after an edit starts sending sooner.
  The connection is dropped when the vault closes or the address, password or pinned certificate changes.
