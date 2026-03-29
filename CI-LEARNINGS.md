# GitHub Actions CI Learnings

This document records every problem encountered while setting up GitHub Actions for this project
(cross-platform Zig 0.15.x build with macOS FSEvents support) and the exact fixes applied.
The goal is a reference so future CI changes don't rediscover the same pitfalls.

---

## Summary of Working Setup

| Target              | Runner          | Notes                                    |
| ------------------- | --------------- | ---------------------------------------- |
| `x86_64-linux`      | `ubuntu-latest` | straightforward                          |
| `aarch64-linux`     | `ubuntu-latest` | cross-compile, no special steps needed   |
| `x86_64-windows`    | `windows-latest`| straightforward                          |
| `x86_64-macos`      | `macos-latest`  | cross-arch (aarch64 runner → x86_64 bin) |
| `aarch64-macos`     | `macos-latest`  | native                                   |

Both macOS builds produce **FSEvents-backed** watchers (not the polling fallback), because the
runner OS is macOS in both cases even when the CPU arch differs.

---

## Problems Encountered and Fixes

### 1. `macos-13` runner was retired

**Error:**
```
configuration 'macos-13-us-default' is not supported on this GitHub Actions runner
```

**Cause:**  
GitHub retired the `macos-13` (Intel x86_64) runner in early 2025. Using it in a workflow
matrix will silently block or hard-fail job scheduling.

**Fix:**  
Use `macos-latest` for **all** macOS targets, even `x86_64-macos`. The `macos-latest` runner
is Apple Silicon (aarch64), but cross-compiling to `x86_64-macos` works fine from it — and
the macOS SDK is still present, so FSEvents still compiles.

```yaml
# WRONG — macos-13 is retired
- os: macos-13
  target: x86_64-macos

# CORRECT — macos-latest for both macOS targets
- os: macos-latest
  target: x86_64-macos
- os: macos-latest
  target: aarch64-macos
```

---

### 2. Zig binary from `mlugg/setup-zig` does not auto-discover the Xcode SDK

**Error:**
```
error: unable to find framework 'CoreServices'. searched paths: none
```

**Cause:**  
The standalone Zig compiler installed by `mlugg/setup-zig` does not call `xcrun` or read
`SDKROOT`. It has **zero** framework search paths by default. You must pass the sysroot
explicitly.

**Fix — two-part:**

**Part A: Workflow step to capture the SDK path:**

```yaml
- name: Set macOS SDK root
  if: runner.os == 'macOS'
  run: echo "ZIG_SYSROOT=--sysroot $(xcrun --show-sdk-path)" >> $GITHUB_ENV
```

This writes something like:
```
ZIG_SYSROOT=--sysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.2.sdk
```

**Part B: Pass it to `zig build`:**

```yaml
- name: Build
  run: zig build -Dtarget=${{ matrix.target }} -Doptimize=ReleaseSafe ${{ env.ZIG_SYSROOT }} --summary all
```

The env var is empty on non-macOS runners, so this works for all matrix entries with one line.

---

### 3. `--sysroot` alone does not populate framework search paths in Zig

**Error:**
```
error: unable to find framework 'CoreServices'. searched paths: none
```
(same error, even after adding `--sysroot`)

**Cause:**  
In Zig 0.15, passing `--sysroot` to `zig build` populates `b.sysroot` in `build.zig`, but
does **not** automatically add `-F` or `-I` flags pointing inside that sysroot. You must
register the paths manually.

**Fix — in `build.zig`:**

```zig
if (use_coreservices) {
    exe.linkFramework("CoreServices");
    if (b.sysroot) |sysroot| {
        exe.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        exe.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
    }
}
```

Both paths are required:
- `System/Library/Frameworks` — for `-F` (framework resolution)
- `usr/include` — for `-I` (C header resolution, including transitive dependencies)

---

### 4. `libDER/DERItem.h` not found (transitive CoreServices dependency)

**Error:**
```
error: 'libDER/DERItem.h' file not found
```

**Cause:**  
`CoreServices.h` → `Security.framework` → `libDER/DERItem.h`, which lives under
`$SYSROOT/usr/include`. Without `addSystemIncludePath`, the C compiler cannot find it.

**Fix:**  
Already covered in Problem 3 — `exe.addSystemIncludePath` with `$SYSROOT/usr/include` resolves
this. The two `addFrameworkPath` + `addSystemIncludePath` calls must always be applied together.

---

### 5. `@ptrCast` const-stripping is a compile error in Zig 0.15

**Error:**
```
error: cast discards const qualifier
```

In `src/watcher_macos.zig`:
```zig
// WRONG — Zig 0.15 forbids implicit const-strip in @ptrCast
@ptrCast(&path_cfstring)
```

**Cause:**  
`path_cfstring` is a `const CFStringRef`. Zig 0.14 allowed `@ptrCast` to silently strip `const`;
Zig 0.15 makes this a hard compile error.

**Fix:**

```zig
// CORRECT — explicit const cast first, then pointer cast
@ptrCast(@constCast(&path_cfstring))
```

---

### 6. `callconv(.C)` renamed to `callconv(.c)` in Zig 0.15

