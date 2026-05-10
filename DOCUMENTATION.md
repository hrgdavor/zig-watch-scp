# Zig File Sync Tool — Full Documentation

> For a quick-start overview see [README.md](README.md).

## Table of Contents

- [Usage](#usage)
  - [Configuration File](#configuration-file)
  - [Command Line Options](#command-line-options)
  - [Reading Config from Stdin](#reading-config-from-stdin)
- [Config Reference](#config-reference)
  - [Global Settings](#global-settings)
  - [Folder Settings](#folder-settings)
  - [Config Variable Expansion](#config-variable-expansion)
- [Features In Depth](#features-in-depth)
  - [Standalone Checksum Generation](#standalone-checksum-generation)
  - [Standalone Get/Put](#standalone-getput)
  - [Advanced Database Configuration](#advanced-database-configuration)
  - [Key-based Authentication](#key-based-authentication)
  - [Credentials via Environment Variables](#credentials-via-environment-variables)
  - [SSH Config Support](#ssh-config-support)
  - [Using with KeePassXC (SSH Agent)](#using-with-keepassxc-ssh-agent)
  - [Color Output Behavior](#color-output-behavior)
  - [Lightweight Sync Modes](#lightweight-sync-modes)
  - [Single File Sync Alias (`[file]`)](#single-file-sync-alias-file)
  - [Sync Trigger](#sync-trigger)
  - [Version File Support](#version-file-support)
  - [Remote Permissions and ACL Support](#remote-permissions-and-acl-support)
  - [Glob Patterns](#glob-patterns)
- [How It Works](#how-it-works)
- [License](#license)

---

## Usage

### Configuration File

Create a `sync.conf` file:

```ini
# Global Settings
host=172.31.97.223
username=user
key_path=~/.ssh/id_rsa
parallel_threads=8
watch_delay_ms=200
compress=true
cleanup=false

# First folder pair
[folder]
scpdb=.scpdb.custom
local_dir=./src
remote_dir=/tmp/sync_src
includes=*.zig, *.h
excludes=**/temp/**

# Second folder pair
[folder]
local_dir=./docs
remote_dir=/tmp/sync_docs
excludes=**/*.tmp

# Folder with local database and absolute path
[folder]
local_dir=./extra
remote_dir=/tmp/sync_extra
local_db=true
scpdb=D:/sync-metadata/extra.scpdb

# Execute a command on remote after each sync (optional)
exec_cmd=touch /tmp/synced

# Use an alias from ~/.ssh/config
host=my-dev-server
[folder]
local_dir=./project
remote_dir=/home/user/project

# Local copy worker (no SSH)
[local-folder]
dest_dir=./build
[source]
local_dir=./src
includes=**/*.zig
excludes=**/*.tmp

[source]
local_dir=./assets
```

```sh
sync -c sync.conf
```

### Command Line Options

| Flag                  | Description                                                |
| --------------------- | ---------------------------------------------------------- |
| `-c, --config <path>` | Path to config file — use `-c -` to read from **stdin**    |
| `-w, --watch`         | Enable watch mode (continuous monitoring)                  |
| `-x, --compress`      | Enable SSH compression                                     |
| `--color`             | Force ANSI color output even when stdout is not a terminal |
| `--no-color`          | Disable color output                                       |
| `--simple-log`        | No ANSI escape codes in progress output                    |
| `--cleanup`           | Remove remote files not present locally                    |
| `--dry-run`           | Show what would be synced/removed without making changes   |
| `--watch-delay <ms>`  | Override watch debounce delay                              |
| `--exec <cmd>`        | Remote command to run after each sync                      |
| `--check <hash\       | mtime_size>`                                               | Change detection mode (default: `hash`) |
| `--no-db`             | Disable checksum database on remote server                 |
| `--var VARNAME=value` | Set a config variable (repeatable, highest priority)       |
| `-D VARNAME=value`    | Short form of `--var`                                      |
| `-h, --help`          | Show help message                                          |

**Examples:**
```sh
# Sync with compression and cleanup
sync -c sync.conf -x --cleanup

# Override host and credentials
sync -c sync.conf myserver.com myuser mypass

# Watch mode with a specific config
sync -w -c sync.conf

# Force colored output into a pipe
sync -c sync.conf --color | sed 's/\x1b\[[0-9;]*m//g'
```

### Reading Config from Stdin

Pass `-c -` (a single dash) to read config from standard input. Useful for:
- Dynamically generated configs
- Securely injecting credentials without writing to disk
- Shell heredocs in CI/CD scripts

```sh
# Pipe config
cat sync.conf | sync -w -c -

# Redirect
sync -c - < sync.conf

# Inject password from a secret manager
my-secret-tool render sync.conf.tpl | sync -w -c -

# Heredoc
sync -c - <<'EOF'
host=myserver.com
username=user
key_path=~/.ssh/id_rsa
[folder]
local_dir=./src
remote_dir=/opt/app/src
EOF
```

---

## Config Reference

### Global Settings

| Key                | Default       | Description                                     |
| ------------------ | ------------- | ----------------------------------------------- |
| `host`             | —             | Remote hostname or SSH config alias             |
| `username`         | —             | SSH username                                    |
| `password`         | —             | SSH password (prefer key auth or agent)         |
| `key_path`         | —             | Path to SSH private key                         |
| `passphrase`       | —             | Passphrase for private key                      |
| `port`             | `22`          | SSH port                                        |
| `parallel_threads` | `4`           | Upload threads for initial sync                 |
| `watch_delay_ms`   | `200`         | Debounce delay for file-change events (ms)      |
| `compress`         | `false`       | Enable SSH compression                          |
| `cleanup`          | `false`       | Remove remote files missing locally             |
| `dry_run`          | `false`       | Dry run mode (don't upload or delete)           |
| `color`            | auto          | Force/disable ANSI color output                 |
| `exec_cmd`         | —             | Remote command to run after each sync           |
| `file_mode`        | `0644`        | SFTP permission mode for created files          |
| `dir_mode`         | `0755`        | SFTP permission mode for created directories    |
| `text_extensions`  | built-in list | Extensions treated as text (CRLF→LF normalised) |
| `version_from`     | —             | Local version template file path                |
| `version_to`       | —             | Remote path for processed version file          |
| `version_name`     | —             | Project name injected into version file         |
| `ENV.VARNAME`      | —             | Config-level default for `${VARNAME}` expansion |

### Folder Settings

| Key            | Description                                 |
| -------------- | ------------------------------------------- |
| `local_dir`    | Local directory to watch/sync               |
| `local_file`   | (`[file]` only) Single local file           |
| `remote_dir`   | Remote destination directory                |
| `includes`     | Comma-separated glob patterns to include    |
| `excludes`     | Comma-separated glob patterns to exclude    |
| `check`        | `hash` (default) or `mtime_size`            |
| `no_db`        | `true` to skip the `.scpdb` database        |
| `local_db`     | `true` to store `.scpdb` locally            |
| `scpdb`        | Custom path/name for the database file      |
| `trigger_from` | Local file to upload as sync trigger        |
| `trigger_to`   | Remote path to write the sync trigger       |
| `version_from` | Per-folder override for version template    |
| `version_to`   | Per-folder override for version remote path |
| `version_name` | Per-folder override for project name        |

### Config Variable Expansion

Any config value can contain `${VARNAME}` placeholders resolved at load time.

**Resolution order (highest to lowest priority):**

| Priority | Source                        | Example                                 |
| -------- | ----------------------------- | --------------------------------------- |
| 1        | `--var` CLI flag              | `sync --var SUBDIR=v2 -c sync.conf`     |
| 2        | Real environment variable     | `export SUBDIR=v2`                      |
| 3        | `ENV.VARNAME=` config default | `ENV.SUBDIR=project` in `sync.conf`     |
| —        | **Error**                     | Variable missing from all three sources |

**Why this order?**

- **`--var` is highest**: most explicit — typed on *this specific invocation*. Also the only override that doesn't pollute the shell environment; `export` leaks into the whole session, `--var` is strictly scoped to one run.
- **Env vars are second**: represent the process's context (Docker, CI/CD, shell profile). Right for per-machine or per-environment settings spanning many runs.
- **`ENV.X=` defaults are last**: live in the file, version-controlled, visible. Apply only when nothing external is specified.
- **Missing = error**: silent empty expansion creates broken paths like `:/opt/app/src` that are very hard to debug.

**Example — reusable team config:**
```ini
# Defaults — override any of these from the shell or --var
ENV.HOST=dev.example.com
ENV.REMOTE_BASE=/opt/app
ENV.SUBDIR=project

host=${HOST}

[folder]
local_dir=./src
remote_dir=${REMOTE_BASE}/${SUBDIR}/src

version_from=./version.json
version_to=${REMOTE_BASE}/${SUBDIR}/version.json
version_name=${SUBDIR}
```

```sh
# Use file defaults
sync -c sync.conf

# Override via --var (beats env vars)
sync --var SUBDIR=feature-x --var HOST=staging.example.com -c sync.conf

# Override via environment variable (Linux/macOS)
SUBDIR=project-v2 sync -c sync.conf

# Windows cmd (scoped to one invocation)
cmd /C "set SUBDIR=project-v2 && sync -c sync.conf"

# Windows PowerShell (scoped)
& { $env:SUBDIR = "project-v2"; sync -c sync.conf }
```

**Error on undefined variable:**
```sh
Config error: variable '${HOST}' is not defined.
  Set it via: --var HOST=value  |  env var HOST  |  ENV.HOST= in config
```

---

## Features In Depth

### Standalone Checksum Generation

Create a `.scpdb` file locally without connecting to a remote server:
```sh
sync create ./src --includes *.zig,*.h --excludes **/temp/**
```

### Standalone Get/Put

Download or upload a single file without folder matching or watching:
```sh
# Download remote file to local path
sync get /remote/path/file.txt ./local/file.txt -c sync.conf

# Upload local file to remote path
sync put ./local/file.txt /remote/path/file.txt -c sync.conf
```

### Advanced Database Configuration

- **`local_db=true`**: Saves `.scpdb` locally — keeps remote directories clean of metadata.
- **Absolute Paths**: If `scpdb` is an absolute path, it bypasses relative resolution.
  - `local_db=false` → absolute path on the **remote** server.
  - `local_db=true` → absolute path on the **local** machine.

Benefits:
- **Clean Remotes**: No sync metadata in production/remote folders.
- **Centralized Metadata**: All `.scpdb` files in one local directory.
- **Reliability**: Avoids remote filesystem latency when reading/writing the database.

### Key-based Authentication

Add `key_path` to `sync.conf`. If the key is encrypted, add `passphrase` as well, or use an SSH agent.

### Credentials via Environment Variables

- `SYNC_SSH_PWD` — SSH password fallback
- `SYNC_SSH_PASSPHRASE` — Key passphrase fallback

These are checked after explicit config values but before prompting.

### SSH Config Support

Reads `~/.ssh/config` (or `%USERPROFILE%\.ssh\config` on Windows). If `host` matches an alias, fills in:
- `HostName` — actual IP or hostname
- `User` — remote username
- `Port` — SSH port
- `IdentityFile` — private key path (supports `~` expansion)

Explicit settings in `sync.conf` or CLI args always take precedence.

### Using with KeePassXC (SSH Agent)

1. In KeePassXC, enable **SSH Agent** in settings.
2. Add your SSH key to an entry; enable **SSH Agent** for that entry.
3. The tool automatically uses any active SSH agent — no `password` or `passphrase` in the config file needed.

On Windows, ensure the `OpenSSH Authentication Agent` service is running and KeePassXC is configured to use it (named pipe).

### Color Output Behavior

- Stdout is a TTY → ANSI colors **on** by default.
- Stdout is piped/redirected → colors **off** by default (keeps logs clean).
- `--color` → force ANSI colors even in a pipe.
- `--no-color` → disable colors even in a terminal.

### Lightweight Sync Modes

**Check Mode (`check`):**
- `hash` (default): Wyhash64 content hash — accurate, reads file content.
- `mtime_size`: Modification time + size — faster, no content read.

**No-DB Mode (`no_db=true`):**
- Skips the `.scpdb` database.
- Uses direct SFTP `stat` calls to decide if upload is needed.
- Ideal for single files or small projects.

```ini
[folder]
local_dir=./assets
remote_dir=/var/www/assets
check=mtime_size
no_db=true
```

### Single File Sync Alias (`[file]`)

A shorthand for syncing one file using `mtime_size` + `no_db=true`:

```ini
[file]
local_file=D:/project/src/deps.extra.txt
remote_dir=/opt/dev/project/dev33
```

Equivalent to:
```ini
[folder]
local_dir=D:/project/src
remote_dir=/opt/dev/project/dev33
includes=deps.extra.txt
check=mtime_size
no_db=true
```

### Sync Trigger

Copies a file (or creates an empty one) on the remote after each sync:

```ini
[folder]
local_dir=./src
remote_dir=/opt/app/src
trigger_to=/opt/app/sync-complete.flag
# Optional: omit trigger_from to create an empty file
trigger_from=./local-trigger.txt
```

### Version File Support

Maintains a "heartbeat" version file on the remote, updated every sync.

**How it works:**
1. Reads local template (`version_from`).
2. Replaces placeholders with current Unix timestamp and `version_name`.
3. Uploads processed file to `version_to`.

`version_from` / `version_to` / `version_name` can be global or per-folder (per-folder takes priority).

**Placeholder injection (all formats):**

| Placeholder       | Replaced with                    |
| ----------------- | -------------------------------- |
| `${timestamp}`    | Current Unix timestamp (seconds) |
| `${name}`         | Value of `version_name`          |
| `${version_name}` | Value of `version_name` (alias)  |

**Automatic field injection by extension:**

| Extension | Field replaced       | Example result            |
| --------- | -------------------- | ------------------------- |
| `.json`   | `"timestamp": <old>` | `"timestamp": 1715170800` |
| `.json`   | `"name": "<old>"`    | `"name": "MyProject-1.0"` |
| `.ini`    | `timestamp=<old>`    | `timestamp=1715170800`    |
| `.ini`    | `name=<old>`         | `name=MyProject-1.0`      |

**JSON template:**
```json
{ "name": "placeholder", "timestamp": 0 }
```
After sync:
```json
{ "name": "MyProject-1.0", "timestamp": 1715170800 }
```

**Generic template:**
```
version=${name} built at ${timestamp}
```
After sync:
```
version=MyProject-1.0 built at 1715170800
```

### Remote Permissions and ACL Support
> since v1.3.2

Default permissions: files `0644`, directories `0755`. Override in `sync.conf`:
```ini
file_mode=0664
dir_mode=0775
```

Accepts:
- Octal strings: `0644`, `0o644`
- Decimal integers: `420` (= `0644`)

For ACL environments, `0666` / `0777` is often most neutral — lets the server's `umask` and ACLs govern final permissions without client interference.

The tool avoids `sftp_setstat` / `sftp_fsetstat` calls, so it never changes ownership on files it doesn't own.

### Glob Patterns

Supported in `includes` and `excludes`:
- `*` — any characters within one directory level
- `?` — any single character
- `**` — any number of directory levels (recursive)

---

## How It Works

1. **Initial Sync**:
   - Downloads `.scpdb` for each remote folder (if exists and `no_db=false`)
   - Scans local directories in parallel
   - Detects changes using Wyhash64 or `mtime`+`size`
   - Uploads only changed/new files
   - Prunes `.scpdb`: removes entries for files no longer present locally

2. **Initial Cleanup** (if `--cleanup`):
   - Lists all remote files matching patterns
   - Removes remote files missing locally

3. **Watch Mode** (if `-w`):
   - Spawns watcher threads per folder pair
   - On change: uploads if different, updates `.scpdb`

---

## License

MIT
