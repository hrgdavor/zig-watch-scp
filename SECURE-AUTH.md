# Secure Authentication Setup

This page is the single place for credentials. It covers SSH keys and agents,
OS keychain/vault helpers, CI secrets, and the rules the tool enforces.

The short version:

| Situation                        | Use                                                                                   |
| -------------------------------- | ------------------------------------------------------------------------------------- |
| No password needed (best)        | SSH key + `ssh-agent`                                                                 |
| Password unavoidable, desktop    | `password_command=` reading from the OS keychain or a vault                           |
| CI / containers                  | `SCP_PASSWORD_FILE` pointing at a mounted secret                                      |
| Avoid                            | `--var`, `password=` in a committed config, plaintext files under your home directory |

---

## 1. SSH key + agent (recommended)

Generate a key. libssh2 in this project works best with **PEM** keys:

```sh
ssh-keygen -t rsa -b 4096 -m PEM -f ~/.ssh/my.devkey.rsa.pem
```

Install the public half on the server, then load the private half into an agent
so the passphrase is typed **once per session**, not per sync:

```sh
# Linux / macOS
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/my.devkey.rsa.pem
ssh-add -l                       # verify it is loaded
```

macOS Keychain can keep the key across logins — `~/.ssh/config`:

```sshconfig
Host dev
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/my.devkey.rsa.pem
```

Windows uses the OpenSSH agent service. Enable it once from an **admin**
PowerShell, then add keys as your normal user:

```powershell
# admin PowerShell, once:
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service ssh-agent

# your user:
ssh-add $env:USERPROFILE\.ssh\my.devkey.rsa.pem
```

KeePassXC and other agents work too: enable their SSH agent and load the key from
the database.

Then the config needs no secret at all:

```ini
host=dev
username=deploy
```

The agent supplies the key during authentication. `key_path` is only needed when
you want the tool to read a key file directly (no agent).

---

## 2. Password from a credential store

When a password is unavoidable, do not store it in a file that scans look for.
Run a **credential helper**: `password_command=` executes a command and uses the
first line of its stdout as the secret.

```ini
password_command=security find-generic-password -s zig-watch-scp-dev -w
```

| Store                | One-time setup                                                                 | `password_command=`                                        |
| -------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------- |
| macOS Keychain       | `security add-generic-password -s zig-watch-scp-dev -a "$USER" -w`             | `security find-generic-password -s zig-watch-scp-dev -w`   |
| Linux Secret Service | `secret-tool store --label='zig-watch-scp dev' service zig-watch-scp host dev` | `secret-tool lookup service zig-watch-scp host dev`        |
| Windows DPAPI        | PowerShell snippet below                                                       | PowerShell one-liner below                                 |
| 1Password            | `op signin` once                                                               | `op read op://Private/zig-watch-scp/password`              |
| pass                 | `pass insert zig-watch-scp/dev`                                                | `pass show zig-watch-scp/dev`                              |
| KeePassXC            | unlock the database in the GUI (or use a key file)                             | `keepassxc-cli show -q -a password db.kdbx entry`          |

**Windows (DPAPI, tied to your Windows account):**

```powershell
# once; prompts without echoing
$secure = Read-Host -AsSecureString 'Password for dev'
ConvertFrom-SecureString $secure | Set-Content "$env:APPDATA\zig-watch-scp\dev.dpapi"
```

```ini
password_command=powershell -NoProfile -Command "$s = Get-Content ($env:APPDATA + '\zig-watch-scp\dev.dpapi'); [System.Net.NetworkCredential]::new('', (ConvertTo-SecureString $s)).Password"
```

**How the command runs:**

- The command line is split into arguments (whitespace separated, `'` or `"`
  quoted) and executed **directly, without a shell**. Pipes and redirects are not
  interpreted — put those in a script if you need them.
- It runs with your privileges, exactly like a `git credential` helper.
- stdout must be exactly one line (a trailing newline is ignored). Non-zero exit,
  empty output or extra lines are errors.
