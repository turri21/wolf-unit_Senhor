#!/usr/bin/env bash
# run_sdram_burst.sh — iverilog cycle-accurate BANK-INTERLEAVED OPEN-PAGE BURST SDRAM
# bandwidth harness. Drives rtl/sdram/sdram_burst.sv (the Partition-C framebuffer controller)
# through the SAME real MT48LC16M16 model + real yunit_sdram_arb + yunit_sdram_adapter as the
# stock harness, replaying the identical iter-2 mid-fight demand mix, on the 2x (N64) SDRAM
# clock. Prints sustained total MB/s.
#
# ACCEPTANCE:
#   (a) FUNCTIONAL EQUIVALENCE — the read-data checksum (RDCHK) over the identical deterministic
#       replay must be BYTE-IDENTICAL to the stock controller's (this script computes both and
#       diffs them), and
#   (b) >= 123 MB/s sustained (framebuffer-resident demand floor), decisively beating the locked
#       21.62 MB/s stock baseline.
# Touches NO existing gate: run_sdram_bw.sh (stock baseline) is unchanged and its default run
# (no +define+RDCHK) is byte-for-byte as before.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
IVERILOG=/c/iverilog/bin/iverilog
VVP=/c/iverilog/bin/vvp

BURST_OUT="$HERE/sdram_burst.vvp"
STOCK_OUT="$HERE/sdram_bw_rdchk.vvp"

# ---- build + run the BURST controller (2x, RDCHK on for byte-identity) ----
"$IVERILOG" -g2012 -D RDCHK -o "$BURST_OUT" \
    -s tb_sdram_burst \
    "$HERE/tb_sdram_burst.sv" \
    "$HERE/mt48lc16m16.v" \
    "$ROOT/rtl/sdram/sdram_burst.sv" \
    "$ROOT/rtl/sdram/yunit_sdram_adapter.sv" \
    "$ROOT/rtl/sdram/yunit_sdram_arb.sv"
BURST_LOG="$("$VVP" "$BURST_OUT" | grep -E "^NOTE:|VIOLATION|ERROR|FATAL" || true)"

# ---- build + run the STOCK controller with RDCHK on (golden read-data checksum) ----
"$IVERILOG" -g2012 -D RDCHK -o "$STOCK_OUT" \
    -s tb_sdram_bw \
    "$HERE/tb_sdram_bw.sv" \
    "$HERE/mt48lc16m16.v" \
    "$ROOT/rtl/sdram/sdram_stock.sv" \
    "$ROOT/rtl/sdram/yunit_sdram_adapter.sv" \
    "$ROOT/rtl/sdram/yunit_sdram_arb.sv"
STOCK_LOG="$("$VVP" "$STOCK_OUT" | grep -E "RDCHK" || true)"

echo "$BURST_LOG"

# ---- byte-identity verdict ----
BURST_CHK="$(echo "$BURST_LOG" | grep -oE 'RDCHK [0-9a-f]+' | awk '{print $2}' | head -1)"
STOCK_CHK="$(echo "$STOCK_LOG" | grep -oE 'RDCHK [0-9a-f]+' | awk '{print $2}' | head -1)"
echo "NOTE: stock golden RDCHK = ${STOCK_CHK}"
if [ -n "$BURST_CHK" ] && [ "$BURST_CHK" = "$STOCK_CHK" ]; then
    echo "NOTE: EQUIVALENCE PASS  burst RDCHK ${BURST_CHK} == stock RDCHK ${STOCK_CHK} (byte-identical read data)"
else
    echo "NOTE: EQUIVALENCE FAIL  burst RDCHK ${BURST_CHK} != stock RDCHK ${STOCK_CHK}"
fi
