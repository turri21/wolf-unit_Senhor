#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTNAME="${OUTNAME:-Arcade-UMK3_SRT_ERASE}"
QOUT="${QOUT:-output_files/q256_scanfix}"
MRA="${MRA:-$ROOT/releases/Arcade-UMK3_SRT_ERASE.mra}"
CORE="$ROOT/build_syn/smashtv_core.v"
RBF="$ROOT/releases/$OUTNAME.rbf"
RAW_RBF="$ROOT/$QOUT/Arcade-SmashTV.rbf"
MAP_LOG="$ROOT/build_syn/hw_map.log"
FIT_LOG="$ROOT/build_syn/hw_fit.log"
STA_LOG="$ROOT/build_syn/hw_sta.log"
ASM_LOG="$ROOT/build_syn/hw_asm.log"
RUN_MARKER="$ROOT/build_syn/hw_build.start"
RELEASE_MARKER="$ROOT/build_syn/umk3_release.start"
INPUT_HASH="$ROOT/build_syn/hw_inputs.sha256"
GATE_HASH="$ROOT/build_syn/umk3_gate_inputs.sha256"
E2E_PASS="$ROOT/sim/build/gfxdl_e2e/gate.pass"
FULL_LOG="$ROOT/sim/build/tb_wolf_gfxdl_full.log"
DCS_LOG="$ROOT/sim/build/tb_wolf_dcs_stub.log"
RATE_LOG="$ROOT/sim/build/tb_wolf_boot_extrom_rate.vsim.log"
ADAPTER_LOG="$ROOT/sim/build/tb_yunit_sdram_adapter_startup.log"
VRAM_LOG="$ROOT/sim/build/tb_vram_ddr.log"
VIDEO_DDR_LOG="$ROOT/sim/build/tb_wolf_video_ddr_pageflip.log"
HIROW_LOG="$ROOT/sim/build/tb_wolf_vram_hirow.log"
CONTENTION_LOG="$ROOT/sim/build/ddr3_contention/contention.log"
CONTROL_LOG="$ROOT/sim/build/ddr3_contention/control.log"
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

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

MODE="${1:-full}"
[ "$#" -le 1 ] || fail "usage: check_umk3_build.sh [--manifest-only]"
[ "$MODE" = "full" ] || [ "$MODE" = "--manifest-only" ] || \
  fail "usage: check_umk3_build.sh [--manifest-only]"

[ -f "$MRA" ] || fail "release MRA is missing"
command -v python >/dev/null 2>&1 || fail "python is required for strict MRA validation"
python - "$MRA" "$OUTNAME" <<'PY' || exit 1
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
expected_rbf = sys.argv[2]
try:
    root = ET.parse(path).getroot()
except Exception as exc:
    print(f"FAIL: strict MRA XML parse failed: {exc}", file=sys.stderr)
    raise SystemExit(1)

indexes = sorted(int(node.attrib["index"]) for node in root.findall("rom"))
if indexes != [0, 1, 2]:
    print(f"FAIL: expected MRA ROM indexes [0, 1, 2], found {indexes}", file=sys.stderr)
    raise SystemExit(1)
if root.findtext("rbf") != expected_rbf:
    print(f"FAIL: MRA rbf name must be {expected_rbf}", file=sys.stderr)
    raise SystemExit(1)

