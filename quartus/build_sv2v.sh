#!/usr/bin/env bash
# build_sv2v.sh — Phase 6: down-convert all SystemVerilog to Quartus-17-friendly
# plain Verilog via sv2v, then Quartus synthesizes the .v output.
#
# WHY: Quartus Prime 17.0 Lite (the MiSTer-pinned version for Cyclone V) has a weak
# SystemVerilog front-end — it rejects size-casts `N'(...)`, header package-imports,
# and other constructs the vendored birdybro TMS34010 core + the Y-unit wrapper use
# (Questa/Icarus accept them). sv2v (github.com/zachjs/sv2v) resolves packages,
# params, and casts into Verilog-2005 that Quartus swallows cleanly — so the
# vendored core stays PRISTINE and we don't hand-patch casts. `-DSYNTHESIS` reuses
# the `ifndef SYNTHESIS` guard so the sim-only $readmemh/array-init loops are skipped.
#
# Usage:  SV2V=/path/to/sv2v.exe ./build_sv2v.sh   (default sv2v in /c/tools/sv2v)
set -e
SV2V="${SV2V:-/c/tools/sv2v/sv2v-Windows/sv2v.exe}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build_syn/smashtv_core.v"
mkdir -p "$ROOT/build_syn"

# SV set in dependency order: packages FIRST, then the (P0017+P0019) TMS34010 core, then
# the wolf modules + wrapper. WOLF first flash: gfx + DCS DEFERRED, so NO gfx_unpack, NO
# sound-side SV, NO yunit video/mem/palram (replaced by wolf_*). yunit_scanline is REUSED
# verbatim (the proven double-buffer line loader). smashtv_diag2_overlay is the DIAG_BOOT
# readout (generic taps). vram_sdram/_top are shared (wolf_memsys instantiates them).
SV=( "$ROOT/rtl/pkg/wolf_pkg.sv" "$ROOT/rtl/pkg/yunit_pkg.sv" "$ROOT/rtl/tms34010/rtl/tms34010_pkg.sv" )
while IFS= read -r f; do SV+=("$f"); done \
  < <(find "$ROOT/rtl/tms34010/rtl" -name '*.sv' ! -name 'tms34010_pkg.sv' | sort)
SV+=( "$ROOT/rtl/wolf/wolf_mem.sv" "$ROOT/rtl/wolf/wolf_dma.sv" "$ROOT/rtl/wolf/wolf_pic.sv" \
      "$ROOT/rtl/yunit/vram_sdram.sv" "$ROOT/rtl/yunit/vram_sdram_top.sv" "$ROOT/rtl/wolf/ram_sdram.sv" \
      "$ROOT/rtl/sdram/stv_vram_ddr_agent.sv" "$ROOT/rtl/sdram/stv_vram_ddr_top.sv" \
      "$ROOT/rtl/sdram/wolf_gfx_ddr_top.sv" "$ROOT/rtl/sdram/wolf_dcs_ddr_top.sv" "$ROOT/rtl/sdram/wolf_ddr3_arb.sv" \
      "$ROOT/rtl/wolf/wolf_memsys.sv" "$ROOT/rtl/wolf/wolf_dcs_stub.sv" \
      "$ROOT/rtl/dcs/adsp2105.sv" "$ROOT/rtl/wolf/wolf_dcs_board.sv" \
      "$ROOT/rtl/wolf/wolf_video.sv" "$ROOT/rtl/yunit/yunit_scanline.sv" \
      "$ROOT/rtl/wolf/wolf_video_top.sv" "$ROOT/rtl/wolf/wolf_palram.sv" "$ROOT/rtl/wolf/wolf_video_post.sv" \
      "$ROOT/rtl/sdram/yunit_sdram_arb.sv" "$ROOT/rtl/sdram/sdram_stock.sv" "$ROOT/rtl/sdram/yunit_sdram_adapter.sv" \
      "$ROOT/rtl/yunit/yunit_mem_cdc.sv" "$ROOT/rtl/wolf/wolf_gfxdl_guard.sv" "$ROOT/rtl/wolf/wolf_top.sv" \
      "$ROOT/rtl/diag/smashtv_diag2_overlay.sv" "$ROOT/rtl/diag/wolf_diag_geom_overlay.sv" \
      "$ROOT/rtl/diag/wolf_faceoff_diag_overlay.sv" )
# emu.sv (Arcade-SmashTV.sv) is Quartus-native SV (NOT sv2v'd): it instantiates
# wolf_top from this blob + smashtv_diag2_overlay + sys/ modules by name; in files.qip.

echo "sv2v: ${#SV[@]} SV files -> $OUT"
"$SV2V" -DSYNTHESIS ${SV2V_EXTRA:-} "${SV[@]}" > "$OUT"
echo "  $(wc -l < "$OUT") lines; size-casts remaining: $(grep -cE "[0-9A-Za-z_]+'\(" "$OUT")"
echo "Quartus reads build_syn/smashtv_core.v (Verilog) + the VHDL sound board + jt51/mc6809/pia (Verilog/VHDL)."
