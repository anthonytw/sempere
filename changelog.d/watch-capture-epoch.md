### Fixed

- Apple Watch: after a device was removed (or the key changed another way), every note from the watch was held in
  Settings with "The vault has a newer key than this device", and reinstalling did not help. The quick voice notes
  profile now takes the new key's epoch along with the key; a device already in that state is repaired the next time
  the vault is unlocked, and the watch is given the repaired profile.
- Voice notes recorded on the phone or the watch in that state no longer make every write retry a catch-up that could
  not finish: `sempere vault catch-up` reports such inbox files as `relabeled`.
