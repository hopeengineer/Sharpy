import time, resource
out=open("results/scene.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
from scenedetect import detect, ContentDetector, AdaptiveDetector
for f,frames in (("media/test1080_h264.mp4",900),("media/test4k_h264.mp4",900)):
    for det in (ContentDetector(), AdaptiveDetector()):
        t0=time.time(); scenes=detect(f, det); dt=time.time()-t0
        log(f"PySceneDetect {type(det).__name__} {f}: wall={dt:.1f}s fps={frames/dt:.1f} scenes={len(scenes)} peakRSS={resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1048576:.0f}MB")
log("SCENE_DONE")
