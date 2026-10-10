# Environments, storage and data on MetaCentrum

> For torch/vLLM-sized stacks, or jobs that may land on ELIXIR nodes, skip the
> venv-on-`/storage` pattern below and use `templates/scratch-runtime/` (see
> SKILL.md, "the scratch-runtime pattern").

Companion to `SKILL.md`. Sources: docs.metacentrum.cz (2026-09-08) and a
working setup on `brno2`. `<user>` / `<store>` as in `SKILL.md`.

## The base environment

```
/storage/<store>/home/<user>/mamba_base    mamba env: python 3.11 + uv + pip
```

Built once per account and reused (check `notes.md` — it may already exist). It
is a **base**, not a project env — the pattern is mamba for the interpreter and
`uv`, then a `uv venv` per project:

```bash
. /etc/profile.d/30_meta_modules.sh
module add mambaforge
source activate /storage/<store>/home/<user>/mamba_base
cd $PROJECT
uv venv --python 3.11 .venv && source .venv/bin/activate
uv pip install -r requirements.txt
```

`templates/bootstrap.pbs.sh` does this as a batch job, creating `mamba_base`
first if it is missing.

### Cache placement is not optional

```bash
export TMPDIR="$SCRATCHDIR/tmp"
export UV_CACHE_DIR="$SCRATCHDIR/uv"
export PIP_CACHE_DIR="$SCRATCHDIR/pip"
export CONDA_PKGS_DIRS="$SCRATCHDIR/conda_pkgs"
export UV_LINK_MODE=copy
```

`/tmp` is capped at 1 GB per node (root-filesystem quota) and a torch resolve
will exceed it; the docs list this as the most common cause of failed installs.
`UV_LINK_MODE=copy` is needed because the cache is on local scratch while the
venv is on NFS — hardlinks cannot cross that boundary.

### Alternatives

- **mamba env per project** — `mamba create -p /storage/.../env python=3.11`,
  then `mamba activate <prefix>`. Better when there are non-Python system deps.
  For long jobs the docs suggest cloning the env onto scratch at job start
  (`mamba create -p $SCRATCHDIR/env --clone /storage/.../env`) so a storage
  hiccup mid-run cannot kill it.
- **`pip --user`** — set `PYTHONUSERBASE` to a storage dir, then `PATH`/
  `PYTHONPATH` to match. Fragile; prefer a venv.
- **Apptainer/Singularity** — most reproducible. `qsub -v PBS_SINGULARITY_IMAGE=<path|docker://...>`
  runs the whole job inside the image, with `/var/spool/pbs` and `/etc/pbs.conf`
  bind-mounted automatically. Also `singularity exec image.sif cmd`.
  `$SINGULARITY_TMPDIR`/`CACHEDIR` are pointed at scratch automatically when
  `SCRATCHDIR` exists. Prebuilt images live under
  `/cvmfs/singularity.metacentrum.cz/`. An image plus a writable ext3 overlay
  (`singularity exec --overlay overlay.img.ext3 image.sif ...`) is the pattern
  for an image you need to add packages to.
- **System modules** (`module avail python/`) — often old. Fine for `python`
  as a bootstrap interpreter, not as the project env.

## ML-specific settings

### Thread count — the mandatory one

```bash
export OMP_NUM_THREADS=${NCPUS:-1}
export MKL_NUM_THREADS=${NCPUS:-1}
export OPENBLAS_NUM_THREADS=${NCPUS:-1}
```

torch and numpy size their thread pools from the *machine's* core count, not
your allocation. On a 128-core node with `ncpus=4` that is a 32× overrun and
PBS kills the job with exit **-25**. `torch.set_num_threads()` in the code is
equivalent but only covers torch.

### torch

CPU-only wheels are ~200 MB against ~2.5 GB for the CUDA build:

```bash
uv pip install torch --index-url https://download.pytorch.org/whl/cpu
```

Install torch *first*, then the rest of `requirements.txt`, or the CUDA wheel
gets pulled in as a dependency. Check whether the project actually uses a GPU
before requesting one — a repo whose config says `device = "cpu"` will queue
behind hundreds of real GPU jobs for no gain.

For GPU: `gpu_cap=compute_70` covers everything from Volta up and excludes the
old `konos`/`grimbold` cards that modern wheels have dropped.

