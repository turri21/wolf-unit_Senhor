import re, sys
f = sys.argv[1]; sigfile = sys.argv[2]
sigs = open(sigfile).read().split()
lines = open(f, encoding="utf-8").read().split("\n")
mod_i = next(i for i,l in enumerate(lines) if l.startswith("module tms34010_core"))
close_i = next(i for i in range(mod_i,len(lines)) if lines[i].strip()==");")
def is_decl_of(l,s):
    code=l.split("//")[0].rstrip()
    return code.endswith(";") and re.match(r'^  (logic|wire|reg)\b.*\b'+re.escape(s)+r'\b', l)
move=set()
for s in sigs:
    h=next((i for i in range(close_i+1,len(lines)) if is_decl_of(lines[i],s)),None)
    if h is not None: move.add(h)
move=sorted(move); moved=[lines[i] for i in move]
kept=[l for i,l in enumerate(lines) if i not in set(move)]
ins=next(i for i in range(mod_i,len(kept)) if kept[i].strip()==");")
blk=["","  // ===== P0002 (Arcade-SmashTV): forward declarations hoisted for Questa FSE 25.1std",
 "  // (2025.2), which enforces declaration-before-use. Pure decls moved verbatim from",
 "  // below; behavior-neutral (SV module items are order-independent). See PATCHES.md."]+moved+[""]
open(f,"w",encoding="utf-8").write("\n".join(kept[:ins+1]+blk+kept[ins+1:]))
print("hoisted %d lines for %d signals"%(len(move),len(sigs)))
