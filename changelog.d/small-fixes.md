### Added

- The same emoji shortcodes (`:smile`) in text boxes on the canvas (iPad and Mac), at the caret.

### Fixed

- Mac: a note window restored for a note the vault no longer has closes instead of staying empty, and a
  library window restored with its note list hidden and no note selected shows the list instead of an
  empty "No Note Selected" window.
- Web viewer: the decrypted notes kept in memory are bounded by an estimated size (128 MiB) as well as
  by count, so a few large handwritten notes cannot fill a tab's memory.
