import time, sys, glob, resource, traceback, gc
out=open("results/vlm.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
def rss(): return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1048576
import mlx.core as mx
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_config
FRAMES=sorted(glob.glob("frames/*.jpg"))
MODELS=["mlx-community/Qwen3-VL-4B-Instruct-4bit","mlx-community/Qwen3-VL-2B-Instruct-4bit","mlx-community/SmolVLM2-2.2B-Instruct-mlx","mlx-community/gemma-3n-E2B-it-4bit"]
PROMPT="You are a video editor's perception module. For each frame, state: what is on screen, whether a person is visible, any on-screen text, and the dominant motion. Then in one sentence: what kind of video is this?"
for repo in MODELS:
    try:
        mx.reset_peak_memory(); gc.collect()
        t0=time.time(); model,processor=load(repo); cfg=load_config(repo); tl=time.time()-t0
        log(f"VLM {repo}: load={tl:.1f}s modelMem={mx.get_active_memory()/1e9:.2f}GB")
        for n in (1,4,8):
            imgs=FRAMES[:n]
            prompt=apply_chat_template(processor,cfg,PROMPT,num_images=len(imgs))
            mx.reset_peak_memory()
            t0=time.time()
            r=generate(model,processor,prompt,image=imgs,max_tokens=120,verbose=False,temperature=0.0)
            dt=time.time()-t0
            pt=getattr(r,"prompt_tokens",None); ptps=getattr(r,"prompt_tps",None); gtps=getattr(r,"generation_tps",None); gt=getattr(r,"generation_tokens",None); pk=getattr(r,"peak_memory",None)
            log(f"   frames={n}: wall={dt:.1f}s prompt_tokens={pt} prefill_tps={ptps and round(ptps,1)} gen_tokens={gt} gen_tps={gtps and round(gtps,1)} peak={pk and round(pk,2)}GB peakMLX={mx.get_peak_memory()/1e9:.2f}GB")
            txt=(r.text if hasattr(r,"text") else str(r)).replace("\n"," ")
            log(f"      out: {txt[:220]}")
        del model, processor; gc.collect(); mx.clear_cache()
    except Exception as e:
        log(f"VLM {repo}: FAILED {e!r}"); traceback.print_exc()
log("VLM_DONE")
