### Fixed

- Joining a device: a request or an approval written while a long sync runs (a first upload of a whole vault to iCloud, a big
  pull) now goes out within seconds. The run looks at the control files (`vault.json`, `joins/`, `epochs/`, `keys/`) again between
  its transfers, for iCloud, folder and WebDAV targets alike, instead of only at its start.
- Joining nearby: when the Local Network permission is refused (or not answered), Wi-Fi is off, or the link fails, Join This Device
  and Add Device say so in one sentence, with a button to the place where Local Network is allowed (this app's page in Settings on
  iPhone and iPad; Privacy & Security ▸ Local Network on the Mac). The join screen says only the device that manages devices can
  approve; Add Device on a device that is not home says which device can, instead of waiting.
