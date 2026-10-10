# Self-contained scratch runtime (verified 2026-10-09)

Taken from a real vLLM project (it kept them in `experiments/metacentrum/`, which is
the path the scripts source `common.sh` from), where they ran on ELIXIR CPU nodes
(eluo1-3, elmo1-1) and GPU nodes (fobos10 L40S, zia1 A100).
Use them as the starting point for any job that needs a big Python stack (torch,
vLLM) or that may land on a node whose `/storage` mount is slow.

| File | What |
|---|---|
| `common.sh` | Sourced by every job. `via`/`move` (rsync over ssh to the storage server, with timeouts), own job log synced back, `start_sync`/`stop_sync`/`finish` (EXIT trap: final sync, then `clean_scratch`), `use_netrc`, `use_runtime`, `use_gpu`. |
| `bootstrap.pbs.sh` | CPU job: uv static binary → standalone CPython → `uv pip install -r requirements.lock` into it → HF model snapshot → one `tar.zst` uploaded to `~/envs/`. 16 min, ~5 GB. |
| `check.pbs.sh` | CPU job: unpack the archive, import everything, a W&B run from the node. Run it with `-W depend=afterok:<bootstrap>`. |
| `merge_shards.py` | Joins `shard-NN/` output dirs of an array run (concatenates jsonl, checks unique keys). |
| `gpu-vllm.pbs.sh` | The GPU job, single or as a sharded array (`-J 0-7 -v SHARDS=8`): resume copy in, periodic `--append-verify` sync out, TERM handler that kills python **and its children** (vLLM's EngineCore). |

Every script opens with the same inline prologue that fetches the repo onto
scratch over ssh **before** `common.sh` exists locally; keep that order.

Project-specific bits to change (marked `EDIT`): the `RUNTIME_TAR` name, the
path to `common.sh`, the excludes in the prologue, the Python blocks, the `run`
steps. Storage paths are not among them: everything is derived from the
`/storage/<name>/home/<user>` directory the job was submitted from.
