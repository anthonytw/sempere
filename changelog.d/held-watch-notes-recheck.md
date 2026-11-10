### Fixed

- CLI: `sempere inbox watch held add --all` skips a held Watch note that cannot be added now (its epoch or vault is no longer
  one this machine holds) and says how many on stderr, instead of trying it and failing. Adding a note that an earlier add
  already took reports `notHeld` (a no-op, not a failure) rather than placing it a second time.
