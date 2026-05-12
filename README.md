# Zig File Sync Tool

Watch local directories and instantly sync changed files to a remote server over SSH/SCP — with checksum-based deduplication so only what changed gets transferred.

Written in Zig 0.16. No runtime, no JVM, single binary.

## Quick Start

**1. Create `sync.conf`:**
```ini
host=myserver.com
username=deploy
key_path=~/.ssh/id_rsa

[folder]
local_dir=./src
remote_dir=/opt/app/src
excludes=**/temp/**
```

**2. Run:**
```sh
# One-shot sync
sync -c sync.conf

# Continuous watch mode
sync -w -c sync.conf
```

The tool syncs only changed files on startup, then watches and re-syncs on every save.

## What It Can Do

- **Multiple folder pairs** — sync several directories in one config, with per-folder include/exclude patterns
- **Cross-platform watching** — inotify (Linux), ReadDirectoryChangesW (Windows), FSEvents (macOS)
- **Fast change detection** — content hashing (default) or `mtime`+`size` for large binary trees
- **SSH agent support** — works with KeePassXC and other agents; no credentials in config files
- **SSH config integration** — use `~/.ssh/config` aliases as the `host` value
- **Text file normalisation** — CRLF→LF before checksumming so Windows edits don't force re-uploads
- **Version file** — automatically writes a timestamped JSON/INI "heartbeat" to the remote on each sync
- **Sync trigger** — touch a remote file after sync to kick off a CI/CD pipeline
- **Config variables** — reuse one config across environments with `${VARNAME}` expansion and `--var` overrides
- **Local copy worker** — sync between local directories without SSH
- **stdin config** — pipe or heredoc a config with `-c -`
- **Colored output** — ANSI colors auto-detected; `--color` / `--no-color` to override

## A More Complex Example

Reusable config with environment-driven variables:

```ini
# Defaults — override any of these from the shell or --var
ENV.HOST=dev.example.com
ENV.REMOTE_BASE=/opt/app
ENV.SUBDIR=project

host=${HOST}

[folder]
local_dir=./src
remote_dir=${REMOTE_BASE}/${SUBDIR}/src

[folder]
local_dir=./assets
remote_dir=${REMOTE_BASE}/${SUBDIR}/assets

version_from=./version.json
version_to=${REMOTE_BASE}/${SUBDIR}/version.json
version_name=${SUBDIR}
```

```sh
# Use file defaults
sync -w -c sync.conf

# Override for a feature branch — beats env vars
sync --var SUBDIR=feature-x -w -c sync.conf

# Point at prod via env var
HOST=prod.example.com sync -c sync.conf
```

→ See [Config Variable Expansion](DOCUMENTATION.md#config-variable-expansion) for the full priority rules and reasoning.

## Key CLI Flags

| Flag                                 | Description                         |
| ------------------------------------ | ----------------------------------- |
| `-c <path>` or `-c -`                | Config file path or stdin           |
| `-w`                                 | Watch mode                          |
| `--var NAME=value` / `-D NAME=value` | Set config variable (repeatable)    |
| `--check hash\                       | mtime_size`                         | Change detection mode |
| `--no-db`                            | Skip remote checksum database       |
| `--cleanup`                          | Remove remote files missing locally |
| `--dry-run`                          | Show changes without making them    |
| `--exec <cmd>`                       | Run command on remote after sync    |
| `--color` / `--no-color`             | Force or disable ANSI colors        |

## priv pub key pairs

Version of libssl used here does not play well with new ssl formats, so use pem instead

```shell
ssh-keygen -t rsa -b 4096 -m PEM -f ~/my.devkey.rsa.pem
```

## Full Documentation

→ **[DOCUMENTATION.md](DOCUMENTATION.md)** — complete config reference, all CLI options, SSH agent setup, ACL permissions, version files, glob patterns, and more.

## License

MIT
