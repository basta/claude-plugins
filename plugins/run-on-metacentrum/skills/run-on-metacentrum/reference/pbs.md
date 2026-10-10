# PBS on MetaCentrum — reference

Distilled from <https://docs.metacentrum.cz> (fetched 2026-09-08) plus facts
verified on the frontends. PBS Pro, Debian 12.

## Resources

Four are requested on essentially every job: `ncpus`, `mem`, `walltime`,
`scratch_*`. Defaults: `ncpus=1`, `mem=400mb`, `walltime=24:00:00`,
**scratch: none** — you get a token directory, not space.

```bash
qsub -l select=1:ncpus=8:mem=32gb:scratch_local=100gb -l walltime=12:00:00 job.sh
qsub -I -l select=1:ncpus=4:mem=16gb:scratch_local=20gb -l walltime=2:00:00     # interactive
```

`select=...` resources are **chunk-wide** (per chunk); `walltime` and licences
are **job-wide**. Normal jobs use one chunk. CLI `-l` beats `#PBS -l` in the
script.

| Flag | Meaning |
|---|---|
| `ncpus=N` | cores |
| `mem=Xgb` | RAM |
| `scratch_local=Xgb` | node-local disk (the default choice) |
| `scratch_ssd=Xgb` | SSD, not on every node, smaller |
| `scratch_shm=true` | RAM disk; size comes out of `mem` |
| `scratch_shared=Xgb` | cluster-shared network volume; add `cl_bee=True` for BeeGFS |
| `ngpus=N` | GPU cards |
| `gpu_mem=Xgb` | minimum VRAM |
| `gpu_cap=compute_70` | min CUDA architecture (`sm_XY` = within one arch); commas are OR; quote it |
| `cuda_version=X` | installed CUDA |
| `cpu_vendor=amd|intel` | |
| `spec=4.8` | SPEC CPU2017 speed class, ≥ |
| `os=debian12`, `osfamily=debian` | |
| `cluster=halmir` / `cl_halmir=True` | pin a cluster; `^name` or `=False` to avoid |
| `brno=True`, `praha=True`, … | pin a location |
| `mpiprocs=N`, `ompthreads=N` | MPI/OpenMP layout |

A resource can appear only **once** per select, so `cluster=^adan:cluster=^halmir`
silently fails — use `cl_adan=False:cl_halmir=False` instead.

GUI for assembling all this: <https://my.metacentrum.cz/qsub-assembler>.

## Queues

**Do not pass `-q`.** Jobs enter `default@pbs-m1.metacentrum.cz` and are routed
by walltime and `ngpus`. Naming a queue is mostly a way to be rejected by its
`resources_min`.

Snapshot of `qstat -q` on 2026-09-08 (`Run`/`Que`):

| Queue | Max walltime | Run | Que |
|---|---|---|---|
| `q_2h` | 2 h | 360 | 4098 |
| `q_4h` | 4 h | 9 | 8 |
| `q_1d` | 24 h | 1301 | 107 |
| `q_2d` | 48 h | 105 | 69 |
| `q_4d` | 96 h | 594 | 943 |
| `q_1w` | 168 h | 357 | 830 |
| `q_2w` | 336 h | 350 | 35 |
| `q_2w_plus` | 720 h | 1556 | 3 |
| `gpu` | 48 h | 176 | **879** |
| `gpu_long` | 336 h | 39 | 18 |
| `interactive` | 48 h | 33 | 1 |
| `large_mem` | 168 h | 8 | 7 |

Contention moves; re-check with `mc sh 'qstat -q'`. The structural point is
stable: `gpu` is the bottleneck queue, and a >48 h GPU request lands in
`gpu_long`, which is usually shorter.

Queues you *do* name explicitly: `gpu_dgx` (≥4 GPUs with NVLink), `uv18`
(>100 CPUs or >500 GB RAM), `elixircz` (ELIXIR members).

`qstat -Q -f gpu_long@pbs-m1.metacentrum.cz` shows a queue's limits and
`Priority`. Priorities on 2026-10-10: `interactive` 110, `gpu_long` 66, `gpu`
65, all CPU `q_*` 50, `backfill` 20; see "Who starts first" in `SKILL.md` for
how that combines with fairshare.

## GPU clusters

| Cluster | GPUs/node | Cap | VRAM |
|---|---|---|---|
| `bee.cerit-sc.cz` | 2× H100 NVL | 9.0 | 96 GB |
| `capy.cerit-sc.cz` | 8× H100 | 9.0 | 82 GB |
| `zia.cerit-sc.cz` | 4× A100 | 8.0 | 40 GB |
| `elbi1` | 2× A100 | 8.0 | 40 GB |
| `fobos` | 4× L40S | 8.9 | 46 GB |
| `alfridII` | 4× L40S | 8.9 | 48 GB |
| `galdor` | 4× A40 | 8.6 | 46 GB |
| `luna2022` | 1× A40 | 8.6 | 46 GB |
| `fer` | 8× RTX A4000 | 8.6 | 16 GB |
| `konos` | 4× GTX 1080 Ti | 6.1 | 12 GB |
| `fau` | 8× Quadro RTX 5000 | 7.5 | 16 GB |
| `cha` | 8× RTX 2080 Ti | 7.5 | 12 GB |
| `grimbold` | 2× P100 | 6.0 | 12 GB |

`pbsnodes <node> | grep cuda_version` probes a specific node.
`$CUDA_VISIBLE_DEVICES` holds the assigned GPUs **by UUID** (`GPU-2be73caf-…`),
not by index. CUDA accepts that, but code that parses it as integers breaks —
vLLM 0.23 dies at startup with `invalid literal for int() ... 'GPU-…'` inside
"Model architectures failed to be inspected". Fix: `use_gpu` in
`templates/scratch-runtime/common.sh` (UUID → `nvidia-smi` index, with
`CUDA_DEVICE_ORDER=PCI_BUS_ID`).

