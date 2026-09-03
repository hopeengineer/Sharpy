import time, json, resource, traceback, subprocess, re
AUDIO="real/reel12_16k.wav"
out=open("results/asr_real.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
def rss(): return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1048576
DUR=float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",AUDIO],capture_output=True,text=True).stdout)
tx={}
# Apple
t0=time.time(); r=subprocess.run(["./asr_apple_full",AUDIO],capture_output=True,text=True); dt=time.time()-t0
full=[l for l in r.stdout.splitlines() if l.startswith("FULLTEXT: ")]
tx["apple"]=full[0][10:] if full else ""
log(f"REAL-ASR apple: wall={dt:.1f}s audio={DUR:.0f}s words={len(tx['apple'].split())}")
import mlx.core as mx, mlx_whisper
for name,repo in [("whisper-turbo","mlx-community/whisper-large-v3-turbo"),("distil-whisper","mlx-community/distil-whisper-large-v3")]:
    try:
        t0=time.time(); r=mlx_whisper.transcribe(AUDIO,path_or_hf_repo=repo,word_timestamps=True,language="en"); dt=time.time()-t0
        tx[name]=r["text"]; log(f"REAL-ASR {name}: wall={dt:.1f}s words={len(r['text'].split())} peakRSS={rss():.0f}MB")
    except Exception as e: log(f"REAL-ASR {name}: FAILED {e!r}")
try:
    from parakeet_mlx import from_pretrained
    m=from_pretrained("mlx-community/parakeet-tdt-0.6b-v3"); t0=time.time(); res=m.transcribe(AUDIO); dt=time.time()-t0
    tx["parakeet"]=res.text; log(f"REAL-ASR parakeet: wall={dt:.1f}s words={len(res.text.split())}")
except Exception as e: log(f"REAL-ASR parakeet: FAILED {e!r}")
json.dump(tx,open("results/asr_real_transcripts.json","w"),indent=1)
# pairwise agreement (WER of each vs each) — NOT ground truth, just disagreement
def norm(s): return re.sub(r"[^a-z0-9' ]+"," ",s.lower()).split()
def wer(a,b):
    r,h=norm(a),norm(b); n,m=len(r),len(h); d=list(range(m+1))
    for i in range(1,n+1):
        p=d[:]; d[0]=i
        for j in range(1,m+1): d[j]=min(p[j]+1,d[j-1]+1,p[j-1]+(r[i-1]!=h[j-1]))
    return d[m]/max(n,1)
names=list(tx)
log("PAIRWISE word-disagreement (row as reference):")
log("            "+" ".join(f"{n:>14}" for n in names))
for a in names: log(f"{a:>12}"+" ".join(f"{wer(tx[a],tx[b])*100:13.1f}%" for b in names))
for n in names: log(f"--- {n} ---\n{tx[n][:600]}")
log("REAL_ASR_DONE")
