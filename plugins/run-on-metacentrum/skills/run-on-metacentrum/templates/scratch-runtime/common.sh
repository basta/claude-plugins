# Sourced by every job script in this directory, from the copy of the repo the
# script has already fetched onto scratch (see fetch_code below).
#
# A job never reads or writes /storage through the node's network mount. On some
# nodes that mount stalls: on ELIXIR nodes in Prague a Python interpreter run from
# /storage/brno2 sat in uninterruptible I/O, and copying 20 MB of code from it did
# not finish in 10 minutes. Instead every transfer goes over ssh to the storage
# server (storage-<name>.metacentrum.cz), authenticated by the Kerberos ticket PBS
# gives the job (MetaCentrum's documented route for moving data in and out of
# jobs), with a timeout, in a few big copies. The job then works on local scratch
# and syncs its log and output back in the background, so a slow sync delays the
# copy, never the work.

: "${SCRATCHDIR:?no scratch: the job must request scratch_local}"
# Work through $SCR, never $SCRATCHDIR itself: an array subjob's scratch is named like
# job_24460603[0].pbs-m1, and Python's glob reads "[0]" as a character class, so vLLM
# globbing for *.safetensors under it found no model weights. A bracket-free link to the
# same directory fixes every such tool at once; clean_scratch still gets $SCRATCHDIR.
SCR="$SCRATCHDIR"
case "$SCRATCHDIR" in
  *[][*?]*)
    SCR="/tmp/scratch-$USER-${PBS_JOBID//[^A-Za-z0-9.-]/_}"
    ln -sfn "$SCRATCHDIR" "$SCR"
    cd "$SCR${PWD#"$SCRATCHDIR"}" ;;
esac
export OMP_NUM_THREADS="${NCPUS:-1}" MKL_NUM_THREADS="${NCPUS:-1}"
export TMPDIR="$SCR/tmp" XDG_CACHE_HOME="$SCR/cache"
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"

# the home on the storage the project was submitted from, e.g. /storage/brno2/home/$USER
STORE="${PBS_O_WORKDIR%%/home/$USER/*}/home/$USER"
RUNTIME_TAR="${RUNTIME_TAR:-$STORE/envs/runtime.tar.zst}"   # <-- one name per project
LOGS="$PBS_O_WORKDIR/logs"
JOBLOG="$SCR/job.log"
SYNC_EVERY="${SYNC_EVERY:-120}"
SYNC_OUT=""          # set to "local_dir|storage_dir" to sync job output as well
SYNC_PID=""

via() {  # a /storage/<name>/home path -> the same file on storage-<name>, over ssh
  local s
  case "$1" in
    /storage/*/home/*) s="${1#/storage/}"; echo "$USER@storage-${s%%/*}.metacentrum.cz:/home/${s#*/home/}" ;;
    *) echo "$1" ;;  # anything else is local (pbs-local on the workstation)
  esac
}
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30"
move() {  # move SECONDS SRC DST [rsync options]: rsync with a timeout, either side may be via'd
  local limit=$1 src=$2 dst=$3; shift 3
  timeout "$limit" rsync -a --mkpath -e "$SSH" "$@" "$src" "$dst"
}

exec > "$JOBLOG" 2>&1
echo "[job] $PBS_JOBID on $(hostname -f) at $(date -Is)"

sync_back() {
  move 300 "$JOBLOG" "$(via "$LOGS")/$PBS_JOBID.log" 2>/dev/null
  if [ -n "$SYNC_OUT" ]; then
    # the jsonl files only grow: --append-verify sends the new tail, and re-sends
    # a whole file only if its checksum disagrees
    move 1800 "${SYNC_OUT%%|*}/" "$(via "${SYNC_OUT#*|}")/" --append-verify 2>/dev/null
  fi
}

start_sync() {
  (
    # the inner trap kills the sleep too: an orphaned sleep holding the job's
    # output open keeps PBS in state E after the work is done
    trap 'kill "${SP:-0}" 2>/dev/null; exit 0' TERM
    while :; do
      sleep "$SYNC_EVERY" & SP=$!; wait "$SP"
      sync_back
    done
  ) >/dev/null 2>&1 &
  SYNC_PID=$!
}

stop_sync() {
  if [ -n "$SYNC_PID" ]; then kill -TERM "$SYNC_PID" 2>/dev/null; wait "$SYNC_PID" 2>/dev/null; fi
  SYNC_PID=""
}

finish() {  # on every exit: last copy back, then free the scratch
  local rc=$?
  trap - EXIT
  stop_sync
  echo "[job] exit $rc at $(date -Is)"
  sync_back
  [ "$SCR" = "$SCRATCHDIR" ] || rm -f "$SCR"
  clean_scratch
  exit "$rc"
}
trap finish EXIT

use_netrc() {  # the W&B key (ELIXIR nodes have another $HOME, so ~/.netrc is not it)
  if move 120 "$(via "$STORE/.netrc")" "$SCR/netrc" 2>/dev/null; then
    chmod 600 "$SCR/netrc"
    export NETRC="$SCR/netrc"
  fi
}

use_runtime() {  # Python, every package and the model, from bootstrap.pbs.sh's archive
  # decided from the path, not with a test that would itself go through the mount
  if [ "$(via "$RUNTIME_TAR")" != "$RUNTIME_TAR" ] || [ -f "$RUNTIME_TAR" ]; then
    local t=$SECONDS
    move 1800 "$(via "$RUNTIME_TAR")" "$SCR/runtime.tar.zst" || {
      echo "[job] fetching the runtime failed or timed out"; return 1; }
    mkdir -p "$SCR/runtime"
    tar -I zstd -xf "$SCR/runtime.tar.zst" -C "$SCR/runtime" || return 1
    rm "$SCR/runtime.tar.zst"
    echo "[job] runtime fetched and unpacked in $((SECONDS - t)) s"
    export PATH="$SCR/runtime/python/bin:$PATH"
    export HF_HOME="$SCR/runtime/hf" HF_HUB_OFFLINE=1
    export HF_HUB_CACHE="$HF_HOME/hub" HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
  else  # pbs-local on the workstation, without an archive
    set +u
    . "$PBS_O_WORKDIR/.venv/bin/activate"
    set -u
  fi
}

use_gpu() {  # PBS names the job's GPUs by UUID; vLLM parses CUDA_VISIBLE_DEVICES as integers
  local ids="" u i
  export CUDA_DEVICE_ORDER=PCI_BUS_ID   # so CUDA counts GPUs in nvidia-smi's order
  local list="${CUDA_VISIBLE_DEVICES:-}"
  for u in ${list//,/ }; do
    case "$u" in
      GPU-*|MIG-*)
        i=$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader | awk -F', ' -v u="$u" '$2 == u {print $1}')
        [ -n "$i" ] || { echo "[job] GPU $u is not in nvidia-smi"; return 1; } ;;
      *) i=$u ;;
    esac
    ids="${ids:+$ids,}$i"
  done
  [ -n "$ids" ] && export CUDA_VISIBLE_DEVICES="$ids"
  echo "[job] CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
}
