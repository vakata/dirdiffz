const std = @import("std");
const App = @import("app.zig").App;
const Terminal = @import("terminal.zig").Terminal;

pub const TUI = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app: *App,
    terminal: Terminal,
    s: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, app: *App, terminal: Terminal) !*TUI {
        const self = try allocator.create(TUI);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .app = app,
            .terminal = terminal,
            .s = 0
        };
        return self;
    }
    pub fn deinit(self: *TUI) void {
        self.allocator.destroy(self);
    }
    pub fn run(self: *TUI) !void {
        while (true) {
            try self.draw();

            const key = try self.terminal.read();
            switch (key) {
                .up    => { try self.app.prev(); },
                .down  => { try self.app.next(); },
                .left  => { try self.app.close(); },
                .right => { try self.app.open(); },
                .space => { try self.app.toggle(); },
                .enter => {
                    try self.terminal.deactivate();
                    if (self.app.diffable()) |s| {
                        const path_lft = try std.fs.path.join(self.allocator, &.{ self.app.left(), s.path });
                        defer self.allocator.free(path_lft);
                        const path_rgt = try std.fs.path.join(self.allocator, &.{ self.app.right(), s.path });
                        defer self.allocator.free(path_rgt);
                        var child = try std.process.spawn(self.io, .{ .argv = &.{ "vimdiff", path_lft, path_rgt, } });
                        _ = try child.wait(self.io);
                        try self.app.reloadFile();
                    }
                    try self.terminal.activate();
                },
                .escape => break,
                .char => |c| switch (c) {
                    'q' => break,
                    'o' => { try self.app.openAll(); },
                    'c' => { try self.app.closeAll(); },
                    'r' => { try self.app.reload(); },
                    'x' => { try self.app.deleteRight(); },
                    'z' => { try self.app.deleteLeft(); },
                    ']' => { try self.app.copyToRight(); },
                    '[' => { try self.app.copyToLeft(); },
                    'a' => { try self.app.clearFilters(); },
                    's' => { try self.app.toggleSame(); },
                    'd' => { try self.app.toggleDifferent(); },
                    'f' => { try self.app.toggleOrphan(); },
                    'k' => { try self.app.prev(); },
                    'j' => { try self.app.next(); },
                    'h' => { try self.app.close(); },
                    'l' => { try self.app.open(); },
                    'y' => {
                        switch (self.app.state.confirm) {
                            .delete_left => try self.app.deleteLeft(),
                            .delete_right => try self.app.deleteRight(),
                            .copy_left => try self.app.copyToLeft(),
                            .copy_right => try self.app.copyToRight(),
                            else => {}
                        }
                        self.app.state.confirm = .nothing;
                    },
                    'n' => {
                        self.app.state.confirm = .nothing;
                    },
                    '?' => { self.app.toggleHelp(); },
                    else => {},
                },
                else => {},
            }
        }
    }
    pub fn draw(self: *TUI) !void {
        var i: usize = 0;
        if (self.app.selected()) |sel| {
            for (self.app.nodes.items,0..) |item,c| {
                if (std.mem.eql(u8, sel.path, item.path)) {
                    i = c;
                    break;
                }
            }
        }
        // get size and workable size
        const d = try self.terminal.size();
        const w = d.width;
        const h = d.height - 4;
        const p = (w - 5) / 2;
        if (self.app.nodes.items.len < h or i < 3) {
            self.s = 0;
        } else if (i > self.app.nodes.items.len - 3) {
            self.s = self.app.nodes.items.len - h - 1;
        } else if (self.s > i - 3) {
            self.s = i - 3;
        } else if (i > self.s + h - 3) {
            self.s = (i + 2) - h;
        }

        try self.terminal.clear();
        // header
        try self.terminal.write("┌─ ");
        try self.terminal.writeFixedCustom(self.app.left(), p - 5, "─");
        try self.terminal.write("─┐ ");
        try self.terminal.write("┌─ ");
        try self.terminal.writeFixedCustom(self.app.right(), p - 5, "─");
        try self.terminal.write("─┐\n");

        // render nodes
        for (self.app.nodes.items, 0..) |node, n| {
            if (n < self.s) continue;
            if (n > self.s + h) continue;
            try self.terminal.write("│");
            if (n == i) {
                try self.terminal.bold(true);
                try self.terminal.highlight(true);
            }
            switch (node.status) {
                .different => try self.terminal.red(),
                .same => try self.terminal.gray(),
                .left_only => try self.terminal.blue(),
                .right_only => try self.terminal.blue(),
                .unknown => try self.terminal.magenta()
            }
            if (node.type == .directory and node.status == .unknown) {
                try self.terminal.default();
            }
            if (node.status != .right_only) {
                for (0..node.level) |_| { try self.terminal.print("  ", .{}); }
                if (node.type == .directory) {
                    if (self.app.state.opened.contains(node.path)) {
                        try self.terminal.write("▼ ");
                    } else {
                        try self.terminal.write("▶ ");
                    }
                } else {
                    try self.terminal.write("  ");
                }
                try self.terminal.writeFixed(node.name, p - node.level * 2 - 2 - 2);
            } else {
                try self.terminal.writeFixed(" ", p - 2);
            }
            if (n == i) {
                try self.terminal.bold(false);
                try self.terminal.highlight(false);
            }
            try self.terminal.default();
            try self.terminal.write("│");
            switch (node.status) {
                .different => try self.terminal.write("≠"),
                .same => try self.terminal.write(" "),
                .left_only => try self.terminal.write("←"),
                .right_only => try self.terminal.write("→"),
                .unknown => try self.terminal.write("?")
            }
            try self.terminal.write("│");
            if (n == i) {
                try self.terminal.bold(true);
                try self.terminal.highlight(true);
            }
            switch (node.status) {
                .different => try self.terminal.red(),
                .same => try self.terminal.gray(),
                .left_only => try self.terminal.blue(),
                .right_only => try self.terminal.blue(),
                .unknown => try self.terminal.magenta()
            }
            if (node.type == .directory and node.status == .unknown) {
                try self.terminal.default();
            }
            if (node.status != .left_only) {
                for (0..node.level) |_| { try self.terminal.print("  ", .{}); }
                if (node.type == .directory) {
                    if (self.app.state.opened.contains(node.path)) {
                        try self.terminal.write("▼ ");
                    } else {
                        try self.terminal.write("▶ ");
                    }
                } else {
                    try self.terminal.write("  ");
                }
                try self.terminal.writeFixed(node.name, p - node.level * 2 - 2 - 2);
            } else {
                try self.terminal.writeFixed(" ", p - 2);
            }
            if (n == i) {
                try self.terminal.bold(false);
                try self.terminal.highlight(false);
            }
            try self.terminal.default();
            try self.terminal.write("│\n");
        }
        if (self.app.nodes.items.len < h) {
            for (0..h-self.app.nodes.items.len+1) |_| {
                try self.terminal.write("│");
                try self.terminal.writeFixed(" ", p - 2);
                try self.terminal.write("│ │");
                try self.terminal.writeFixed(" ", p - 2);
                try self.terminal.write("│\n");
            }
        }
        try self.terminal.write("└");
        try self.terminal.writeRepeat("─", p - 2);
        try self.terminal.write("┘ └");
        try self.terminal.writeRepeat("─", p - 2);
        try self.terminal.write("┘\n");

        try self.terminal.default();
        try self.terminal.write(" ");
        try self.terminal.highlight(self.app.state.filter.same);
        //try self.terminal.gray();
        try self.terminal.write("    same   ");
        try self.terminal.highlight(false);
        try self.terminal.write(" ");
        try self.terminal.red();
        try self.terminal.highlight(self.app.state.filter.different);
        try self.terminal.write(" different ");
        try self.terminal.highlight(false);
        try self.terminal.write(" ");
        try self.terminal.blue();
        try self.terminal.highlight(self.app.state.filter.orphan);
        try self.terminal.write("  orphans  ");
        try self.terminal.highlight(false);
        try self.terminal.default();

        if (self.app.state.help) {
            var row: u8 = 2;
            const wid = 60;
            const col = w / 2 - wid / 2;
            try self.terminal.move(row, col);
            try self.terminal.write("┌");
            try self.terminal.writeRepeat("─", wid - 2);
            try self.terminal.write("┐\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" arrows - move the list and open / close folders", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" o / c - open / close all folders", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" a / s / d / f - toggle filters", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" r - refresh", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" [ / ] - copy to left / right", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" z / x - delete left / right", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" Enter - open in diff editor", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" ? - toggle help", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" q / Esc - quit", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("└");
            try self.terminal.writeRepeat("─", wid - 2);
            try self.terminal.write("┘\n");
        }
        if (self.app.state.confirm != .nothing) {
            var row: u8 = 4;
            const wid = 40;
            const col = w / 2 - wid / 2;
            try self.terminal.move(row, col);
            try self.terminal.write("┌");
            try self.terminal.writeRepeat("─", wid - 2);
            try self.terminal.write("┐\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" ", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed("             Are you sure?", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed("         [Y]es          [N]o", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("│");
            try self.terminal.writeFixed(" ", wid - 2);
            try self.terminal.write("│\n");
            row += 1;
            try self.terminal.move(row, col);
            try self.terminal.write("└");
            try self.terminal.writeRepeat("─", wid - 2);
            try self.terminal.write("┘\n");
        }

        try self.terminal.flush();
    }
};

