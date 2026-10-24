### Added

- Join This Device: a new device asks to join with six words or a QR code; the device that manages devices approves
  it in Devices ▸ Add Device and shows six words back, which the new device types (or scans) to confirm.
- Take Over with Recovery Kit: with the kit's key and root, or the passphrase, a device takes over managing devices
  (for a lost or stolen one) and picks which devices stay.
- Settings ▸ Sync & Devices: Require Face ID (or Touch ID) to open a vault on this device.

### Changed

- Each device keeps its own key in its Keychain, never synced or exported, and its signing key in the Secure
  Enclave. A vault opens by itself on a device that holds its key; the "Remember key" sheet, the iCloud Keychain
  option and the sidebar's Vault Key menu are gone. A vault made by a build before this one is joined again (or
  taken over with its recovery kit) on each device.
