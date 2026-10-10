#!/bin/bash
# One-off, on a CPU node: build the runtime every other job unpacks, as one archive
# at ~/envs/runtime.tar.zst (RUNTIME_TAR in common.sh):
#
#   python/   a standalone CPython 3.12 with every package from requirements.lock
#             installed into it (no venv, so nothing points back at a fixed path)
#   hf/       the Hugging Face cache with the pinned model snapshot
#
#   qsub experiments/metacentrum/bootstrap.pbs.sh
#
# See common.sh for why everything is built on scratch and nothing runs from /storage.

#PBS -N rt_bootstrap
#PBS -l select=1:ncpus=4:mem=16gb:scratch_local=60gb
#PBS -l walltime=1:00:00
#PBS -m ae

set -euo pipefail
: "${SCRATCHDIR:?no scratch: the job must request scratch_local}"
# the repo onto scratch over ssh, not through the /storage mount (see common.sh)
# /storage/<name>/home/<path> is /home/<path> on storage-<name>.metacentrum.cz
case "$PBS_O_WORKDIR" in
  /storage/*/home/*) _s="${PBS_O_WORKDIR#/storage/}"; SRC="$USER@storage-${_s%%/*}.metacentrum.cz:/home/${_s#*/home/}" ;;
  *) SRC="$PBS_O_WORKDIR" ;;
esac
timeout 600 rsync -a -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30" \
  --exclude .git --exclude .venv --exclude results --exclude logs --exclude runs --exclude __pycache__ \
  "$SRC/" "$SCRATCHDIR/code/"
cd "$SCRATCHDIR/code"
. experiments/metacentrum/common.sh
set -x
start_sync
use_netrc

UV_VERSION=0.6.3
RT="$SCR/runtime"
export UV_CACHE_DIR="$SCR/uv-cache" UV_PYTHON_INSTALL_DIR="$SCR/uv-python"
mkdir -p "$RT" "$SCR/bin"

# uv itself, a pinned static binary: the one in the mamba env would run from /storage
curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz" \
  | tar -xz -C "$SCR/bin" --strip-components=1
export PATH="$SCR/bin:$PATH"

# a standalone CPython, moved to a plain directory: python-build-standalone finds
# its prefix from the executable, so it works wherever the archive is unpacked
uv python install 3.12
mv "$(find "$UV_PYTHON_INSTALL_DIR" -mindepth 1 -maxdepth 1 -type d -name 'cpython-3.12*' | head -1)" "$RT/python"
ln -sf python3.12 "$RT/python/bin/python"
PY="$RT/python/bin/python"
uv pip install --python "$PY" --break-system-packages -r experiments/metacentrum/requirements.lock

export HF_HOME="$RT/hf" HF_HUB_CACHE="$RT/hf/hub" HUGGINGFACE_HUB_CACHE="$RT/hf/hub"
"$PY" - <<'PY'
import sys
import torch, vllm, transformers, peft, wandb
print("python", sys.version.split()[0], "| torch", torch.__version__, "cuda", torch.version.cuda,
      "| vllm", vllm.__version__, "| transformers", transformers.__version__,
      "| peft", peft.__version__, "| wandb", wandb.__version__)
# <-- EDIT: the model and revision your project pins
from huggingface_hub import snapshot_download
print("model at", snapshot_download("Qwen/Qwen3-0.6B", revision="main"))
print("wandb login as", wandb.Api().viewer.username)
PY

du -sh "$RT"/python "$RT"/hf
tar -C "$RT" -cf - python hf | zstd -T"${NCPUS:-1}" -3 -q -o "$SCR/runtime.tar.zst"
ls -la "$SCR/runtime.tar.zst"
# under a temporary name, renamed only when complete (rsync does that itself)
move 1800 "$SCR/runtime.tar.zst" "$(via "$RUNTIME_TAR")"
echo "bootstrap ok"
