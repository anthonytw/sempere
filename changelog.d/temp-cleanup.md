### Fixed

- The app removes its temporary working folders when it is done with them (the scratch locations a
  model creates for itself), and a temporary blob file left half written by a failed read is removed,
  so nothing accumulates in the temporary folder.