expected = {
    0: [
        ("l1.2_mortal_kombat_3_u54_ultimate.u54", "712b4db6"),
        ("l1.2_mortal_kombat_3_u63_ultimate.u63", "6d301faf"),
    ],
    1: [
        ("l1_mortal_kombat_3_u133_game_rom.u133", "79b94667"),
        ("l1_mortal_kombat_3_u132_game_rom.u132", "13e95228"),
        ("l1_mortal_kombat_3_u131_game_rom.u131", "41001e30"),
        ("l1_mortal_kombat_3_u130_game_rom.u130", "49379dd7"),
        ("l1_mortal_kombat_3_u129_game_rom.u129", "a8b41803"),
        ("l1_mortal_kombat_3_u128_game_rom.u128", "b410d72f"),
        ("l1_mortal_kombat_3_u127_game_rom.u127", "bd985be7"),
        ("l1_mortal_kombat_3_u126_game_rom.u126", "e7c32cf4"),
        ("l1_mortal_kombat_3_u125_game_rom.u125", "9a52227e"),
        ("l1_mortal_kombat_3_u124_game_rom.u124", "5c750ebc"),
        ("l1_mortal_kombat_3_u123_game_rom.u123", "f0ab88a8"),
        ("l1_mortal_kombat_3_u122_game_rom.u122", "9b87cdac"),
        ("umk-u121.bin", "cc4b95db"),
        ("umk-u120.bin", "1c8144cd"),
        ("umk-u119.bin", "5f10c543"),
        ("umk-u118.bin", "de0c4488"),
        ("umk-u113.bin", "99d74a1e"),
        ("umk-u112.bin", "b5a46488"),
        ("umk-u111.bin", "a87523c8"),
        ("umk-u110.bin", "0038f205"),
    ],
    2: [
        ("l2.0_mortal_kombat_3_u2_ultimate.u2", "3838cfe5"),
        ("l1_mortal_kombat_3_u3_music_spch.u3", "856fe411"),
        ("l1_mortal_kombat_3_u4_music_spch.u4", "428a406f"),
        ("l1_mortal_kombat_3_u5_music_spch.u5", "3b98a09f"),
    ],
}
for rom in root.findall("rom"):
    index = int(rom.attrib["index"])
    actual = [(part.attrib.get("name"), part.attrib.get("crc", "").lower())
              for part in rom.findall("part")]
    if actual != expected[index]:
        print(f"FAIL: ROM index {index} part order/CRC differs from the verified UMK3 manifest",
              file=sys.stderr)
        raise SystemExit(1)
PY

if [ "$MODE" = "--manifest-only" ]; then
  printf 'PASS: UMK3 MRA manifest verified\n'
  exit 0
fi

[ -f "$CORE" ] || fail "generated core is missing"
grep -Eq '^[[:space:]]*wolf_gfx_ddr_top.*[[:space:]]u_gfxddr[[:space:]]*\(' "$CORE" || \
  fail "generated core has no active wolf_gfx_ddr_top u_gfxddr instance"
grep -Eq '^[[:space:]]*stv_vram_ddr_top[[:space:]]*#\(' "$CORE" || \
  fail "generated core has no active parameterized stv_vram_ddr_top instance"
grep -Eq '^[[:space:]]*module[[:space:]]+wolf_gfxdl_guard' "$CORE" || \
  fail "generated core does not contain the download-drain guard"
if grep -Eq "^[[:space:]]*assign[[:space:]]+gfx_dl_ack[[:space:]]*=[[:space:]]*1[[:space:]]*'[bB][[:space:]]*0[[:space:]]*;" "$CORE"; then
  fail "generated core contains tied-low gfx_dl_ack fallback"
fi

[ -s "$RBF" ] || fail "expected releases/$OUTNAME.rbf is missing or empty"
[ -s "$RAW_RBF" ] || fail "Quartus assembler RBF is missing or empty"
cmp -s "$RBF" "$RAW_RBF" || fail "release RBF does not match Quartus assembler output"

[ -f "$RELEASE_MARKER" ] || fail "canonical UMK3 release marker is missing"
[ -f "$E2E_PASS" ] || fail "focused gfx download gate did not pass in this release run"
[ -s "$DCS_LOG" ] || fail "DCS mailbox gate log is missing or empty"
grep -Fq 'PASS wolf_dcs_stub:' "$DCS_LOG" || fail "DCS mailbox gate did not pass cleanly"
[ -s "$RATE_LOG" ] || fail "external-ROM CPU-rate gate log is missing or empty"
grep -Fq 'PASS: tb_wolf_boot_extrom_rate' "$RATE_LOG" || \
  fail "external-ROM CPU-rate/MAME-PC gate did not pass cleanly"
