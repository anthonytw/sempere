### Added

- CLI: `sempere keys derive` prints the key schedule of a vault epoch key from the key-hierarchy design
  (vault identity, derived keys, epoch link keys, root fingerprint), for checking other implementations
  against shared test vectors. Vaults do not use it yet.
