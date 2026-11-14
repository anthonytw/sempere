### Changed

- Apple Watch: the iPhone holds at most 20 files or 50 MB of Watch notes that can only be deleted (for a vault or key it
  never held), inside the general limit, so a watch sending those cannot use up the room for notes you can add. A file left
  in the held folder without its record is removed after a day. `sempere inbox watch held summary` shows the count per reason,
  the limits and what it removed (`held list --json` is unchanged).
- Apple Watch: recordings the watch cannot place (another vault's, or one whose manifest names none) are no longer silent:
  the watch says "N recordings could not be placed", with Delete. Nothing is deleted by itself.
- Nearby join: Add Device keeps one handshake place per remote address, so a device that opens connections very fast ends
  only its own, never the others'.

### Fixed

- Sync: a revision this device wrote before 1.1.0 and left cut on a server that lists no file sizes is now found and
  replaced (one bounded check per revision, remembered in the sync state).
