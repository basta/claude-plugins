#!/bin/bash
# CPU-only check of the runtime bootstrap.pbs.sh built, before spending a GPU job
# on it: it unpacks within the time limit, imports, loads the model files offline,
# tokenizes every training prompt, and W&B accepts a run from a compute node.
#
#   qsub experiments/metacentrum/check.pbs.sh

#PBS -N rt_check
#PBS -l select=1:ncpus=2:mem=8gb:scratch_local=40gb
#PBS -l walltime=0:30:00
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
use_runtime
export WANDB_DIR="$SCR"

# <-- EDIT: everything below is the example project's own check (its prompts, its
# token budget); keep the shape: import the stack, touch the data, one W&B run
python - <<'PY'
import sys, time
sys.path.insert(0, ".")
sys.path.insert(0, "experiments")
import torch, vllm, wandb  # noqa: F401  (vllm must at least import without a GPU)
import shorten_sft as s

tick = time.time()
tok = s.Tok()
qs = s.load_questions("train", 0)
lengths = [len(tok.prompt(q["prompt"])) for q in qs]
print(f"{len(qs)} training prompts tokenized in {time.time() - tick:.0f}s, "
      f"longest {max(lengths)} tokens (budget {s.evaluate.PROMPT_BUDGET})")
assert max(lengths) <= s.evaluate.PROMPT_BUDGET

run = wandb.init(project="metacentrum-check", name="metacentrum-setup-check", job_type="check")
run.log({"check": 1})
print("wandb run", run.url)
run.finish()
PY
echo "check ok"
