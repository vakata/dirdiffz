const std = @import("std");

pub const Type = enum {
    file,
    directory,
    mismatch,
};
pub const Status = enum {
    unknown,
    same,
    different,
    left_only,
    right_only,
};
pub const Node = struct {
    type: Type,
    level: usize,
    status: Status,
    parent: ?*Node,
    children: std.ArrayList(*Node),
    path: []const u8,
    name: []const u8,
};

pub const Diff = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lft: std.Io.Dir,
    rgt: std.Io.Dir,
    map: std.StringHashMap(*Node),
    nodes: std.ArrayList(*Node),
    roots: std.ArrayList(*Node),
    ignores: []const []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        lft: std.Io.Dir,
        rgt: std.Io.Dir,
        ignores: []const []const u8
    ) !*Diff {
        const self = try allocator.create(Diff);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .lft = lft,
            .rgt = rgt,
            .map = std.StringHashMap(*Node).init(allocator),
            .nodes = .empty,
            .roots = .empty,
            .ignores = ignores
        };
        try self.refresh();
        return self;
    }
    pub fn deinit(self: *Diff) void {
        self.map.deinit();
        for (self.nodes.items) |node| {
            node.children.deinit(self.allocator);
            self.allocator.free(node.path);
            self.allocator.free(node.name);
            self.allocator.destroy(node);
        }
        self.nodes.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn refresh(self: *Diff) !void {
        for (self.nodes.items) |node| {
            node.children.deinit(self.allocator);
            self.allocator.free(node.path);
            self.allocator.free(node.name);
            self.allocator.destroy(node);
        }
        self.nodes.clearRetainingCapacity();
        self.roots.clearRetainingCapacity();
        self.map.clearRetainingCapacity();

        var walker_left = try self.lft.walkSelectively(self.allocator);
        defer walker_left.deinit();
        while (try walker_left.next(self.io)) |entry| {
            if (entry.kind != .directory and entry.kind != .file) {
                continue;
            }
            if (
                entry.kind == .directory and (
                    std.mem.eql(u8, entry.basename, ".git") or
                    std.mem.eql(u8, entry.basename, ".svn") or
                    std.mem.eql(u8, entry.basename, ".hg")
                )
            ) {
                continue;
            }
            if (self.ignored(entry.basename)) {
                continue;
            }
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = if (entry.kind == .directory) .directory else .file,
                .level = entry.depth(),
                .status = .left_only,
                .parent = null,
                .children = .empty,
                .name = try self.allocator.dupe(u8, entry.basename),
                .path = try self.allocator.dupe(u8, entry.path),
            };
            try self.nodes.append(self.allocator, node);
            try self.map.put(node.path, node);
            if (node.level == 1) {
                try self.roots.append(self.allocator, node);
            }
            if (entry.kind == .directory) {
                try walker_left.enter(self.io, entry);
            }
        }
        var walker_right = try self.rgt.walkSelectively(self.allocator);
        defer walker_right.deinit();
        while (try walker_right.next(self.io)) |entry| {
            if (entry.kind != .directory and entry.kind != .file) {
                continue;
            }
            if (
                entry.kind == .directory and (
                    std.mem.eql(u8, entry.basename, ".git") or
                    std.mem.eql(u8, entry.basename, ".svn") or
                    std.mem.eql(u8, entry.basename, ".hg")
                )
            ) {
                continue;
            }
            if (self.ignored(entry.basename)) {
                continue;
            }
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = if (entry.kind == .directory) .directory else .file,
                .level = entry.depth(),
                .status = .right_only,
                .parent = null,
                .children = .empty,
                .name = try self.allocator.dupe(u8, entry.basename),
                .path = try self.allocator.dupe(u8, entry.path),
            };
            if (!self.map.contains(entry.path)) {
                try self.nodes.append(self.allocator, node);
                try self.map.put(node.path, node);
                if (node.level == 1) {
                    try self.roots.append(self.allocator, node);
                }
                if (entry.kind == .directory) {
                    try walker_right.enter(self.io, entry);
                }
                continue;
            }
            defer {
                self.allocator.free(node.name);
                self.allocator.free(node.path);
                self.allocator.destroy(node);
            }
            var orig = self.map.get(entry.path) orelse return error.notfound;
            if (orig.type != node.type) {
                orig.type = .mismatch;
                orig.status = .different;
                continue;
            }
            orig.status = .unknown; //if (orig.type == .directory) .same else .unknown;
            if (entry.kind == .directory) {
                try walker_right.enter(self.io, entry);
            }
        }
        std.mem.sort(*Node, self.nodes.items, {}, struct {
            fn lessThan(_: void, a: *Node, b: *Node) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.lessThan);
        for (self.nodes.items) |item| {
            const path = if (item.path.len - item.name.len > 0) item.path[0..item.path.len - item.name.len - 1] else "";
            if (!self.map.contains(path)) {
                continue;
            }
            var parent = self.map.get(path) orelse return error.notfound;
            try parent.children.append(self.allocator, item);
            item.parent = parent;
        }
        for (self.nodes.items) |item| {
            std.mem.sort(*Node, item.children.items, {}, struct {
                fn lessThan(_: void, a: *Node, b: *Node) bool {
                    if (a.type != .file and b.type == .file) return true;
                    if (b.type != .file and a.type == .file) return false;
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lessThan);
        }
        std.mem.sort(*Node, self.roots.items, {}, struct {
            fn lessThan(_: void, a: *Node, b: *Node) bool {
                if (a.type != .file and b.type == .file) return true;
                if (b.type != .file and a.type == .file) return false;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        for (self.nodes.items) |item| {
            if (item.type == .file and item.status == .unknown) {
                self.diff(item);
            }
        }
    }
    pub fn diff(self: *Diff, node: *Node) void {
        if (node.type != .file or node.status == .left_only or node.status == .right_only) return;
        const file_lft: ?std.Io.File = self.lft.openFile(self.io, node.path, .{}) catch null;
        defer if (file_lft) |f| f.close(self.io);
        const file_rgt: ?std.Io.File = self.rgt.openFile(self.io, node.path, .{}) catch null;
        defer if (file_rgt) |f| f.close(self.io);
        if (file_lft == null and file_rgt == null) {
            node.status = .unknown;
            return;
        }
        if (file_rgt == null) {
            node.status = .left_only;
            return;
        }
        if (file_lft == null) {
            node.status = .right_only;
            return;
        }
        const stat_lft = file_lft.?.stat(self.io) catch {
            node.status = .unknown;
            return;
        };
        const stat_rgt = file_rgt.?.stat(self.io) catch {
            node.status = .unknown;
            return;
        };
        if (stat_lft.size != stat_rgt.size) {
            node.status = .different;
            return;
        }
        var buf_lft: [128 * 1024]u8 = undefined;
        var buf_rgt: [128 * 1024]u8 = undefined;
        while (true) {
            const lr = file_lft.?.readStreaming(self.io, &.{&buf_lft}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => {
                    node.status = .unknown;
                    return;
                }
            };
            const rr = file_rgt.?.readStreaming(self.io, &.{&buf_rgt}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => {
                    node.status = .unknown;
                    return;
                }
            };
            if (lr != rr) {
                node.status = .different;
                return;
            }
            if (lr == 0) {
                node.status = .same;
                return;
            }
            if (!std.mem.eql(u8, buf_lft[0..lr], buf_rgt[0..rr])) {
                node.status = .different;
                return;
            }
        }
    }
    pub fn deleteLeft(self: *Diff, node: *Node) !void {
        try self.lft.deleteTree(self.io, node.path);
        try self.refresh();
    }
    pub fn deleteRight(self: *Diff, node: *Node) !void {
        try self.rgt.deleteTree(self.io, node.path);
        try self.refresh();
    }
    pub fn copyToRight(self: *Diff, node: *Node) !void {
        try self.copyToRightRecursive(node);
        try self.refresh();
    }
    fn copyToRightRecursive(self: *Diff, node: *Node) !void {
        if (node.type == .directory) {
            for (node.children.items) |item| {
                try self.copyToRightRecursive(item);
            }
            return;
        }
        try self.lft.copyFile(node.path, self.rgt, node.path, self.io, .{ .make_path = true });
    }
    pub fn copyToLeft(self: *Diff, node: *Node) !void {
        try self.copyToLeftRecursive(node);
        try self.refresh();
    }
    fn copyToLeftRecursive(self: *Diff, node: *Node) !void {
        if (node.type == .directory) {
            for (node.children.items) |item| {
                try self.copyToLeftRecursive(item);
            }
            return;
        }
        try self.rgt.copyFile(node.path, self.lft, node.path, self.io, .{ .make_path = true });
    }
    fn match(pattern: []const u8, name: []const u8) bool {
        var p: usize = 0;
        var n: usize = 0;
        var star: ?usize = null;
        var retry: usize = 0;
        while (n < name.len) {
            if (p < pattern.len and pattern[p] == name[n]) {
                p += 1;
                n += 1;
            } else if (p < pattern.len and pattern[p] == '*') {
                star = p;
                p += 1;
                retry = n;
            } else if (star) |s| {
                p = s + 1;
                retry += 1;
                n = retry;
            } else {
                return false;
            }
        }
        while (p < pattern.len and pattern[p] == '*')
            p += 1;
        return p == pattern.len;
    }
    fn ignored(self: *Diff, name: []const u8) bool {
        for (self.ignores) |pattern| {
            if (match(pattern, name)) {
                return true;
            }
        }
        return false;
    }
};