[ -s "$DMA_DGO_LOG" ] || fail "Wolf DMA DGO semantics log is missing or empty"
grep -Fq 'PASS: tb_wolf_dma_dgo_semantics' "$DMA_DGO_LOG" || \
  fail "Wolf DMA halt/resume/kill oracle did not pass"
grep -Fq 'PASS: no_pause mutant killed by FAIL[halt]' "$DMA_DGO_LOG" || \
  fail "Wolf DMA halt mutation survived"
grep -Fq 'PASS: no_kill mutant killed by FAIL[kill]' "$DMA_DGO_LOG" || \
  fail "Wolf DMA kill mutation survived"
grep -Fq 'COVER[loaded-kill]: second zero preceded drain; 4 queued writes discarded' "$DMA_DGO_LOG" || \
  fail "Wolf DMA loaded-kill gate did not reach and discard a full FIFO"
grep -Fq 'PASS: no_loaded_discard mutant killed by FAIL[loaded-kill-discard]' "$DMA_DGO_LOG" || \
  fail "Wolf DMA loaded-discard mutation survived"
[ -s "$DMA_RESTART_LOG" ] || fail "Wolf DMA queued-restart log is missing or empty"
grep -Fq 'PASS: tb_wolf_dma_dgo_queued_restart writes=4' "$DMA_RESTART_LOG" || \
  fail "Wolf DMA dropped or corrupted a GO queued behind a pending kill"
grep -Fq 'PASS: busy_readback mutant killed by COMMAND readback remained busy' "$DMA_RESTART_LOG" || \
  fail "Wolf DMA queued-restart status-readback mutation survived"
grep -Fq 'PASS: no_restart_capture mutant killed by GO written during the pending kill was dropped' "$DMA_RESTART_LOG" || \
  fail "Wolf DMA queued-restart capture mutation survived"
grep -Fq 'PASS: latest_go_wins mutant killed by queued transfer wrote 2 pixels, expected 4' "$DMA_RESTART_LOG" || \
  fail "Wolf DMA queued-restart first-wins mutation survived"
grep -Fq 'PASS: stale_command mutant killed by queued transfer wrote 3 pixels, expected 4' "$DMA_RESTART_LOG" || \
  fail "Wolf DMA queued-restart COMMAND-edge mutation survived"
grep -Fq 'PASS: lost_done_clear mutant killed by completion lost the stored DGO clear' "$DMA_RESTART_LOG" || \
  fail "Wolf DMA completion/register-write collision mutation survived"
[ -s "$DMA_MATRIX_LOG" ] || fail "Wolf DMA matrix log is missing or empty"
grep -Eq '^TOTAL: [0-9]+  PASS: [1-9][0-9]*  FAIL: 0$' "$DMA_MATRIX_LOG" || \
  fail "Wolf DMA exact-output matrix did not pass"
[ -s "$DMA_REALGFX_LOG" ] || fail "Wolf DMA real-gfx DDR log is missing or empty"
grep -Fq "RESULT: PASS -- bit-exact vs MAME's real captured post-blit VRAM" "$DMA_REALGFX_LOG" || \
  fail "Wolf DMA DDR graphics replay diverged from MAME"
for log in "$DMA_FIGHT_LOG" "$DMA_ATTRACT_LOG" "$DMA_BIO_LOG"; do
  [ -s "$log" ] || fail "Wolf DMA workload budget log ${log#$ROOT/} is missing or empty"
  grep -Fq 'PASS: live-fight frame retires inside the production frame budget' "$log" || \
    fail "Wolf DMA workload missed its modeled cadence in ${log#$ROOT/}"
done
grep -Fq 'replayed trace sim/traces/umk3_peak_fight_regs.txt rank 1:' "$DMA_FIGHT_LOG" || \
  fail "peak-fight DMA gate did not replay the intended trace"
grep -Fq 'WRITE ORACLE: blits=163 writes=148678 fnv64=91b0c6cfb9fb159a' "$DMA_FIGHT_LOG" || \
  fail "peak-fight ordered write oracle did not match"
