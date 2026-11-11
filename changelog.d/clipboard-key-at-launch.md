### Fixed

- Mac: if Sempere was killed or crashed after Copy Key, the vault key stayed on the clipboard until something else was
  copied. The next launch now clears it. Only a key Sempere itself copied is cleared, never anything another app put
  on the clipboard.
