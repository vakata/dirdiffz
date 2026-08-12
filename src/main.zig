const std = @import("std");
const Diff = @import("dirdiffz").Diff;
const Terminal = @import("terminal.zig").Terminal;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        try stdout.print("Usage: diff <dir_left> <dir_right>\n", .{});
        try stdout.flush();
        return;
    }
    const dir_lft = std.Io.Dir.cwd().openDir(io, args[1], .{}) catch {
        try stdout.print("Invalid left directory: {s}\n", .{ args[1] });
        try stdout.flush();
        return;
    };
    defer dir_lft.close(io);
    const dir_rgt = std.Io.Dir.cwd().openDir(io, args[2], .{}) catch {
        try stdout.print("Invalid right directory: {s}\n", .{ args[2] });
        try stdout.flush();
        return;
    };
    defer dir_rgt.close(io);


    var diff = try Diff.init(gpa, io, dir_lft, dir_rgt);
    defer diff.deinit();

    const nodes = try diff.list();

    // TUI part
    var terminal = try Terminal.init(stdout, true);
    defer terminal.deinit();

    var filter_s: bool = true;
    var filter_d: bool = true;
    var filter_o: bool = true;

    var help: bool = false;

    var i: usize = 0;
    var s: usize = 0;
    while (true) {
        // get size and workable size
        const d = try terminal.size();
        const w = d.width;
        const h = d.height - 4;
        const p = (w - 5) / 2;

        try terminal.clear();

        // header
        try terminal.write("┌─ ");
        try terminal.writeFixedCustom(args[1], p - 5, "─");
        try terminal.write("─┐ ");
        try terminal.write("┌─ ");
        try terminal.writeFixedCustom(args[2], p - 5, "─");
        try terminal.write("─┐\n");

        // render nodes
        for (nodes.items, 0..) |node, n| {
            if (n < s) continue;
            if (n > s + h) continue;
            try terminal.write("│");
            if (n == i) {
                try terminal.bold(true);
                try terminal.highlight(true);
            }
            switch (node.status) {
                .different => try terminal.red(),
                .same => try terminal.gray(),
                .left_only => try terminal.blue(),
                .right_only => try terminal.blue(),
                .unknown => try terminal.magenta()
            }
            if (node.type == .directory and node.status == .different) {
                try terminal.default();
            }
            if (node.status != .right_only) {
                for (0..node.level) |_| { try terminal.print("  ", .{}); }
                if (node.type == .directory) {
                    if (node.state == .closed) {
                        try terminal.write("▶ ");
                    } else {
                        try terminal.write("▼ ");
                    }
                } else {
                    try terminal.write("  ");
                }
                try terminal.writeFixed(node.name, p - node.level * 2 - 2 - 2);
            } else {
                try terminal.writeFixed(" ", p - 2);
            }
            if (n == i) {
                try terminal.bold(false);
                try terminal.highlight(false);
            }
            try terminal.default();
            try terminal.write("│");
            switch (node.status) {
                .different => try terminal.write("≠"),
                .same => try terminal.write(" "),
                .left_only => try terminal.write("←"),
                .right_only => try terminal.write("→"),
                .unknown => try terminal.write("?")
            }
            try terminal.write("│");
            if (n == i) {
                try terminal.bold(true);
                try terminal.highlight(true);
            }
            switch (node.status) {
                .different => try terminal.red(),
                .same => try terminal.gray(),
                .left_only => try terminal.blue(),
                .right_only => try terminal.blue(),
                .unknown => try terminal.magenta()
            }
            if (node.type == .directory and node.status == .different) {
                try terminal.default();
            }
            if (node.status != .left_only) {
                for (0..node.level) |_| { try terminal.print("  ", .{}); }
                if (node.type == .directory) {
                    if (node.state == .closed) {
                        try terminal.write("▶ ");
                    } else {
                        try terminal.write("▼ ");
                    }
                } else {
                    try terminal.write("  ");
                }
                try terminal.writeFixed(node.name, p - node.level * 2 - 2 - 2);
            } else {
                try terminal.writeFixed(" ", p - 2);
            }
            if (n == i) {
                try terminal.bold(false);
                try terminal.highlight(false);
            }
            try terminal.default();
            try terminal.write("│\n");
        }
        if (nodes.items.len < h) {
            for (0..h-nodes.items.len+1) |_| {
                try terminal.write("│");
                try terminal.writeFixed(" ", p - 2);
                try terminal.write("│ │");
                try terminal.writeFixed(" ", p - 2);
                try terminal.write("│\n");
            }
        }
        try terminal.write("└");
        try terminal.writeRepeat("─", p - 2);
        try terminal.write("┘ └");
        try terminal.writeRepeat("─", p - 2);
        try terminal.write("┘\n");

        try terminal.default();
        try terminal.write(" ");
        try terminal.highlight(filter_s);
        //try terminal.gray();
        try terminal.write("    same   ");
        try terminal.highlight(false);
        try terminal.write(" ");
        try terminal.red();
        try terminal.highlight(filter_d);
        try terminal.write(" different ");
        try terminal.highlight(false);
        try terminal.write(" ");
        try terminal.blue();
        try terminal.highlight(filter_o);
        try terminal.write("  orphans  ");
        try terminal.highlight(false);
        try terminal.default();

        if (help) {
            var row: u8 = 2;
            const wid = 60;
            const col = w / 2 - wid / 2;
            try terminal.move(row, col);
            try terminal.write("┌");
            try terminal.writeRepeat("─", wid - 2);
            try terminal.write("┐\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("│");
            try terminal.writeFixed(" arrows - move the list and open / close folders", wid - 2);
            try terminal.write("│\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("│");
            try terminal.writeFixed(" o / c - open / close all folders", wid - 2);
            try terminal.write("│\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("│");
            try terminal.writeFixed(" a / s / d / f - toggle filters", wid - 2);
            try terminal.write("│\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("│");
            try terminal.writeFixed(" r - refresh", wid - 2);
            try terminal.write("│\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("│");
            try terminal.writeFixed(" [ / ] - copy to left / right", wid - 2);
            try terminal.write("│\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("│");
            try terminal.writeFixed(" Enter - open in diff editor", wid - 2);
            try terminal.write("│\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("│");
            try terminal.writeFixed(" ? - toggle help", wid - 2);
            try terminal.write("│\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("│");
            try terminal.writeFixed(" q / Esc - quit", wid - 2);
            try terminal.write("│\n");
            row += 1;
            try terminal.move(row, col);
            try terminal.write("└");
            try terminal.writeRepeat("─", wid - 2);
            try terminal.write("┘\n");
        }

        try terminal.flush();

        const key = try terminal.read();
        switch (key) {
            .up => { if (i > 0) i -= 1; if (i >= 3 and i - s < 3) s -= 1; },
            .down => { if (i < nodes.items.len - 1) i+= 1; if (i - s > h - 3 and s < nodes.items.len - h - 1) s += 1; },
            .left => { try diff.close(nodes.items[i]); if (s > nodes.items.len - h) s = nodes.items.len - h - 1; },
            .right => { try diff.open(nodes.items[i]); },
            .space => { try diff.toggle(nodes.items[i]); },
            .enter => { }, // TODO: vimdiff
            .escape => break,
            .char => |c| switch (c) {
                'q' => break,
                'o' => { try diff.openAll(); },
                'c' => { try diff.closeAll(); i = 0; s = 0; },
                'r' => { try diff.refresh(); i = 0; s = 0; },
                'x' => {}, // TODO: delete
                ']' => {}, // TODO: put
                '[' => {}, // TODO: get
                'a' => { filter_s = true; filter_d = true; filter_o = true; try diff.filter(filter_s, filter_d, filter_o); i = 0; s = 0; },
                's' => { filter_s = !filter_s; try diff.filter(filter_s, filter_d, filter_o); i = 0; s = 0; },
                'd' => { filter_d = !filter_d; try diff.filter(filter_s, filter_d, filter_o); i = 0; s = 0; },
                'f' => { filter_o = !filter_o; try diff.filter(filter_s, filter_d, filter_o); i = 0; s = 0; },
                'k' => { if (i > 0) i -= 1; if (i >= 3 and i - s < 3) s -= 1; },
                'j' => { if (i < nodes.items.len - 1) i+= 1; if (i - s > h - 3 and s < nodes.items.len - h - 1) s += 1; },
                'h' => { try diff.close(nodes.items[i]); if (s > nodes.items.len - h) s = nodes.items.len - h - 1; },
                'l' => { try diff.open(nodes.items[i]); },
                '?' => { help = !help; },
                else => {},
            },
            else => {},
        }
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

