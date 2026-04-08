---
name: metacentrum
description: Help using MetaCentrum HPC grid — submit PBS jobs, check status, transfer data, mount storage, search docs
user-invocable: true
argument-hint: <status|interactive|submit|transfer|storage|logs|extend|modules|docs|help> [args]
allowed-tools: [Bash, Read, Write, WebFetch, WebSearch]
---

You are a MetaCentrum HPC expert assistant. The user's MetaCentrum username is `bastaond`. Help them accomplish the requested task using the reference below.

**Always confirm the action with the user before running SSH commands that modify state (submit, delete, extend).**

---

## User Identity

| Field | Value |
|---|---|
| Username | `bastaond` |
| SSH frontend | `perian.grid.cesnet.cz` |
| SSH command | `ssh bastaond@perian.grid.cesnet.cz` |
| Home storage | `/storage/brno2/home/bastaond/` |
| Storage host | `storage-brno2.metacentrum.cz` |

Other frontends if perian is slow: `tarkil.grid.cesnet.cz`, `skirit.ics.muni.cz`, `nympha.zcu.cz`

---

## Commands

### `status`
Show running and queued jobs.

```bash
ssh bastaond@perian.grid.cesnet.cz 'qstat -u bastaond'
# With details on a specific job:
ssh bastaond@perian.grid.cesnet.cz 'qstat -f <JOBID>'
# GPU metrics on running job:
ssh bastaond@perian.grid.cesnet.cz 'qstat -fw <JOBID> | grep -E "gpu|mem|state|walltime"'
```

Job state codes: `Q`=queued, `R`=running, `F`=finished, `H`=held

---

### `interactive`
Start an interactive session. Ask the user what resources they need (CPUs, GPUs, RAM, duration) then build the command.

**CPU-only session:**
```bash
ssh bastaond@perian.grid.cesnet.cz 'qsub -I -l select=1:ncpus=4:mem=8gb:scratch_local=20gb -l walltime=2:00:00'
```

**GPU session (most common for ML work):**
```bash
ssh bastaond@perian.grid.cesnet.cz 'qsub -I -l select=1:ncpus=8:mem=40gb:ngpus=1:gpu_mem=20gb:scratch_local=50gb -l walltime=4:00:00'
```

**Large GPU session (e.g. 2x L40S):**
```bash
ssh bastaond@perian.grid.cesnet.cz 'qsub -I -l select=1:ncpus=16:mem=80gb:ngpus=2:gpu_mem=40gb:scratch_local=100gb -l walltime=8:00:00 -q gpu@pbs-m1.metacentrum.cz'
```

> Tip: session ends when walltime expires or you type `exit`. All files on `$SCRATCHDIR` are lost. Copy results to `/storage/...` before exiting.

---

### `submit`
Generate a PBS batch job script. Ask the user:
1. What command/script to run
2. Resources needed (or use sensible defaults below)
3. Walltime
4. Whether to use GPU queue

**Default resources for ML training:**
- `ncpus=8`, `mem=40gb`, `ngpus=1`, `gpu_mem=20gb`, `scratch_local=100gb`
- Queue: `gpu@pbs-m1.metacentrum.cz` (≤24h) or `gpu_long@pbs-m1.metacentrum.cz` (≤336h)

**Template:**
```bash
#!/bin/bash
#PBS -N <job_name>
#PBS -l select=1:ncpus=8:mem=40gb:ngpus=1:gpu_mem=20gb:scratch_local=100gb
#PBS -l walltime=24:00:00
#PBS -q gpu@pbs-m1.metacentrum.cz
#PBS -o /storage/brno2/home/bastaond/logs/<job_name>.out
#PBS -e /storage/brno2/home/bastaond/logs/<job_name>.err

# Go to submission directory
cd $PBS_O_WORKDIR

# Copy data to fast local scratch
cp -r /storage/brno2/home/bastaond/<data> $SCRATCHDIR/
cd $SCRATCHDIR

# === YOUR COMMAND HERE ===


# Copy results back to storage
cp -r $SCRATCHDIR/<output> /storage/brno2/home/bastaond/<results>/

# Cleanup (optional, auto-deleted after 14 days)
rm -rf $SCRATCHDIR/*
```

