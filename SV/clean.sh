#!/bin/bash
#==============================================================================
# FIDO V3 (WITCHER) SV kit - housekeeping for the runs/ folder
#   ./clean.sh -l    delete compiled libraries (xcelium.d, *.vvp) in every run,
#                    keep all logs and results                (safe, default)
#   ./clean.sh -a    delete the whole runs/ folder (asks for confirmation)
#==============================================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fido_env.sh" || exit 1
MODE=libs
while getopts "lah" opt; do
  case $opt in l) MODE=libs ;; a) MODE=all ;; *) sed -n '2,7p' "$0"; exit 2 ;; esac
done
[ -d "$FIDO_RUNS" ] || { echo "nothing to clean ($FIDO_RUNS does not exist)"; exit 0; }
if [ "$MODE" = "all" ]; then
  printf "delete %s completely? [y/N] " "$FIDO_RUNS"; read -r a
  [ "$a" = "y" ] || [ "$a" = "Y" ] || { echo "cancelled"; exit 0; }
  rm -rf "$FIDO_RUNS" && echo "removed $FIDO_RUNS"
else
  find "$FIDO_RUNS" -type d -name xcelium.d -prune -exec rm -rf {} +
  find "$FIDO_RUNS" -type f -name '*.vvp' -delete
  echo "compiled libraries removed; logs and results kept in $FIDO_RUNS"
fi
