### Changed

- Apple Watch voice notes: the iPhone adds a note from the watch to your inbox only while Use on Apple Watch is on and the
  note was sealed under the key the iPhone currently holds. Any other note is kept on the iPhone, never in your vault, until you
  choose, note by note, Add (after a confirmation, with a warning for notes that came after the setting went off or under an
  earlier key) or Delete in Settings (`sempere inbox watch held list|add|delete`; `held add --all` skips those notes). Turning the setting off also makes the
  iPhone forget the watch's key. If you lose the watch: turn the setting off, unpair or erase the watch, then replace the key.
- Apple Watch: a recording that is in progress when the iPhone clears the watch is still saved, and recordings left without a
  profile are deleted instead of waiting.
