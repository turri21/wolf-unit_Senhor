#!/usr/bin/env bash
# Judge an STA log. MUST run BEFORE quartus_asm, and the caller MUST exit on failure.
#
# WHY THIS EXISTS (2026-07-27, Wolf RC-20260727-1509):
#   quartus_sta REPORTS slack; it does not JUDGE it. It exits 0 on a design that
#   misses timing by any margin -- its exit code answers "did I run", not "does
#   this design close". Our build emitted a FRESH, correctly-hashed,
#   provenance-clean RBF at setup -0.031 because nothing downstream asked the
#   question. NARC's flow refused at -0.119 purely because its STA stage is not
#   bare quartus_sta.
#
#   A missing artifact announces itself. A timing-FAILING image that passes every
#   freshness and provenance check does not. verify_rbf.sh answers "is this image
#   what we built"; it CANNOT answer "should we have built it". This answers that.
#
# Exit: 0 = closes, 1 = violation, 2 = INCONCLUSIVE (never silently "clean").
#
# KNOWN LIMITATION OF THIS GATE'S *PASS* PATH (T-unit, 2026-07-27):
#   Validated three ways -- real failing log (FAIL), synthetic clean log (PASS),
#   5-byte log (INCONCLUSIVE). The middle arm proves the gate CAN pass, i.e. it is
#   not an always-fail gate, which arms 1+3 alone cannot exclude. But that arm used
#   a log I WROTE; no real clean Quartus STA log has ever existed in this tree to
#   test against. So the PASS path is proven REACHABLE, not proven FAITHFUL.
#   The decision is string-coupled: if Quartus renamed "Timing requirements not
#   met" or "Worst-case ... slack is", both signals vanish and this returns PASS on
#   a failing design. The vacuity check below is the only thing standing in the way
#   (it refuses to grade a log with no slack lines at all), so it must not be
#   removed. Replace the synthetic arm with a genuine clean report when one exists.
set -uo pipefail

LOG="${1:?usage: check_timing.sh <hw_sta.log>}"

if [ ! -f "$LOG" ]; then
  echo "TIMING: INCONCLUSIVE -- $LOG does not exist" >&2; exit 2
fi
# LIVENESS, not existence. A truncated/zero-byte log must never read as clean --
# that trap hit all four sessions today. 1 KB is well under any real STA log.
if [ "$(wc -c < "$LOG")" -lt 1024 ]; then
  echo "TIMING: INCONCLUSIVE -- $LOG is $(wc -c < "$LOG") bytes (<1KB), STA did not run to completion" >&2
  exit 2
fi
# The log must actually contain slack reporting, or we are grading silence.
if ! grep -q "Worst-case setup slack" "$LOG"; then
  echo "TIMING: INCONCLUSIVE -- no 'Worst-case setup slack' lines in $LOG" >&2; exit 2
fi

# Two independent signals. Either one failing fails the build.
#  (a) Quartus's own verdict across all corners.
#  (b) The most negative slack we can find, so a future Quartus that drops the
#      critical warning still cannot slip a violation past us.
NOTMET="$(grep -c "Timing requirements not met" "$LOG" || true)"

WORST="$(grep -E "Worst-case (setup|hold|recovery|removal|minimum pulse width) slack is" "$LOG" \
         | grep -oE "\-[0-9]+\.[0-9]+" | sort -n | head -1)"

echo "TIMING REPORT: $LOG"
echo "  'Timing requirements not met' occurrences : ${NOTMET}"
echo "  most negative worst-case slack            : ${WORST:-none}"

if [ "$NOTMET" -gt 0 ] || [ -n "$WORST" ]; then
  echo "TIMING: FAIL -- design does not close. Refusing to assemble an RBF." >&2
  echo "  Failing clocks/corners:" >&2
  grep -B2 -A6 "Timing requirements not met" "$LOG" | grep -E "^\s+Info \(332119\):\s+\-" >&2 || true
  exit 1
fi

echo "TIMING: PASS -- no negative slack, no unmet requirements."
exit 0
