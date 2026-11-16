### Fixed

- Apple Watch: after a device was removed (or the key changed another way), every note from the watch was held in
  Settings with "The vault has a newer key than this device", and reinstalling did not help. The quick voice notes
  profile now takes the new key's epoch along with the key; a device already in that state is repaired the next time
  the vault is unlocked, and the watch is given the repaired profile.
- Voice notes recorded on the phone or the watch in that state no longer make every write retry a catch-up that could
  not finish: `sempere vault catch-up` reports such inbox files as `relabeled`.
- Apple Watch: notes held only because the iPhone was behind (removed from the device list and then added back, or not
  yet on the vault's current key) go into the inbox by themselves once it catches up; notes sent while Use on Apple Watch
  was off, or under an earlier key, still wait for you.
- Apple Watch: a watch that asks for a profile while Use on Apple Watch is off (after Sempere was reinstalled on the
  iPhone) is cleared, instead of recording notes the iPhone can only hold.
- Turning Quick Voice Notes off and on again keeps your Transcribe Voice Notes choice.

### Changed

- Settings: a held Watch note sealed under an earlier key names a key change on this vault as the usual cause before the
  lost-watch caution, and Settings says that held Watch notes are kept only on this iPhone.
