# Sourced by run.sh and sim-signin.sh: a kernel lock (flock, hold-lock.py) on the sempere-cloudkit base simulator (xc-lock gives no
# exclusion for these job kinds), so the account check's boot, the sign-in and the clone never overlap with another run. The holder
# is a small process that keeps the flock until its owner (this shell) dies or sim_unlock kills it: a killed run frees the lock by
# itself, and there is no stale-lock takeover to race on.
sim_lock_file=${SEMPERE_CKL_LOCK_FILE:-$HOME/.cache/sempere/sim-cloudkit-base.flock}
sim_lock_py=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hold-lock.py
sim_lock_helper=""
sim_lock_ancestor() { # is $1 this process or one of its ancestors?
  local p=$$
  while [[ -n $p && $p -gt 1 ]]; do
    [[ $p == "$1" ]] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}
sim_lock() {
  # An inherited SEMPERE_CKL_SIM_LOCKED (the pid of the caller that holds the lock) counts only if that pid is an ancestor of this
  # process, is the recorded owner, and the lock really is held.
  if [[ -n ${SEMPERE_CKL_SIM_LOCKED:-} && $(cat "$sim_lock_file" 2>/dev/null || true) == "$SEMPERE_CKL_SIM_LOCKED" ]] \
     && sim_lock_ancestor "$SEMPERE_CKL_SIM_LOCKED" && "$sim_lock_py" check "$sim_lock_file"; then
    return 0
  fi
  [[ -z $sim_lock_helper ]] || return 0   # already ours
  mkdir -p "$(dirname "$sim_lock_file")"
  local ready; ready=$(mktemp "${TMPDIR:-/tmp}/sim-lock-ready.XXXXXX"); : > "$ready"
  "$sim_lock_py" hold "$sim_lock_file" $$ 1800 "$ready" &
  sim_lock_helper=$!
  while [[ ! -s $ready ]]; do
    if ! kill -0 "$sim_lock_helper" 2>/dev/null; then
      rm -f "$ready"; sim_lock_helper=""
      echo "error: the sempere-cloudkit base simulator is locked by another run ($sim_lock_file); gave up after 30 minutes" >&2
      return 1
    fi
    sleep 0.2
  done
  rm -f "$ready"
}
sim_unlock() {
  [[ -n $sim_lock_helper ]] || return 0
  kill "$sim_lock_helper" 2>/dev/null || true
  wait "$sim_lock_helper" 2>/dev/null || true
  sim_lock_helper=""
}
