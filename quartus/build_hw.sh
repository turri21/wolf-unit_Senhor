#!/usr/bin/env bash
# build_hw.sh — full HW build (sv2v -> quartus map/fit/sta/asm -> releases/<name>.rbf).
#   ./build_hw.sh [VERILOG_MACROS] [OUTNAME]
# e.g.  ./build_hw.sh DIAG_SDRAM=1 Arcade-SmashTV_diag     (SDRAM loopback diagnostic)
#       ./build_hw.sh USE_DDR3_GFX=1,USE_DDR3_VRAM=1 Arcade-UMK3
#       ./build_hw.sh "" Arcade-SmashTV_stocksdram          (normal core)
set -eo pipefail   # pipefail: a failed quartus_* stage now stops the build (the tee|grep|tail
                   # pipe used to mask the map exit code -> a failed map wrongly ran fit/asm).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QBIN=/c/intelFPGA_lite/17.0/quartus/bin64
REV=Arcade-SmashTV
MACRO="${1:-}"
OUTNAME="${2:-Arcade-SmashTV}"
QOUT="${QOUT:-output_files/q256_scanfix}"
RUN_MARKER="$ROOT/build_syn/hw_build.start"
INPUT_HASH="$ROOT/build_syn/hw_inputs.sha256"
QSF_QOUT="$(sed -n -E 's/^set_global_assignment -name PROJECT_OUTPUT_DIRECTORY[[:space:]]+//p' "$ROOT/$REV.qsf" | tail -1)"

if [[ "$QOUT" != "$QSF_QOUT" ]]; then
  echo "FAIL: QOUT=$QOUT but Quartus project writes to $QSF_QOUT" >&2
  exit 2
fi

# Remove prior success evidence before this run. A failed stage must not leave an
# older raw/release RBF or log set that a later preflight could mistake for current.
rm -f "$ROOT/build_syn/hw_map.log" "$ROOT/build_syn/hw_fit.log" \
      "$ROOT/build_syn/hw_sta.log" "$ROOT/build_syn/hw_asm.log" \
      "$INPUT_HASH" "$ROOT/$QOUT/$REV.rbf" "$ROOT/releases/$OUTNAME.rbf"
mkdir -p "$ROOT/build_syn"
: > "$RUN_MARKER"

export SV2V="${SV2V:-/c/tools/sv2v/sv2v-Windows/sv2v.exe}"
MACROS=()
SV2V_DEFS=()
if [ -n "$MACRO" ]; then
  IFS=',' read -r -a MACROS <<< "$MACRO"
  for feature in "${MACROS[@]}"; do
    [[ "$feature" =~ ^[A-Za-z_][A-Za-z0-9_]*(=.*)?$ ]] || {
      printf 'FAIL: invalid Verilog macro %q\n' "$feature" >&2
      exit 2
    }
    SV2V_DEFS+=("-D$feature")
  done

  # Most Wolf-unit RTL is converted before Quartus sees it, so every feature
  # define must reach sv2v as well as quartus_map.
  export SV2V_EXTRA="${SV2V_EXTRA:+$SV2V_EXTRA }${SV2V_DEFS[*]}"
fi
echo "=== sv2v ==="
bash "$ROOT/quartus/build_sv2v.sh"

cd "$ROOT"
MACROARG=()
for feature in "${MACROS[@]}"; do
  MACROARG+=(--verilog_macro="$feature")
done
# run_stage: run a Quartus stage, tee the FULL log, show a digest, and propagate
# the STAGE's exit code -- NOT the pipeline's.
#
# `cmd | tee log | grep | tail` reports the exit status of TAIL, so a stage that
# died returns 0 and the build sails on. NARC hit exactly this (a wrapper exiting
# 0 over a build that exited 3) and Y-unit found the same shape in their queued
# script. Every stage below had it.
run_stage() {
  local name="$1" log="$2" filter="$3"; shift 3
  echo "=== $name ==="
  "$@" 2>&1 | tee "$log" | grep -iE "$filter" | tail -6
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo "!!! $name FAILED (exit $rc) -- see $log" >&2
    exit "$rc"
  fi
}

run_stage "quartus_map ${MACRO:+(macros ${MACROS[*]})}" build_syn/hw_map.log \
  "error|successful" "$QBIN/quartus_map" $REV -c $REV "${MACROARG[@]}"
bash "$ROOT/quartus/hash_build_inputs.sh" write "$INPUT_HASH"

run_stage "quartus_fit" build_syn/hw_fit.log "error|successful" \
  "$QBIN/quartus_fit" $REV -c $REV

run_stage "quartus_sta" build_syn/hw_sta.log "slack|error|successful" \
  "$QBIN/quartus_sta" $REV -c $REV

# THE GATE quartus_sta WILL NOT APPLY FOR YOU.
# quartus_sta exits 0 on a design that misses timing -- its exit code answers
# "did I run", not "does this close". Without this, the build assembles a FRESH,
# correctly-hashed, provenance-clean, TIMING-FAILING RBF (RC-20260727-1509 at
# setup -0.031). A missing artifact announces itself; that one does not.
# MUST stay BEFORE quartus_asm: the protection is that no RBF is ever produced.
echo "=== timing gate ==="
if ! bash "$ROOT/quartus/check_timing.sh" build_syn/hw_sta.log; then
  echo "!!! TIMING GATE FAILED -- refusing to assemble. No RBF will be produced." >&2
  exit 5
fi

run_stage "quartus_asm" build_syn/hw_asm.log "error|successful" \
  "$QBIN/quartus_asm" $REV -c $REV

mkdir -p releases
cp -v "$QOUT/$REV.rbf" "releases/$OUTNAME.rbf"
echo "=== done: releases/$OUTNAME.rbf ==="
