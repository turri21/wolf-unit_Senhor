#!/usr/bin/env bash
# run_sdram_bw.sh — iverilog cycle-accurate STOCK SDRAM bandwidth harness.
# Drives rtl/sdram/sdram_stock.sv through a real-timing MT48LC16M16 model, replays the
# iter-2 mid-fight demand mix, prints per-channel + total sustained MB/s. MEASUREMENT ONLY.
#
# ACCEPTANCE: total lands in the fitment-predicted ~18-21 MB/s stock band (proving the
# deficit vs the measured 161-179 MB/s demand). Outside the band => harness/model wrong.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
IVERILOG=/c/iverilog/bin/iverilog
VVP=/c/iverilog/bin/vvp
OUT="$HERE/sdram_bw.vvp"

"$IVERILOG" -g2012 -o "$OUT" \
    -s tb_sdram_bw \
    "$HERE/tb_sdram_bw.sv" \
    "$HERE/mt48lc16m16.v" \
    "$ROOT/rtl/sdram/sdram_stock.sv" \
    "$ROOT/rtl/sdram/yunit_sdram_adapter.sv" \
    "$ROOT/rtl/sdram/yunit_sdram_arb.sv"

# SIM_NO_ALTERA is not needed (stock guards its DDIO), but pass define harmlessly if the
# module references it. The stock module already gates altera_mf behind SIM_NO_ALTERA.
"$VVP" "$OUT" | grep -E "^NOTE:|VIOLATION|ERROR|FATAL" || true
