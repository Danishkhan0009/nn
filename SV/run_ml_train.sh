#!/bin/bash
#==============================================================================
# FIDO V3 (WITCHER) SV kit - retrain the ML power-gating models from simulation traces.
# Every run creates a new session folder  runs/<date>_<time>_MLTRAIN/
#   fine/ coarse/        trace runs (cgpg_ml_* with +MLTRACE: reactive policy,
#                        ml_trace_Tnn.csv per test)
#   ml_models.v          trained models (Verilog, generated)
#   model_report.txt     per-domain model, train / held-out scores
#   backup/              previous ml_export/*.sv files (only with -i)
#
# usage : ./run_ml_train.sh [-s xrun|icarus] [-o A|B] [-w W_NEG] [-p purity] [-i]
#   -s  simulator for the trace runs (default xrun)
#   -w  weight of "idle too short" samples (default 2)   -p tree leaf purity (default 0.75)
#   -i  install the new models into optionB_common/rtl/ml_export/*.sv and rebuild
#       every Option A file (ml/install_models_sv.py)
# after -i: ./run_all.sh -k new    measures the new models
#==============================================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fido_env.sh" || exit 1
. "$HERE/fido_lib.sh"

SIM=xrun; OPT=B; WNEG=2; PUR=0.75; INST=0
while getopts "s:o:w:p:ih" opt; do
  case $opt in
    s) SIM=$OPTARG ;;
    o) OPT=$OPTARG ;;
    w) WNEG=$OPTARG ;;
    p) PUR=$OPTARG ;;
    i) INST=1 ;;
    *) sed -n '2,17p' "$0"; exit 2 ;;
  esac
done
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed for ml/train_ml.py)" >&2; exit 1; }

SES=$(fido_new_run_dir "$FIDO_RUNS" "MLTRAIN") || exit 1
fido_link_latest "$SES"
echo "FIDO V3 SV | ML training | traces with $SIM, option $OPT | session $SES"
for g in fine coarse; do
  mkdir -p "$SES/$g"
  FIDO_EXTRA_PLUS="+MLTRACE" fido_run_one "$SIM" "cgpg_ml_$g" "$OPT" "" "" 0 0 0 "$SES/$g"
  n=$(ls "$SES/$g"/ml_trace_T*.csv 2>/dev/null | wc -l)
  echo "  $g: $n trace files"
  [ "$n" -gt 0 ] || { echo "no traces written - see $SES/$g" >&2; exit 1; }
done
python3 "$FIDO_ROOT/ml/train_ml.py" --fine "$SES/fine" --coarse "$SES/coarse" \
        --wneg "$WNEG" --purity "$PUR" -o "$SES/ml_models.v" > "$SES/train.log" 2>&1 || {
  echo "training failed - see $SES/train.log" >&2; exit 1; }
echo "  models : $SES/ml_models.v"
echo "  report : $SES/model_report.txt"
if [ $INST -eq 1 ]; then
  python3 "$FIDO_ROOT/ml/install_models_sv.py" "$SES/ml_models.v" "$FIDO_ROOT" "$SES/backup" | tee "$SES/install.log"
  echo "  installed (originals in $SES/backup). Next: ./run_all.sh -k new"
else
  echo "  not installed. To install: ./run_ml_train.sh ... -i   (or ml/install_models_sv.py)"
fi
