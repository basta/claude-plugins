# basta-plugins

Personal Claude Code plugin marketplace.

## Plugins

| Plugin | Description |
|---|---|
| [run-on-metacentrum](plugins/run-on-metacentrum/) | Move a whole research repo onto MetaCentrum and back: `mc` helper, local fake-PBS, job templates for sweeps / arrays / GPU runs, fairshare notes |
| [metacentrum](plugins/metacentrum/) | MetaCentrum HPC grid helper — PBS jobs, data transfer, SSHFS storage mount, docs search |

## Installation

In Claude Code:

```
/plugin marketplace add basta/claude-plugins
/plugin install run-on-metacentrum@basta-plugins
```

`/plugin marketplace update basta-plugins` pulls later changes.
