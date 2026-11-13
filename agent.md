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
