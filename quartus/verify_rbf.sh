#!/usr/bin/env bash
# Verify an RBF is a FRESH product of the build that claims to have made it.
# NARC 2026-07-27: a STALE .rbf beside a FAILED build is indistinguishable from a
# fresh one by size and sha alone -- a count, a size and a hash all survive the
# ABSENCE of the thing they describe. Only PROVENANCE distinguishes them.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RBF="$1"; [ -n "$RBF" ] || { echo "usage: verify_rbf.sh <rbf>"; exit 2; }
FIT="$ROOT/build_syn/hw_fit.log"; ASM="$ROOT/build_syn/hw_asm.log"
fail=0
[ -f "$RBF" ] || { echo "FAIL: no RBF at $RBF"; exit 1; }
for r in "$FIT" "$ASM"; do
  if [ -f "$r" ] && [ "$RBF" -ot "$r" ]; then
    echo "FAIL: RBF is OLDER than $(basename $r) -- this is a LEFTOVER, do not flash"
    echo "   rbf: $(stat -c%y "$RBF")"; echo "   rpt: $(stat -c%y "$r")"; fail=1
  fi
done
grep -qiE "^Error|Fatal" "$ASM" 2>/dev/null && { echo "FAIL: assembler log reports errors"; fail=1; }
echo "RBF      : $RBF"
echo "SIZE     : $(stat -c%s "$RBF") bytes"
echo "SHA256   : $(sha256sum "$RBF" | cut -d' ' -f1)"
echo "RBF MTIME: $(stat -c%y "$RBF")"
echo "FIT MTIME: $(stat -c%y "$FIT" 2>/dev/null || echo none)"
echo "ASM MTIME: $(stat -c%y "$ASM" 2>/dev/null || echo none)"
[ "$fail" -eq 0 ] && echo "VERDICT: FRESH -- provenance checks pass" || echo "VERDICT: DO NOT FLASH"
exit $fail