grep -Fq 'replayed trace sim/traces/umk3_peak_attract_regs.txt rank 1:' "$DMA_ATTRACT_LOG" || \
  fail "peak-attract DMA gate did not replay the intended trace"
grep -Fq 'WRITE ORACLE: blits=198 writes=150546 fnv64=0bc2983e86e3a0ea' "$DMA_ATTRACT_LOG" || \
  fail "peak-attract ordered write oracle did not match"
grep -Fq 'replayed trace sim/traces/umk3_peak_bio_regs.txt rank 4:' "$DMA_BIO_LOG" || \
  fail "biography DMA gate did not replay the intended Kitana frame"
grep -Fq 'WRITE ORACLE: blits=28 writes=122037 fnv64=d6dd9e257ca4d44b' "$DMA_BIO_LOG" || \
  fail "biography ordered write oracle did not match"
[ -s "$VRAM_ABA_LOG" ] || fail "framebuffer A/B/A hazard log is missing or empty"
grep -Fq 'GATE: PASS -- forward and guard each cover the posted tail' "$VRAM_ABA_LOG" || \
  fail "framebuffer posted-write A/B/A oracle did not pass"
[ -s "$SRT2_LOG" ] || fail "SRT Tier-2 integration log is missing or empty"
grep -Fq 'SRT2 TB: PASS' "$SRT2_LOG" || \
  fail "SRT Tier-2 integration gate did not pass"
[ -s "$SRT_XDIFF_LOG" ] || fail "SRT Tier-2 cross-diff log is missing or empty"
grep -Fq 'PASS: SRT Tier-2 exact baseline; all four mutations diverge' "$SRT_XDIFF_LOG" || \
  fail "SRT Tier-2 output did not match the blind golden or a mutation survived"
[ -s "$SRT_DLANE_LOG" ] || fail "SRT DDR D-lane log is missing or empty"
grep -Fq 'GATE: PASS -- D-lane unit oracles green; both mutants killed' "$SRT_DLANE_LOG" || \
  fail "SRT DDR D-lane gate did not pass"
[ -s "$SRT_MEM_LOG" ] || fail "SRT alternate-memory log is missing or empty"
grep -Fq 'GATE: PASS -- both non-DDR3 SRT backends' "$SRT_MEM_LOG" || \
  fail "SRT alternate-memory gate did not pass"
[ -s "$ADAPTER_LOG" ] || fail "SDRAM startup-adapter gate log is missing or empty"
grep -Fq 'PASS: tb_yunit_sdram_adapter_startup' "$ADAPTER_LOG" || \
  fail "SDRAM startup-adapter gate did not pass cleanly"
[ -s "$VRAM_LOG" ] || fail "DDR3 VRAM loopback/cross-diff gate log is missing or empty"
grep -Fq 'RESULT: PASS -- P0 DDR3 loopback verified' "$VRAM_LOG" || \
  fail "DDR3 VRAM P0 loopback gate did not pass cleanly"
grep -Fq 'RESULT: PASS -- DDR3 VRAM subsystem bit-exact' "$VRAM_LOG" || \
  fail "DDR3 VRAM P1 cross-diff gate did not pass cleanly"
[ -s "$VIDEO_DDR_LOG" ] || fail "Wolf DDR page-flip gate log is missing or empty"
grep -Fq 'RESULT: PASS -- page-256 scanout seam matched' "$VIDEO_DDR_LOG" || \
  fail "page-256 line-prefetch seam gate did not pass cleanly"
grep -Fq 'RESULT: PASS -- page publication waited for transparent blit completion' "$VIDEO_DDR_LOG" || \
  fail "DMA-completion page-publication gate did not pass cleanly"
grep -Fq 'RESULT: PASS -- mid-blank page commit preserved prefetch margin' "$VIDEO_DDR_LOG" || \
  fail "bounded vblank page commit gate did not pass cleanly"
