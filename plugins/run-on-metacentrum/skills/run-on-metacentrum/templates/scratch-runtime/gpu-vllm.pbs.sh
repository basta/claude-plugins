#!/bin/bash
# Sample traces for every training question, then run the cut oracle, on one GPU.
#
#   qsub -J 0-7 -v SHARDS=8 experiments/metacentrum/traces.pbs.sh            # the full run
#   qsub -J 0-1 -l walltime=1:00:00 -v SHARDS=2,OUT_NAME=shorten-sft-smoke2,PER_SOURCE=20 \
#        experiments/metacentrum/traces.pbs.sh                                # smoke test
#   qsub experiments/metacentrum/traces.pbs.sh                                # one job, no shards
#
# As an array, subjob i does shard i/SHARDS of the questions into results/$OUT_NAME/shard-0i:
# the shards are independent, so they run in parallel or one after another, as GPUs free up.
# A subjob that hits the walltime resumes when resubmitted alone (qsub -J i-i ... or a
# plain qsub with -v SHARD_INDEX=i).
#
# Output is written on scratch and synced to results/$OUT_NAME in the project
# directory every SYNC_EVERY seconds and at the end; a job starts by copying
# what is already there, and both steps skip finished work, so a job killed on
# walltime is continued by submitting the same command again. Progress: W&B
# and logs/<jobid>.log. See common.sh for the scratch layout.
#
# The example project's driver is experiments/shorten_sft.py; the lines marked EDIT
# are where yours goes.

#PBS -N vllm_run
#PBS -l select=1:ncpus=8:mem=64gb:ngpus=1:gpu_mem=40gb:gpu_cap=compute_80:scratch_local=100gb
#PBS -l walltime=6:00:00
#PBS -m ae

SYNC_EVERY="${SYNC_EVERY:-300}"
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
set +e   # from here the exit codes are checked by hand
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
use_gpu || exit 1

OUT_STORE="${OUT:-$PBS_O_WORKDIR/results/${OUT_NAME:-shorten-sft-full}}"
SHARD_INDEX="${SHARD_INDEX:-${PBS_ARRAY_INDEX:-}}"
SHARD_ARGS=()
if [ -n "$SHARD_INDEX" ]; then
  SHARD_ARGS=(--shard "$SHARD_INDEX/${SHARDS:?set SHARDS, the number of shards}")
  OUT_STORE="$OUT_STORE/$(printf 'shard-%02d' "$SHARD_INDEX")"
fi
# the last two parts of the path, as on storage: W&B names the run group after the
# directory, or after its parent for a shard
OUT_LOCAL="$SCR/out/$(basename "$(dirname "$OUT_STORE")")/$(basename "$OUT_STORE")"
mkdir -p "$OUT_LOCAL"
# a first run has nothing to resume from: create the directory, then copy whatever is in it
move 300 "$OUT_LOCAL/" "$(via "$OUT_STORE")/" || { echo "[job] cannot reach $OUT_STORE"; exit 1; }
move 3600 "$(via "$OUT_STORE")/" "$OUT_LOCAL/" || { echo "[job] resume copy failed"; exit 1; }
echo "[job] resuming from $(du -sh "$OUT_LOCAL" | cut -f1) in $OUT_STORE"
SYNC_OUT="$OUT_LOCAL|$OUT_STORE"
start_sync

use_netrc
use_runtime || exit 1
export VLLM_CACHE_ROOT="$SCR/vllm" TRITON_CACHE_DIR="$SCR/triton"
export WANDB_DIR="$SCR"   # WANDB_ENTITY / WANDB_PROJECT: pass with qsub -v if not the key's default
# a killed job loses the chunk in flight: 1000 prompts is ~15 GPU-minutes of skywork
export GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.9}" CHUNK="${CHUNK:-1000}"

PY=0
on_term() {  # walltime: PBS sends TERM, then KILL 10 s later
  trap '' TERM
  echo "[job] SIGTERM at $(date -Is); resubmit to continue"
  # python and vLLM's engine process: left alive, they keep the job in state E
  local procs; procs="$PY $(pgrep -P "$PY" | tr '\n' ' ')"
  kill -TERM $procs 2>/dev/null; sleep 2; kill -KILL $procs 2>/dev/null
  exit 143   # -> finish in common.sh: last sync, clean scratch
}
trap on_term TERM

run() {   # <-- EDIT: your driver
  echo "=== $(date -Is) shorten_sft.py $*"
  python experiments/shorten_sft.py "$@" --out "$OUT_LOCAL" &
  PY=$!
  wait $PY         # in the background, so the TERM trap fires while python runs
}

run sample --per-source "${PER_SOURCE:-0}" --traces "${TRACES:-4}" "${SHARD_ARGS[@]}"
RC=$?
if [ $RC -eq 0 ]; then
  run oracle --answers "${ANSWERS:-4}" "${SHARD_ARGS[@]}"
  RC=$?
fi
exit $RC
