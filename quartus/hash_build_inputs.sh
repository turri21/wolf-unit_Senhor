#!/usr/bin/env bash
# Hash every source, constraint, project, build-flow, and release-gate input.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
MANIFEST="${2:-$ROOT/build_syn/hw_inputs.sha256}"

# Build-set profile: which core's regression corpus this worktree pins into the
# gate. Default "umk3" preserves the full Wolf/UMK3 input set for every existing
# UMK3 / NBA-Hangtime tree (their manifests are unchanged, byte for byte, so
# their check / check-source gates still pass). A forked core worktree (e.g.
# Rampage) commits quartus/hw_build_profile naming itself, which excludes the
# UMK3-only regression corpus that does not exist in — and is not built by — that
# fork. This is an explicit, committed opt-out: the core source set below is
# ALWAYS required, so a deleted RTL/constraint/project file still breaks the gate
# in every worktree. Only the fork-irrelevant UMK3 sim/release corpus is dropped,
# and only where the worktree declares it.
PROFILE_FILE="$ROOT/quartus/hw_build_profile"
BUILD_PROFILE="umk3"
if [ -f "$PROFILE_FILE" ]; then
  BUILD_PROFILE="$(head -1 "$PROFILE_FILE" | tr -d '[:space:]')"
  [ -n "$BUILD_PROFILE" ] || BUILD_PROFILE="umk3"
fi

list_core_inputs() {
  # Files that actually determine the synthesized bitstream: RTL, constraints,
  # project, and build-flow scripts. Required in EVERY worktree regardless of
  # profile — a deleted or changed source file must make the manifest differ.
  find "$ROOT/sys" "$ROOT/rtl" -type f \
    \( -name '*.sv' -o -name '*.v' -o -name '*.vhd' -o -name '*.vhdl' \
       -o -name '*.vh' -o -name '*.svh' -o -name '*.qip' -o -name '*.tcl' \
       -o -name '*.sdc' -o -name '*.hex' -o -name '*.mif' \) -print0
  find "$ROOT/quartus" -maxdepth 1 -type f -name '*.sh' -print0
  printf '%s\0' \
    "$ROOT/Arcade-SmashTV.qsf" "$ROOT/Arcade-SmashTV.qpf" "$ROOT/files.qip" \
    "$ROOT/Arcade-SmashTV.sv"
}

