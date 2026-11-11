### Fixed

- iPhone and iPad: Sempere was sometimes closed by the system while you were not using it (TestFlight 1.1, build 67).
  When iOS started it in the background (a note from the Apple Watch, a background sync), it could reopen the last
  vault and keep a lock on its files while suspended. Now it locks nothing until it is on screen, and every write in
  the background has background time of its own or waits for the next launch.
