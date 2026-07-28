#!/usr/bin/env bash
# Canonical one-RBF Midway Wolf Unit master build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTNAME="Arcade-WolfUnit"
PACKAGE="$ROOT/releases/WolfUnit-Master"

# A release build must not inherit a diagnostic overlay or a per-game macro.
unset SV2V_EXTRA

bash "$ROOT/sim/run_wolf_game_profiles.sh"
bash "$ROOT/sim/run_wolf_nvram.sh"
bash "$ROOT/sim/run_wolf_pic.sh"
bash "$ROOT/sim/run_wolf_srt2_contract.sh"
bash "$ROOT/sim/run_wolf_dma_matrix.sh"
bash "$ROOT/sim/run_wolf_gfxdl_e2e.sh"
bash "$ROOT/sim/run_wolf_gfxdl_full.sh"
bash "$ROOT/sim/run_ase_wolf_profile_boots.sh"
bash "$ROOT/sim/run_ase_rwt_boot.sh"

bash "$ROOT/quartus/build_hw.sh" \
  WOLF_MASTER=1,USE_DDR3_GFX=1,USE_DDR3_VRAM=1 \
  "$OUTNAME"

mkdir -p "$PACKAGE"
cp -f "$ROOT/releases/$OUTNAME.rbf" "$PACKAGE/$OUTNAME.rbf"
echo "Wolf Unit master package: $PACKAGE"
