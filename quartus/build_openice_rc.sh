#!/usr/bin/env bash
# Open Ice release-candidate build, under the CROSS-SESSION Quartus mutex.
#
# Macro set is the one the last cab image used (build_syn/hw_map.log):
#   OPEN_ICE=1, USE_DDR3_GFX=1, USE_DDR3_VRAM=1
# so the DDR3 VRAM + DDR3 GFX paths are in the image -- which is where the
# cg_safe_w starvation fix lives.
set -eo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK=/d/deck/fpga/tunit/Arcade-TUnit_MiSTer/tools/quartus_lock.sh
[ -f "$LOCK" ] || { echo "FATAL: shared quartus lock missing at $LOCK" >&2; exit 4; }
NAME="Arcade-OpenIce-RC-$(date +%Y%m%d-%H%M)"
export FPGA_SESSION=WOLF
echo "== requesting the box for $NAME =="
FPGA_SESSION=WOLF bash "$LOCK" bash -c "
  cd '$ROOT' &&
  ./quartus/build_hw.sh 'OPEN_ICE=1,USE_DDR3_GFX=1,USE_DDR3_VRAM=1' '$NAME'
"
rc=$?
echo "== build exit $rc =="
RBF="$ROOT/releases/$NAME.rbf"
if [ -f "$RBF" ]; then
  echo "RBF   : $RBF"
  echo "SIZE  : $(stat -c%s "$RBF") bytes"
  echo "SHA256: $(sha256sum "$RBF" | cut -d' ' -f1)"
  echo "MTIME : $(stat -c%y "$RBF")"
else
  echo "NO RBF PRODUCED -- do not flash"; exit 1
fi
