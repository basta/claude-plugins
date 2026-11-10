# Interactive GPU without the queue: a personal "GPU box"

For short experiments that are not worth a PBS queue: poke at a model, check
memory use, debug a CUDA error. Long runs still belong in batch jobs.

## The options

| Option | Queue? | Walltime | GPU choice | Files |
|---|---|---|---|---|
| **CERIT-SC JupyterHub** <https://hub.cloud.e-infra.cz/hub/> | **none** (Kubernetes) | none; idle rule below | A10, A40, A100, H100, RTX PRO 6000, A100 MIG 10/20 GB slices | own persistent home + optional MetaCentrum storage mount |
| **OnDemand** <https://ondemand.metacentrum.cz> | PBS `interactive` | 1–48 h, extendable | via the form (PBS `ngpus`) | your `/storage/<store>/home` |
| **`qsub -I`** with `ngpus=1` | PBS, and a GPU request waits on GPU nodes | ≤48 h | `gpu_mem=` / `gpu_cap=` | your `/storage/<store>/home` |

The JupyterHub is the closest to "a GPU in my own PC": a GPU as soon as one
is free, a server that stays up for days, and SSH into it. The spawn form shows
live free/used counts per GPU type. The rest of this file is about that option.

## Spawning the server

Sign in with e-INFRA CZ AAI (an ordinary MetaCentrum account with no group project got in on 2026-11-10).
Then **+ New Server**, give it a name, **Start**, and set:

| Field | Value | Why |
|---|---|---|
| Image | "Minimal NB" with the **SSH** tag, and turn on "Ensure SSH access into the notebook" | sshd inside; nothing else needed |
| Persistent Notebook Home | **New** the first time, **Existing** afterwards. Never "Erase if home exists" | `/home/jovyan` survives server deletion |
| MetaCentrum Storage | on, choose `<store>`, turn on "Mount selected home directory" | the same files batch jobs see, under `/home/meta/<user>` (the server will not start if that home is not initialised) |
| CPU / Memory | 8 / 32 GB | CPU is a soft limit, memory a hard one |
| GPU | `MIG (20GB)` for a mid-range card, or a whole A40/RTX PRO 6000 for FP32-heavy work | see the comparison below |

The SSH address is `jupyter-<user>--<servername>.dyn.cloud.e-infra.cz`,
also available as `$SSH_ADDRESS` inside. **Reuse the same server name**
and the address stays the same across re-spawns.

Inside a terminal (JupyterLab → Terminal), once:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<your public key>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
pgrep -a sshd || /usr/sbin/sshd      # the SSH image normally starts it on its own
```

## SSH: the hub is IPv6-only, so hop through a frontend

The hub's SSH endpoints have only AAAA records. From a network without IPv6
the connection fails with `No route to host`. The documented fix is eduVPN,
but an eduVPN **Institute Access** profile only routes the institution's own
prefix (seen on 2026-11-10: only `2001:718:2::/48`, private ULA address, no
IPv6 internet), which does not include the hub. **Secure Internet** profiles
may work, but not every account has one.

What does work everywhere: the frontends have IPv6, reach the hub, and allow
TCP forwarding, so jump through one with the Kerberos ticket you already
need for this skill.

```sshconfig
Host tarkil
    HostName tarkil.grid.cesnet.cz
    User <user>
    GSSAPIAuthentication yes
    GSSAPIDelegateCredentials yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 8h

Host metahub
    HostName jupyter-<user>--<servername>.dyn.cloud.e-infra.cz
    User jovyan
    ProxyJump tarkil
    ServerAliveInterval 60
```

Then `ssh metahub`, or VS Code Remote-SSH on host `metahub`.
`scripts/hub-up` checks the ticket and the connection, and opens the hub if
the server is gone.

## Inside the box

- **Login shells over SSH do not get the notebook's environment.** Conda is at
  `/opt/conda/bin` but not on PATH. Put this in `~/.bashrc` (persistent; bash
  reads it for non-interactive ssh commands too) and have `~/.bash_profile`
  source it:

  ```bash
  export PATH=/opt/conda/bin:$HOME/.local/bin:$PATH
  export OMP_NUM_THREADS=8 MKL_NUM_THREADS=8    # = your CPU limit
  ```

- **`nproc`, `free` and torch see the whole host** (120 cores, 503 GB on
  2026-11-10), not your limit. The real limits are in `/sys/fs/cgroup/cpu.max`
  and `memory.max`. Without `OMP_NUM_THREADS`, numpy/torch start 120 threads
  on 8 cores.
- **No torch preinstalled** in the minimal image. Install into a venv or conda
  env under `/home/jovyan` so it survives re-spawns.
- `nvidia-smi` shows `[Insufficient Permissions]` for some fields on a MIG
  slice; that is normal.

## The idle rule

A daily check deletes a **GPU** server after **2 consecutive days** with peak
5-minute GPU utilisation below 0.5 % (CPU-only servers: 4 days below 0.1 core).
Warning emails go out first. The persistent home survives; re-spawn with
**Existing** home and the same name. Don't fake load to keep it: release the
GPU and re-spawn when needed. After a re-spawn the host key may change:
`ssh-keygen -R jupyter-<user>--<servername>.dyn.cloud.e-infra.cz`.

## What a MIG 2g.20gb slice is worth

2/7 of an A100 80 GB PCIe's compute and 2/8 of its memory system.
Spec-sheet estimates (dense; not benchmarked):

| | RTX 4070 | MIG 2g.20gb | A40 (whole) |
|---|---|---|---|
| VRAM | 12 GB | 20 GB | 48 GB |
| Memory bandwidth | ~500 GB/s | ~480 GB/s | ~700 GB/s |
| FP32 (non-tensor) | ~29 TFLOPS | ~5 TFLOPS | ~37 TFLOPS |
| BF16/FP16 tensor, FP32 accumulate | ~58 TFLOPS | ~80 TFLOPS | ~150 TFLOPS |
| FP8 | yes | no | no |

- **About the same as a 4070:** AMP/bf16 training and memory-bound inference.
- **Better:** anything that did not fit in 12 GB.
- **Clearly worse:** plain FP32 code, custom kernels, GPU simulation. Take a
  whole A40 or RTX PRO 6000 for those.
- Nsight profiling is limited under MIG.

Docs: <https://docs.cerit-sc.cz/en/docs/web-apps/jupyterhub>,
[start a server](https://docs.cerit-sc.cz/en/docs/web-apps/jupyterhub/start-server),
[idle shutdown](https://docs.cerit-sc.cz/en/docs/web-apps/jupyterhub/idle-shutdown),
[OnDemand](https://docs.metacentrum.cz/en/docs/graphical/ondemand).
