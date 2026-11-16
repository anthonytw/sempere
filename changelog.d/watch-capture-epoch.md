### Fixed

- Apple Watch: after a device was removed (or the key changed another way), every note from the watch was held in
  Settings with "The vault has a newer key than this device", and reinstalling did not help. The quick voice notes
  profile now takes the new key's epoch along with the key; a device already in that state is repaired the next time
  the vault is unlocked, and the watch is given the repaired profile.
- Voice notes recorded on the phone or the watch in that state no longer make every write retry a catch-up that could
  not finish: `sempere vault catch-up` reports such inbox files as `relabeled`.
- Apple Watch: notes held because the iPhone had been removed from the device list go into the inbox by themselves once
  it is listed again, and notes for a vault the iPhone did not hold once it does. Notes sent while Use on Apple Watch was
  off, or sealed before the vault's key changed (this includes the notes held because of the problem above: add them in
  Settings ▸ Quick Voice Notes), still wait for you.
- Apple Watch: a watch that asks for a profile while Use on Apple Watch is off (after Sempere was reinstalled on the
  iPhone) is cleared, instead of recording notes the iPhone can only hold.
- Turning Quick Voice Notes off and on again keeps your Transcribe Voice Notes choice.

### Changed

- Settings: a held Watch note shows why it is held now rather than when it arrived; one sealed under an earlier key names
  a key change on this vault as the usual cause before the lost-watch caution, and one that arrived while Use on Apple
  Watch was off always carries that caution. Settings also says that held Watch notes are kept only on this iPhone.
