#!/bin/bash
# Build the project's Python environment on /storage, as a batch job.
#
#   mc push
#   mc submit templates/bootstrap.pbs.sh
#   mc log <jobid>
#
# Why a job and not the frontend: frontends are small VMs shared by everyone,
# and MetaCentrum kills processes that load them. A pip/uv resolve of a torch
# stack qualifies. This is also why an interactive job (`qsub -I`) is the
# documented alternative — but that needs a terminal, and this does not.

#PBS -N proj_bootstrap
#PBS -l select=1:ncpus=4:mem=16gb:scratch_local=40gb
#PBS -l walltime=2:00:00
#PBS -m ae

set -euo pipefail

: "${SCRATCHDIR:?no scratch}"

# Every installer cache goes on scratch. /tmp is capped at 1 GB per node and
# blowing it locks you out of that node until you clear it (check-local-quota).
export TMPDIR="$SCRATCHDIR/tmp"
export UV_CACHE_DIR="$SCRATCHDIR/uv"
export PIP_CACHE_DIR="$SCRATCHDIR/pip"
export CONDA_PKGS_DIRS="$SCRATCHDIR/conda_pkgs"
export UV_LINK_MODE=copy          # cache is on scratch, venv on NFS: no hardlinks
mkdir -p "$TMPDIR" "$UV_CACHE_DIR" "$PIP_CACHE_DIR" "$CONDA_PKGS_DIRS"

. /etc/profile.d/30_meta_modules.sh 2>/dev/null || true
module add mambaforge

# in the home of the storage the project lives on (where `mc submit` ran qsub)
BASE="${PBS_O_WORKDIR%%/home/$USER/*}/home/$USER/mamba_base"
if [ ! -d "$BASE" ]; then
  echo "creating mamba base at $BASE"
  mamba create -p "$BASE" python=3.11 -y
  source activate "$BASE"
  mamba install -c conda-forge uv -y
else
  source activate "$BASE"
fi

cd "$PBS_O_WORKDIR"

uv venv --python 3.11 .venv
source .venv/bin/activate

# CPU-only torch is ~200 MB instead of ~2.5 GB. Drop these two lines if the
# code actually runs on GPU.
uv pip install torch --index-url https://download.pytorch.org/whl/cpu

uv pip install -r requirements.txt

python - <<'PY'
import sys, importlib
print("python", sys.version)
for m in ("torch", "numpy", "gymnasium", "minari"):
    try:
        mod = importlib.import_module(m)
        print(f"  {m:12s} {getattr(mod, '__version__', '?')}")
    except Exception as e:  # noqa: BLE001
        print(f"  {m:12s} MISSING ({e})")
PY

echo "venv ready: $PBS_O_WORKDIR/.venv"
clean_scratch
