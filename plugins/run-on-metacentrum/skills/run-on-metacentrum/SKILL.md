---
name: run-on-metacentrum
description: Run a whole compute project on MetaCentrum (the CESNET/PBS national grid) — bootstrap the Python environment, sync the repo, submit batch and array jobs, watch them, and pull results back. Use whenever a sweep, training run, or long experiment needs more CPUs, more GPUs, or more wall-clock than this machine has, or when a PBS job needs writing, debugging, or babysitting.
---

# Running a project on MetaCentrum

MetaCentrum is a **PBS Pro** grid (Debian 12) with ~42 000 CPUs. This skill is for
the case where a local research repo — a sweep driver, a training script, a
battery of experiments — needs to move onto it wholesale and come back with
results.

Paths below write `<user>` for the MetaCentrum login and `<store>` for the
storage the projects live on (e.g. `brno2`); `mc config` prints the real ones.

```
local repo ──rsync──► /storage/<store>/home/<user>/projects/<proj>   (the master copy)
                            │  qsub from here → $PBS_O_WORKDIR
                            ▼
                      compute node: cp → $SCRATCHDIR, run, rsync results back every 10 min
                            │
results/ ◄──rsync──── storage-<store>.metacentrum.cz   (direct — never via the frontend)
```

**The three rules that cause most failures:** the frontend is not a computer,
scratch has no default size, and PBS kills you for using more CPUs than you
asked for.

## Start here: the account's own settings and notes

Everything account-specific lives outside this skill, in
`~/.config/run-on-metacentrum/` (`$XDG_CONFIG_HOME` if set):

| File | What |
|---|---|
| `config.env` | `MC_USER`, `MC_HOME`, `MC_FRONTEND` (and optionally `MC_STORAGE`), sourced by `mc` |
| `notes.md` | what is true for this account only: environments that already exist, which frontend works, accounts (W&B, HF), quirks of the user's projects, local paths |

