### Fixed

- Apple Watch: a note your iPhone holds without a vault yet (saved under an old key, or while "Use on Apple Watch" was
  off) now stays on the watch until you add or delete it on the phone, so deleting and reinstalling the iPhone app no
  longer loses it; the watch sends it again after the reinstall.
- Devices: voice notes this device saved under its earlier key, before it was removed and joined again, are now re-sealed
  under the new key instead of being retried at every write (only keys this device itself held, which it now remembers
  from this version on); a note no key this device held can open is given up on once and left in the inbox.
- Apple Watch: after an iPhone restart, before the first unlock, or when the held-notes folder cannot be read, the phone
  no longer tells the watch it holds nothing, so the watch keeps its copies.
