### Fixed

- CLI on Linux: the release binary is fully static (built with Swift's Static Linux SDK) and runs on any
  distribution, including Debian 12, Ubuntu 22.04, Ubuntu 25.10 and 26.04 and Alpine. 1.0.0's binary
  needed glibc 2.38 or later and the system's libcurl and `libxml2.so.2`.
