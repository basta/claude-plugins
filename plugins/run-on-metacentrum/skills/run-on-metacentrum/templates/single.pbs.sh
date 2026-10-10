#!/bin/bash
# One long run on one node. Copy, edit the marked lines, `mc submit`.
#
#   mc submit templates/single.pbs.sh
#   mc submit templates/single.pbs.sh -l walltime=48:00:00 -N other_name
#
# CLI -l flags override the #PBS lines below.

#PBS -N proj_run
#PBS -l select=1:ncpus=16:mem=32gb:scratch_local=50gb
#PBS -l walltime=24:00:00
#PBS -m ae
# GPU instead? swap the select line for something like:
#   #PBS -l select=1:ncpus=8:mem=40gb:ngpus=1:gpu_mem=20gb:gpu_cap=compute_70:scratch_local=100gb
# and do NOT add -q; PBS routes by walltime + ngpus.

set -uo pipefail   # deliberately not -e: a failing cell must not skip the copy-back

# --- 1. never use more CPUs than you asked for (exit -25 otherwise) ---------
export OMP_NUM_THREADS="${NCPUS:-1}"
export MKL_NUM_THREADS="${NCPUS:-1}"
export OPENBLAS_NUM_THREADS="${NCPUS:-1}"
export NUMEXPR_NUM_THREADS="${NCPUS:-1}"

# --- 2. keep every cache off /tmp (1 GB root-fs quota per node) -------------
: "${SCRATCHDIR:?no scratch — the job must request scratch_local}"
export TMPDIR="$SCRATCHDIR/tmp"
export XDG_CACHE_HOME="$SCRATCHDIR/cache"
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"

RESULTS="$PBS_O_WORKDIR/results"
LOGS="$PBS_O_WORKDIR/logs"
mkdir -p "$RESULTS" "$LOGS"

echo "$PBS_JOBID on $(hostname -f), scratch $SCRATCHDIR ($SCRATCH_TYPE, $SCRATCH_VOLUME)"

# --- 3. stage code onto scratch --------------------------------------------
cd "$SCRATCHDIR"
rsync -a --exclude '.git' --exclude '.venv' --exclude 'runs' --exclude 'results' \
      "$PBS_O_WORKDIR/" ./ || exit 1
mkdir -p results runs

# --- 4. environment ---------------------------------------------------------
# Works both on a compute node and under scripts/pbs-local.
. /etc/profile.d/30_meta_modules.sh 2>/dev/null || true
# mamba_base sits in the home of the storage the project was submitted from
BASE="${PBS_O_WORKDIR%%/home/$USER/*}/home/$USER/mamba_base"
if [ -d "$BASE" ]; then
  module add mambaforge
  source activate "$BASE"
fi
. "$PBS_O_WORKDIR/.venv/bin/activate"          # <-- EDIT if the venv lives elsewhere
# Headless MuJoCo / OpenGL, only needed if the code renders:
# export MUJOCO_GL=egl __GLX_VENDOR_LIBRARY_NAME=nvidia
# Persist dataset caches across jobs:
# export MINARI_DATASETS_PATH=${PBS_O_WORKDIR%%/home/$USER/*}/home/$USER/.minari

# --- 5. sync results back WHILE running ------------------------------------
# A walltime kill gives 10 s between SIGTERM and SIGKILL — not enough to copy
# a run out. So copy continuously; the trap is only a courtesy.
#
# The loop's `sleep` must be killable. A plain `( while sleep N; do ...; done ) &`
# leaves an ORPHANED sleep behind when the subshell is killed: it inherits the
# job's stdout, so PBS sees the job's output stream still open and parks the job
# in state E, burning walltime after the work is done. Hence the inner trap.

sync_back() {
  rsync -a results/ "$RESULTS/" 2>/dev/null
  rsync -a runs/    "$PBS_O_WORKDIR/runs/" 2>/dev/null
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

# NOTE: TERM, not EXIT. A trap on EXIT fires on any early exit, including a
# failure before the copy-back below — deleting the results you meant to save.
# The handler ENDS IN exit: without it the script falls through into the normal
# copy-back, which then runs against a scratch the handler already emptied.
on_term() {
  trap '' TERM
  echo "[job] SIGTERM at $(date -Is) — saving what exists, then exiting" >&2
  stop_sync
  sync_back
  cp run.log "$LOGS/$PBS_JOBID.log" 2>/dev/null
  clean_scratch
  exit 143
}
trap on_term TERM

# --- 6. the actual work -----------------------------------------------------
python scripts/YOUR_DRIVER.py --whatever > run.log 2>&1   # <-- EDIT
RC=$?

# --- 7. copy back and clean -------------------------------------------------
stop_sync
sync_back
cp run.log "$LOGS/$PBS_JOBID.log"

clean_scratch
exit $RC
