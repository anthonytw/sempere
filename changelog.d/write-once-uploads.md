### Fixed

- Sync: notebook records, join requests and recovery passphrase copies upload to a temporary name and then move
  into place, as revisions and attachments do, so a connection cut mid-upload never leaves a partial file on a
  WebDAV server. A partial copy an earlier version left is replaced by the whole file on the next sync, and a
  join request counts as delivered only once the server holds all of it.
- Sync: a partial `vault.json` on a sync target no longer stops two-way sync there: the next sync of a device
  that has the vault unlocked replaces it with the device list it holds.
