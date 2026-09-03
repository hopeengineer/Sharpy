#!/bin/zsh
cd "$(dirname "$0")"; export PATH="$HOME/.local/bin:$PATH"; . .venv/bin/activate
uv pip install -q -U mlx-vlm 2>&1 | tail -1
python -c "import mlx_vlm; print('mlx_vlm', mlx_vlm.__version__)"
python - <<'PY'
from huggingface_hub import snapshot_download, HfApi
api=HfApi()
for r in ["mlx-community/gemma-4-E2B-it-4bit","mlx-community/gemma-4-E4B-it-4bit"]:
    try:
        info=api.model_info(r); size=sum((s.size or 0) for s in (info.siblings or []))/1e9
        print("exists",r,f"{size:.2f}GB")
        snapshot_download(r); print("ok",r)
    except Exception as e: print("MISSING/FAIL",r,repr(e)[:100])
PY
python bench_vlm_gemma4.py
echo CHAIN4_DONE