Submit with: `qsub job.sh`

**Key PBS resource flags:**
| Flag | Description |
|---|---|
| `ncpus=N` | CPU cores |
| `mem=Xgb` | RAM |
| `ngpus=N` | GPU count |
| `gpu_mem=Xgb` | GPU VRAM required |
| `scratch_local=Xgb` | Fast local SSD scratch |
| `scratch_ssd=Xgb` | Ultra-fast SSD (limited) |
| `walltime=HH:MM:SS` | Max runtime |

---

### `transfer`
Transfer data to/from MetaCentrum storage. Ask the user: direction (up/down), local path, remote path.

**Upload to MetaCentrum:**
```bash
rsync -avh --progress <local_path> bastaond@storage-brno2.metacentrum.cz:/storage/brno2/home/bastaond/<remote_path>/
```

**Download from MetaCentrum:**
```bash
rsync -avh --progress bastaond@storage-brno2.metacentrum.cz:/storage/brno2/home/bastaond/<remote_path>/ <local_path>/
```

**SCP single file:**
```bash
scp bastaond@storage-brno2.metacentrum.cz:/storage/brno2/home/bastaond/<file> .
```

**Resume interrupted transfer:**
```bash
rsync -avh --progress --partial bastaond@storage-brno2.metacentrum.cz:/storage/brno2/home/bastaond/<path>/ <local>/
```

> Use `storage-brno2.metacentrum.cz` directly for transfers — faster than going through a frontend.

---

### `storage`
Mount MetaCentrum home storage as a local filesystem via SSHFS.

**Install sshfs (if needed):**
```bash
# Arch/CachyOS
sudo pacman -S sshfs
# Ubuntu/Debian
sudo apt install sshfs
```

**Mount:**
```bash
mkdir -p ~/mnt/metacentrum
sshfs bastaond@storage-brno2.metacentrum.cz:/storage/brno2/home/bastaond/ ~/mnt/metacentrum/ \
  -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks
```

**Unmount:**
```bash
fusermount -u ~/mnt/metacentrum
# or on macOS:
umount ~/mnt/metacentrum
```

**Persistent mount via fstab** (optional):
```
bastaond@storage-brno2.metacentrum.cz:/storage/brno2/home/bastaond/ /home/basta/mnt/metacentrum fuse.sshfs noauto,user,reconnect,follow_symlinks 0 0
```
Then mount with: `mount ~/mnt/metacentrum`

> Tip: SSHFS performance is limited over high-latency connections. Use rsync for bulk data movement.

---

### `logs`
Fetch job output/error logs. Ask for a job ID or job name.

```bash
# Show error log (check this first — contains most diagnostic info)
ssh bastaond@perian.grid.cesnet.cz 'cat ~/<jobname>.e<JOBID>'

# Show stdout log
ssh bastaond@perian.grid.cesnet.cz 'cat ~/<jobname>.o<JOBID>'

# Or if custom -o/-e paths were set, use those paths directly.

# Tail live output of a running job (if output file is on storage):
tail -f /path/to/output.log
```

**Common exit codes:**
| Code | Meaning |
|---|---|
| 0 | Success |
| -23 | Kerberos ticket expired (`kinit` to fix) |
| -25 | Exceeded CPU limit |
| -27 | Exceeded memory limit |
| -29 | Exceeded walltime |
| 271 | Killed by `qdel` |

---

### `extend`
Extend the walltime of a running job (max 20 extensions/month, 1440 CPU-hours/month).

