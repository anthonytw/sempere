### Added

- Joining a device no longer waits for the sync target when the two devices are near each other: while Add Device
  shows on one and the join screen on the other, the request and the approval go straight between them over
  peer-to-peer Wi-Fi (as AirDrop does) or a shared network, even on different Wi-Fi networks. Both still type or scan
  the six words, and the sync target is used as before; whichever arrives first wins. Add Device marks a request that
  came this way "Nearby", and the join screen says when it has found and reached the other device. App only.
