# Zig 0.17.0 Agent Guidelines

When writing or modifying Zig code in this project, you must strictly adhere to the following Zig 0.17.0 standards and practices:

## 1. "Juicy Main" Pattern
Always use the "Juicy Main" pattern for entry points instead of manually initializing allocators or parsing args/env from `os`. In Zig 0.17.0, `main` takes a `std.process.Init` struct, which provides built-in dependency injection for the process state.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    // init.arena, init.environ_map, init.minimal.args, etc., are also available
}
```

## 2. New I/O: Mandatory Buffers & Flushing
Following the Zig 0.16.0 I/O overhaul, I/O is buffered by default.
- You must provide an explicit buffer when initializing writers (e.g., standard output).
- You **must** call `.flush()` to ensure data is physically written out. Missing flushes are a common source of bugs where output does not appear.
- Use `std.Io` and `std.Io.File`; the old `std.io` namespace is deprecated.

```zig
    // Create an explicit mandatory buffer
    var stdout_buffer: [1024]u8 = undefined;

    // Initialize the file writer with the new I/O subsystem arguments
    var stdout_file_writer = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("Hello, World!\n", .{});

    // Flushing is mandatory!
    try stdout.flush();
```

For whole-buffer file writes, `std.Io.File.writeStreamingAll(io, bytes)` is the direct replacement for the removed `File.writeAll`.

## 3. Detecting Pipes and Redirects
To detect whether standard output is a terminal or has been piped/redirected, use `std.Io.File.stdout().isTty(init.io)`.
This works cross-platform in Zig 0.17.0 and is the recommended way to choose terminal-friendly behavior.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const stdout = std.Io.File.stdout();
    const is_terminal = try stdout.isTty(init.io);

    if (is_terminal) {
        std.debug.print("Output is a terminal. Colors enabled!\n", .{});
    } else {
        std.debug.print("Output is piped or redirected. Stripping colors...\n", .{});
    }
}
```

## 4. No Unmanaged Arrays
Do not use `std.ArrayListUnmanaged` or other older Unmanaged array variants. The managed vs unmanaged distinction is being simplified in newer Zig versions. Rely on standard types (like `std.ArrayList`) and explicitly pass allocators when required by the API, or initialize standard lists with the allocator directly.

```zig
    // Use the standard array list and avoid Unmanaged variants
    var list = std.ArrayList(u8).init(init.gpa);
    defer list.deinit();
```

## 5. Zig 0.17.0 API Notes
These removals/renames are relevant to this codebase:

- `std.builtin` is deprecated: use `std.lang` (for example `std.lang.Optimize`).
- Optimization modes are lowercase: `.debug`, `.safe`, `.fast`, `.small` (not `.ReleaseSafe`).
- `Allocator.dupeZ` was removed: use `Allocator.dupeSentinel(u8, s, 0)`.
- `std.fmt.bufPrintZ` was removed: use `std.fmt.bufPrintSentinel(buf, fmt, args, 0)`.
- `std.Io.File.writeAll` was removed: use `writeStreamingAll` or a `File.Writer`.
- `std.Io.init` was removed. In tests use `std.testing.io`; in `main` use `init.io`.
- `@enumFromInt` / `@intFromEnum` are deprecated: prefer `@fromBackingInt(@intCast(x))` / `@backingInt(x)`.
- `@cImport` was removed from the language. This project already translates headers through `b.addTranslateC`; keep using that path.
- Build scripts run in a separate configure process: `b.build_root` and `b.args` no longer exist. Depend on files explicitly with `b.dependOnFileContents(...)`.
- `b.sysroot` was removed. macOS builds pass the SDK path explicitly with `-Dmacos-sdk`; see section 6.

## 6. macOS SDK and CoreServices Framework Paths

macOS builds link `CoreServices` for FSEvents. CI passes both the Zig sysroot and the SDK path:

```yaml
- name: Set macOS SDK root
  if: runner.os == 'macOS'
  run: |
    echo "ZIG_SYSROOT=--sysroot $(xcrun --show-sdk-path)" >> $GITHUB_ENV
    echo "ZIG_SDK=$(xcrun --show-sdk-path)" >> $GITHUB_ENV

- name: Build
  run: zig build -Dtarget=${{ matrix.target }} -Doptimize=safe ${{ env.ZIG_SYSROOT }} ${{ runner.os == 'macOS' && format('-Dmacos-sdk={0}', env.ZIG_SDK) || '' }} --summary all
```

`build.zig` must declare the SDK option and register the paths itself:

```zig
const macos_sdk = b.option([]const u8, "macos-sdk", "macOS SDK root for CoreServices framework/header paths");

if (use_coreservices) {
    exe.root_module.linkFramework("CoreServices", .{});
    if (macos_sdk) |sysroot| {
        // Zig re-roots absolute -F paths under --sysroot, so use the
        // target-root path here; only -isystem needs the SDK prefix.
        exe.root_module.addFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
    }
}
```

Apply the same block to the `stats` executable and `addTranslateC` step.

Critical rule:

- Framework paths (`-F`, `addFrameworkPath`) use the **target-root** path: `/System/Library/Frameworks`.
  `--sysroot <sdk>` rewrites it to `<sdk>/System/Library/Frameworks`.
  Passing `<sdk>/System/Library/Frameworks` produces the broken `<sdk>/<sdk>/System/Library/Frameworks`.
- Include paths (`-isystem`, `addSystemIncludePath`) are **not** re-rooted. They must include the SDK prefix: `<sdk>/usr/include`.

Do not reintroduce `b.sysroot`; it does not exist in Zig 0.17. If CI reports
`unable to find system framework "CoreServices"` with a doubled SDK path, check this rule first.
