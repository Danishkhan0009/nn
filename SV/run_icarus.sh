#!/bin/bash
#==============================================================================
# FIDO V3 (WITCHER) SV kit - OPTIONAL licence-free cross-check with Icarus Verilog.
# Same options and the same per-run folders as run_xrun.sh / run_all.sh, with
# icarus.log instead of xrun.log. Xcelium remains the target simulator.
#
# usage : ./run_icarus.sh -c <cfg|all> [-k all|old|new] [-o A|B] [-t test] [-s seed] [-v]
#==============================================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG=cg_fine; ARGS=()
KARG=()
while getopts "c:k:o:t:s:vn:h" opt; do
  case $opt in
    c) CFG=$OPTARG ;;
    k) KARG=("-k" "$OPTARG") ;;
    o|t|s|n) ARGS+=("-$opt" "$OPTARG") ;;
    v) ARGS+=("-v") ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
  esac
done
if [ "$CFG" = "all" ]; then
  FIDO_SIM=icarus exec "$HERE/run_all.sh" "${KARG[@]}" "${ARGS[@]}" -n icarus
fi
. "$HERE/fido_env.sh" || exit 1
. "$HERE/fido_lib.sh"
fido_check_cfg "$CFG" || exit 2
OPT=A; TEST=""; SEED=""; VERB=0
set -- "${ARGS[@]}"
OPTIND=1
while getopts "o:t:s:vn:" opt; do
  case $opt in o) OPT=$OPTARG ;; t) TEST=$OPTARG ;; s) SEED=$OPTARG ;; v) VERB=1 ;; n) ;; esac
done
label="${CFG}_${OPT}_icarus"
[ -n "$TEST" ] && label="${label}_T$(printf %02d "$TEST")"
[ -n "$SEED" ] && label="${label}_S$SEED"
DIR=$(fido_new_run_dir "$FIDO_RUNS" "$label") || exit 1
fido_link_latest "$DIR"
fido_run_one icarus "$CFG" "$OPT" "$TEST" "$SEED" 0 0 "$VERB" "$DIR"
rc=$?
echo "  results : $DIR/results.txt"
exit $rc