grep -Fq 'RESULT: PASS -- TMS DPYADR load and software override matched' "$VIDEO_DDR_LOG" || \
  fail "TMS DPYADR publication gate did not pass cleanly"
grep -Fq 'RESULT: PASS -- scanout phase-locked to TMS DPYADR boundary' "$VIDEO_DDR_LOG" || \
  fail "TMS raster phase-lock gate did not pass cleanly"
grep -Fq 'RESULT: PASS -- full DDR page-flip chain matched' "$VIDEO_DDR_LOG" || \
  fail "full Wolf DDR page-flip chain did not pass cleanly"
[ -s "$HIROW_LOG" ] || fail "DDR3 VRAM high-row gate log is missing or empty"
grep -Fq 'PASS: tb_wolf_vram_hirow' "$HIROW_LOG" || \
  fail "DDR3 VRAM high-row gate did not pass cleanly"
[ -s "$FULL_LOG" ] || fail "full 20 MB gfx download log is missing or empty"
LC_ALL=C grep -aEq '^(# )?PASS: tb_wolf_gfxdl_full .*model_err=0\)' "$FULL_LOG" || \
  fail "full 20 MB paced gfx download gate did not pass cleanly"
[ -s "$CONTENTION_LOG" ] || fail "DDR3 contention gate log is missing or empty"
grep -Fq 'RESULT: PASS' "$CONTENTION_LOG" || \
  fail "DDR3 contention gate did not pass cleanly"
[ -s "$CONTROL_LOG" ] || fail "DDR3 control gate log is missing or empty"
grep -Fq 'RESULT: PASS' "$CONTROL_LOG" || \
  fail "DDR3 control gate did not pass cleanly"
[ "$E2E_PASS" -nt "$RELEASE_MARKER" ] || fail "focused gfx gate predates this release run"
[ "$DCS_LOG" -nt "$RELEASE_MARKER" ] || fail "DCS mailbox gate predates this release run"
[ "$RATE_LOG" -nt "$RELEASE_MARKER" ] || fail "CPU-rate gate predates this release run"
[ "$DMA_DGO_LOG" -nt "$RELEASE_MARKER" ] || fail "DMA DGO gate predates this release run"
[ "$DMA_RESTART_LOG" -nt "$RELEASE_MARKER" ] || fail "DMA queued-restart gate predates this release run"
[ "$DMA_MATRIX_LOG" -nt "$RELEASE_MARKER" ] || fail "DMA matrix gate predates this release run"
[ "$DMA_REALGFX_LOG" -nt "$RELEASE_MARKER" ] || fail "DMA real-gfx gate predates this release run"
[ "$DMA_FIGHT_LOG" -nt "$RELEASE_MARKER" ] || fail "DMA fight budget predates this release run"
[ "$DMA_ATTRACT_LOG" -nt "$RELEASE_MARKER" ] || fail "DMA attract budget predates this release run"
[ "$DMA_BIO_LOG" -nt "$RELEASE_MARKER" ] || fail "DMA biography budget predates this release run"
[ "$VRAM_ABA_LOG" -nt "$RELEASE_MARKER" ] || fail "framebuffer A/B/A gate predates this release run"
[ "$SRT2_LOG" -nt "$RELEASE_MARKER" ] || fail "SRT Tier-2 gate predates this release run"
[ "$SRT_XDIFF_LOG" -nt "$RELEASE_MARKER" ] || fail "SRT cross-diff predates this release run"
[ "$SRT_DLANE_LOG" -nt "$RELEASE_MARKER" ] || fail "SRT DDR D-lane gate predates this release run"
[ "$SRT_MEM_LOG" -nt "$RELEASE_MARKER" ] || fail "SRT alternate-memory gate predates this release run"
[ "$ADAPTER_LOG" -nt "$RELEASE_MARKER" ] || fail "SDRAM startup gate predates this release run"
[ "$VRAM_LOG" -nt "$RELEASE_MARKER" ] || fail "DDR3 VRAM gate predates this release run"
[ "$VIDEO_DDR_LOG" -nt "$RELEASE_MARKER" ] || fail "Wolf DDR page-flip gate predates this release run"
[ "$HIROW_LOG" -nt "$RELEASE_MARKER" ] || fail "DDR3 VRAM high-row gate predates this release run"
[ "$FULL_LOG" -nt "$RELEASE_MARKER" ] || fail "full gfx gate predates this release run"
[ "$CONTENTION_LOG" -nt "$RELEASE_MARKER" ] || fail "DDR3 contention gate predates this release run"
[ "$CONTROL_LOG" -nt "$RELEASE_MARKER" ] || fail "DDR3 control gate predates this release run"
bash "$ROOT/quartus/hash_build_inputs.sh" check-source "$GATE_HASH" || \
  fail "a release-gate input changed after the focused/full simulations"

