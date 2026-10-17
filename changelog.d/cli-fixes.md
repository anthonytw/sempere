### Fixed

- CLI: `vault verify -q` and `backup verify -q` list only real problems. A healthy
  backup no longer prints its unreferenced blobs, so the weekly `backup verify -q`
  cron job stays silent, and `backup verify` no longer counts them as problems.
- CLI: `export --format media` of a note without media leaves no empty `--out` folder
  and says "no media". `import notability` with a missing file, and other errors,
  print a readable message instead of the Swift error case. `--videos` accepts only
  `none` and `attach`, as documented. `compact --thin-all` help and the unknown
  `%` directive message in a title format now match what they do. Deltas written by the
  CLI carry its real version.
- Settings: Quick Voice Notes' notebook and transcription settings sync to the Mac too.
  Keep Screen On is no longer shown on the Mac, where it does nothing.
