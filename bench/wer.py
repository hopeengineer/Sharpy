import re, json, sys, time, subprocess
def norm(s):
    s=re.sub(r"\[\[.*?\]\]","",s).lower()
    s=re.sub(r"[^a-z0-9' ]+"," ",s)
    return s.split()
def wer(ref,hyp):
    r,h=norm(ref),norm(hyp); n,m=len(r),len(h)
    d=list(range(m+1))
    for i in range(1,n+1):
        prev=d[:]; d[0]=i
        for j in range(1,m+1):
            d[j]=min(prev[j]+1,d[j-1]+1,prev[j-1]+(r[i-1]!=h[j-1]))
    return d[m]/n, n
a=open("media/script_a.txt").read(); b=open("media/script_b.txt").read()
REF=a+" "+b+" "+a+" "+b
out=open("results/wer.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
# Apple
t=subprocess.run(["./asr_apple_full","media/speech16k.wav"],capture_output=True,text=True).stdout
full=[l for l in t.splitlines() if l.startswith("FULLTEXT: ")][0][10:]
w,n=wer(REF,full); log(f"WER Apple SpeechAnalyzer: {w*100:.2f}%  (ref words={n})")
import mlx_whisper
for repo in ["mlx-community/whisper-large-v3-turbo","mlx-community/distil-whisper-large-v3"]:
    r=mlx_whisper.transcribe("media/speech16k.wav",path_or_hf_repo=repo,word_timestamps=True,language="en")
    w,n=wer(REF,r["text"]); log(f"WER {repo.split('/')[1]}: {w*100:.2f}%")
from parakeet_mlx import from_pretrained
m=from_pretrained("mlx-community/parakeet-tdt-0.6b-v3"); res=m.transcribe("media/speech16k.wav")
w,n=wer(REF,res.text); log(f"WER parakeet-tdt-0.6b-v3: {w*100:.2f}%")
log("WER_DONE")
