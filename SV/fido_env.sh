#!/bin/bash
#==============================================================================
# FIDO V3 (WITCHER) SV kit - environment for the run scripts (bash).
# Sourced by every run_*.sh script of the SV kit.
#==============================================================================
# Cadence Xcelium 22.09
XCELIUM_HOME=${XCELIUM_HOME:-/home/install/XCELIUM2209}
case ":$PATH:" in
  *":$XCELIUM_HOME/tools/bin:"*) ;;
  *) PATH="$XCELIUM_HOME/tools/bin:$PATH" ;;
esac
export XCELIUM_HOME PATH

# SV kit root. Order: $FIDO_SV_ROOT if set, the folder holding this script,
# /home/testam/WITCHER/SV. (FIDO_ROOT of the Verilog kit is ignored here, so
# the two kits never mix; inside the scripts FIDO_ROOT = the SV kit root.)
_fido_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_fido_ok() { [ -f "$1/optionB_common/flist/rtl.f" ] && [ -d "$1/optionA_self_contained" ]; }
if [ -n "${FIDO_SV_ROOT:-}" ] && _fido_ok "$FIDO_SV_ROOT"; then
  FIDO_ROOT="$FIDO_SV_ROOT"
elif _fido_ok "$_fido_here"; then
  FIDO_ROOT="$_fido_here"
elif _fido_ok "/home/testam/WITCHER/SV"; then
  FIDO_ROOT="/home/testam/WITCHER/SV"
else
  echo "fido_env.sh: cannot find the SV kit (optionB_common/flist/rtl.f) - set FIDO_SV_ROOT" >&2
  return 1 2>/dev/null || exit 1
fi
FIDO_RUNS="${FIDO_SV_RUNS:-$FIDO_ROOT/runs}"
export FIDO_ROOT FIDO_RUNS
# configurations: the 4 single-technique ones and the 4 combined ones
FIDO_CFGS_OLD="cg_fine cg_coarse pg_fine pg_coarse"
FIDO_CFGS_NEW="cgpg_fine cgpg_coarse cgpg_ml_fine cgpg_ml_coarse"
FIDO_CFGS="$FIDO_CFGS_OLD $FIDO_CFGS_NEW"

# Cadence start-up reminder (lab: the licence and tool set-up come from
# /home/install/cshrc, which must be sourced in a csh shell in every new terminal)
FIDO_CADENCE_CSHRC=${FIDO_CADENCE_CSHRC:-/home/install/cshrc}
fido_cadence_hint() {
  echo "  REMINDER - start Cadence in this terminal first, then run the script again:" >&2
  echo "      cd $FIDO_ROOT" >&2
  echo "      csh" >&2
  echo "      source $FIDO_CADENCE_CSHRC        (prints 'Welcome to Cadence tools Suite')" >&2
  echo "      sh run_all.sh" >&2
}
