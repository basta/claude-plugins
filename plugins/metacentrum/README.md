# metacentrum

A Claude Code plugin for working with [MetaCentrum](https://www.metacentrum.cz/) — the Czech national grid computing infrastructure.

## Commands

### `/metacentrum <subcommand>`

| Subcommand | Description |
|---|---|
| `status` | Show running and queued PBS jobs |
| `interactive` | Start an interactive compute/GPU session |
| `submit` | Generate a PBS batch job script |
| `transfer` | Upload/download data with rsync/scp |
| `storage` | Mount home storage locally via SSHFS |
| `logs` | Fetch job output and error logs |
| `extend` | Extend walltime of a running job |
| `modules` | Search and load software modules |
| `docs` | Search MetaCentrum documentation |
| `help` | List all subcommands |

## Installation

```
/plugin install metacentrum@basta-plugins
```

## Configuration

Edit the command file and set your MetaCentrum username and preferred storage location at the top of the "User Identity" section.