[ -f "$RUN_MARKER" ] || fail "hardware build start marker is missing"
[ "$RUN_MARKER" -nt "$E2E_PASS" ] || fail "hardware build did not follow the focused gfx gate"
[ "$RUN_MARKER" -nt "$DCS_LOG" ] || fail "hardware build did not follow the DCS mailbox gate"
[ "$RUN_MARKER" -nt "$RATE_LOG" ] || fail "hardware build did not follow the CPU-rate gate"
[ "$RUN_MARKER" -nt "$DMA_DGO_LOG" ] || fail "hardware build did not follow the DMA DGO gate"
[ "$RUN_MARKER" -nt "$DMA_RESTART_LOG" ] || fail "hardware build did not follow the DMA queued-restart gate"
[ "$RUN_MARKER" -nt "$DMA_MATRIX_LOG" ] || fail "hardware build did not follow the DMA matrix gate"
[ "$RUN_MARKER" -nt "$DMA_REALGFX_LOG" ] || fail "hardware build did not follow the DMA real-gfx gate"
[ "$RUN_MARKER" -nt "$DMA_FIGHT_LOG" ] || fail "hardware build did not follow the DMA fight budget"
[ "$RUN_MARKER" -nt "$DMA_ATTRACT_LOG" ] || fail "hardware build did not follow the DMA attract budget"
[ "$RUN_MARKER" -nt "$DMA_BIO_LOG" ] || fail "hardware build did not follow the DMA biography budget"
[ "$RUN_MARKER" -nt "$VRAM_ABA_LOG" ] || fail "hardware build did not follow the framebuffer A/B/A gate"
[ "$RUN_MARKER" -nt "$SRT2_LOG" ] || fail "hardware build did not follow the SRT Tier-2 gate"
[ "$RUN_MARKER" -nt "$SRT_XDIFF_LOG" ] || fail "hardware build did not follow the SRT cross-diff"
[ "$RUN_MARKER" -nt "$SRT_DLANE_LOG" ] || fail "hardware build did not follow the SRT DDR D-lane gate"
[ "$RUN_MARKER" -nt "$SRT_MEM_LOG" ] || fail "hardware build did not follow the SRT alternate-memory gate"
[ "$RUN_MARKER" -nt "$ADAPTER_LOG" ] || fail "hardware build did not follow the SDRAM startup gate"
[ "$RUN_MARKER" -nt "$VRAM_LOG" ] || fail "hardware build did not follow the DDR3 VRAM gate"
[ "$RUN_MARKER" -nt "$VIDEO_DDR_LOG" ] || fail "hardware build did not follow the Wolf DDR page-flip gate"
[ "$RUN_MARKER" -nt "$HIROW_LOG" ] || fail "hardware build did not follow the DDR3 VRAM high-row gate"
[ "$RUN_MARKER" -nt "$FULL_LOG" ] || fail "hardware build did not follow the full gfx gate"
[ "$RUN_MARKER" -nt "$CONTENTION_LOG" ] || fail "hardware build did not follow the DDR3 contention gate"
[ "$RUN_MARKER" -nt "$CONTROL_LOG" ] || fail "hardware build did not follow the DDR3 control gate"
[ "$CORE" -nt "$RUN_MARKER" ] || fail "generated RTL predates this hardware build"
[ "$MAP_LOG" -nt "$CORE" ] || fail "map log predates generated RTL"
[ "$INPUT_HASH" -nt "$MAP_LOG" ] || fail "input hash was not captured after map"
[ "$FIT_LOG" -nt "$INPUT_HASH" ] || fail "fit did not follow the mapped input snapshot"
[ "$STA_LOG" -nt "$FIT_LOG" ] || fail "timing analysis did not follow fit"
[ "$ASM_LOG" -nt "$STA_LOG" ] || fail "assembler did not follow timing analysis"
[ "$RAW_RBF" -nt "$STA_LOG" ] || fail "raw RBF predates timing analysis"
[ "$RBF" -nt "$ASM_LOG" ] || fail "release RBF predates assembler completion"
if [ "$RAW_RBF" -nt "$RBF" ]; then
  fail "release RBF predates raw assembler output"
