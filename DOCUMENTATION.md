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
  - [Passwords and Passphrases](#passwords-and-passphrases)
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

| Key                | Default       | Description                                              |
| ------------------ | ------------- | -------------------------------------------------------- |
| `host`             | —             | Remote hostname or SSH config alias                      |
| `username`         | —             | SSH username                                             |
| `password`         | —             | SSH password (deprecated; use `password_file`)           |
| `password_file`    | —             | File holding the SSH password (one line)                 |
| `key_path`         | —             | Path to SSH private key                                  |
| `passphrase`       | —             | Key passphrase (deprecated; use `passphrase_file`)       |
| `passphrase_file`  | —             | File holding the key passphrase (one line)               |
| `port`             | `22`          | SSH port                                                 |
| `parallel_threads` | `4`           | Threads for hashing and parallel uploads                 |
| `watch_delay_ms`   | `200`         | Debounce delay for file-change events (ms)               |
| `watch_backend`    | `nightwatch`  | `nightwatch` or `fsmeta` (reserved, see below)           |
| `fsmeta_socket`    | —             | fs-meta Unix socket path (reserved backend)              |
| `compress`         | `false`       | Enable SSH compression                                   |
| `cleanup`          | `false`       | Remove remote files missing locally                      |
| `dry_run`          | `false`       | Dry run mode (don't upload or delete)                    |
| `color`            | auto          | Force/disable ANSI color output                          |
| `exec_cmd`         | —             | Remote command to run after each sync                    |
| `file_mode`        | `0644`        | SFTP permission mode for created files                   |
| `dir_mode`         | `0755`        | SFTP permission mode for created directories             |
| `text_extensions`  | built-in list | Extensions treated as text (CRLF→LF normalised)          |
| `version_from`     | —             | Local version template file path                         |
| `version_to`       | —             | Remote path for processed version file                   |
| `version_name`     | —             | Project name injected into version file                  |
| `ENV.VARNAME`      | —             | Config-level default for `${VARNAME}` expansion          |

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

These keys belong to a `[folder]` section. Placed in the global section they are
ignored, and the parser prints a warning for them.

**Each folder keeps its own database.** A folder's `.scpdb` defaults to
`<remote_dir>/.scpdb` (`local_db=false`) or `<local_dir>/.scpdb`
(`local_db=true`). Two folders may not resolve to the same database file: the
run stops with a config error, because the folders would overwrite each other's
entries and every run would re-upload both in full. Give such folders a distinct
`scpdb` value:

```ini
[folder]
local_dir=./a
remote_dir=/srv/app
scpdb=.scpdb.a

[folder]
local_dir=./b
remote_dir=/srv/app
scpdb=.scpdb.b
```

Database files are metadata: they are never scanned, uploaded, watched or
removed by cleanup, even when a folder's `local_dir` contains another folder's
database.

A missing `local_dir` is created before the sync instead of aborting the run, so
build-output folders can be listed before they exist. Files deleted locally are
dropped from the database on the next run (no `--cleanup` needed for that).

### Watcher Backends

`zig-watch-scp` depends on `fs-meta` as its primary watcher dependency. That
pins `nightwatch` transitively, and the watcher code imports nightwatch through
fs-meta instead of declaring a separate top-level nightwatch dependency.

The implemented backend is **nightwatch**:

```ini
watch_backend=nightwatch
```

Nightwatch supplies the platform watcher: inotify on Linux, ReadDirectoryChangesW
on Windows, FSEvents on native macOS builds, and kqueue on BSD or macOS
cross-builds. The old hand-written inotify / ReadDirectoryChangesW / FSEvents
watchers were removed so there is one event pipeline and one set of semantics.

Nightwatch does **not** read `.gitignore` and does not hide ignored build outputs.
Everything below `local_dir` is watched; only `includes` / `excludes` from
`sync.conf` decide what is synced. This is deliberate: the tool usually copies
build artifacts that are gitignored.

An **fs-meta Unix-socket** backend is reserved:

```ini
watch_backend=fsmeta
fsmeta_socket=/run/user/1000/fs-meta/project.sock
```

That backend is not implemented yet. Selecting it currently fails at startup
with a clear `fs-meta Unix-socket watcher backend is not implemented yet`
message. The intended use case is a dev project that already runs fs-meta:
fs-meta watches the project's non-gitignored sources, while zig-watch-scp watches
ignored build outputs, so the two tools share one event source instead of arming
competing watchers.

The nightwatch path remains the integral default and is not replaced by the
fs-meta integration.

### Config Variable Expansion

Any value in the config may contain `${NAME}` placeholders. The value comes from,
in order:

| Priority | Source                        | Example                                   |
| -------- | ----------------------------- | ----------------------------------------- |
| 1        | `--var` CLI flag              | `sync --var REMOTE_ROOT=/home/me/app`     |
| 2        | Real environment variable     | `export REMOTE_ROOT=/home/me/app`         |
| 3        | `ENV.VARNAME=` config default | `ENV.REMOTE_ROOT=/opt/app` in `sync.conf` |
| —        | **Error**                     | No value, or an empty value               |

The committed default is always `ENV.NAME=...` — there is no inline fallback
syntax. A variable with no value at all fails with `is not defined`; a variable
that resolves to an empty value fails with `is empty`. A literal empty value in
the file (such as `password=`) is still allowed.

**Secrets and `--var`:** `--var` rejects names containing `PASSWORD` or
`PASSPHRASE`, because the value would be visible in shell history and process
listings. Environment variables are still allowed. For passwords and
passphrases, use a secret file or an SSH agent — see
[Passwords and Passphrases](#passwords-and-passphrases).

**Why this order?**

- **`--var` is highest**: most explicit — typed on *this specific invocation*. It is also the only override that doesn't touch the shell environment, so one run cannot leak into the next.
- **Env vars are second**: the right place for a shell profile, IDE run configuration, Docker Compose or CI job that applies to many runs.
- **`ENV.X=` defaults are last**: they live in the file, are version-controlled and visible to the whole team, and make a fresh checkout work without any setup.

**Where variables are expanded:** every config value — `host`, `username`,
`key_path`, `password_file`, `passphrase_file`, `local_dir`, `remote_dir`,
`scpdb`, `includes`, `excludes`, `trigger_*`, `version_*`, `exec_cmd`, and modes.
`ENV.NAME=` lines are read from the global section (before the first
`[section]`) and are expanded in file order, so an `ENV.` value may use
variables defined above it.

**Reusable team config (checked into git):**

```ini
# Shared defaults. Each developer overrides only what differs for them.
ENV.DEV_HOST=dev.example.com
ENV.DEV_USER=ubuntu
ENV.REMOTE_ROOT=/opt/app

host=${DEV_HOST}
username=${DEV_USER}

# Optional: publish a version file after a sync
version_from=./version.json
version_to=${REMOTE_ROOT}/version.json
version_name=${DEV_USER}-api

[folder]
local_dir=./api
remote_dir=${REMOTE_ROOT}/api

[folder]
local_dir=./worker
remote_dir=${REMOTE_ROOT}/worker

[folder]
local_dir=./conf
remote_dir=${REMOTE_ROOT}/conf
```

A developer sets **one** value — in their environment or with `--var` — and the
whole config follows. Per shell profile or IDE run configuration:

```sh
# Linux/macOS
export REMOTE_ROOT=/home/me/app
sync -c sync.conf
```

```powershell
# Windows PowerShell
$env:REMOTE_ROOT = 'D:\srv\app'
sync -c sync.conf
```

For a one-off run, or CI, keep it scoped to the invocation:

```sh
sync --var REMOTE_ROOT=/home/me/app -c sync.conf
REMOTE_ROOT=/srv/ci/app sync -c sync.conf
```

```powershell
sync --var REMOTE_ROOT=D:\srv\app -c sync.conf
```

Nothing personal needs to be committed: the config holds shared `ENV.` defaults,
and each developer's root comes from the environment or `--var`. Credentials
follow the same rule — see [Passwords and Passphrases](#passwords-and-passphrases).

**Errors:**

```sh
Config error: variable '${REMOTE_ROOT}' is not defined.
  Set it via: --var REMOTE_ROOT=value  |  env var REMOTE_ROOT  |  ENV.REMOTE_ROOT= in config
```

```sh
Config error: variable '${REMOTE_ROOT}' is empty.
  Give it a value (--var REMOTE_ROOT=value, env var REMOTE_ROOT, or ENV.REMOTE_ROOT= in the config).
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
  - `local_db=false` → absolute path on the **remote** server (used exactly as written; its directory is created on the server if needed).
  - `local_db=true` → absolute path on the **local** machine.
- **Uniqueness**: each folder needs its own database file. Sharing one is
  rejected before the connection is opened.

Benefits:
- **Clean Remotes**: No sync metadata in production/remote folders.
- **Centralized Metadata**: All `.scpdb` files in one local directory, e.g.
  `scpdb=/var/lib/sync/app.scpdb` and `scpdb=/var/lib/sync/docs.scpdb`.
- **Reliability**: Avoids remote filesystem latency when reading/writing the database.

### Key-based Authentication

Add `key_path` to `sync.conf`. If the key is encrypted, add `passphrase_file=`
(a one-line secret file) or let an SSH agent hold the decrypted key — see
[Passwords and Passphrases](#passwords-and-passphrases).

### Passwords and Passphrases

The short version: prefer an SSH key + agent. If a password is unavoidable, point
the config at a per-user **secret file**; environment variables are a fallback for
CI. Secrets are never accepted through `--var`.

#### Preferred: no stored secret

Use a key with `ssh-agent` (or `IdentityFile` in `~/.ssh/config`). The agent holds
the decrypted key for the session, so nothing password-like is stored by this tool:

```sh
ssh-add ~/.ssh/id_ed25519        # once per login/session
sync -c sync.conf
```

#### Password from a file (recommended for unattended runs)

`password_file=` is a *path*, not a secret, so it is safe to commit:

```ini
password_file=~/.config/zig-watch-scp/dev.password
```

Create the file once. The password is typed a single time, never per run, and
never appears in shell history or the process list:

```sh
# Linux/macOS
mkdir -p ~/.config/zig-watch-scp && chmod 700 ~/.config/zig-watch-scp
read -rsp 'Password for dev: ' P; printf '%s' "$P" > ~/.config/zig-watch-scp/dev.password; unset P
chmod 600 ~/.config/zig-watch-scp/dev.password
```

```powershell
# Windows PowerShell
$dir = "$env:USERPROFILE\.config\zig-watch-scp"
New-Item -ItemType Directory -Force $dir | Out-Null
$secure = Read-Host -AsSecureString 'Password for dev'
$plain = [System.Net.NetworkCredential]::new('', $secure).Password
[System.IO.File]::WriteAllText("$dir\dev.password", $plain)
icacls "$dir\dev.password" /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R)"
```

The same mechanism protects an encrypted key's passphrase with
`passphrase_file=`.

#### Password sources and precedence

For both the password and the passphrase, the first available source wins:

| Priority | Source                                 | Example                                  |
| -------- | -------------------------------------- | ---------------------------------------- |
| 1        | `--password-file <path>`               | `sync --password-file ./dev.pass -c ...` |
| 2        | positional password                    | `sync host user 'secret' -c sync.conf`   |
| 3        | `SCP_PASSWORD_FILE` (a path)           | `SCP_PASSWORD_FILE=/run/secrets/pw sync` |
| 4        | `SCP_PASSWORD` (the value)             | `SCP_PASSWORD='secret' sync -c ...`      |
| 5        | `password_file=` in the config         | `password_file=~/.config/...`            |
| 6        | `password=` in the config (deprecated) | warns on every run                       |

The passphrase uses the matching names: `--passphrase-file`,
`SCP_PASSPHRASE_FILE`, `SCP_PASSPHRASE`, `passphrase_file=`, `passphrase=`.

#### Why `--var` may not carry a password

`--var MY_PASSWORD=...` is **rejected**:

```
Config error: --var MY_PASSWORD=... is not allowed: names containing PASSWORD or PASSPHRASE may not be passed on the command line.
```

`--var` values are visible in shell history and in the process listing (`ps`,
Task Manager), so any local user or process can read them. Names containing
PASSWORD or PASSPHRASE are therefore refused for `--var` (and `-D`).

Environment-provided variables are still allowed, because they are the normal
place for a shell profile or CI secret. They are, however, inherited by child
processes, which is why the file is preferred over `SCP_PASSWORD` for unattended
runs.

#### File rules

- One line; a single trailing newline (LF or CRLF) is ignored.
- Empty files and files with more than one line are rejected.
- The file must be readable only by you. On POSIX a group/world-readable file
  prints a warning with the `chmod 600` command to run; on Windows use `icacls`.
- Keep it out of the repository and off network shares.

#### CI

Mount the secret as a file and point `SCP_PASSWORD_FILE` at it:

```sh
SCP_PASSWORD_FILE=/run/secrets/sync_password sync -c sync.conf
```

`SCP_PASSWORD` works too, but CI systems often expose environment variables to
child processes and logs, so the file is safer.

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

A shorthand for syncing one file. The first sync uploads it defensively. In watch mode the last checksum is kept in memory, so touching the file (changing only its timestamp) without changing its contents does not upload it again.

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
   - Scans and hashes local directories in parallel
   - Detects changes using Wyhash64 or `mtime`+`size`
   - Uploads changed/new files in parallel (`parallel_threads`), one SSH session
     per worker. Logins are serialized, and the vendored
     `third_party/libssh2/crypto.c` locks the mbedTLS backend's process-global
     RNG, so concurrent sessions no longer corrupt each other.
   - An empty or missing `.scpdb` means nothing is known about the server, so
     every file is uploaded. Conversely, a folder with **no local files** leaves
     the database untouched: an empty local tree (wrong working directory, not
     built yet) must never wipe a good database.
   - A file only enters `.scpdb` after its upload completed and the SFTP handle
     closed successfully, so an interrupted transfer is retried on the next run.
   - Checkpoints `.scpdb` every 5 seconds during large uploads, so a crash or
     network failure only loses the files uploaded since the last checkpoint;
     the next run resumes from there. Database writes use a temp file plus
     rename, so an interrupted save cannot truncate the previous good database.
     An empty database is never written.
   - Prunes `.scpdb`: removes entries for files no longer present locally

2. **Initial Cleanup** (if `--cleanup`):
   - Lists all remote files matching patterns
   - Removes remote files missing locally

3. **Watch Mode** (if `-w`):
   - Spawns nightwatch watcher threads per folder pair
   - On change: uploads if different, updates `.scpdb`

---

## License

MIT
