#!/bin/zsh
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
until grep -q CHAIN_DONE chain.log 2>/dev/null; do sleep 10; done
. .venv/bin/activate
uv pip install -q sherpa-onnx 2>&1 | tail -1
echo "== diar =="; python bench_diar.py
uv pip install -q torch transnetv2-pytorch 2>&1 | tail -1
echo "== transnet =="; python bench_transnet.py
echo CHAIN2_DONE
