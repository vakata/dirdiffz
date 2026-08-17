const std = @import("std");
const App = @import("app.zig").App;
const TUI = @import("tui.zig").TUI;
const Diff = @import("diff.zig").Diff;
const Terminal = @import("terminal.zig").Terminal;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var color = true;
    var ignores: std.ArrayList([]const u8) = .empty;
    defer ignores.deinit(gpa);
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(gpa);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--no-color")) {
            color = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ignore")) {
            i += 1;
            if (i >= args.len) {
                try stdout.print("Missing ignore\n", .{});
                try stdout.flush();
                return;
            }
            try ignores.append(gpa, args[i]);
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "-")) {
            try dirs.append(gpa, arg);
        }
    }
    if (dirs.items.len != 2) {
        try stdout.print("Usage: diff [--no-color] [--ignore pattern] <dir_left> <dir_right>\n", .{});
        try stdout.flush();
        return;
    }
    const dir_lft = std.Io.Dir.cwd().openDir(io, dirs.items[0], .{ .iterate = true }) catch {
        try stdout.print("Invalid left directory: {s}\n", .{ dirs.items[0] });
        try stdout.flush();
        return;
    };
    defer dir_lft.close(io);
    const dir_rgt = std.Io.Dir.cwd().openDir(io, dirs.items[1], .{ .iterate = true }) catch {
        try stdout.print("Invalid right directory: {s}\n", .{ dirs.items[1] });
        try stdout.flush();
        return;
    };
    defer dir_rgt.close(io);

    var diff = try Diff.init(gpa, io, dir_lft, dir_rgt, ignores.items);
    defer diff.deinit();

    var app = try App.init(gpa, diff, dirs.items);
    defer app.deinit();

    var terminal = try Terminal.init(stdout, color);
    defer terminal.deinit();

    var tui = try TUI.init(gpa, io, app, terminal);
    defer tui.deinit();

    try tui.run();
}

