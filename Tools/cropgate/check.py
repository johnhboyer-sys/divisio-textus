# Gate: every case's NEW crop must contain its OLD crop (new keeps at least as much).
import re, sys
L=[l for l in open(sys.argv[1]) if l.startswith(('OLD','NEW'))]
pat=r'crop(?:\(px\))?:? ?(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+)'
# Other printouts: "CropRect(x: a, y: b, width: w, height: h)" and a bare "name a b c d".
rect=r'CropRect\(x: (-?[\d.e-]+), y: (-?[\d.e-]+), width: (-?[\d.e-]+), height: (-?[\d.e-]+)\)'
bare=r' (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+)\s*$'
def box(line):
    m=re.search(pat,line)
    if m: return [float(x) for x in m.groups()]
    m=re.search(rect,line)
    if m:
        x,y,w,h=[float(v) for v in m.groups()]; return [x,y,x+w,y+h]
    m=re.search(bare,line)
    return [float(x) for x in m.groups()] if m else None
bad=0
for o,n in zip(L[0::2],L[1::2]):
    a=box(o); b=box(n)
    if a is None or b is None: print('UNPARSED', o.strip(), n.strip()); bad+=1; continue
    if not (b[0]<=a[0]+0.01 and b[1]<=a[1]+0.01 and b[2]>=a[2]-0.01 and b[3]>=a[3]-0.01):
        bad+=1; print(o.strip()[:120]); print(n.strip()[:120]); print()
print(f'GATE: {bad} case(s) where NEW keeps less than OLD' + (' — FAIL' if bad else ' — PASS'))
sys.exit(1 if bad else 0)
