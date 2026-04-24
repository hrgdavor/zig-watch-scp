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
- **Colored lines** for copied files
- **SSH Agent Support**: Compatible with [KeePassXC](https://keepassxc.org/) and other SSH agents for secure, passphrase-free authentication.

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

- `-c, --config <path>`: Path to configuration file (required for sync mode)
- `-x, --compress`: Enable SSH compression
- `--cleanup`: Remove remote files not present locally (matching patterns)
- `--simple-log`: Use simple logging (no escape codes for progress)
- `-h, --help`: Show help message

**Examples**:
```sh
# Sync with compression and cleanup
sync -c sync.conf -x --cleanup

# Sync overidding host and credentials
sync -c sync.conf myserver.com myuser mypass
```

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

### Sync Trigger

A "Sync Trigger" allows you to copy a specific local file (or create an empty one) to the remote server after every synchronization event (both initial and on-change). This is useful for triggering remote scripts, reloaders, or CI/CD pipelines that monitor a specific "signal" file.

**Configuration**:
```ini
[folder]
local_dir=./src
remote_dir=/opt/app/src
# (Optional) Local file to copy to the remote
trigger_from=./trigger.signal
# (Required) Remote path where the trigger file will be written
trigger_to=/tmp/app-reload.trigger
```

If `trigger_from` is not specified, an empty file will be created at `trigger_to` on the remote server.

### Remote Permissions and ACL Support

The tool uses **neutral SFTP permissions** (mode `0`) when creating files and directories on the remote server. 

This behavior is intentional and provides several benefits:
- **ACL Compatibility**: Specifically required when using POSIX ACLs (`setfacl`). Explicitly setting a mode (like `0644`) can override the ACL "mask" on many SFTP servers, effectively capping the permissions granted by other ACL entries.
- **Shared Group Folders**: Allows you to upload files to directories owned by other users where you have group write access.
- **Server Defaults**: Relies on the remote server's `umask` and default directory ACLs to apply the correct permissions, rather than forcing a hardcoded local preference.

Additionally, the tool avoids making `sftp_setstat` or `sftp_fsetstat` calls, which ensures that it doesn't try to change ownership or permissions on files it doesn't own.

## Glob Patterns

The tool supports modern glob patterns for both `includes` and `excludes`:
- `*`: Matches characters within a single directory level
- `?`: Matches any single character
- `**`: Matches any number of directory levels (recursive)

## How It Works

1. **Initial Sync**:
   - Downloads `.scpdb` checksum database for each remote folder (if exists)
   - Scans local directories using parallel threads
   - Calculates Wyhash checksums (with CRLF normalization for text files)
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
