import time, resource, traceback, sys
out=open("results/transnet.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
try:
    import torch
    dev="mps" if torch.backends.mps.is_available() else "cpu"
    log(f"torch {torch.__version__} device={dev}")
    import transnetv2_pytorch as tn
    log("transnetv2_pytorch exports: "+", ".join(x for x in dir(tn) if not x.startswith("_"))[:300])
    model=None
    for ctor in ("TransNetV2",):
        if hasattr(tn,ctor):
            model=getattr(tn,ctor)()
    if model is None: raise RuntimeError("no TransNetV2 class")
    # try common weight-loading paths
    for loader in ("from_pretrained","load_pretrained","load_weights"):
        if hasattr(model,loader):
            try: getattr(model,loader)(); log(f"weights via {loader}"); break
            except Exception as e: log(f"{loader} failed: {e!r}")
    model=model.to(dev).eval()
    import cv2, numpy as np
    for f,label in (("media/test1080_h264.mp4","1080p"),):
        cap=cv2.VideoCapture(f); frames=[]
        while True:
            ok,fr=cap.read()
            if not ok: break
            frames.append(cv2.resize(fr,(48,27)))
        arr=np.stack(frames); n=len(arr)
        t0=time.time()
        with torch.no_grad():
            x=torch.from_numpy(arr).to(dev)
            # TransNetV2 expects [B, T, H, W, C] uint8, windows of 100 frames
            preds=[]
            for i in range(0,n,100):
                chunk=x[i:i+100].unsqueeze(0)
                o=model(chunk)
                preds.append(o[0] if isinstance(o,tuple) else o)
            torch.mps.synchronize() if dev=="mps" else None
        dt=time.time()-t0
        log(f"TransNetV2 {label}: frames={n} infer_wall={dt:.1f}s fps={n/dt:.1f} device={dev} peakRSS={resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1048576:.0f}MB")
except Exception as e:
    log(f"TRANSNET FAILED {e!r}"); traceback.print_exc()
log("TRANSNET_DONE")
