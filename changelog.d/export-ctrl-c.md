### Fixed

- CLI: Ctrl-C during `sempere export --all` stops after the note being written instead of leaving a
  half-written `.pdf.partial` / `.png.partial` file in the output folder, and a re-run removes any such
  file an earlier killed run left. Run the same command again to resume.