fi

bash "$ROOT/quartus/hash_build_inputs.sh" check "$INPUT_HASH" || \
  fail "a Quartus source, constraint, project, flow, MRA, or gate input changed after map"

for log in "$MAP_LOG" "$FIT_LOG" "$STA_LOG" "$ASM_LOG"; do
  [ -s "$log" ] || fail "required build log ${log#$ROOT/} is missing or empty"
  [ "$log" -nt "$CORE" ] || fail "build log ${log#$ROOT/} predates generated RTL"
done

grep -Fq -- '--verilog_macro=USE_DDR3_GFX=1' "$MAP_LOG" || \
  fail "Quartus map log does not record USE_DDR3_GFX=1"
grep -Fq -- '--verilog_macro=USE_DDR3_VRAM=1' "$MAP_LOG" || \
  fail "Quartus map log does not record USE_DDR3_VRAM=1"
if grep -Fq -- '--verilog_macro=NBA_HANGTIME' "$MAP_LOG"; then
  fail "UMK3 map log unexpectedly records NBA_HANGTIME"
fi
if grep -Fq -- '--verilog_macro=RAMPAGE_WT' "$MAP_LOG"; then
  fail "UMK3 map log unexpectedly records RAMPAGE_WT"
fi
if grep -Eq -- '--verilog_macro=DIAG_[A-Za-z0-9_]+' "$MAP_LOG"; then
  fail "UMK3 map log unexpectedly records a diagnostic overlay macro"
fi
grep -Fq 'Analysis & Synthesis was successful. 0 errors' "$MAP_LOG" || fail "Quartus map did not pass"
grep -Fq 'Fitter was successful. 0 errors' "$FIT_LOG" || fail "Quartus fit did not pass"
grep -Fq 'Timing Analyzer was successful. 0 errors' "$STA_LOG" || fail "TimeQuest did not pass"
grep -Fq 'Assembler was successful. 0 errors' "$ASM_LOG" || fail "Quartus assembler did not pass"

python - "$STA_LOG" <<'PY' || exit 1
import collections
import re
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
values = [(kind.lower(), float(value)) for kind, value in re.findall(
    r"Worst-case (setup|hold|recovery|removal|minimum pulse width) slack is\s+(-?\d+(?:\.\d+)?)",
    text,
    flags=re.IGNORECASE,
)]
counts = collections.Counter(kind for kind, _ in values)
expected = {kind: 4 for kind in ("setup", "hold", "recovery", "removal", "minimum pulse width")}
if len(values) != 20 or counts != expected:
    print(f"FAIL: incomplete multicorner timing matrix: count={len(values)}, categories={dict(counts)}",
          file=sys.stderr)
    raise SystemExit(1)
bad = [(kind, value) for kind, value in values if value < 0.0]
if bad:
    print("FAIL: negative timing slack: " + ", ".join(f"{kind}={value}" for kind, value in bad),
          file=sys.stderr)
    raise SystemExit(1)
PY

printf 'PASS: UMK3 release build artifacts verified\n'
