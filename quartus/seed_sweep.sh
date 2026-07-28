#!/usr/bin/env bash
# Refit the current synthesis across seeds and accept only a placement that
# closes every reported setup and hold corner. The mapped database is reused,
# so each candidate runs fitter plus TimeQuest before any RBF is assembled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

QBIN=/c/intelFPGA_lite/17.0/quartus/bin64
REV=Arcade-SmashTV
OUTNAME="${OUTNAME:-Arcade-UMK3_Q256_SCANFIX}"
QOUT="${QOUT:-output_files/q256_scanfix}"
TARGET_SETUP="${TARGET_SETUP:-0.20}"
TARGET_HOLD="${TARGET_HOLD:-0.00}"
SEEDS="${SEEDS:-1 2 4 6}"
FIT_PARALLEL="${FIT_PARALLEL:-4}"
QSF="$ROOT/$REV.qsf"
INPUT_HASH="$ROOT/build_syn/hw_inputs.sha256"

QSF_QOUT="$(sed -n -E 's/^set_global_assignment -name PROJECT_OUTPUT_DIRECTORY[[:space:]]+//p' "$QSF" | tail -1)"
if [[ "$QOUT" != "$QSF_QOUT" ]]; then
  echo "FAIL: QOUT=$QOUT but Quartus project writes to $QSF_QOUT" >&2
  exit 2
fi

worst_slack () {
  local kind="$1"
  grep -E "Worst-case ${kind} slack is" "$ROOT/$QOUT/$REV.sta.rpt" \
    | sed -E 's/.*is +(-?[0-9.]+).*/\1/' | sort -g | head -1
}

mkdir -p releases build_syn/seed_sweep
rm -f "releases/$OUTNAME.rbf"

for S in $SEEDS; do
  echo "======== SEED $S ========"
  sed -i -E "s/^set_global_assignment -name SEED [0-9]+/set_global_assignment -name SEED $S/" "$QSF"
  # Quartus rewrites QSF files with CRLF. Normalize before hashing so that harmless
  # line-ending churn during fit cannot look like a semantic input mutation.
  sed -i 's/\r$//' "$QSF"
  sed -i 's/$/\r/' "$QSF"
  grep -E "^set_global_assignment -name SEED " "$QSF"

  MARKER="build_syn/seed_${S}.start"
  rm -f "$QOUT/$REV.fit.rpt" "$QOUT/$REV.fit.summary" \
        "$QOUT/$REV.sta.rpt" "$QOUT/$REV.sta.summary" "$QOUT/$REV.rbf" \
        "build_syn/seed_${S}_fit.log" "build_syn/seed_${S}_sta.log" \
        "build_syn/seed_${S}_asm.log"
  : > "$MARKER"
  bash "$ROOT/quartus/hash_build_inputs.sh" write "$INPUT_HASH"

  echo "-- fit --"
  "$QBIN/quartus_fit" $REV -c $REV --parallel="$FIT_PARALLEL" 2>&1 \
    | tee "build_syn/seed_${S}_fit.log" \
    | grep -iE "error|successful" | tail -3
  [[ -s "$QOUT/$REV.fit.rpt" && "$QOUT/$REV.fit.rpt" -nt "$MARKER" ]] || {
    echo "FAIL: seed $S produced no current fit report" >&2
    exit 1
  }
  echo "-- sta --"
  "$QBIN/quartus_sta" $REV -c $REV 2>&1 \
    | tee "build_syn/seed_${S}_sta.log" \
    | grep -iE "Worst-case (setup|hold|recovery|removal|minimum pulse width) slack|error|successful" | tail -24
  [[ -s "$QOUT/$REV.sta.rpt" && "$QOUT/$REV.sta.rpt" -nt "$QOUT/$REV.fit.rpt" ]] || {
    echo "FAIL: seed $S produced no current timing report" >&2
    exit 1
  }

  WS="$(worst_slack setup)"
  WH="$(worst_slack hold)"
  WR="$(worst_slack recovery)"
  WM="$(worst_slack removal)"
  WP="$(worst_slack 'minimum pulse width')"
  echo "SEED $S -> setup=$WS hold=$WH recovery=$WR removal=$WM minpulse=$WP"

  mkdir -p build_syn/seed_sweep
  cp -f "$QOUT/$REV.fit.summary" "build_syn/seed_sweep/seed_${S}.fit.summary"
  cp -f "$QOUT/$REV.sta.summary" "build_syn/seed_sweep/seed_${S}.sta.summary"

  if [[ -n "$WS" && -n "$WH" ]] &&
     awk -v w="$WS" -v t="$TARGET_SETUP" 'BEGIN{exit !(w+0 >= t+0)}' &&
     awk -v w="$WH" -v t="$TARGET_HOLD" 'BEGIN{exit !(w+0 >= t+0)}' &&
     awk -v w="$WR" 'BEGIN{exit !(w+0 >= 0)}' &&
     awk -v w="$WM" 'BEGIN{exit !(w+0 >= 0)}' &&
     awk -v w="$WP" 'BEGIN{exit !(w+0 >= 0)}'; then
    echo "==== SEED $S IS CAB-SAFE -- asm + copy ===="
    bash "$ROOT/quartus/hash_build_inputs.sh" check "$INPUT_HASH"
    "$QBIN/quartus_asm" $REV -c $REV 2>&1 \
      | tee "build_syn/seed_${S}_asm.log" \
      | grep -iE "error|successful" | tail -3
    [[ -s "$QOUT/$REV.rbf" && "$QOUT/$REV.rbf" -nt "$QOUT/$REV.sta.rpt" ]] || {
      echo "FAIL: seed $S assembler produced no current RBF" >&2
      exit 1
    }
    bash "$ROOT/quartus/hash_build_inputs.sh" check "$INPUT_HASH"
    mkdir -p releases
    cp -v "$QOUT/$REV.rbf" "releases/$OUTNAME.rbf"
    cmp -s "$QOUT/$REV.rbf" "releases/$OUTNAME.rbf" || {
      echo "FAIL: copied release differs from current assembler output" >&2
      exit 1
    }
    echo "SWEEP_DONE seed=$S setup=$WS hold=$WH recovery=$WR removal=$WM minpulse=$WP rbf=releases/$OUTNAME.rbf"
    exit 0
  fi

  echo "SEED $S rejected; trying next"
done

echo "SWEEP_EXHAUSTED -- no seed in [$SEEDS] met setup/hold targets"
exit 1
