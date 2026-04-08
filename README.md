# basta-plugins

Personal Claude Code plugin marketplace.

## Plugins

| Plugin | Description |
|---|---|
| [metacentrum](plugins/metacentrum/) | MetaCentrum HPC grid helper — PBS jobs, data transfer, SSHFS storage mount, docs search |

## Installation

First, register this marketplace in Claude Code (one-time setup):

Add to `~/.claude/plugins/known_marketplaces.json`:
```json
{
  "basta-plugins": {
    "source": {
      "source": "github",
      "repo": "basta/claude-plugins"
    }
  }
}
```

Then install any plugin:
```
/plugin install metacentrum@basta-plugins
```
