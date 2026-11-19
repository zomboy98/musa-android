#!/usr/bin/env bash
set -u
SERIAL="${1:-adb-R5CXC179VNB-5diQAD._adb-tls-connect._tcp}"
PKG="${2:-org.musa.music.debug}"
OUT="${3:-./medicion_video_$(date +%Y%m%d_%H%M%S)}"
SECS="${4:-20}"
mkdir -p "$OUT"
adb_() { adb -s "$SERIAL" "$@"; }

adb_ shell dumpsys SurfaceFlinger --list > "$OUT/capas.txt" 2>&1
CAPA=$(grep -o "SurfaceView\[$PKG[^#]*#[0-9]*" "$OUT/capas.txt" | grep BLAST | head -1)
[ -z "$CAPA" ] && CAPA=$(grep -o "SurfaceView\[$PKG[^#]*#[0-9]*" "$OUT/capas.txt" | head -1)
[ -z "$CAPA" ] && CAPA=$(grep -o "VRI-$PKG[^ ]*#[0-9]*" "$OUT/capas.txt" | head -1)
echo "capa: $CAPA" | tee "$OUT/resumen.txt"

adb_ shell dumpsys gfxinfo "$PKG" > "$OUT/gfx_antes.txt" 2>&1
adb_ logcat -c
adb_ shell "dumpsys SurfaceFlinger --latency '$CAPA'" > "$OUT/latencia_a.txt" 2>&1
sleep "$SECS"
adb_ shell "dumpsys SurfaceFlinger --latency '$CAPA'" > "$OUT/latencia_b.txt" 2>&1
adb_ shell dumpsys gfxinfo "$PKG" > "$OUT/gfx_despues.txt" 2>&1
adb_ shell dumpsys gfxinfo "$PKG" framestats > "$OUT/framestats.txt" 2>&1
adb_ shell dumpsys media.codec > "$OUT/codec.txt" 2>&1
adb_ shell dumpsys display | grep -o "mActiveRenderFrameRate=[0-9.]*" > "$OUT/hz.txt"
adb_ logcat -d -t 30000 > "$OUT/logcat.txt" 2>&1

grep -E "flutter : video:" "$OUT/logcat.txt" > "$OUT/video_log.txt"
grep -E "Skipped [0-9]+ frames|Davey|dropped|MediaCodec.*(drop|late)|exynos.*(h264|hevc|vp9)" "$OUT/logcat.txt" > "$OUT/caidas.txt"

cat > "$OUT/analiza.py" <<'PY'
import sys,re,statistics
d=sys.argv[1]
def frames(f):
    t=[]
    for l in open(f"{d}/{f}",errors="ignore").read().splitlines()[1:]:
        p=l.split()
        if len(p)==3 and p[1].isdigit() and int(p[1])<2**62: t.append(int(p[1])/1e6)
    return t
t=sorted(set(frames("latencia_b.txt")))
out=[]
if len(t)>3:
    iv=[b-a for a,b in zip(t,t[1:]) if b>a]
    med=statistics.median(iv)
    span=(t[-1]-t[0])/1000
    out.append(f"fotogramas={len(t)} ventana={span:.1f}s fps_efectivos={len(t)/span:.1f} intervalo_mediano={med:.1f}ms")
    for k in (1.5,2.0):
        n=sum(1 for x in iv if x>med*k)
        out.append(f"intervalos>{k}x_mediano={n} ({100*n/len(iv):.1f} %) max={max(iv):.0f}ms")
else:
    out.append("sin fotogramas en la capa (el vídeo no estaba reproduciéndose)")
def g(f,key):
    m=re.search(key+r".*",open(f"{d}/{f}",errors="ignore").read()); return m.group(0) if m else "?"
for k in ("Total frames rendered","Janky frames:","99th percentile","Number Slow UI thread"):
    out.append("antes   "+g("gfx_antes.txt",k)); out.append("despues "+g("gfx_despues.txt",k))
open(f"{d}/resumen.txt","a").write("\n".join(out)+"\n"); print("\n".join(out))
PY
python3 "$OUT/analiza.py" "$OUT" 2>/dev/null || python "$OUT/analiza.py" "$OUT"
echo "--- video: ---"; tail -15 "$OUT/video_log.txt"
echo "salida en $OUT"
