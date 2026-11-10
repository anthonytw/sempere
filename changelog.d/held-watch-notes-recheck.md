### Fixed

- CLI: `sempere inbox watch held add --all` skips a held Watch note that cannot be added now (its epoch or vault is no longer
  one this machine holds) instead of trying it and failing; adding the same note twice is no longer a second placement.