list_umk3_regression_inputs() {
  # UMK3 / Wolf-lineage verification corpus: release MRAs, sim runners + TBs,
  # MAME-gospel traces, and generated fixtures. These do not feed synthesis;
  # they pin the proof corpus that validated the UMK3 / Hangtime bitstream. A
  # forked core has its own corpus and excludes this set via BUILD_PROFILE.
  printf '%s\0' \
    "$ROOT/releases/Ultimate Mortal Kombat 3.mra" \
    "$ROOT/releases/Arcade-UMK3_SRT_ERASE.mra" \
    "$ROOT/sim/ddr3_avalon_model.sv" "$ROOT/sim/make_wolf_gfx_linear_hex.py" \
    "$ROOT/sim/run_ddr3.sh" "$ROOT/sim/tb_vram_ddr_loopback.sv" \
    "$ROOT/sim/tb_vram_ddr_xdiff.sv" \
    "$ROOT/sim/run_wolf_video_ddr_pageflip.sh" \
    "$ROOT/sim/tb_wolf_video_blit_guard.sv" \
    "$ROOT/sim/tb_wolf_video_pageflip_seam.sv" \
    "$ROOT/sim/tb_wolf_video_flip_guard.sv" \
    "$ROOT/sim/tb_tms_dpyadr_load.sv" \
    "$ROOT/sim/tb_wolf_video_tms_lock.sv" \
    "$ROOT/sim/tb_wolf_video_ddr_pageflip.sv" \
    "$ROOT/sim/run_wolf_vram_hirow.sh" "$ROOT/sim/tb_wolf_vram_hirow.sv" \
    "$ROOT/sim/run_wolf_gfxdl_e2e.sh" "$ROOT/sim/run_wolf_gfxdl_full.sh" \
    "$ROOT/sim/tb_wolf_gfxdl_e2e.sv" "$ROOT/sim/tb_wolf_gfxdl_full.sv" \
    "$ROOT/sim/run_wolf_ddr3_contention.sh" "$ROOT/sim/tb_wolf_ddr3_contention.sv" \
    "$ROOT/sim/run_wolf_dcs_stub.sh" "$ROOT/sim/tb_wolf_dcs_stub.sv" \
    "$ROOT/sim/run_questa_wolf_boot_extrom_rate.sh" \
    "$ROOT/sim/tb_wolf_boot_extrom_rate.sv" "$ROOT/sim/sdram_model.sv" \
    "$ROOT/sim/make_maindata_hex.py" "$ROOT/sim/build/umk3_maindata.hex" \
    "$ROOT/sim/build/umk3_gfx.hex" "$ROOT/sim/build/umk3_gfx_linear.bin" \
    "$ROOT/../mame-gospel/trace/umk3_main_pc.ref" \
    "$ROOT/sim/run_yunit_sdram_adapter_startup.sh" \
    "$ROOT/sim/tb_yunit_sdram_adapter_startup.sv" \
    "$ROOT/sim/run_wolf_dma_dgo_semantics.sh" "$ROOT/sim/tb_wolf_dma_dgo_semantics.sv" \
    "$ROOT/sim/run_wolf_dma_dgo_queued_restart.sh" \
    "$ROOT/sim/tb_wolf_dma_dgo_queued_restart.sv" \
    "$ROOT/sim/run_wolf_dma_matrix.sh" "$ROOT/sim/tb_wolf_dma.sv" \
    "$ROOT/sim/gen_wolf_dma_vectors.py" "$ROOT/sim/wolf_dma_model.py" \
    "$ROOT/sim/wolf_dma_vectors.json" "$ROOT/sim/wolf_dma_realblits.json" \
    "$ROOT/sim/run_wolf_dma_ddr3_realgfx.sh" "$ROOT/sim/tb_wolf_dma_ddr3_realgfx.sv" \
    "$ROOT/sim/diff_dma_out_vs_mame.py" "$ROOT/sim/traces/wolf_dma_realblit1_stim.txt" \
    "$ROOT/../mame-gospel/trace/nearblit/vram.hex" \
    "$ROOT/../mame-gospel/trace/nearblit/vram_postblit.hex" \
    "$ROOT/sim/run_wolf_peak_fight_budget.sh" "$ROOT/sim/tb_wolf_peak_fight_budget.sv" \
    "$ROOT/sim/traces/umk3_peak_fight_regs.txt" \
    "$ROOT/sim/traces/umk3_peak_attract_regs.txt" \
    "$ROOT/sim/traces/umk3_peak_bio_regs.txt" \
    "$ROOT/sim/run_wolf_vram_aba_partial.sh" "$ROOT/sim/tb_wolf_vram_aba_partial.sv"
  printf '%s\0' \
    "$ROOT/sim/golden_srt_entry_level.py" \
    "$ROOT/sim/run_wolf_srt2_contract.sh" "$ROOT/sim/tb_wolf_srt2_contract.sv" \
    "$ROOT/sim/run_wolf_vram_srt_dlane.sh" "$ROOT/sim/tb_wolf_vram_srt_dlane.sv" \
    "$ROOT/sim/run_wolf_mem_srt_units.sh" "$ROOT/sim/tb_wolf_mem_srt_units.sv"
}

list_source_inputs() {
  list_core_inputs
  # Add the UMK3 regression corpus only where the worktree pins it (default).
  # A fork's profile (e.g. "rampage") excludes it — see BUILD_PROFILE above.
  case "$BUILD_PROFILE" in
    umk3) list_umk3_regression_inputs ;;
  esac
}

list_inputs() {
  list_source_inputs
  printf '%s\0' "$ROOT/build_id.v" "$ROOT/build_syn/smashtv_core.v"
}

write_manifest() {
  local selector="$1"
  local output="$2"
  mkdir -p "$(dirname "$output")"
  local tmp="$output.tmp"
  "$selector" | sort -z | xargs -0 sha256sum > "$tmp"
  mv "$tmp" "$output"
}

case "$MODE" in
  write)
    write_manifest list_inputs "$MANIFEST"
    ;;
  write-source)
    write_manifest list_source_inputs "$MANIFEST"
    ;;
  check)
    [ -s "$MANIFEST" ] || { echo "FAIL: build-input hash manifest is missing" >&2; exit 1; }
    VERIFY="$MANIFEST.verify.$$"
    write_manifest list_inputs "$VERIFY"
    cmp -s "$MANIFEST" "$VERIFY" || {
      rm -f "$VERIFY"
      echo "FAIL: build-input set or content differs from the captured manifest" >&2
      exit 1
    }
    rm -f "$VERIFY"
    ;;
  check-source)
    [ -s "$MANIFEST" ] || { echo "FAIL: source/gate hash manifest is missing" >&2; exit 1; }
    VERIFY="$MANIFEST.verify.$$"
    write_manifest list_source_inputs "$VERIFY"
    cmp -s "$MANIFEST" "$VERIFY" || {
      rm -f "$VERIFY"
      echo "FAIL: source/gate input set or content differs from the captured manifest" >&2
      exit 1
    }
    rm -f "$VERIFY"
    ;;
  *)
    echo "usage: hash_build_inputs.sh {write|write-source|check|check-source} [manifest]" >&2
    exit 2
    ;;
esac