**Error:**
```
error: union 'builtin.CallingConvention' has no member named 'C'
```

In `src/watcher_macos.zig`:
```zig
// WRONG — Zig 0.14 style
fn fseventsCallback(...) callconv(.C) void { ... }
```

**Cause:**  
In Zig 0.15, `CallingConvention` enum members were renamed from `PascalCase` to `camelCase`:
`C` → `c`, `Stdcall` → `stdcall`, etc.

**Fix:**

```zig
// CORRECT — Zig 0.15 style
fn fseventsCallback(...) callconv(.c) void { ... }
```

---

### 7. Cross-compiling macOS from Windows — `@cImport` fails at build time

**Error (Windows host, any macOS target):**
```
error: 'CoreServices/CoreServices.h' file not found
```

**Cause:**  
When building on Windows, there are no macOS system headers available at all. The `@cImport`
for `CoreServices/CoreServices.h` is evaluated at compile time and fails immediately.

**Fix — conditional compilation via `build_options`:**

**`build.zig`:**
```zig
const builtin = @import("builtin");

const build_opts = b.addOptions();
// use_coreservices = true ONLY when BOTH host AND target are macOS
const use_coreservices = target.result.os.tag == .macos and builtin.os.tag == .macos;
build_opts.addOption(bool, "use_coreservices", use_coreservices);
exe.root_module.addOptions("build_options", build_opts);
```

**`src/watcher_macos.zig`:**
```zig
const bopts = @import("build_options");

// @cImport is only compiled when use_coreservices is true at comptime
const c = if (bopts.use_coreservices) @cImport({
    @cInclude("CoreServices/CoreServices.h");
}) else struct {};

pub const MacOsWatcher = if (bopts.use_coreservices) struct {
    // FSEvents implementation
} else struct {
    // Polling fallback (mtime-based directory scan)
    // Used when cross-compiling, e.g. from Windows
};
```

**Key insight:** In `build.zig`, `builtin.os.tag` is the **host** machine OS. In source `.zig`
files compiled **with a `-target` flag**, `builtin.os.tag` becomes the **target** OS. The check
`builtin.os.tag == .macos` in `build.zig` is evaluated at build-system time on the host machine,
not inside the compiled binary.

---

### 8. zlib includes `<unistd.h>` — not available when targeting Windows

**Cause:**  
The `zlib` dependency includes `<unistd.h>` on POSIX systems. When using MSVC target
(`x86_64-windows-msvc`), this header does not exist and the build fails.

**Fix — conditionally disable zlib for Windows targets:**

```zig
const use_zlib = target.result.os.tag != .windows;

const zlib_dep = if (use_zlib) b.dependency("zlib", .{
    .target = target,
    .optimize = optimize,
}) else null;

const libssh2_dep = b.dependency("libssh2", .{
    // ...
    .zlib = use_zlib,   // tell libssh2 whether to use zlib compression
});

if (use_zlib) {
    ssh2_lib.linkLibrary(zlib_dep.?.artifact("z"));
    exe.linkLibrary(zlib_dep.?.artifact("z"));
}
```

---

## Recommended Zig Action

Always use `mlugg/setup-zig@v2`. It uses official Zig download mirrors and handles version
caching reliably across Linux, macOS, and Windows.

```yaml
- uses: mlugg/setup-zig@v2
  with:
    version: '0.15.2'
```

Do not use `goto-bus-stop/setup-zig` or `zigup/actions-setup-zig` — they are less reliable
and not maintained to the same standard.

---

## Zig 0.15 API Changes Cheatsheet

| Old (Zig 0.14)           | New (Zig 0.15)              | Where it bites                      |
| ------------------------ | --------------------------- | ----------------------------------- |
| `callconv(.C)`           | `callconv(.c)`              | C callback declarations             |
| `callconv(.Stdcall)`     | `callconv(.stdcall)`        | Windows API callbacks               |
| `@ptrCast(&const_val)`   | `@ptrCast(@constCast(&val))`| Any const pointer passed to C APIs  |
| `std.fs.cwd().writeFile(path, data)` | `std.fs.cwd().writeFile(.{ .sub_path = path, .data = data })` | File writes |
| `std.mem.split`          | `std.mem.splitScalar` / `splitSequence` | String splitting            |
| `std.time.sleep`         | `std.Thread.sleep`          | Cross-platform sleep                |

---

## Final Working Workflow Snippet

```yaml
jobs:
  build:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-linux
          - os: windows-latest
            target: x86_64-windows
          - os: macos-latest        # Apple Silicon runner; cross-arch to x86_64 is fine
            target: x86_64-macos
          - os: macos-latest
            target: aarch64-macos

    steps:
      - uses: actions/checkout@v4

      - uses: mlugg/setup-zig@v2
        with:
          version: '0.15.2'

      - name: Set macOS SDK root
        if: runner.os == 'macOS'
        run: echo "ZIG_SYSROOT=--sysroot $(xcrun --show-sdk-path)" >> $GITHUB_ENV

      - name: Build
        run: zig build -Dtarget=${{ matrix.target }} -Doptimize=ReleaseSafe ${{ env.ZIG_SYSROOT }} --summary all
```
