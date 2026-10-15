#!/bin/bash
#==============================================================================
# FIDO V3 (WITCHER) SV kit - run ONE configuration on Cadence Xcelium 22.09 (SystemVerilog sources).
# Every run creates a new folder  runs/<date>_<time>_<cfg>_<opt>[_T<n>][_S<n>]/
#   xrun.log  results.txt  results.csv  run_info.txt  STATUS  cmd.txt
#   tool_version.txt  tool_warnings.txt (if any)  tool_errors.txt (if any)
#   waves.shm (with -w)  xcelium.d (compiled library)
# and adds one line to runs/history.csv; runs/latest points to it.
# exit code: 0 PASS, 3 WARN (tests pass, simulator warnings), 1 FAIL, 2 usage
#
# usage : ./run_xrun.sh -c <cfg> [-o A|B] [-t test] [-s seed] [-w] [-g] [-v] [-n tag]
#   -c  cg_fine | cg_coarse | pg_fine | pg_coarse                 (11 tests)
#       cgpg_fine | cgpg_coarse | cgpg_ml_fine | cgpg_ml_coarse     (16 tests)
#                                                           (default cg_fine)
#   -o  A = optionA_self_contained, B = optionB_common      (default A)
#   -t  run only test n (1..11, or 1..16 for the cgpg configs) (default all)
#   -s  seed for T11 random_stress                          (default 1)
#   -w  dump SHM waveforms      -g  open SimVision GUI     -v  verbose mismatches
#   -n  extra label in the run-folder name
# examples (any shell, incl. tcsh):
#   ./run_xrun.sh -c pg_fine
#   ./run_xrun.sh -c pg_coarse -o B -t 8 -w
#==============================================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fido_env.sh" || exit 1
. "$HERE/fido_lib.sh"

CFG=cg_fine; OPT=A; TEST=""; SEED=""; WAVES=0; GUI=0; VERB=0; TAG=""
while getopts "c:o:t:s:wgvn:h" opt; do
  case $opt in
    c) CFG=$OPTARG ;;
    o) OPT=$OPTARG ;;
    t) TEST=$OPTARG ;;
    s) SEED=$OPTARG ;;
    w) WAVES=1 ;;
    g) GUI=1 ;;
    v) VERB=1 ;;
    n) TAG=$OPTARG ;;
    *) sed -n '2,27p' "$0"; exit 2 ;;
  esac
done
fido_check_cfg "$CFG" || exit 2
case "$OPT" in A|B) ;; *) echo "option must be A or B" >&2; exit 2 ;; esac

label="${CFG}_${OPT}"
[ -n "$TEST" ] && label="${label}_T$(printf %02d "$TEST")"
[ -n "$SEED" ] && label="${label}_S$SEED"
[ -n "$TAG" ]  && label="${label}_$TAG"
DIR=$(fido_new_run_dir "$FIDO_RUNS" "$label") || exit 1
fido_link_latest "$DIR"

echo "FIDO V3 SV | Xcelium | root $FIDO_ROOT"
fido_run_one xrun "$CFG" "$OPT" "$TEST" "$SEED" "$WAVES" "$GUI" "$VERB" "$DIR"
rc=$?
echo "  results : $DIR/results.txt"
echo "  log     : $DIR/xrun.log"
exit $rc
