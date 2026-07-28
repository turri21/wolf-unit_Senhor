#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/quartus/build_hw.sh" \
  MK3=1,USE_DDR3_GFX=1,USE_DDR3_VRAM=1 \
  Arcade-MK3
