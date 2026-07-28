#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/quartus/build_hw.sh" \
  WWF_MANIA=1,USE_DDR3_GFX=1,USE_DDR3_VRAM=1 \
  Arcade-WWFMania
