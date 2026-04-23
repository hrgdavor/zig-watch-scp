# Zig 0.16.0 Agent Guidelines

When writing or modifying Zig code in this project, you must strictly adhere to the following Zig 0.16.0 standards and practices:

## 1. "Juicy Main" Pattern
Always use the "Juicy Main" pattern for entry points instead of manually initializing allocators or parsing args/env from `os`. In Zig 0.16.0, `main` takes a `std.process.Init` (or `std.process.Init.Minimal`) struct, which provides built-in dependency injection for the process state.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    // init.arena, init.environ_map, etc., are also available
}
```

## 2. New I/O: Mandatory Buffers & Flushing
Following the Zig 0.16.0 I/O overhaul, I/O is buffered by default.
- You must provide an explicit buffer when initializing writers (e.g., standard output).
- You **must** call `.flush()` to ensure data is physically written out. Missing flushes are a common source of bugs where output does not appear.

```zig
    // Create an explicit mandatory buffer
    var stdout_buffer: [1024]u8 = undefined;
    
    // Initialize the file writer with the new I/O subsystem arguments
    var stdout_file_writer = std.io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    
    try stdout.print("Hello, World!\n", .{});
    
    // Flushing is mandatory!
    try stdout.flush(); 
```

## 3. No Unmanaged Arrays
Do not use `std.ArrayListUnmanaged` or other older Unmanaged array variants. The managed vs unmanaged distinction is being simplified in newer Zig versions. Rely on standard types (like `std.ArrayList`) and explicitly pass allocators when required by the API, or initialize standard lists with the allocator directly.

```zig
    // Use the standard array list and avoid Unmanaged variants
    var list = std.ArrayList(u8).init(init.gpa);
    defer list.deinit();
```
