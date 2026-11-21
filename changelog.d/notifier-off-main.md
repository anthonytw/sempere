### Fixed

- Backup reminders: cancelling a pending reminder no longer runs a blocking notification-center call on the main
  thread (it stalled the app for over a minute after a fresh boot); cancels and schedules now run off the main
  thread, in order.
