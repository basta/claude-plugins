# run-on-metacentrum

A Claude Code skill for running a whole compute project on
[MetaCentrum](https://metavo.metacentrum.cz) (the CESNET PBS grid): push the
repo, build the environment, submit batch and array jobs, watch them, pull the
results back. Everything in it was learned the hard way on real jobs.

- `scripts/mc` — one command for ssh (with a persistent connection), rsync to the
  storage server, `qsub`/`qstat`/`qextend`, logs and live tails.
- `scripts/pbs-local` — runs a PBS script on your own machine inside a fake PBS,
  including the walltime kill, so a broken job fails in seconds, not after hours in the queue.
- `templates/` — single run, array sweep, environment bootstrap, and a
  self-contained scratch runtime for torch/vLLM GPU jobs.
- Notes on queues, fairshare, GPUs, scratch, storage and the usual exit codes.

## Setup

1. Install (see the marketplace README), and have `kinit` (krb5) installed locally.
2. Ask Claude to run something on MetaCentrum. On first use it asks for your
   username and home storage and runs `mc setup`, which writes
   `~/.config/run-on-metacentrum/config.env` and a `notes.md`.
3. `kinit <user>@META` in your terminal (tickets last 10 h; Claude cannot type the password).

`notes.md` is your personal layer: Claude reads it before every MetaCentrum task
and records account-specific facts there (environments you built, which
frontend works for you, W&B entity, project quirks), so the shared skill stays
generic.
