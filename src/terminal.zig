const std = @import("std");
const posix = std.posix;

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Key = union(enum) {
    up,
    down,
    left,
    right,
    enter,
    escape,
    tab,
    space,
    backspace,
    char: u8,
    unknown,
};

pub const Terminal = struct {
    original: posix.termios,
    writer: *std.Io.Writer,
    colors: bool,

    pub fn init(writer: *std.Io.Writer, colors: bool) !Terminal {
        const original = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = original;
        // Receive input immediately rather than line-by-line.
        raw.lflag.ICANON = false;
        // Don't echo typed characters.
        raw.lflag.ECHO = false;
        // read() may return after a single byte.
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(
            posix.STDIN_FILENO,
            .FLUSH,
            raw,
        );
        var self: Terminal = .{ .original = original, .writer = writer, .colors = colors };
        // Enter alternate screen and hide cursor.
        try self.write("\x1b[?1049h");
        try self.write("\x1b[?25l");
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        // Reset attributes, show cursor, leave alternate screen.
        self.write("\x1b[0m") catch {};
        self.write("\x1b[?25h") catch {};
        self.write("\x1b[?1049l") catch {};
        posix.tcsetattr(
            posix.STDIN_FILENO,
            .FLUSH,
            self.original,
        ) catch {};
    }
    pub fn write(self: *Terminal, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
    }
    pub fn flush(self: *Terminal) !void {
        try self.writer.flush();
    }
    pub fn writeRepeat(self: *Terminal, text: []const u8, width: usize) !void {
        for (0..width) |_| {
            try self.write(text);
        }
    }
    pub fn writeFixedCustom(self: *Terminal, text: []const u8, width: usize, padding: []const u8) !void {
        var i: usize = 0;
        var cells: usize = 0;

        while (i < text.len and cells < width) {
            const seq_len = try std.unicode.utf8ByteSequenceLength(text[i]);
            if (i + seq_len > text.len) return error.InvalidUtf8;
            i += seq_len;
            cells += 1;
        }
        try self.write(text[0..i]);
        try self.writeRepeat(padding, width - cells);
    }
    pub fn writeFixed(self: *Terminal, text: []const u8, width: usize) !void {
        try self.writeFixedCustom(text, width, " ");
    }
    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const out = try std.fmt.bufPrint(
            &buf,
            fmt,
            args,
        );
        try self.write(out);
    }
    pub fn clear(self: *Terminal) !void {
        try self.write("\x1b[H\x1b[2J");
    }
    pub fn home(self: *Terminal) !void {
        try self.write("\x1b[H");
    }
    pub fn size(self: *Terminal) !Size {
        _ = self;
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(
            posix.STDOUT_FILENO,
            posix.T.IOCGWINSZ,
            @intFromPtr(&ws),
        );
        if (posix.errno(rc) != .SUCCESS) return error.GetTerminalSizeFailed;
        return .{
            .width = ws.col,
            .height = ws.row,
        };
    }
    pub fn move(self: *Terminal, row: usize, col: usize) !void {
        try self.print(
            "\x1b[{};{}H",
            .{ row + 1, col + 1 },
        );
    }
    pub fn read(self: *Terminal) !Key {
        _ = self;
        var byte: [1]u8 = undefined;
        const n = try posix.read(
            posix.STDIN_FILENO,
            &byte,
        );
        if (n == 0)
            return .unknown;
        return switch (byte[0]) {
            '\r', '\n' => .enter,
            '\t' => .tab,
            ' ' => .space,
            0x7f, 0x08 => .backspace,
            0x1b => try readEscapeSequence(),
            else => .{ .char = byte[0] },
        };
    }

    fn readEscapeSequence() !Key {
        var seq: [2]u8 = undefined;
        const n1 = try posix.read(
            posix.STDIN_FILENO,
            seq[0..1],
        );
        if (n1 == 0) return .escape;

        if (seq[0] != '[') return .escape;

        const n2 = try posix.read(
            posix.STDIN_FILENO,
            seq[1..2],
        );

        if (n2 == 0) return .escape;

        return switch (seq[1]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => .unknown,
        };
    }
    pub fn highlight(self: *Terminal, set: bool) !void {
        try self.bold(set);
        if (self.colors) {
            //try self.background(set);
            try self.reverse(set);
        } else {
            try self.reverse(set);
        }
    }
    pub fn bold(self: *Terminal, set: bool) !void {
        try self.write(if (set) "\x1b[1m" else "\x1b[22m");
    }
    pub fn reverse(self: *Terminal, set: bool) !void {
        try self.write(if (set) "\x1b[7m" else "\x1b[27m");
    }
    pub fn default(self: *Terminal) !void {
        if (!self.colors) return;
        try self.write("\x1b[39m");
    }
    pub fn background(self: *Terminal, set: bool) !void {
        try self.write(if (set) "\x1b[100m" else "\x1b[49m");
    }
    pub fn red(self: *Terminal) !void {
        if (!self.colors) return;
        try self.write("\x1b[31m");
    }
    pub fn blue(self: *Terminal) !void {
        if (!self.colors) return;
        try self.write("\x1b[34m");
    }
    pub fn gray(self: *Terminal) !void {
        if (!self.colors) return;
        try self.write("\x1b[90m");
    }
    pub fn magenta(self: *Terminal) !void {
        if (!self.colors) return;
        try self.write("\x1b[35m");
    }
};


