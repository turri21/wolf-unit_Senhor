#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/quartus/build_hw.sh" \
  OPEN_ICE=1,USE_DDR3_GFX=1,USE_DDR3_VRAM=1,DIAG_FACEOFF=1 \
  Arcade-OpenIce-faceoff-diag
