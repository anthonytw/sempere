# shellcheck shell=bash
# Source this from a script that runs Xcode or SwiftPM (scripts/app.sh, local-ci.sh, testflight.sh, screenshots.sh).
#
# Why: swift build/test leave 5-6 empty `TemporaryDirectory.XXXXXX` folders (each holding `.keep-directory`) in
# $TMPDIR per invocation, and xcodebuild leaves `ResultBundle_*` and `SempereApp_*.xcdistributionlogs`. Nothing
# cleans them: 18,000 piled up in four days and slowed the Mac (docs/ci.md "Temp-folder guard"). They are Apple's
# tooling, not ours, so the run gets a TMPDIR of its own and removes it when it ends. Only what this run (and its
# child processes) made is in it, so it never touches another agent's files. A nested script (local-ci.sh running
# app.sh) inherits its parent's folder, and the parent removes it.
#
#   SEMPERE_RUN_TMP_KEEP=1   keep the folder (to look at what a run left)
if [[ -z ${SEMPERE_RUN_TMP:-} ]]; then
  SEMPERE_RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sempere-run.XXXXXX")
  export SEMPERE_RUN_TMP
  SEMPERE_RUN_TMP_OWNER=$$
  export TMPDIR="$SEMPERE_RUN_TMP/"
fi

# Removes this run's TMPDIR if this process made it. Safe to call twice.
run_tmp_end() {
  if [[ ${SEMPERE_RUN_TMP_OWNER:-} == "$$" && -n ${SEMPERE_RUN_TMP:-} && ${SEMPERE_RUN_TMP##*/} == sempere-run.* \
        && ${SEMPERE_RUN_TMP_KEEP:-} != 1 ]]; then
    rm -rf "$SEMPERE_RUN_TMP"
  fi
}
trap run_tmp_end EXIT
