#!/bin/bash
#==============================================================================
# FIDO V3 (WITCHER) SV kit - T11 random_stress over a range of seeds (Xcelium 22.09).
# Every run creates a new folder  runs/<date>_<time>_SEEDS_<cfg>_<opt>_<first>-<last>/
#   seeds.csv  summary.txt  and one sub-folder per <cfg>_S<seed>
#
# usage : ./run_seeds.sh [-c cfg|all] [-o A|B] [-f first] [-l last]
# example: ./run_seeds.sh -c all -f 1 -l 20
#==============================================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fido_env.sh" || exit 1
. "$HERE/fido_lib.sh"

CFG=all; OPT=A; FIRST=1; LAST=10; SIM=${FIDO_SIM:-xrun}
while getopts "c:o:f:l:h" opt; do
  case $opt in
    c) CFG=$OPTARG ;;
    o) OPT=$OPTARG ;;
    f) FIRST=$OPTARG ;;
    l) LAST=$OPTARG ;;
    *) sed -n '2,9p' "$0"; exit 2 ;;
  esac
done
if [ "$CFG" = "all" ]; then LIST=$FIDO_CFGS; else fido_check_cfg "$CFG" || exit 2; LIST=$CFG; fi

SES=$(fido_new_run_dir "$FIDO_RUNS" "SEEDS_${CFG}_${OPT}_${FIRST}-${LAST}") || exit 1
fido_link_latest "$SES"
echo "FIDO V3 SV | $SIM | T11 seeds $FIRST..$LAST | option $OPT"
echo "cfg,seed,status" > "$SES/seeds.csv"
fail=0; n=0
for c in $LIST; do
  for ((sd = FIRST; sd <= LAST; sd++)); do
    mkdir -p "$SES/${c}_S$sd"
    fido_run_one "$SIM" "$c" "$OPT" 11 "$sd" 0 0 0 "$SES/${c}_S$sd"
    case $? in 0) st=PASS ;; 3) st=WARN ;; *) st=FAIL; fail=$((fail + 1)) ;; esac
    echo "$c,$sd,$st" >> "$SES/seeds.csv"
    n=$((n + 1))
  done
done
{
  echo "T11 random_stress   seeds $FIRST..$LAST   configs: $LIST   option $OPT"
  echo "runs: $n   failed: $fail"
  grep -E 'FAIL|WARN' "$SES/seeds.csv"
  [ $fail -eq 0 ] && echo "SESSION PASS" || echo "SESSION FAIL"
} > "$SES/summary.txt"
echo; cat "$SES/summary.txt"; echo "  folder  : $SES"
[ $fail -eq 0 ]
