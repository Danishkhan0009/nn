#!/bin/bash
#==============================================================================
# FIDO V3 (WITCHER) SV kit - run all configurations on Cadence Xcelium 22.09 (SystemVerilog sources).
# Every run creates a new session folder  runs/<date>_<time>_ALL_<set>_<opt>/
#   summary.txt  summary.csv  results_all.csv  and one sub-folder per config
#   (same contents as a run_xrun.sh run folder).
#
# usage : ./run_all.sh [-k all|old|new] [-o A|B] [-t test] [-s seed] [-v] [-n tag]
#   -k  all = 8 configurations (default)
#       old = cg_fine cg_coarse pg_fine pg_coarse              (11 tests each)
#       new = cgpg_fine cgpg_coarse cgpg_ml_fine cgpg_ml_coarse (16 tests each)
# example: ./run_all.sh            ./run_all.sh -k new -o B -t 11 -s 5
#==============================================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fido_env.sh" || exit 1
. "$HERE/fido_lib.sh"

OPT=A; TEST=""; SEED=""; VERB=0; TAG=""; SIM=${FIDO_SIM:-xrun}; KSET=all
while getopts "k:o:t:s:vn:h" opt; do
  case $opt in
    k) KSET=$OPTARG ;;
    o) OPT=$OPTARG ;;
    t) TEST=$OPTARG ;;
    s) SEED=$OPTARG ;;
    v) VERB=1 ;;
    n) TAG=$OPTARG ;;
    *) sed -n '2,14p' "$0"; exit 2 ;;
  esac
done
case "$OPT" in A|B) ;; *) echo "option must be A or B" >&2; exit 2 ;; esac
case "$KSET" in
  all) LIST=$FIDO_CFGS ;;
  old) LIST=$FIDO_CFGS_OLD ;;
  new) LIST=$FIDO_CFGS_NEW ;;
  *) echo "-k must be all, old or new" >&2; exit 2 ;;
esac

label="ALL"
[ "$KSET" != "all" ] && label="${label}_${KSET}"
label="${label}_${OPT}"
[ -n "$TEST" ] && label="${label}_T$(printf %02d "$TEST")"
[ -n "$SEED" ] && label="${label}_S$SEED"
[ -n "$TAG" ]  && label="${label}_$TAG"
SES=$(fido_new_run_dir "$FIDO_RUNS" "$label") || exit 1
fido_link_latest "$SES"

echo "FIDO V3 SV | $SIM | configurations: $KSET | option $OPT | root $FIDO_ROOT"
fail=0; warn=0
for c in $LIST; do
  mkdir -p "$SES/$c"
  fido_run_one "$SIM" "$c" "$OPT" "$TEST" "$SEED" 0 0 "$VERB" "$SES/$c"
  case $? in 0) ;; 3) warn=1 ;; *) fail=1 ;; esac
done

# session summary
{
  echo "FIDO V3 SV session $(basename "$SES")   simulator $SIM   option $OPT   test ${TEST:-all}   seed ${SEED:-1}"
  echo "-----------------------------------------------------------------------"
  for c in $LIST; do
    line=$(grep -h ' SUMMARY ' "$SES/$c/"*.log 2>/dev/null | tail -1 | sed 's/^ *//')
    printf "%-15s %-5s %s\n" "$c" "$(cat "$SES/$c/STATUS" 2>/dev/null)" "${line:-no test summary - see $c/xrun.log}"
  done
  echo "-----------------------------------------------------------------------"
  if [ $fail -ne 0 ]; then echo "SESSION FAIL"
  elif [ $warn -ne 0 ]; then echo "SESSION WARN (tests pass, simulator warnings - see */tool_warnings.txt)"
  else echo "SESSION PASS"; fi
} > "$SES/summary.txt"
{
  echo "cfg,status,passed,failed,checker_errors,tool_warnings,tool_errors"
  for c in $LIST; do
    pfc=$(sed -n 's/^passed\/failed : \([0-9]*\) \/ \([0-9]*\)   checker errors: \([0-9]*\)/\1,\2,\3/p' "$SES/$c/run_info.txt")
    tw=$(sed -n 's/^tool messages : \([0-9]*\) warnings, \([0-9]*\) errors.*/\1,\2/p' "$SES/$c/run_info.txt")
    echo "$c,$(cat "$SES/$c/STATUS"),${pfc:-,,},${tw:-,}"
  done
} > "$SES/summary.csv"
{
  echo "cfg,test,name,result,retired,ref_cycles,dut_cycles,overhead_pct,gating_stalls"
  for c in $LIST; do [ -f "$SES/$c/results.csv" ] && tail -n +2 "$SES/$c/results.csv" | sed "s/^/$c,/"; done
} > "$SES/results_all.csv"

echo
cat "$SES/summary.txt"
echo "  folder  : $SES"
[ $fail -ne 0 ] && exit 1
[ $warn -ne 0 ] && exit 3
exit 0
