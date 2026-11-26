# Sourced by run.sh and sim-signin.sh: an mkdir lock on the sempere-cloudkit base simulator (xc-lock gives no exclusion for these job
# kinds), so the account check's boot, the sign-in and the clone never overlap with another run. A lock whose owner died is taken over.
sim_lock_dir=${SEMPERE_CKL_LOCK_DIR:-$HOME/.cache/sempere/sim-cloudkit-base.lock}
sim_lock() {
  [[ -n ${SEMPERE_CKL_SIM_LOCKED:-} ]] && return 0   # the caller (run.sh) holds it
  mkdir -p "$(dirname "$sim_lock_dir")"
  local i owner
  for ((i = 0; i < 900; i++)); do
    if mkdir "$sim_lock_dir" 2>/dev/null; then echo $$ > "$sim_lock_dir/pid"; sim_lock_mine=1; return 0; fi
    owner=$(cat "$sim_lock_dir/pid" 2>/dev/null || true)
    if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$sim_lock_dir"; continue; fi
    sleep 2
  done
  echo "error: the sempere-cloudkit base simulator is locked by another run ($sim_lock_dir, pid ${owner:-?})" >&2
  return 1
}
sim_unlock() {
  [[ -n ${sim_lock_mine:-} ]] || return 0
  [[ $(cat "$sim_lock_dir/pid" 2>/dev/null || true) == "$$" ]] && rm -rf "$sim_lock_dir"
  sim_lock_mine=""
}
