### Fixed

- Joining nearby: home now allows 15 seconds (not 3) for a new device's request to arrive over the peer-to-peer link, which
  made every attempt fail on a slow link. When connecting keeps failing, the join screen says it could not reach the device
  nearby and that the request still comes through sync (it keeps trying in the background, slower after each failure); after a
  while with nothing found it says the other device must have Add Device open, with Local Network allowed. Add Device says
  when a nearby connection dropped. The "Sending the request" line no longer flips back while a sync run goes.