### MuJoCo / gymnasium

```bash
export MUJOCO_GL=egl                      # headless GPU rendering
export __GLX_VENDOR_LIBRARY_NAME=nvidia
```

Only needed when the code renders (video, image observations). Physics-only
rollouts need neither, and setting `MUJOCO_GL=egl` on a CPU node will fail.
`MUJOCO_GL=osmesa` is the software fallback. If EGL misbehaves, this module
set fixed it once: `gui`, `mesa`, `libx11`, `mesa-glu`, `ffmpeg`.

### Dataset caches (Minari, HuggingFace)

Default to `$HOME`, which is NFS and quota-counted. Point them at storage once,
then stage to scratch inside the job:

```bash
export MINARI_DATASETS_PATH=/storage/<store>/home/<user>/.minari
export HF_HOME=/storage/<store>/home/<user>/.cache/huggingface
# in the job, for read-heavy datasets:
cp -r "$MINARI_DATASETS_PATH" "$SCRATCHDIR/.minari" && export MINARI_DATASETS_PATH="$SCRATCHDIR/.minari"
```

Download them **once**, in the bootstrap job — hundreds of array subjobs each
fetching the same 50 MB dataset is both slow and rude.

## Storage

| | |
|---|---|
| `storage-brno2.metacentrum.cz` | `/storage/brno2/` — native home of `perian`, `skirit`, `oven`; backup class 2 |
| `storage-brno12-cerit.metacentrum.cz` | `/storage/brno12-cerit/` — `zenith`; class 2 |
| `storage-plzen1.metacentrum.cz` | `/storage/plzen1/` — `nympha`/`minos`; class 2 |
| `storage-vestec1-elixir` | also mounted as `/storage/praha1/` — `tarkil`, `metafzu` |

Backup classes: 0 = none, 2 = daily snapshot on the same hardware (protects
against `rm`, not against hardware failure), 3 = snapshot + off-hardware copy.
Snapshots are kept two weeks.

Every frontend has one native home, but **all** storages are reachable from any
frontend by `cd /storage/<other>/home/<user>` — a frontend being down is never
a reason you cannot reach your data. The server for `/storage/<store>` is
`storage-<store>.metacentrum.cz` (all of the above resolve, `praha1` included).

Quota on brno2 was 4.29 TB data / 2.5 M files per user (2026-09-08); the login
MOTD prints yours. `ncdu2` finds what is eating it, and should be run **on the
storage server**, not the frontend:

```bash
ssh storage-<store>.metacentrum.cz 'ncdu2 -x -o out.json ~'
ncdu2 -f out.json        # 's' sorts by size, 'c' then 'C' by file count
```

## Moving data

- **≤500 files and ≤50 GB**: through the frontend is fine.
- **More than either**: go straight to the storage server. Frontends are neither
  source nor destination, and processes that load them get killed.

```bash
rsync -avhP ./code/  <user>@storage-<store>.metacentrum.cz:/home/<user>/projects/x/
rsync -avhP <user>@storage-<store>.metacentrum.cz:/home/<user>/projects/x/results/ ./results/
# on the storage server the home is /home/<user> — /storage/<store>/... does not exist there
```

Storage servers have **no login shell** — only a fixed command list works over
ssh: `cat chmod cp dd du getfacl gunzip gzip ls mkdir mv ncdu2 rm rmdir rsync
s3cmd s5cmd scp setfacl ssh tar`. Enough for everything above.

Between two storages, run the copy *on* one of them, and wrap it in a job if it
will outlive the 10-hour Kerberos ticket:

```bash
ssh storage-plzen1.metacentrum.cz "rsync -avh ~/dir storage-brno2.metacentrum.cz:~/dir/"
```

**Many small files** are the real quota hazard — pack finished experiment sets
with `tar` (target chunk ≥500 MB) rather than keeping thousands of loose JSONs.

## Kerberos

Tickets last 10 hours and are what lets you move between nodes and write to
storage without passwords. `klist` / `kinit` / `kdestroy`. A job that outlives
its ticket dies with exit `-23`; PBS renews tickets for batch jobs, but a
long-running `ssh`-driven copy started by hand does not get that.

`kinit <user>@META` is interactive — a human has to type the password. There
is no key-based login on the frontends.