All GPU nodes ran CUDA 13.x drivers on 2026-10-09 (595.x / 610.x), so
cu130 wheels work everywhere. `gpu_mem=40gb:gpu_cap=compute_80` lands on A100 40GB,
A40, L40S or H100 — a good "any modern GPU" request; a 1 h job on it started
within ~10 min.
`qstat -fw <jobid> | grep gpu` reports `gpupercent`, `gpupowerusage` (Wh) and
`gpumemmaxpercent` after the fact — use them to right-size the next request.

## Scratch

`$SCRATCHDIR`, `$SCRATCH_TYPE`, `$SCRATCH_VOLUME`. The directory itself is not
writable, only its contents: `rm -rf $SCRATCHDIR` fails, `rm -rf $SCRATCHDIR/*`
works. `clean_scratch` (from the auto-loaded `metabase/1` module) does it
properly. Left-behind data is purged after at most 14 days.

Speed: `scratch_shm` (RAM) > `scratch_ssd` > `scratch_local` > `scratch_shared`.
Nothing survives the job except BeeGFS `scratch_shared` on `cl_bee`.

### trap

```bash
trap 'clean_scratch' EXIT TERM     # the documented idiom — and a footgun
```

`EXIT` fires on *every* exit, including a `set -e` abort before your copy-back,
which deletes the results you were about to save. Prefer `TERM` only, with an
explicit `clean_scratch` on the success path.

The alternative that works (`templates/scratch-runtime/common.sh`): an `EXIT`
trap whose *first* action is the final sync and only then `clean_scratch` — safe
because output is synced from the start, so an early abort has nothing unsaved.

The `SIGTERM`→`SIGKILL` gap is **10 seconds**. Anything in the trap that copies
more than a few MB will not finish. Sync results periodically during the run
instead of relying on the trap.

## Job arrays

```bash
qsub -J 1-24 script.sh          # indices 1..24
qsub -J 2-7:2 script.sh         # 2,4,6
```

Inside: `$PBS_ARRAY_INDEX` (this subjob), `$PBS_ARRAY_ID` (parent).
Parent shows as `969390[]`; a subjob as `969390[1].pbs-m1.metacentrum.cz`.

```bash
qstat -t                                        # list subjobs
qstat -f '969390[]' -x | grep array_state_count # overview
```

`qextend` does **not** work on arrays (support request only).

## Monitoring

```bash
qstat -u <user>              # running + queued
qstat -xu <user>             # + finished (24 h window only)
qstat -f  <jobid>            # full record, running/queued
qstat -xf <jobid>            # full record, finished
qstat -q                     # queues
qdel <jobid>                 # cancel; qdel -W force <jobid> if stuck
```

States: `Q` queued, `H` held, `R` running, `S` suspended, `E` exiting,
`F` finished, `X` finished subjob, `W` waiting.

**Live stdout of a running job** is not in your home — it is on the exec node:

```bash
qstat -f <jobid> | grep exec_host2      # -> zenon41.cerit-sc.cz:15002/12
ssh zenon41.cerit-sc.cz
tail -f /var/spool/pbs/spool/<jobid>.OU  # .ER for stderr
```

**Older than 24 h**: `pbs-get-job-history <jobid>` returns the submitted script
(`.SC`), stdout (`.OU`), stderr (`.ER`), PBS params (`.JB.TXT`) and node logs —
but never your data.

**After the job**: `jobname.o<jobid>` and `jobname.e<jobid>` land in the submit
directory (`$PBS_O_WORKDIR`) unless `-o`/`-e` redirect them. Read the `.e` first.

## Exit status

```bash
qstat -xf <jobid> | grep Exit_status
```

- `X < 0` — PBS killed it (resource limit)
- `0 ≤ X < 256` — the script's own exit code
- `X ≥ 256` — killed by signal `X-256` (`kill -l` for names)

| | |
|---|---|
| `-23` | Kerberos ticket missing |
| `-25` | exceeded ncpus |
| `-27` | exceeded memory |
| `-29` | exceeded walltime |
| `0` | fine |
| `271` | SIGTERM — `qdel`, or the walltime kill |

## Changing a job after submission

```bash
qalter -l select=1:ncpus=32:mem=10gb <jobid>   # QUEUED jobs only; whole -l at once
qalter -l walltime=02:00:00 <jobid>            # within the queue's max
qextend <jobid> 01:00:00                       # RUNNING jobs
qextend info                                   # remaining budget
```

`qextend` budget: 20 uses **and** 1440 CPU-hours per rolling 30 days. CPU-hours,
not wall hours — extending a 16-CPU job by 1 h costs 16. Out of budget →
meta@cesnet.cz.

Dependencies: `qsub -W depend=afterok:<jobid> next.sh`.

Email: `#PBS -m abe` (abort/begin/end), `-M addr`. Notifications are aggregated
into 30-minute "PBS JOB squashed report" batches, except `-m b`, which flushes
within 60 s.

## Root filesystem quota — 1 GB per node

Separate from the storage quota and easy to hit. Caused by writing to `/tmp`,
or by a job producing a huge `.OU`/`.ER` in `/var/spool`. Once exceeded, **no
further job of yours runs on that node** until cleared:

```bash
ssh <node>
check-local-quota
rm <the offenders>
```

Prevent it: `export TMPDIR=$SCRATCHDIR` at the top of every script, and redirect
your program's output to a file rather than letting it stream into the spool.
