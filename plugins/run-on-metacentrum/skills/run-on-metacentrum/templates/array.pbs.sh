#!/bin/bash
# One subjob per line of cells.txt. This is the right shape for a sweep: N cells
# run at once instead of one after another, and a cell that dies takes only
# itself down.
#
#   mc sh "cd \$MC_REMOTE && wc -l < cells.txt"     # -> N
#   mc submit templates/array.pbs.sh -J 1-N
#   mc status                                        # 12345[] is the parent
#
# cells.txt holds one shell command per line, run from the staged repo root:
#   python scripts/train.py --lr 1e-3 --seed 0
#   python scripts/train.py --lr 1e-4 --seed 0
#
# qextend does NOT work on arrays. Size walltime for the slowest cell, or make
# each cell resumable.

#PBS -N proj_sweep
#PBS -l select=1:ncpus=4:mem=8gb:scratch_local=20gb
#PBS -l walltime=8:00:00
#PBS -m ae

set -uo pipefail

export OMP_NUM_THREADS="${NCPUS:-1}"
export MKL_NUM_THREADS="${NCPUS:-1}"
export OPENBLAS_NUM_THREADS="${NCPUS:-1}"

: "${SCRATCHDIR:?no scratch}"
: "${PBS_ARRAY_INDEX:?not an array job — submit with -J 1-N}"
export TMPDIR="$SCRATCHDIR/tmp"; mkdir -p "$TMPDIR"

IDX="$PBS_ARRAY_INDEX"
CELL="$(sed -n "${IDX}p" "$PBS_O_WORKDIR/cells.txt")"
[ -n "$CELL" ] || { echo "cells.txt has no line $IDX"; exit 2; }

# Per-subjob output dir keeps concurrent subjobs from racing on the same files.
OUT="$PBS_O_WORKDIR/results/$IDX"
LOGS="$PBS_O_WORKDIR/logs"
mkdir -p "$OUT" "$LOGS"

echo "[$IDX] $(hostname -f)  $CELL"

cd "$SCRATCHDIR"
rsync -a --exclude '.git' --exclude '.venv' --exclude 'runs' --exclude 'results' \
      "$PBS_O_WORKDIR/" ./ || exit 1
mkdir -p results runs

# Works both on a compute node and under scripts/pbs-local.
. /etc/profile.d/30_meta_modules.sh 2>/dev/null || true
# mamba_base sits in the home of the storage the project was submitted from
BASE="${PBS_O_WORKDIR%%/home/$USER/*}/home/$USER/mamba_base"
if [ -d "$BASE" ]; then
  module add mambaforge
  source activate "$BASE"
fi
. "$PBS_O_WORKDIR/.venv/bin/activate"          # <-- EDIT if the venv lives elsewhere

# --- 5. sync results back WHILE running ------------------------------------
# A walltime kill gives 10 s between SIGTERM and SIGKILL — not enough to copy
# a run out. So copy continuously; the trap is only a courtesy.
#
# The loop's `sleep` must be killable. A plain `( while sleep N; do ...; done ) &`
# leaves an ORPHANED sleep behind when the subshell is killed: it inherits the
# job's stdout, so PBS sees the job's output stream still open and parks the job
# in state E, burning walltime after the work is done. Hence the inner trap.

sync_back() {
  rsync -a results/ "$OUT/" 2>/dev/null
}

(
  trap 'kill "${SP:-0}" 2>/dev/null; exit 0' TERM
  while :; do
    sleep "${SYNC_EVERY:-600}" & SP=$!; wait "$SP"
    sync_back
  done
) >/dev/null 2>&1 &
SYNC_PID=$!
stop_sync() { kill -TERM "$SYNC_PID" 2>/dev/null; wait "$SYNC_PID" 2>/dev/null; }

# TERM, not EXIT: an EXIT trap would clean scratch before the copy-back below.
# The handler ends in exit so the script does not then fall through into the
# normal copy-back with an already-emptied scratch.
on_term() {
  trap '' TERM
  echo "[$IDX] SIGTERM — saving what exists, then exiting" >&2
  stop_sync
  sync_back
  cp "cell_$IDX.log" "$LOGS/${PBS_JOBID%%.*}_$IDX.log" 2>/dev/null
  clean_scratch
  exit 143
}
trap on_term TERM

eval "$CELL" > "cell_$IDX.log" 2>&1
RC=$?

stop_sync
sync_back
rsync -a runs/    "$PBS_O_WORKDIR/runs/" 2>/dev/null
cp "cell_$IDX.log" "$LOGS/${PBS_JOBID%%.*}_$IDX.log"

clean_scratch
exit $RC
