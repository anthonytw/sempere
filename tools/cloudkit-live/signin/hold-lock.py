#!/usr/bin/python3 -I
"""A kernel lock (flock) for the sempere-cloudkit base simulator, held by this process until its owner dies or it is killed.

  hold-lock.py hold FILE OWNER_PID WAIT_SECONDS READY_FILE   wait for the lock, write OWNER_PID into FILE, write "locked" into
                                                              READY_FILE, then keep it until OWNER_PID is gone (exit 1 on timeout)
  hold-lock.py check FILE                                     exit 0 when somebody holds the lock, 1 when it is free
"""
import fcntl, os, sys, time

def main() -> int:
    mode, path = sys.argv[1], sys.argv[2]
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    if mode == "check":
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
        return 1
    owner, wait, ready = int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    end = time.time() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > end:
                return 1
            time.sleep(1)
    os.ftruncate(fd, 0)
    os.write(fd, str(owner).encode())
    with open(ready, "w") as f:
        f.write("locked\n")
    while True:
        try:
            os.kill(owner, 0)
        except ProcessLookupError:
            return 0
        except PermissionError:
            pass
        time.sleep(1)

sys.exit(main())
