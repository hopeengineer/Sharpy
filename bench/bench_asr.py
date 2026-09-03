import time, sys, json, resource, traceback
AUDIO = "media/speech16k.wav"; DUR = float(open("media/speech_duration.txt").read())
out = open("results/asr.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
def rss(): return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1048576
import mlx.core as mx
# --- mlx-whisper ---
for repo in ["mlx-community/whisper-large-v3-turbo", "mlx-community/distil-whisper-large-v3"]:
    try:
        import mlx_whisper
        mx.reset_peak_memory()
        t0=time.time()
        r = mlx_whisper.transcribe(AUDIO, path_or_hf_repo=repo, word_timestamps=True, language="en")
        dt=time.time()-t0
        words=sum(len(s.get("words",[])) for s in r["segments"])
        log(f"ASR {repo}: wall={dt:.1f}s audio={DUR:.0f}s RTFx={DUR/dt:.1f} words={words} peakMLX={mx.get_peak_memory()/1e9:.2f}GB peakRSS={rss():.0f}MB")
        log("   sample: " + r["text"][:160].strip())
        ws=[w for s in r["segments"] for w in s.get("words",[])][:6]
        log("   words: " + json.dumps([(w["word"].strip(), round(w["start"],2), round(w["end"],2)) for w in ws]))
        # filler check
        fillers=sum(1 for s in r["segments"] for w in s.get("words",[]) if w["word"].strip().lower().strip(",.") in ("um","uh"))
        log(f"   filler tokens transcribed (um/uh): {fillers}")
    except Exception as e:
        log(f"ASR {repo}: FAILED {e!r}"); traceback.print_exc()
# --- parakeet-mlx ---
try:
    from parakeet_mlx import from_pretrained
    mx.reset_peak_memory()
    t0=time.time(); m=from_pretrained("mlx-community/parakeet-tdt-0.6b-v3"); tl=time.time()-t0
    t0=time.time(); res=m.transcribe(AUDIO); dt=time.time()-t0
    toks=[t for s in res.sentences for t in s.tokens]
    log(f"ASR parakeet-tdt-0.6b-v3 (mlx): load={tl:.1f}s wall={dt:.1f}s audio={DUR:.0f}s RTFx={DUR/dt:.1f} tokens={len(toks)} peakMLX={mx.get_peak_memory()/1e9:.2f}GB peakRSS={rss():.0f}MB")
    log("   sample: " + res.text[:160].strip())
    log("   tokens: " + json.dumps([(t.text, round(t.start,2), round(t.end,2)) for t in toks[:8]]))
    fill=sum(1 for t in toks if t.text.strip().lower().strip(",.") in ("um","uh"))
    log(f"   filler tokens transcribed (um/uh): {fill}")
except Exception as e:
    log(f"ASR parakeet: FAILED {e!r}"); traceback.print_exc()
log("ASR_DONE")
