# Zig File Sync Tool

A cross-platform file synchronization tool written in Zig 0.16 that uses SSH/SCP to sync files to a remote server with intelligent checksum-based change detection.

## Features

- **SSH/SCP File Transfer**: Uses libssh2 for secure file transfers
- **Multiple Sync Pairs**: Support for multiple independent folder pairs in a single configuration
- **Remote/Local Checksum Database**: Maintains `.scpdb` for fast change detection. Supports local storage and absolute paths.
- **Absolute Path Support**: Use absolute paths for `.scpdb` on both local and remote filesystems.
- **Relative path**: based on current folder so a config can be reused when using git worktrees for shipping code for QA
- **SSH Config Integration**: Automatically resolves connection details (host, username, port, and identity file) from your system's `~/.ssh/config` file.
- **Text File Normalization**: Automatically normalizes line endings (CRLF → LF) for text files before checksumming
- **Parallel Initial Sync**: Configurable thread count for fast initial synchronization across all folders
- **Real-time File Watching**: Multi-threaded watching for simultaneous tracking of multiple local directories
  - Configurable **watch delay** (debouncing) to handle batch events from editors during save
  - Linux: inotify
  - Windows: ReadDirectoryChangesW
  - macOS: FSEvents
- **Granular Pattern Matching**: Individual include/exclude patterns for each folder pair
- **Remote Cleanup**: Optional `--cleanup` flag to remove files on the remote server that are not present locally (respects include/exclude patterns)
- **Sync Trigger**: Copy a specific local file to the remote (or create an empty one) after each synchronization. Useful for triggering remote scripts or CI/CD pipelines in restricted environments.
- **Version File Support**: Automatically updates a version file (JSON or INI) with the current timestamp and optional project name (`version_name`), then uploads it to the remote server.
- **Colored lines** for copied files
- **SSH Agent Support**: Compatible with [KeePassXC](https://keepassxc.org/) and other SSH agents for secure, passphrase-free authentication.
- **Lightweight Sync Options**: Choose between content hashing or file attribute checks (`mtime` + `size`). Optionally disable the remote database entirely for simple sync tasks.

## Usage

The tool requires a configuration file to define synchronization settings and folders. By default, it looks for `sync.conf` in the current directory.

**Run using a configuration file**:

Create a `sync.conf` file in the same directory as the executable. You can define global connection settings and multiple `[folder]` sections:

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
# change from default, useful when multiple local dirs are synced to one remote
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

# Execute a command on the remote side after each sync (optional)
exec_cmd=touch /tmp/synced
# alias: exec=...

# Use an alias from ~/.ssh/config
host=my-dev-server
[folder]
local_dir=./project
remote_dir=/home/user/project

# Local copy worker mode (no SSH): local-folder + nested source entries
# Useful for local-only syncing or transforming local data into a target output directory.
[local-folder]
dest_dir=./build
[source]
local_dir=./src
includes=**/*.zig
excludes=**/*.tmp

[source]
local_dir=./assets
```

Then just run:

```sh
sync -c sync.conf
```

### Command Line Options

- `-c, --config <path>`: Path to configuration file — use `-c -` to read from **stdin**
- `-x, --compress`: Enable SSH compression
- `--color`: Force ANSI color output even when stdout is not a terminal
- `--cleanup`: Remove remote files not present locally (matching patterns)
- `--simple-log`: Use simple logging (no escape codes for progress)
- `--no-color`: Disable color output
- `--check <hash|mtime_size>`: Change detection mode (default: hash)
- `--no-db`: Disable checksum database (.scpdb) on remote server
- `-h, --help`: Show help message

**Examples**:
```sh
# Sync with compression and cleanup
sync -c sync.conf -x --cleanup

# Force colored output even into a pipe or file
sync -c sync.conf --color | sed -n 's/\x1b\[[0-9;]*m//g'

# Disable colors even when running in a terminal
sync -c sync.conf --no-color

# Sync overriding host and credentials
sync -c sync.conf myserver.com myuser mypass

# Read config from stdin (pipe or heredoc)
cat sync.conf | sync -w -c -
sync -c - < sync.conf
```

### Color Output Behavior
The tool uses Zig 0.16.0's `std.fs.File.stdout().isatty()` check to detect whether standard output is a terminal.
- If stdout is a TTY, ANSI color output is enabled by default.
- If stdout is piped or redirected, colors are disabled by default to keep the output clean.
- Use `--color` to force ANSI colors even when piping output intentionally (for example, when generating colored HTML or passing data to another tool).
- Use `--no-color` to disable colors even when running interactively in a terminal.

> This behavior avoids unwanted escape codes in logs and pipeline output while still allowing explicit color forcing when the user wants it.

### Standalone Checksum Generation
You can create a `.scpdb` file locally without connecting to a remote server:
```sh
sync create ./src --includes *.zig,*.h --excludes **/temp/**
```

### Standalone Get/Put
You can download or upload a single file directly without matching folders or continuous watching:
```sh
# Download remote file to local path
sync get /remote/path/file.txt ./local/file.txt -c sync.conf

# Upload local file to remote path
sync put ./local/file.txt /remote/path/file.txt -c sync.conf
```

### Advanced Database Configuration

- **local_db=true**: Saves the `.scpdb` file locally instead of on the remote server.
- **Absolute Paths**: If `scpdb` is an absolute path, it bypasses the default relative resolution.
    - Local absolute path if `local_db=true`.
    - Remote absolute path if `local_db=false`.

#### Benefits:
- **Clean Remotes**: Keeps your production/remote folders free of synchronization metadata.
- **Centralized Metadata**: Store all your `.scpdb` files in a single local directory for easier management.
- **Reliability**: Avoids issues with remote filesystem syncing or latency when reading/writing the database.

### Key-based Authentication
You can use an SSH private key by adding `key_path` to your `sync.conf`. If your key is encrypted, you can provide the `passphrase` field as well.

### Credentials via Environment Variables
- `SYNC_SSH_PWD`: SSH password
- `SYNC_SSH_PASSPHRASE`: Passphrase for the private key

### SSH Config Support
The tool automatically checks your `~/.ssh/config` (or `%USERPROFILE%\.ssh\config` on Windows) for connection details. If you specify a `host` that matches an alias in your SSH config, the tool will fill in missing details:
- **HostName**: The actual IP or hostname
- **User**: Remote username
- **Port**: SSH port (if not 22)
- **IdentityFile**: Path to your private key (supports `~` expansion)

Explicit settings in `sync.conf` or CLI arguments always take precedence over values found in your SSH config.

### Using with KeePassXC (SSH Agent)
For enhanced security and convenience, it is highly recommended to use an SSH Agent to manage your keys and passphrases.
1. **Enable SSH Agent**: In KeePassXC settings, enable the **SSH Agent** feature.
2. **Add Key**: Add your SSH key to a KeePassXC entry and enable the **SSH Agent** feature for that specific entry.
3. **Automatic Auth**: The tool will automatically attempt to use any active SSH agent for authentication. This allows you to sync securely without storing your `password` or `passphrase` in the `sync.conf` file.

On Windows, ensure the `OpenSSH Authentication Agent` service is running and configured correctly in KeePassXC (typically via a named pipe).

### Lightweight Sync Modes

For performance-critical environments or simple use cases, you can customize the change detection strategy:

- **Check Mode (`check`)**:
    - `hash` (Default): Uses Wyhash64 for absolute content accuracy.
    - `mtime_size`: Uses file modification time and size. Much faster as it avoids reading file content.
- **No-DB Mode (`no_db`)**:
    - Disables the use of the `.scpdb` file on the remote server.
    - The tool performs direct SFTP `stat` calls to decide if an upload is necessary.
    - Ideal for syncing single files or small projects without metadata overhead.

**Example Config**:
```ini
[folder]
local_dir=./assets
remote_dir=/var/www/assets
check=mtime_size
no_db=true
```

### Single File Sync Alias (`[file]`)

For cases where you only need to sync a single file, you can use the `[file]` section alias. This is a simplified version of `[folder]` that automatically configures fast change detection and disables the remote database.

**Example**:
```ini
[file]
local_file=D:/project/src/deps.extra.txt
remote_dir=/opt/dev/project/dev33
```

This is equivalent to the following complex configuration:
```ini
[folder]
local_dir=D:/project/src
remote_dir=/opt/dev/project/dev33
includes=deps.extra.txt
check=mtime_size
no_db=true
```

### Sync Trigger

The "Sync Trigger" feature allows you to copy a specific local file to the remote (or create an empty one) after each synchronization event. This is particularly useful for triggering remote scripts, CI/CD pipelines, or notifying other systems that a sync has completed.

This is an additional option that can be used alongside [Version File Support](#version-file-support). While a version file is typically configured once per session (often in the first folder) to act as a global "heartbeat," a **Sync Trigger** can be configured for each folder individually to signal when that specific component has finished syncing.

**How it works**:
- After every successful sync (both initial and during watch mode), the tool checks for `trigger_to`.
- If `trigger_from` is specified, that file is uploaded to `trigger_to`.
- If `trigger_from` is NOT specified, an empty file is created at `trigger_to`.

**Configuration**:
```ini
[folder]
local_dir=./src
remote_dir=/opt/app/src
# Remote destination path for the trigger
trigger_to=/opt/app/sync-complete.flag
# Optional: Local file to copy as trigger
trigger_from=./local-trigger.txt
```

### Version File Support

The "Version File Support" allows you to maintain a "heartbeat" or version indicator on the remote server that is updated every time a sync occurs. This is useful for remote systems to detect when new content is available without polling the entire filesystem.

**How it works**:
1. The tool reads a local template file (`version_from`).
2. It replaces placeholders and specific properties with the current epoch timestamp (in seconds) and optional project name (`version_name`).
3. The processed file is uploaded to the remote path (`version_to`).

`version_from` / `version_to` / `version_name` can be set **globally** (applies to all folders) or **per-folder** (folder value takes priority over global).

**Configuration**:
```ini
# Global (applies to all folders)
version_from=./version.json
version_to=/opt/app/version.json
version_name=MyProject-1.0

[folder]
local_dir=./src
remote_dir=/opt/app/src
# Per-folder override (takes priority over global)
version_from=./comp.json
version_to=/opt/app/comp.json
version_name=Component-2
```

**Placeholder injection** (all formats):

| Placeholder       | Replaced with                    |
| ----------------- | -------------------------------- |
| `${timestamp}`    | Current Unix timestamp (seconds) |
| `${name}`         | Value of `version_name`          |
| `${version_name}` | Value of `version_name` (alias)  |

**Automatic field injection** (by file extension):

| Extension | Field replaced       | Example result            |
| --------- | -------------------- | ------------------------- |
| `.json`   | `"timestamp": <old>` | `"timestamp": 1715170800` |
| `.json`   | `"name": "<old>"`    | `"name": "MyProject-1.0"` |
| `.ini`    | `timestamp=<old>`    | `timestamp=1715170800`    |
| `.ini`    | `name=<old>`         | `name=MyProject-1.0`      |

**JSON Template (`version.json`)**:
```json
{
  "name": "placeholder",
  "timestamp": 0
}
```
Result after sync:
```json
{
  "name": "MyProject-1.0",
  "timestamp": 1715170800
}
```

**INI Template (`version.ini`)**:
```ini
name=placeholder
timestamp=0
```
Result after sync:
```ini
name=MyProject-1.0
timestamp=1715170800
```

**Generic template (any extension)**:
```
version=${name} built at ${timestamp}
```
Result after sync:
```
version=MyProject-1.0 built at 1715170800
```

### Reading Config from Stdin

Pass `-c -` (a single dash) to read the configuration from standard input instead of a file. This is useful for:
- Piping a dynamically generated config
- Securely injecting credentials without writing them to disk
- Shell heredocs in CI/CD scripts

```sh
# Pipe config from a file
cat sync.conf | sync -w -c -

# Redirect from a file
sync -c - < sync.conf

# Generate config dynamically (e.g., inject password from a secret manager)
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

### Remote Permissions and ACL Support 
> since v1.3.2

By default, the tool uses standard permissions when creating files (`0644`) and directories (`0755`) on the remote server.

If your server uses **POSIX ACLs** or you are working in **shared group folders**, you can customize these in `sync.conf` to be more "neutral" or to match your environment:

```ini
# Global settings
file_mode=0664
dir_mode=0775
```

These settings accept:
- **Octal strings**: starting with `0` or `0o` (e.g., `0664`, `0o775`)
- **Decimal integers**: (e.g., `420` for `0644`)

**Recommended for ACLs**: Using `0666` for files and `0777` for directories is often the most "neutral" approach, as it allows the remote server's `umask` and default ACLs to fully govern the final permissions without being restricted by the client's explicit mode.

Additionally, the tool avoids making `sftp_setstat` or `sftp_fsetstat` calls, which ensures that it doesn't try to change ownership or permissions on files it doesn't own.

## Glob Patterns

The tool supports modern glob patterns for both `includes` and `excludes`:
- `*`: Matches characters within a single directory level
- `?`: Matches any single character
- `**`: Matches any number of directory levels (recursive)

## How It Works

1. **Initial Sync**:
    - Downloads `.scpdb` checksum database for each remote folder (if exists and `no_db=false`)
    - Scans local directories using parallel threads
    - Detects changes using Wyhash checksums or file attributes (`mtime`+`size`)
    - Uploads only changed/new files
    - **Prunes .scpdb**: Removes entries for files that no longer exist locally

2. **Initial Cleanup (Optional)**:
   - If `--cleanup` is enabled, lists all remote files
   - Removes remote files that match patterns but are missing locally

3. **Watch Mode**:
   - Spawns watcher threads for each folder pair
   - On change: uploads if checksum differs and updates `.scpdb`

## License

MIT
