const std = @import("std");
const Config = @import("src/config.zig").Config;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    const app_args = if (args.len > 1) args[1..] else &[_][]const u8{};
    const config = try Config.parseArgs(init.gpa, init, app_args);
    std.debug.print("host={s}\nusername={s}\npassword={s}\nkey_path={s}\n", .{config.host, config.username, config.password, config.key_path});
}
