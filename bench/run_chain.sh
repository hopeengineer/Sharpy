#!/bin/zsh
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
until grep -q SETUP_DONE setup.log 2>/dev/null; do sleep 5; done
. .venv/bin/activate
uv pip install -q parakeet-mlx 2>&1 | tail -1
echo "== downloading models ==" 
python - <<'PY'
from huggingface_hub import snapshot_download
for r in ["mlx-community/whisper-large-v3-turbo","mlx-community/parakeet-tdt-0.6b-v3","mlx-community/Qwen3-VL-4B-Instruct-4bit","mlx-community/Qwen3-VL-2B-Instruct-4bit","mlx-community/SmolVLM2-2.2B-Instruct-mlx","mlx-community/gemma-3n-E2B-it-4bit","mlx-community/distil-whisper-large-v3"]:
    try: p=snapshot_download(r); print("ok",r)
    except Exception as e: print("DL FAIL",r,repr(e)[:120])
PY
echo "== ffmpeg =="; ./bench_ffmpeg.sh
echo "== asr =="; python bench_asr.py
echo "== vlm =="; python bench_vlm.py
echo "== scene =="; python bench_scene.py
echo CHAIN_DONE
