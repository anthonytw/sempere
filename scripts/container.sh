# shellcheck shell=bash
# Source this from a bash script that runs `docker` (ci-linux.sh, test-linux.sh, local-ci.sh, release-build*.sh), then call
# `container_setup`. On a Mac the containers run in a Lima VM (scripts/lima/sempere-docker.yaml), not Docker Desktop: Lima is
# CLI-only and runs as the calling user, so a headless account (an agent's seat) can build without a GUI login. On Linux, and
# whenever you say so, nothing changes: plain `docker`. Needs Lima 2.0+ (brew install lima) and the docker CLI (brew install docker).
#
#   SEMPERE_CONTAINER=docker   use whatever `docker` already talks to (Docker Desktop, a context, DOCKER_HOST)
#   DOCKER_HOST=...            already set (also by an outer sempere script, which exports it): used as it is
#   SEMPERE_LIMA_VM=NAME       the VM's name (default sempere-docker)
#   SEMPERE_LIMA_KEEP=1        this run never stops the VM (nor starts one that a later run would stop)
#
# Users of a VM are files in ~/.cache/sempere-lima/VM/users (pid, with the process's start time so a recycled pid does not
# count). Setup (register, read the state, start) and teardown (unregister, look for other users, stop) each run under one lock
# (~/.cache/sempere-lima/VM.lock, a directory made atomically, broken when its owner is dead), so a script that exits cannot stop a
# VM another one has just joined. A VM this run started is stopped when the last user exits ("started" marker); one that was already
# running is left running. A starter killed with SIGKILL leaves the marker: the next run's exit stops the VM.

_container_root() { echo "$HOME/.cache/sempere-lima"; }
_container_start_time() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'; }

_container_lock() {   # one holder at a time; a lock whose owner is dead is taken over
  local ld; ld="$(_container_root)/$1.lock"; mkdir -p "$(_container_root)"
  local n=0 owner
  until mkdir "$ld" 2>/dev/null; do
    owner=$(cat "$ld/pid" 2>/dev/null || true)
    if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$ld"; continue; fi
    sleep 0.2; n=$((n + 1)); [[ $n -lt 3000 ]] || { echo "error: the lock $ld is held for 10 minutes" >&2; return 1; }
  done
  echo $$ > "$ld/pid"
}
_container_unlock() { rm -rf "$(_container_root)/$1.lock"; }

container_setup() {
  [[ $(uname) == Darwin && ${SEMPERE_CONTAINER:-lima} == lima && -z ${DOCKER_HOST:-} ]] || return 0
  command -v limactl >/dev/null || { echo "error: need Lima 2.0+ (brew install lima docker), or SEMPERE_CONTAINER=docker to use Docker Desktop" >&2; return 1; }
  local vm=${SEMPERE_LIMA_VM:-sempere-docker} here root vstate
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); root=$(_container_root)
  local pass=${SEMPERE_CI_PASS_DIR:-$HOME/.cache/sempere-ci-pass} sdk=${SEMPERE_SDK_CACHE:-$HOME/.cache/sempere/swift-sdk}
  mkdir -p "$pass" "$sdk" "$root/$vm/users"   # mount points must exist on the host
  _container_lock "$vm" || return 1
  CONTAINER_VM=$vm
  echo "$(_container_start_time $$)" > "$root/$vm/users/$$"   # registered first: no teardown stops the VM under us
  if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm"; then
    echo "container: creating the Lima VM $vm (first run: downloads an Ubuntu image, installs Docker; a few minutes)" >&2
    limactl create --tty=false --name "$vm" "$here/lima/sempere-docker.yaml" >&2 || { _container_abort "$vm"; return 1; }
  fi
  vstate=$(limactl list "$vm" --format '{{.Status}}')
  if [[ $vstate != Running ]]; then
    echo "container: starting the Lima VM $vm" >&2
    limactl start --tty=false "$vm" >&2 || { _container_abort "$vm"; return 1; }
    if [[ -n ${SEMPERE_LIMA_KEEP:-} ]]; then rm -f "$root/$vm/started"; else touch "$root/$vm/started"; fi
  fi
  # Every host path a container will mount must be inside a VM mount.
  local mounts p ok m
  mounts=$(limactl list "$vm" --format '{{range .Config.Mounts}}{{.Location}}{{"\n"}}{{end}}')
  for p in "$PWD" "$pass" "$sdk"; do
    ok=false; while IFS= read -r m; do [[ -n $m && ( $p == "$m" || $p == "$m"/* ) ]] && ok=true; done <<<"$mounts"
    [[ $ok == true ]] || { echo "error: $p is not under a mount of the Lima VM $vm; its mounts are in scripts/lima/sempere-docker.yaml. Fix: limactl stop $vm && limactl delete $vm (it is recreated), or SEMPERE_CONTAINER=docker" >&2; _container_abort "$vm"; return 1; }
  done
  unset DOCKER_CONTEXT
  export DOCKER_HOST="unix://$HOME/.lima/$vm/sock/docker.sock"
  local i=0   # the socket answers before the first command needs it
  until docker info >/dev/null 2>&1; do
    i=$((i + 1)); [[ $i -lt 60 ]] || { echo "error: dockerd in the Lima VM $vm does not answer" >&2; _container_abort "$vm"; return 1; }
    sleep 2
  done
  _container_unlock "$vm"
  [[ -n $(trap -p EXIT) ]] || trap container_teardown EXIT   # a script with its own EXIT trap calls container_teardown from it
}

_container_abort() {   # setup failed, lock held: leave as if this run never came (the lock is released, the VM left as it is)
  rm -f "$(_container_root)/$1/users/$$"; _container_unlock "$1"; CONTAINER_VM=""
}

# Unregister; stop the VM if this run started it and no other live user is left (KEEP: never).
container_teardown() {
  [[ -n ${CONTAINER_VM:-} ]] || return 0
  local vm=$CONTAINER_VM root f pid live=0; root=$(_container_root)
  CONTAINER_VM=""
  _container_lock "$vm" || return 0
  rm -f "$root/$vm/users/$$"
  if [[ -z ${SEMPERE_LIMA_KEEP:-} && -e $root/$vm/started ]]; then
    for f in "$root/$vm/users"/*; do
      [[ -e $f ]] || continue
      pid=$(basename "$f")
      if kill -0 "$pid" 2>/dev/null && [[ $(_container_start_time "$pid") == "$(cat "$f")" ]]; then live=1; else rm -f "$f"; fi
    done
    if [[ $live == 0 ]]; then rm -f "$root/$vm/started"; limactl stop "$vm" >/dev/null 2>&1 || true; fi
  fi
  _container_unlock "$vm"
}