**Before anything else: run `mc config`, and read `notes.md` if it exists.**
The notes override the general advice here where they conflict, and they are
where to record what you learn about this account (an env you built, a quota,
a project's layout) — not this skill, which is shared.

No `config.env` yet: ask the user for their MetaCentrum username and which
storage their home should be on (default `brno2`; the frontend they normally
use is a fine hint — see the storage table in `reference/environments.md`), then

```bash
mc setup <user> /storage/<store>/home/<user>    # writes config.env and a stub notes.md
```

| | |
|---|---|
| Frontend | default `tarkil.grid.cesnet.cz` — on 2026-10-09 `perian` and `skirit` hung on ssh (stalled storage mounts) while `tarkil` worked. Alternates: `perian`, `skirit`, `zenith.cerit-sc.cz`, `nympha.zcu.cz`. Always wrap frontend ssh in `timeout`. |
| Home | `/storage/<store>/home/<user>`. Every user has a home on every storage; pick one and keep projects there. |
| Storage host | `storage-<store>.metacentrum.cz` (rsync/scp target, **no login shell**). There the same home is **`/home/<user>`**, not `/storage/<store>/home/<user>` — a `/storage/...` path does not exist on it. `mc` maps this (`on_store`), and so do the templates. |

`/auto/<store>/...` is the automounter's view of the same directory; `pwd`
reports it after login. Always *write* paths as `/storage/<store>/home/...`.

## Auth: Kerberos, not keys

There is no SSH key on the frontend. Access is **GSSAPI/Kerberos**, and the
ticket lasts **10 hours**.

```bash
klist -s || echo "expired"      # test
kinit <user>@META               # renew — INTERACTIVE, the user must type this
```

Claude cannot type the password. When `klist -s` fails, stop and tell the user
to run `! kinit <user>@META` in the terminal; then continue. Everything else
in this skill runs unattended once a ticket exists.

`scripts/mc` opens a **ControlMaster** socket (`ControlPersist=8h`) on first use,
so the second and later commands are instant. Kill it with `mc disconnect`.

### The `module` gotcha

`module` is a shell function defined by `/etc/profile.d/30_meta_modules.sh`. A
plain `ssh host 'module add ...'` fails with `module: command not found`.
`bash -lc` works but dumps the whole MOTD (quota table + ASCII art + fortune)
into your output. Source the one file instead:

```bash
ssh <user>@tarkil.grid.cesnet.cz '. /etc/profile.d/30_meta_modules.sh; module add mambaforge; ...'
```

`qsub`, `qstat`, `qdel` are real binaries in `/usr/bin` and need none of this.

## The `mc` helper

`scripts/mc` (in this skill's base directory) wraps all of the above. Call it
by its full path, or put the `scripts/` directory on PATH for the session.

```bash
mc setup <user> [home]        # once per machine: write ~/.config/run-on-metacentrum/
mc config                     # resolved settings, and where they came from
mc auth                       # check the Kerberos ticket
mc sh '<cmd>'                 # run on the frontend with modules available
mc push                       # rsync repo → remote (honours .gitignore, --delete-safe)
mc pull results runs          # rsync those dirs back, straight from the storage host
mc submit job.pbs.sh [args]   # copy + qsub from the remote project dir
mc status                     # qstat -u
mc log <jobid>                # .o/.e for a finished job; live /var/spool tail for a running one
mc tail <jobid>               # follow a running job's stdout
mc cancel <jobid>
mc info <jobid>               # qstat -xf, exit status decoded
```

Per-project config lives in `.metacentrum.env` at the repo root (gitignore it):

```bash
MC_PROJECT=myproj                                    # remote dir name
MC_REMOTE=/storage/brno2/home/<user>/projects/myproj
MC_VENV=.venv                                        # uv venv inside the project
```

Resolution: `.metacentrum.env` > `config.env` > defaults (`MC_PROJECT` = the
repo's directory name, `MC_REMOTE` = `$MC_HOME/projects/$MC_PROJECT`).

## Test the job here first — no queue involved

`scripts/pbs-local` runs a PBS script on this machine inside a fake PBS: a real
temp `$SCRATCHDIR`, `$PBS_O_WORKDIR`, `$PBS_JOBID`, `$NCPUS`, `$PBS_ARRAY_INDEX`,
and stubs for `clean_scratch` / `module` / `go_to_scratch`. **Always run this
before submitting.** A script that is wrong takes seconds to find out here and
hours of queue plus a wasted allocation to find out there.

```bash
pbs-local --dry-run job.pbs.sh     # parse the #PBS directives, lint, run nothing
pbs-local job.pbs.sh               # run it for real, locally
pbs-local --ncpus 2 job.pbs.sh     # pretend you asked for 2 cores
pbs-local -J 1-4 array.pbs.sh      # four subjobs, sequentially
SYNC_EVERY=5 pbs-local --walltime 30 job.pbs.sh   # kill it like PBS would
```

What it catches, none of which needs the cluster:

- **Wrong paths and a copy-back that never fires** — the commonest way to burn
  24 h and end up with an empty `results/`.
- **`OMP_NUM_THREADS` missing**, `-q` set by hand, no `scratch_*`, no `mem` —
  linted from the `#PBS` lines before anything runs.
- **A `trap ... EXIT` that wipes scratch** before the results are copied out.
- **Background processes the script forgets to reap.** `pbs-local` gives the job
  its own process group and reports anything still alive when the script
  returns. On the cluster those keep the job's output stream open and park it in
  state `E`, burning walltime after the work is done.
- **The walltime kill itself.** `--walltime N` sends SIGTERM at N seconds and
  SIGKILL 10 s later — the real window — so you can check that the periodic sync
  actually saved something and that the TERM handler exits instead of falling
  through into a copy-back whose scratch it just emptied.

`SYNC_EVERY` overrides the templates' 600 s copy-back interval, which makes the
kill test meaningful in a few seconds.

What it cannot tell you: real runtime, real memory use, GPU behaviour, or
anything about contention. For those you still need the cluster.

Run it with a **short `TMPDIR`** (e.g. `TMPDIR=/tmp/t pbs-local ...`):
the fake scratch lives under `$TMPDIR`, and vLLM/zmq IPC socket paths over 107
characters fail. To test a kill/resume cycle cheaply, copy the job scripts into
a stub repo whose Python entry point just appends numbered lines to a jsonl and
spawns a `sleep` child, then check row counts after `--walltime N` and after a
resubmit (the scratch-runtime templates were verified exactly this way).

### When you do need real hardware, skip the queue

The `interactive` queue is nearly empty (33 running / 1 queued on 2026-09-08),
so an interactive job usually starts in seconds:

```bash
ssh <user>@tarkil.grid.cesnet.cz
qsub -I -l select=1:ncpus=4:mem=16gb:scratch_local=20gb -l walltime=1:00:00
```

`qsub -I` needs a terminal — hand it to the user with `! ssh ...` rather than
trying to drive it. Short walltime also backfills better: a 2 h job starts far
sooner than a 24 h one asking for the same cores.

For a pure "does the environment import" check, the frontend itself is allowed
— `mc env-sh 'python -c "import torch, gymnasium"'` is exactly the light
testing frontends are for. Anything that actually computes is not.

## First-time bootstrap of a project

Do this **inside an interactive job**, never on the frontend — the frontend is a
VM with almost no CPU, and installs there get killed.

```bash
mc push
mc sh 'qsub -I -l select=1:ncpus=4:mem=16gb:scratch_local=20gb -l walltime=2:00:00'
```

`qsub -I` needs a terminal, so hand this one to the user (`! ssh ...`) or use
the non-interactive bootstrap job in `templates/bootstrap.pbs.sh`, which does
the same work as a batch job and is the better default.

The install pattern (see `reference/environments.md` for the full story):

```bash
export TMPDIR=$SCRATCHDIR/tmp UV_CACHE_DIR=$SCRATCHDIR/uv UV_LINK_MODE=copy
mkdir -p "$TMPDIR" "$UV_CACHE_DIR"
. /etc/profile.d/30_meta_modules.sh
module add mambaforge
source activate $MC_HOME/mamba_base     # python 3.11 + uv; bootstrap.pbs.sh creates it
cd $MC_REMOTE
uv venv --python 3.11 .venv && source .venv/bin/activate
uv pip install -r requirements.txt
```

Caches **must** go on scratch: `/tmp` has a hard 1 GB root-filesystem quota and
pip/uv/conda will blow through it, after which no job of yours runs on that node
until you clear it (`check-local-quota`, then `rm`).

**That venv-on-`/storage` pattern is fine for small stacks only.** For torch /
vLLM (5 GB, tens of thousands of files) it fails in two ways, both seen
2026-10-09: installing into NFS took far over an hour, and on some nodes a
Python run from `/storage` hung in uninterruptible I/O (`D` state,
`folio_wait_bit_common`) forever. Use the scratch runtime below instead.

## Big stacks and flaky mounts: the scratch-runtime pattern

`templates/scratch-runtime/` (see its README) is the verified design. Use it for
anything with torch/vLLM, or whenever jobs may land on ELIXIR nodes:

- **No job touches `/storage` through the node's mount.** Every transfer is
  `rsync -e ssh` to `<user>@storage-<store>.metacentrum.cz:/home/<user>/...`,
  authenticated by the Kerberos ticket PBS gives the job, wrapped in `timeout`.
  Even `[ -d /storage/... ]` can hang — decide from the path string.
- **One CPU bootstrap job builds a single archive**: a standalone CPython
  (`uv python install`, moved to a plain dir; python-build-standalone is
  relocatable) with the locked packages installed straight into it (no venv →
  no hard-coded paths), plus the HF model cache. Pin with `uv pip freeze` from
  the working local env → `requirements.lock`. ~5 GB `tar.zst`; a job fetches
  and unpacks it in 90–160 s.
- **Work on scratch, sync back in the background** (`--append-verify` for
  append-only jsonl), copy existing output *in* at start so resubmitting resumes,
  and write the job's own log to scratch and sync it — don't rely on PBS
  `.OU/.ER` (they went missing for jobs that died early).
- **Test chain:** `pbs-local` → CPU bootstrap → CPU check (`-W depend=afterok:`)
  → 1 h GPU smoke → full run. Each step caught something the previous could not.

### ELIXIR nodes (`elmo*`, `eluo*`, queue `p2e_1d`)

CPU jobs often land there. Different world: `HOME` is
`/storage/praha5-elixir/home/<user>` (so your `~/.netrc` / `~/.cache` are not
there — fetch `.netrc` to scratch and `export NETRC=`), the brno2 mount was
very slow or stalled (a 20 MB `cp` didn't finish in 10 min), and the cluster
presets `HF_HUB_CACHE` to scratch — set `HF_HOME`, `HF_HUB_CACHE` **and**
`HUGGINGFACE_HUB_CACHE` explicitly. Don't exclude these nodes; make the job
independent of the mount.

### Gotchas collected 2026-10-09

- **Frontend `/storage` stalls**: the first access after login on `tarkil` hung
  >20 s, then was instant. `qsub` from a `/storage` cwd hung the same way. Use
  `timeout` on every ssh, and run `qstat -u` before retrying a submit.
- **Storage host runs only its command whitelist** (`tail`, `grep` → exit 4).
  To watch a job's synced log, `rsync` it down and grep locally.
- **`set -u` + sourcing `/etc/profile.d/30_meta_modules.sh`** exited the job
  silently with 1. Wrap such sourcing in `set +u` … `set -u`, or avoid modules.
- **Kill children on TERM.** vLLM's `EngineCore` is a separate process; killing
  only python leaves it holding the job in state `E`. Kill `$PY` and
  `pgrep -P $PY`, then `KILL` after 2 s.
- **`pkill -f <pattern>`** run through ssh/bash matches its own command line and
  kills your shell (exit 144). Use PIDs.
- **rsync `--exclude .venv/`** only matches directories; a `.venv` symlink still
  gets copied. Use `--exclude .venv`.
- **W&B entity**: a key that belongs to a team logs to the team by default; set
  `WANDB_ENTITY` explicitly (record which in `notes.md`).
- **Throughput reference** (Qwen3-0.6B, vLLM 0.23, A100 40GB): engine start
  44 s cold, ~5 s with the compile cache in the same job.
- **Array subjobs' `$SCRATCHDIR` contains brackets** (`job_24460603[0].pbs-m1`).
  Python's `glob` treats `[0]` as a character class, so anything that globs
  under scratch silently finds nothing — vLLM failed with "Cannot find any model
  weights" although the files were there. `pbs-local` sanitises the name and
  cannot reproduce it. Fix (in `scratch-runtime/common.sh`): work through a
  bracket-free symlink `$SCR=/tmp/scratch-$USER-<jobid>` → `$SCRATCHDIR`, and
  keep `$SCRATCHDIR` itself only for `clean_scratch`.
- **The storage server rate-limits your IP.** A monitor opening a fresh ssh to
  the storage server every minute got this workstation `Connection refused` on port
  22 within ~30 min, while the frontends and jobs still reached it. Poll
  through a frontend with one persistent connection:
  `rsync -e "ssh -o ControlMaster=auto -o ControlPath=... -o ControlPersist=2h -J <user>@tarkil.grid.cesnet.cz"`,
  and fetch logs every few minutes, not every minute. `qstat` on the frontend is
  fine every minute.
- **`qstat -t` column order** for array subjobs: id, name, user, time, **state**,
  queue — state is column 5. Prefer `qstat -t -x -f '<id>[]'` and grep
  `job_state`, which doesn't depend on columns.
- **Sharding instead of one long GPU job**: an array whose subjob `i` processes
  shard `i` (by `crc32(id) % N`, so every shard gets the same mix) into its own
  output dir, merged afterwards. The scheduler runs as many shards at once as
  GPUs are free, short walltimes backfill well, and a failed shard is resubmitted
  alone (`-v SHARD_INDEX=i`). Example: `templates/scratch-runtime/gpu-vllm.pbs.sh`
  + `merge_shards.py`.

## Writing the job script

`templates/single.pbs.sh` is the canonical one. Every line in it is load-bearing:

```bash
#PBS -N myproj_sweep
#PBS -l select=1:ncpus=16:mem=32gb:scratch_local=50gb
#PBS -l walltime=24:00:00
#PBS -m ae
```

- **No `-q`.** PBS routes by walltime and `ngpus` automatically. Naming a queue
  is how you end up rejected by `resources_min`. Only exceptions: `gpu_dgx`
  (≥4 GPUs with NVLink) and `uv18` (>100 CPUs or >500 GB RAM).
- **Always request `scratch_local`.** There is no default size — you get a
  token directory and the job dies mid-write.
- **`ngpus=1:gpu_mem=20gb:gpu_cap=compute_70`** only if the code actually uses
  CUDA. Check first: if the repo's config defaults to `device="cpu"`, a GPU
  request queues behind hundreds of GPU jobs for nothing.

Inside the script, in this order:

```bash
export OMP_NUM_THREADS=${NCPUS:-1} MKL_NUM_THREADS=${NCPUS:-1}
```
**Do not skip this.** torch and numpy default to every core they can see —
which on a shared node is all of them, not your `ncpus` — and PBS kills the job
with exit status **-25**. This is the single most common way an otherwise
correct job dies.

```bash
export TMPDIR=$SCRATCHDIR/tmp; mkdir -p "$TMPDIR"
cp -r "$PBS_O_WORKDIR"/{myproj,scripts,requirements.txt} "$SCRATCHDIR/"
cd "$SCRATCHDIR"
```

Then the **periodic sync-back loop**, which is what makes long sweeps survivable:

```bash
( while sleep 600; do
    rsync -a results/ "$PBS_O_WORKDIR/results/" 2>/dev/null
  done ) &
SYNC=$!
```

A job killed on walltime (**-29**) gets `SIGTERM` and then `SIGKILL` **10 seconds
later**. Ten seconds is not enough to copy 200 MB of checkpoints, so a `trap`
that tries to save your results at the end will silently lose them. Sync as you
go; the trap only cleans up.

```bash
trap 'kill $SYNC 2>/dev/null; rsync -a results/ "$PBS_O_WORKDIR/results/"; clean_scratch' TERM
python scripts/whatever.py ... > run.log 2>&1
kill $SYNC; rsync -a results/ runs/ "$PBS_O_WORKDIR/"
cp run.log "$PBS_O_WORKDIR/logs/$PBS_JOBID.log"
clean_scratch
```

Note `trap ... TERM` and **not** `EXIT`. `trap 'clean_scratch' EXIT` fires on
*any* exit including an early `set -e` failure — which wipes scratch before the
copy-back runs. That footgun is documented by MetaCentrum itself.

Redirect the program's own output to a file (`> run.log 2>&1`). PBS spools raw
stdout to `/var/spool/pbs/spool/$PBS_JOBID.OU` on the node, and that counts
against the same 1 GB root quota that locks you out of the node.

## Sweeps → array jobs

A driver that loops over cells sequentially is the wrong shape for a grid. Turn
the sweep into a **manifest of one command per line** and submit an array:

```bash
# on the remote, cells.txt:
python scripts/train.py --lr 1e-3 --seed 0
python scripts/train.py --lr 1e-4 --seed 0
...
mc sh "cd $MC_REMOTE && wc -l < cells.txt"     # N
mc submit templates/array.pbs.sh -J 1-N
```

`templates/array.pbs.sh` runs `sed -n "${PBS_ARRAY_INDEX}p" cells.txt` and
executes it, giving each subjob its own scratch, its own results subdirectory
(`results/$PBS_ARRAY_INDEX/`), and its own failure. Most repo drivers already
have a `--dry-run`/manifest mode — generate `cells.txt` from that rather than
by hand.

Array notes: `qstat -t` lists subjobs; the parent shows as `12345[]`;
`qstat -f '12345[]' -x | grep array_state_count` is the overview. **`qextend`
does not work on arrays** — size the walltime right the first time, or make
each cell resumable.

## Choosing walltime and queue

`qstat -q` (via `mc sh 'qstat -q'`) shows live depth. Structural facts:

| Want | Walltime | Auto-routes to | Note |
|---|---|---|---|
| CPU, quick test | ≤2 h | `q_2h` | huge but fast-moving |
| CPU, normal sweep | ≤24 h | `q_1d` | the default landing spot |
| CPU, long | ≤336 h / 720 h | `q_2w` / `q_2w_plus` | |
| GPU | ≤48 h | `gpu` | the contended one (879 queued 2026-09-08, 298 on 2026-10-10) |
| GPU, long | 48–336 h | `gpu_long` | shorter queue — asking for >48 h can start *sooner* |

Shorter walltime = better backfill = earlier start, but overrunning is exit -29
and total loss unless you synced. Estimate, then add 50 %.

## Who starts first: queue priority and fairshare

Two things order the waiting jobs (docs: `computing/resources/fairshare`;
priorities from `qstat -Q -f` on 2026-10-10):

**Queue priority** is fixed per queue and mostly flat for ordinary users:
`interactive` 110, `gpu_long` 66, `gpu` 65, every CPU `q_*` queue 50,
`backfill` 20. Group queues (`iti`, `zcu`, `galaxy*`, `elixir*`: 70–95) only
help members. So walltime does not buy priority — it buys **backfill** (a short
job fits gaps a long one cannot), and `gpu_long` starts sooner because it is
shorter, not because it ranks higher. `interactive` really does rank first,
which is why `qsub -I` starts in seconds.

**Fairshare** orders users within a queue, and is the part you control:

- Usage is what you **allocated**, not what you used: `spec × walltime × PE`,
  summed over CPU, RAM, GPU and scratch, where PE ("processor equivalent") is
  how much of the machine the job allocated across ncpus, mem, scratch and gpu. Asking for 80 GB or a GPU "to be safe" costs
  future priority even if the job never touches it — right-size from
  `qstat -xf` / `gpumemmaxpercent` of the previous run.
- `spec` is the node's per-CPU speed, so time on slower nodes is cheaper.
- Recent usage weighs most and decays over roughly a month; no half-life is
  published.
- **Every job that starts lowers it immediately.** Submit a big job together
  with a swarm of small ones and the small ones keep backfilling, your fairshare
  keeps falling, and the big one starves. Submit the big job first, wait until
  it is `R`, then the array.
- Publications acknowledging MetaCentrum/CERIT-SC, reported in the portal,
  raise it.
- The value itself is not shown; while you have jobs queued or running,
  <https://my.metacentrum.cz/users> shows your rank against other users.

## When something goes wrong

`mc info <jobid>` decodes the exit status:

| Status | Meaning | Fix |
|---|---|---|
| `-23` | Kerberos ticket missing | `kinit`, resubmit |
| `-25` | exceeded ncpus | set `OMP_NUM_THREADS` |
| `-27` | exceeded mem | raise `mem=`; watch for dataloader copies |
| `-29` | exceeded walltime | raise it, or make the driver resumable |
| `271` | killed by `qdel`/SIGTERM | |
| `0` | clean | |

- **Live stdout of a running job**: `mc tail <jobid>` — it resolves
  `exec_host2` from `qstat -f`, ssh's to that node, and tails
  `/var/spool/pbs/spool/<jobid>.OU`.
- **Data left in scratch after a crash**: `mc sh 'go_to_scratch <jobid>'` works
  for 24 h after the job ends; after that ssh to the node and
  `cd /scratch/<user>/job_<jobid>`.
- **Jobs older than 24 h** are gone from `qstat -x`; use
  `pbs-get-job-history <jobid>` — it returns the submitted script, stdout,
  stderr and PBS logs, but **not** your results.
- **`qextend <jobid> 4:00:00`** buys time on a *running* job. Budget: 20 uses
  and 1440 CPU-hours per 30 days (`qextend info`). CPU-hours, so extending a
  16-CPU job by 1 h costs 16.

## Moving data

- **Code up**: `mc push` — goes straight to the storage server too (since 2026-10-09; frontend mounts stall).
- **Results down**: `mc pull` — goes to `storage-<store>.metacentrum.cz` directly.
  Never pull GBs through a frontend; the docs warn that such processes get
  killed, and they are not the source or the destination anyway.
- **Many small files** (a `results/` of thousands of JSONs) are the
  thing storage quotas actually punish — the file count quota is 2.5 M. `tar`
  finished experiment sets before archiving; 500 MB is the target chunk size.
- Rule of thumb from the docs: >500 files **or** >50 GB in one operation counts
  as "large data" and must bypass the frontend.

## Reference

- `reference/pbs.md` — resource flags, queues, arrays, exit codes, qstat/qalter/qextend, scratch types.
- `reference/environments.md` — mamba + uv, containers, and the MuJoCo / torch / Minari specifics for ML repos.
- `scripts/pbs-local` — run a PBS script here, with a fake PBS around it.
- `templates/` — `bootstrap.pbs.sh`, `single.pbs.sh`, `array.pbs.sh`, and
  `scratch-runtime/` (the ssh-only, self-contained runtime for big stacks and GPU jobs).
- Docs root: <https://docs.metacentrum.cz/en/docs/welcome>. Qsub assembler
  (GUI for building a `qsub` line): <https://my.metacentrum.cz/qsub-assembler>.
  Queue state: <https://my.metacentrum.cz/queues>. Support: meta@cesnet.cz.

## Confirm before

`qsub`, `qdel`, `qextend`, `mc push --delete`, and anything that writes to
`/storage`. Reading (`qstat`, `mc log`, `mc pull`) needs no confirmation.

Never submit a script that has not been through `pbs-local` first.