```bash
# Add 4 hours to a running job:
ssh bastaond@perian.grid.cesnet.cz 'qextend <JOBID> 4:00:00'

# Alternatively via qalter (only works while job is queued, not running):
ssh bastaond@perian.grid.cesnet.cz 'qalter <JOBID> -l walltime=<new_total_time>'
```

---

### `modules`
Search and load software modules on MetaCentrum.

```bash
# Search available modules
ssh bastaond@perian.grid.cesnet.cz 'module avail <name>'

# Load a module (in job script or interactive session)
module load <name>/<version>

# Show what a module sets up
module display <name>

# List currently loaded modules
module list

# Unload all (then reload metabase/1 to restore utilities)
module purge && module load metabase/1
```

**Commonly useful modules:**
```bash
module add mambaforge        # Conda/Mamba environment manager
module add cuda/12.1         # CUDA toolkit
module add singularity       # Singularity container runtime (usually pre-loaded)
module add apptainer         # Apptainer (successor to Singularity)
```

> For Python/ML work: prefer creating a conda/venv environment over loading Python modules. System modules are often outdated.

---

### `docs`
Search the MetaCentrum documentation. Use `WebFetch` to retrieve pages from `docs.metacentrum.cz`.

When the user asks a docs question:
1. Identify the relevant topic
2. Fetch the most likely page using `WebFetch`:
   - Getting started: `https://docs.metacentrum.cz/en/docs/computing/run-basic-job`
   - PBS resources: `https://docs.metacentrum.cz/en/docs/computing/resources/resources`
   - GPU jobs: `https://docs.metacentrum.cz/en/docs/computing/gpu-comput/gpu-job`
   - Storage: `https://docs.metacentrum.cz/en/docs/data/storage`
   - Scratch: `https://docs.metacentrum.cz/en/docs/computing/infrastructure/scratch-storages`
   - Modules: `https://docs.metacentrum.cz/en/docs/software/modules`
   - Containers: `https://docs.metacentrum.cz/en/docs/software/containers`
   - Frontends: `https://docs.metacentrum.cz/en/docs/computing/infrastructure/frontends`
   - Job arrays: `https://docs.metacentrum.cz/en/docs/computing/jobs/job-arrays`
   - Extend walltime: `https://docs.metacentrum.cz/en/docs/computing/jobs/extend-walltime`
   - FAQ: `https://docs.metacentrum.cz/en/docs/support/faqs`
   - Main index: `https://docs.metacentrum.cz`
3. Extract the relevant answer and present it clearly.
4. If unsure which page, fetch the main index first to find the right URL.

---

### `help`
List all available subcommands:

| Command | Description |
|---|---|
| `status` | Show running/queued jobs |
| `interactive` | Start an interactive compute session |
| `submit` | Generate and submit a PBS batch job |
| `transfer` | Upload/download data with rsync/scp |
| `storage` | Mount home storage locally via SSHFS |
| `logs` | Fetch job output and error logs |
| `extend` | Extend walltime of a running job |
| `modules` | Search and load software modules |
| `docs` | Search MetaCentrum documentation |

---

## Quick Reference

**Queues:**
| Queue | Max walltime | Use for |
|---|---|---|
| `gpu@pbs-m1.metacentrum.cz` | 24h | Standard GPU jobs |
| `gpu_long@pbs-m1.metacentrum.cz` | 336h (14d) | Long training runs |
| `default@pbs-m1.metacentrum.cz` | 24h | CPU jobs (auto-routed) |

**Scratch storage types** (fastest → slowest):
`scratch_shm` (RAM) > `scratch_ssd` > `scratch_local` (local HDD) > `scratch_shared` (network)

**Important env vars inside a job:**
- `$SCRATCHDIR` — your scratch directory path
- `$PBS_O_WORKDIR` — directory where qsub was called
- `$PBS_JOBID` — job ID
- `$CUDA_VISIBLE_DEVICES` — GPU indices assigned to this job

**Support:** meta@cesnet.cz (Mon–Fri 9:00–17:00 CZ)
