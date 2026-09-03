import time, resource, traceback, os, tarfile, urllib.request, numpy as np, wave
out=open("results/diar.txt","a")
def log(s): print(s); out.write(s+"\n"); out.flush()
try:
    import sherpa_onnx
    os.makedirs("models",exist_ok=True)
    seg_tar="models/seg.tar.bz2"; seg_dir="models/sherpa-onnx-pyannote-segmentation-3-0"
    emb="models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
    if not os.path.isdir(seg_dir):
        urllib.request.urlretrieve("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2", seg_tar)
        tarfile.open(seg_tar).extractall("models")
    if not os.path.exists(emb):
        urllib.request.urlretrieve("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx", emb)
    w=wave.open("media/speech16k.wav"); sr=w.getframerate(); samples=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(np.float32)/32768.0
    dur=len(samples)/sr
    cfg=sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=f"{seg_dir}/model.onnx"), num_threads=4),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=emb, num_threads=4),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=-1, threshold=0.5),
        min_duration_on=0.3, min_duration_off=0.5)
    sd=sherpa_onnx.OfflineSpeakerDiarization(cfg)
    t0=time.time(); res=sd.process(samples).sort_by_start_time(); dt=time.time()-t0
    spk=sorted(set(r.speaker for r in res))
    log(f"DIAR sherpa-onnx pyannote-seg-3.0 + eres2net: wall={dt:.1f}s audio={dur:.0f}s RTFx={dur/dt:.1f} segments={len(res)} speakers_found={len(spk)} (truth=2 TTS voices, A B A B) peakRSS={resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1048576:.0f}MB")
    for r in res[:10]: log(f"   spk{r.speaker} {r.start:7.2f}-{r.end:7.2f}")
except Exception as e:
    log(f"DIAR FAILED {e!r}"); traceback.print_exc()
log("DIAR_DONE")
