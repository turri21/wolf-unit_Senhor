#!/usr/bin/env bash
# Canonical release build: graphics ROM and VRAM scanout both live in DDR3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTNAME="${OUTNAME:-Arcade-UMK3_SRT_ERASE}"
MRA="${MRA:-$ROOT/releases/Arcade-UMK3_SRT_ERASE.mra}"
export OUTNAME MRA
DMA_DGO_LOG="$ROOT/sim/build/tb_wolf_dma_dgo_semantics.release.log"
DMA_RESTART_LOG="$ROOT/sim/build/tb_wolf_dma_dgo_queued_restart.release.log"
DMA_MATRIX_LOG="$ROOT/sim/build/wolf_dma_matrix.release.log"
DMA_REALGFX_LOG="$ROOT/sim/build/wolf_dma_ddr3_realgfx.release.log"
DMA_FIGHT_LOG="$ROOT/sim/build/tb_wolf_peak_fight_budget.release.log"
DMA_ATTRACT_LOG="$ROOT/sim/build/tb_wolf_peak_attract_budget.release.log"
DMA_BIO_LOG="$ROOT/sim/build/tb_wolf_peak_bio_budget.release.log"
VRAM_ABA_LOG="$ROOT/sim/build/wolf_vram_aba_partial.release.log"
SRT2_LOG="$ROOT/sim/build/tb_wolf_srt2_contract.release.log"
SRT_XDIFF_LOG="$ROOT/sim/build/tb_wolf_srt2_xdiff.release.log"
SRT_DLANE_LOG="$ROOT/sim/build/tb_wolf_vram_srt_dlane.release.log"
SRT_MEM_LOG="$ROOT/sim/build/tb_wolf_mem_srt_units.release.log"

# A release entry point must not inherit diagnostics or unrelated feature defines.
unset SV2V_EXTRA
RELEASE_MARKER="$ROOT/build_syn/umk3_release.start"
GATE_HASH="$ROOT/build_syn/umk3_gate_inputs.sha256"
mkdir -p "$ROOT/build_syn"
rm -f "$RELEASE_MARKER" "$ROOT/sim/build/gfxdl_e2e/gate.pass" \
      "$ROOT/sim/build/tb_wolf_gfxdl_full.log" \
      "$ROOT/sim/build/tb_wolf_dcs_stub.log" \
      "$ROOT/sim/build/tb_yunit_sdram_adapter_startup.log" \
      "$ROOT/sim/build/tb_vram_ddr.log" \
      "$ROOT/sim/build/tb_wolf_video_ddr_pageflip.log" \
      "$ROOT/sim/build/tb_wolf_vram_hirow.log" \
      "$ROOT/sim/build/ddr3_contention/contention.log" \
      "$ROOT/sim/build/ddr3_contention/control.log" \
      "$DMA_DGO_LOG" "$DMA_RESTART_LOG" "$DMA_MATRIX_LOG" "$DMA_REALGFX_LOG" \
      "$DMA_FIGHT_LOG" "$DMA_ATTRACT_LOG" "$DMA_BIO_LOG" "$VRAM_ABA_LOG" \
      "$SRT2_LOG" "$SRT_XDIFF_LOG" "$SRT_DLANE_LOG" "$SRT_MEM_LOG" \
      "$ROOT/sim/build/tb_wolf_boot_extrom_rate.vsim.log" "$GATE_HASH"
: > "$RELEASE_MARKER"
bash "$ROOT/quartus/hash_build_inputs.sh" write-source "$GATE_HASH"

if [ "$#" -ne 0 ]; then
  printf 'FAIL: build_umk3.sh takes no arguments\n' >&2
  exit 2
fi

bash "$ROOT/quartus/check_umk3_build.sh" --manifest-only
bash "$ROOT/sim/run_wolf_srt2_contract.sh" 2>&1 | tee "$SRT2_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
{
  python "$ROOT/sim/golden_srt_entry_level.py"
  for dump in vram_entries.hex scan_p0.hex scan_p1.hex; do
    cmp "$ROOT/sim/build/srt2_tb/$dump" "$ROOT/sim/build/srt2_golden/$dump"
  done
  for mutation in no-srt pixel-only-copy sr512 wrong-page; do
    if cmp -s "$ROOT/sim/build/srt2_tb/vram_entries.hex" \
              "$ROOT/sim/build/srt2_golden_${mutation}/vram_entries.hex" && \
       cmp -s "$ROOT/sim/build/srt2_tb/scan_p0.hex" \
              "$ROOT/sim/build/srt2_golden_${mutation}/scan_p0.hex" && \
       cmp -s "$ROOT/sim/build/srt2_tb/scan_p1.hex" \
              "$ROOT/sim/build/srt2_golden_${mutation}/scan_p1.hex"; then
      printf 'FAIL: SRT mutation %s is indistinguishable from the RTL output\n' "$mutation" >&2
      exit 1
    fi
  done
  printf 'PASS: SRT Tier-2 exact baseline; all four mutations diverge\n'
} 2>&1 | tee "$SRT_XDIFF_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_vram_srt_dlane.sh" 2>&1 | tee "$SRT_DLANE_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_mem_srt_units.sh" 2>&1 | tee "$SRT_MEM_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_dcs_stub.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_yunit_sdram_adapter_startup.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_questa_wolf_boot_extrom_rate.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_dma_dgo_semantics.sh" 2>&1 | tee "$DMA_DGO_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_dma_dgo_queued_restart.sh" 2>&1 | tee "$DMA_RESTART_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_dma_matrix.sh" 2>&1 | tee "$DMA_MATRIX_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_dma_ddr3_realgfx.sh" 2>&1 | tee "$DMA_REALGFX_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
TRACE=sim/traces/umk3_peak_fight_regs.txt RANK=1 \
  EXPECT_BLITS=163 EXPECT_WRITES=148678 EXPECT_HASH=91b0c6cfb9fb159a \
  LOG="$DMA_FIGHT_LOG" \
  bash "$ROOT/sim/run_wolf_peak_fight_budget.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
TRACE=sim/traces/umk3_peak_attract_regs.txt RANK=1 \
  EXPECT_BLITS=198 EXPECT_WRITES=150546 EXPECT_HASH=0bc2983e86e3a0ea \
  LOG="$DMA_ATTRACT_LOG" \
  bash "$ROOT/sim/run_wolf_peak_fight_budget.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
TRACE=sim/traces/umk3_peak_bio_regs.txt RANK=4 \
  EXPECT_BLITS=28 EXPECT_WRITES=122037 EXPECT_HASH=d6dd9e257ca4d44b \
  LOG="$DMA_BIO_LOG" \
  bash "$ROOT/sim/run_wolf_peak_fight_budget.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_vram_aba_partial.sh" 2>&1 | tee "$VRAM_ABA_LOG"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_ddr3.sh" 2>&1 | tee "$ROOT/sim/build/tb_vram_ddr.log"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_video_ddr_pageflip.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_vram_hirow.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_gfxdl_e2e.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/sim/run_wolf_gfxdl_full.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
FRAMES=2 bash "$ROOT/sim/run_wolf_ddr3_contention.sh"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH"
bash "$ROOT/quartus/build_hw.sh" USE_DDR3_GFX=1,USE_DDR3_VRAM=1 "$OUTNAME"
bash "$ROOT/quartus/check_umk3_build.sh"