- Test it by hand first: the command must print the password and nothing else.

The same mechanism covers an encrypted key's passphrase:

```ini
passphrase_command=security find-generic-password -s zig-watch-scp-key -w
```

Precedence, highest first — for both password and passphrase:

1. `--password-file <path>` / `--passphrase-file <path>`
2. `--password-command <cmd>` / `--passphrase-command <cmd>`
3. positional password (`sync host user password`)
4. `SCP_PASSWORD_FILE` / `SCP_PASSPHRASE_FILE`
5. `SCP_PASSWORD_COMMAND` / `SCP_PASSPHRASE_COMMAND`
6. `SCP_PASSWORD` / `SCP_PASSPHRASE`
7. `password_command=` / `passphrase_command=` in the config
8. `password_file=` / `passphrase_file=` in the config
9. `password=` / `passphrase=` in the config (deprecated, warns)

---

## 3. CI and containers

Prefer a deploy key from the CI secret store written to a `0600` file:

```yaml
# GitHub Actions example
- name: Deploy
  env:
    KEY_PATH: ${{ runner.temp }}/deploy_key
  run: |
    install -m 600 /dev/null "$KEY_PATH"
    printf '%s' "${{ secrets.DEPLOY_KEY }}" > "$KEY_PATH"
    ./sync -c sync.conf
```

with the config referencing the path as a variable:

```ini
key_path=${KEY_PATH}
```

If only a password exists, mount it as a secret file and point the tool at it —
no plaintext in the repository, no secret in the environment:

```sh
SCP_PASSWORD_FILE=/run/secrets/sync_password ./sync -c sync.conf
```

`SCP_PASSWORD` works too, but CI systems often expose environment variables to
child processes and logs; the mounted file is safer.

---

## 4. Rules the tool enforces

- **`--var` rejects names containing `PASSWORD` or `PASSPHRASE`.** Values passed
  there appear in shell history and the process list. Environment variables are
  still allowed.
- A missing variable without a value fails (`is not defined`); so does one that
  resolves to an empty value (`is empty`). Variables have no inline default
  syntax — declare defaults with `ENV.NAME=`.
- `password_file` / `passphrase_file` must contain one line; empty and multi-line
  files are rejected. On POSIX, a group/world-readable file prints a `chmod 600`
  warning.
- `password=` / `passphrase=` in the config are still accepted but warn on every
  run.

## 5. Threat model — what this does and does not stop

No local scheme can stop a process that runs **as you**: it can ask the same
vault, decrypt the same DPAPI blob, or use the agent. The realistic goals are:

- **Nothing plaintext at rest** in predictable, scan-friendly files
  (`.password`, `.env`, `*.secret`, `id_*` under the home directory are what
  agents and malware look for).
- **Unlock gating**: the keychain/vault can require a login or biometric unlock;
  a file cannot.
- **No secrets in config, git, env dumps or shell history.**
- **The agent never exports the private key**; the strongest option is an agent
  plus short-lived credentials or a hardware token.

## 6. Troubleshooting

| Message                                            | Meaning / fix                                                                                 |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `the password command failed (exited)`             | Run the command manually; check its exit code and the printed stderr.                         |
| `the password command must print exactly one line` | The helper printed progress or several entries; add its quiet flag (`-q`, `--quiet`) or select a single field. |
| `the password command printed nothing`             | Empty vault entry or wrong lookup key.                                                        |
| `cannot read password file ... (FileNotFound)`     | Wrong path, or the CI secret was not mounted.                                                 |
| `Permission denied` / authentication failed        | Wrong entry, a helper that appends `\r`, or the account cannot log in with a password.        |
| DPAPI blob fails on another machine/account        | DPAPI is bound to the Windows account that created it; regenerate it there.                   |
| Key rejected                                       | Use a PEM key (`ssh-keygen -m PEM`); this libssh2 build does not handle every new key format. |
