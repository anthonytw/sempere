# shellcheck shell=bash
# Source this from a script that runs `docker` (ci-linux.sh, test-linux.sh, local-ci.sh, release-build*.sh), then call
# `container_setup`. On a Mac the containers run in a Lima VM (scripts/lima/sempere-docker.yaml), not Docker Desktop: Lima is
# CLI-only and runs as the calling user, so a headless account (an agent's seat) can build without a GUI login. On Linux, and
# whenever you say so, nothing changes: plain `docker`.
#
#   SEMPERE_CONTAINER=docker   use whatever `docker` already talks to (Docker Desktop, a context, DOCKER_HOST)
#   DOCKER_HOST=...            already set (also by an outer sempere script, which exports it): used as it is
#   SEMPERE_LIMA_VM=NAME       the VM's name (default sempere-docker)
#   SEMPERE_LIMA_KEEP=1        leave the VM running at exit even if this run started it
#
# A VM this run started is stopped when the last sempere script using it exits (users are pid files in
# ~/.cache/sempere-lima/users); one that was already running is left running.
container_setup() {
  [[ $(uname) == Darwin && ${SEMPERE_CONTAINER:-lima} == lima && -z ${DOCKER_HOST:-} ]] || return 0
  command -v limactl >/dev/null || { echo "error: need Lima (brew install lima), or SEMPERE_CONTAINER=docker to use Docker Desktop" >&2; return 1; }
  local vm=${SEMPERE_LIMA_VM:-sempere-docker} here status
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  mkdir -p "$HOME/.cache/sempere-ci-pass" "$HOME/.cache/sempere"   # mount points must exist on the host
  if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm"; then
    echo "container: creating the Lima VM $vm (first run: downloads an Ubuntu image, installs Docker; a few minutes)" >&2
    limactl create --tty=false --name "$vm" "$here/lima/sempere-docker.yaml" >&2 || return 1
  fi
  status=$(limactl list "$vm" --format '{{.Status}}')
  local users="$HOME/.cache/sempere-lima/users"; mkdir -p "$users"
  : > "$users/$$"   # registered before the start, so a concurrent script's exit cannot stop a VM this one is starting
  if [[ $status != Running ]]; then
    echo "container: starting the Lima VM $vm" >&2
    limactl start --tty=false "$vm" >&2 || { rm -f "$users/$$"; return 1; }
    [[ -n ${SEMPERE_LIMA_KEEP:-} ]] || touch "$HOME/.cache/sempere-lima/started-$vm"
  fi
  # Every host path a container will mount must be inside a VM mount.
  local mounts p ok
  mounts=$(limactl list "$vm" --format '{{range .Config.Mounts}}{{.Location}}{{"\n"}}{{end}}')
  for p in "$PWD" "$HOME/.cache/sempere-ci-pass" "$HOME/.cache/sempere"; do
    ok=false; while IFS= read -r m; do [[ -n $m && ( $p == "$m" || $p == "$m"/* ) ]] && ok=true; done <<<"$mounts"
    [[ $ok == true ]] || { echo "error: $p is not under a mount of the Lima VM $vm; its mounts are in scripts/lima/sempere-docker.yaml. Fix: limactl stop $vm && limactl delete $vm (it is recreated), or SEMPERE_CONTAINER=docker" >&2; return 1; }
  done
  unset DOCKER_CONTEXT
  export DOCKER_HOST="unix://$HOME/.lima/$vm/sock/docker.sock"
  CONTAINER_VM=$vm
  [[ -n $(trap -p EXIT) ]] || trap container_teardown EXIT   # a script with its own EXIT trap calls container_teardown from it
}

# Stop the VM if this run started it and no other sempere script is using it. Chains to a trap set before container_setup
# only through the caller's own cleanup: call container_teardown from it if the script has an EXIT trap of its own.
container_teardown() {
  [[ -n ${CONTAINER_VM:-} ]] || return 0
  local users="$HOME/.cache/sempere-lima/users" f live=0
  rm -f "$users/$$"
  [[ -e $HOME/.cache/sempere-lima/started-$CONTAINER_VM ]] || return 0
  for f in "$users"/*; do [[ -e $f ]] && kill -0 "$(basename "$f")" 2>/dev/null && live=1 || rm -f "$f"; done
  if [[ $live == 0 ]]; then
    rm -f "$HOME/.cache/sempere-lima/started-$CONTAINER_VM"
    limactl stop "$CONTAINER_VM" >/dev/null 2>&1 || true
  fi
}
