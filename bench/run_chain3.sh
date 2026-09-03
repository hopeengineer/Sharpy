#!/bin/zsh
cd "$(dirname "$0")"; export PATH="$HOME/.local/bin:$PATH"; . .venv/bin/activate
uv pip install -q torchvision 2>&1 | tail -1
python - <<'PY'
import time, gc, glob, traceback
import mlx.core as mx
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_config
out=open("results/vlm.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
FRAMES=sorted(glob.glob("frames/*.jpg")); repo="mlx-community/SmolVLM2-2.2B-Instruct-mlx"
PROMPT="You are a video editor's perception module. For each frame, state: what is on screen, whether a person is visible, any on-screen text, and the dominant motion. Then in one sentence: what kind of video is this?"
try:
    t0=time.time(); model,processor=load(repo); cfg=load_config(repo); log(f"VLM {repo} (retry w/ torchvision): load={time.time()-t0:.1f}s modelMem={mx.get_active_memory()/1e9:.2f}GB")
    for n in (1,4,8):
        imgs=FRAMES[:n]; prompt=apply_chat_template(processor,cfg,PROMPT,num_images=n); mx.reset_peak_memory(); t0=time.time()
        r=generate(model,processor,prompt,image=imgs,max_tokens=120,verbose=False,temperature=0.0); dt=time.time()-t0
        log(f"   frames={n}: wall={dt:.1f}s prompt_tokens={getattr(r,'prompt_tokens',None)} prefill_tps={round(getattr(r,'prompt_tps',0),1)} gen_tps={round(getattr(r,'generation_tps',0),1)} peakMLX={mx.get_peak_memory()/1e9:.2f}GB")
        log(f"      out: {(r.text if hasattr(r,'text') else str(r))[:200]!r}")
except Exception as e: log(f"VLM {repo}: FAILED AGAIN {e!r}"); traceback.print_exc()
PY
python wer.py
echo CHAIN3_DONE
