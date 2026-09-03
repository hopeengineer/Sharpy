import time, sys, glob, json, re, gc, traceback, resource
import mlx.core as mx
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_config
FRAMES=sorted(glob.glob("real/frames_nosfx/*.jpg"))
GT=json.load(open("real/labels_nosfx.json"))
MODELS=sys.argv[1:] or ["mlx-community/Qwen3-VL-2B-Instruct-4bit","mlx-community/Qwen3-VL-4B-Instruct-4bit","mlx-community/gemma-4-E2B-it-4bit","mlx-community/gemma-4-E4B-it-4bit"]
PROMPT=("You are the perception module of a video editor. Look at this single frame and answer ONLY with a JSON object, no prose, no markdown:\n"
 '{"person_visible": true|false, "face_count": <int>, "hands_visible": true|false, '
 '"layout": "talking_head"|"card"|"split"|"other", '
 '"on_screen_text": [<every distinct line of text you can actually read, verbatim>], '
 '"setting": "<one short phrase>"}\n'
 "Rules: layout=card means a dark graphic card fills the frame with no person; split means a card on top and a person below; talking_head means a person fills the frame. "
 "Only list text you can read with confidence; an empty list is a valid answer.")
out=open("results/vlm_quality.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
def parse(t):
    m=re.search(r"\{.*\}",t,flags=re.S)
    if not m: return None
    s=m.group(0)
    try: return json.loads(s)
    except Exception:
        try: return json.loads(re.sub(r",\s*([}\]])",r"\1",s))
        except Exception: return None
def norm(s): return re.sub(r"[^a-z0-9]+"," ",s.lower()).strip()
def text_scores(gt_lines, pred_lines):
    g=[norm(x) for x in gt_lines if norm(x)]; p=[norm(x) for x in (pred_lines or []) if isinstance(x,str) and norm(x)]
    hit=sum(1 for x in g if any(x in y or y in x for y in p))
    halluc=sum(1 for y in p if not any(x in y or y in x for x in g))
    return hit, len(g), halluc, len(p)
all_rows={}
for repo in MODELS:
    try:
        gc.collect(); mx.reset_peak_memory()
        model,processor=load(repo); cfg=load_config(repo)
        rows=[]; t_all=time.time()
        for f in FRAMES:
            k=f.split("/")[-1]; gt=GT[k]
            prompt=apply_chat_template(processor,cfg,PROMPT,num_images=1)
            t0=time.time(); r=generate(model,processor,prompt,image=[f],max_tokens=200,verbose=False,temperature=0.0); dt=time.time()-t0
            txt=r.text if hasattr(r,"text") else str(r); j=parse(txt)
            rows.append({"frame":k,"sec":dt,"raw":txt[:300],"pred":j})
        wall=time.time()-t_all
        n=len(rows); ok=[r for r in rows if r["pred"]]
        def acc(field):
            c=sum(1 for r in ok if str(r["pred"].get(field)).lower()==str(GT[r["frame"]][field]).lower()); return c, n
        pv=acc("person_visible"); fc=acc("face_count"); hv=acc("hands_visible"); lay=acc("layout")
        th=tg=hal=tp=0
        for r in ok:
            h,g,x,p=text_scores(GT[r["frame"]]["on_screen_text"], r["pred"].get("on_screen_text")); th+=h; tg+=g; hal+=x; tp+=p
        # false person: model says person visible when GT says none (worst error class)
        fp_person=sum(1 for r in ok if r["pred"].get("person_visible") is True and GT[r["frame"]]["person_visible"] is False)
        fn_person=sum(1 for r in ok if r["pred"].get("person_visible") is False and GT[r["frame"]]["person_visible"] is True)
        setting_ok=sum(1 for r in ok if any(w in str(r["pred"].get("setting","")).lower() for w in ["indoor","room","wall","door","home","office","desk","studio","interior"]) and GT[r["frame"]]["person_visible"])
        setting_n=sum(1 for r in ok if GT[r["frame"]]["person_visible"])
        log(f"QUALITY {repo}: frames={n} parsed_json={len(ok)}/{n} wall={wall:.0f}s ({wall/n:.1f}s/frame) peakMLX={mx.get_peak_memory()/1e9:.2f}GB")
        log(f"   person_visible acc {pv[0]}/{pv[1]}  (false-person={fp_person}, missed-person={fn_person})")
        log(f"   face_count acc     {fc[0]}/{fc[1]}")
        log(f"   hands_visible acc  {hv[0]}/{hv[1]}")
        log(f"   layout acc         {lay[0]}/{lay[1]}")
        log(f"   text recall        {th}/{tg} lines   hallucinated text lines {hal}/{tp} reported")
        log(f"   setting plausible  {setting_ok}/{setting_n}")
        all_rows[repo]=rows
        del model, processor; gc.collect(); mx.clear_cache()
    except Exception as e:
        log(f"QUALITY {repo}: FAILED {e!r}"); traceback.print_exc()
json.dump(all_rows,open("results/vlm_quality_rows.json","w"),indent=1)
log("VLM_QUALITY_DONE")
