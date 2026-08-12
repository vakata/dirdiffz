const std = @import("std");

pub const Type = enum {
    file,
    directory,
    mismatch,
};
pub const State = enum {
    none,
    opened,
    closed
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
    path: []const u8,
    name: []const u8,
    level: usize,
    state: State,
    status: Status,
    parent: ?*Node,
    children: std.ArrayList(*Node),
    has_s: bool,
    has_d: bool,
    has_o: bool,
};

pub const Diff = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lft: std.Io.Dir,
    rgt: std.Io.Dir,
    map: std.StringHashMap(*Node),
    nodes: std.ArrayList(*Node),
    roots: std.ArrayList(*Node),
    vis: std.ArrayList(*Node),
    s: bool,
    d: bool,
    o: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, lft: std.Io.Dir, rgt: std.Io.Dir) !*Diff {
        const self = try allocator.create(Diff);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .lft = lft,
            .rgt = rgt,
            .map = std.StringHashMap(*Node).init(allocator),
            .nodes = .empty,
            .roots = .empty,
            .vis = .empty,
            .s = true,
            .d = true,
            .o = true
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
        self.vis.deinit(self.allocator);
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
        self.vis.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        var walker_left = try self.lft.walk(self.allocator);
        defer walker_left.deinit();
        while (try walker_left.next(self.io)) |entry| {
            if (entry.kind != .directory and entry.kind != .file) {
                continue;
            }
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = if (entry.kind == .directory) .directory else .file,
                .name = try self.allocator.dupe(u8, entry.basename),
                .path = try self.allocator.dupe(u8, entry.path),
                .level = entry.depth(),
                .state = if (entry.kind == .directory) .closed else .none,
                .status = .left_only,
                .parent = null,
                .children = .empty,
                .has_s = false,
                .has_d = false,
                .has_o = false,
            };
            try self.nodes.append(self.allocator, node);
            try self.map.put(node.path, node);
            if (node.level == 1) {
                try self.roots.append(self.allocator, node);
            }
        }
        var walker_right = try self.rgt.walk(self.allocator);
        defer walker_right.deinit();
        while (try walker_right.next(self.io)) |entry| {
            if (entry.kind != .directory and entry.kind != .file) {
                continue;
            }
            const node = try self.allocator.create(Node);
            node.* = .{
                .type = if (entry.kind == .directory) .directory else .file,
                .name = try self.allocator.dupe(u8, entry.basename),
                .path = try self.allocator.dupe(u8, entry.path),
                .level = entry.depth(),
                .state = if (entry.kind == .directory) .closed else .none,
                .status = .right_only,
                .parent = null,
                .children = .empty,
                .has_s = false,
                .has_d = false,
                .has_o = false,
            };
            if (!self.map.contains(entry.path)) {
                try self.nodes.append(self.allocator, node);
                try self.map.put(node.path, node);
                if (node.level == 1) {
                    try self.roots.append(self.allocator, node);
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
                orig.state = .closed;
                continue;
            }
            orig.status = if (orig.type == .directory) .same else .unknown;
            self.diff(orig, false);
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
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lessThan);
        }
        std.mem.sort(*Node, self.roots.items, {}, struct {
            fn lessThan(_: void, a: *Node, b: *Node) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        _ = try self.list();
    }
    pub fn list(self: *Diff) !*std.ArrayList(*Node) {
        self.vis.clearRetainingCapacity();
        std.mem.sort(*Node, self.roots.items, {}, struct {
            fn lessThan(_: void, a: *Node, b: *Node) bool {
                if (a.type != .file and b.type == .file) return true;
                if (b.type != .file and a.type == .file) return false;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        for (self.roots.items) |item| {
            _ = self.down(item);
        }
        for (self.roots.items) |item| {
            try self.process(item);
        }
        return &self.vis;
    }
    fn process(self: *Diff, node: *Node) !void {
        const add = (self.s and (node.status == .same or node.has_s)) or
            (self.d and ((node.type == .file and node.status == .different) or node.type == .mismatch or node.status == .unknown or node.has_d)) or
            (self.o and (node.status == .left_only or node.status == .right_only or node.has_o));
        if (!add) return;
        try self.vis.append(self.allocator, node);
        if (node.state == .closed) return;
        std.mem.sort(*Node, node.children.items, {}, struct {
            fn lessThan(_: void, a: *Node, b: *Node) bool {
                if (a.type != .file and b.type == .file) return true;
                if (b.type != .file and a.type == .file) return false;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        for (node.children.items) |item| {
            try self.process(item);
        }
    }
    pub fn openAll(self: *Diff) !void {
        for (self.nodes.items) |item| {
            if (item.type == .directory or item.type == .mismatch) {
                item.state = .opened;
            }
        }
        _ = try self.list();
    }
    pub fn closeAll(self: *Diff) !void {
        for (self.nodes.items) |item| {
            if (item.type == .directory or item.type == .mismatch) {
                item.state = .closed;
            }
        }
        _ = try self.list();
    }
    pub fn open(self: *Diff, node: *Node) !void {
        if (node.type == .directory or node.type == .mismatch) {
            node.state = .opened;
            _ = try self.list();
        }
    }
    pub fn close(self: *Diff, node: *Node) !void {
        if (node.type == .directory or node.type == .mismatch) {
            node.state = .closed;
            _ = try self.list();
        }
    }
    pub fn toggle(self: *Diff, node: *Node) !void {
        if (node.type == .directory or node.type == .mismatch) {
            node.state = if (node.state == .closed) .opened else .closed;
            _ = try self.list();
        }
    }
    pub fn diff(self: *Diff, node: *Node, sync: bool) void {
        if (node.type == .mismatch) {
            node.status = .different;
            return;
        }
        if (node.type == .directory) {
            return;
        }
        const file_lft: ?std.Io.File = self.lft.openFile(self.io, node.path, .{}) catch null;
        defer if (file_lft) |f| f.close(self.io);
        const file_rgt: ?std.Io.File = self.rgt.openFile(self.io, node.path, .{}) catch null;
        defer if (file_rgt) |f| f.close(self.io);
        defer {
            if (sync) {
                if (node.parent) |p| self.up(p);
                for (self.roots.items) |item| {
                    _ = self.down(item);
                }
            }
        }
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
    fn up(self: *Diff, parent: *Node) void {
        var calculated: Status = .same;
        if (parent.status == .left_only or parent.status == .right_only) {
            return;
        }
        var lo: bool = true;
        var ro: bool = true;
        for (parent.children.items) |item| {
            if (item.status == .unknown) {
                calculated = .different;
                break;
            }
            if (item.status != .left_only) {
                lo = false;
            }
            if (item.status != .right_only) {
                ro = false;
            }
            if (item.status != .same) {
                calculated = .different;
            }
        }
        if (lo and parent.children.items.len > 0) calculated = .left_only;
        if (ro and parent.children.items.len > 0) calculated = .right_only;
        if (parent.status != calculated) {
            parent.status = calculated;
            if (parent.parent) |p| {
                self.up(p);
            }
        }
    }
    fn down(self: *Diff, node: *Node) Status {
        if (
            node.type == .file or
            node.type == .mismatch or
            node.status == .left_only or
            node.status == .right_only
        ) {
            return node.status;
        }
        if (node.children.items.len == 0) {
            node.status = .same;
            return .same;
        }
        // only dirs with files from here down
        node.has_s = false;
        node.has_d = false;
        node.has_o = false;
        var calculated: Status = .same;
        var lo: bool = true;
        var ro: bool = true;
        for (node.children.items) |item| {
            const status = self.down(item);
            if (status != .left_only) {
                lo = false;
            }
            if (status != .right_only) {
                ro = false;
            }
            if (status != .same) {
                calculated = .different;
            }
            if (status == .left_only or status == .right_only) {
                node.has_o = true;
            }
            if (status == .same) {
                node.has_s = true;
            }
            if (item.has_d or (item.type == .file and status == .different) or item.type == .mismatch) {
                node.has_d = true;
            }
        }
        if (lo) calculated = .left_only;
        if (ro) calculated = .right_only;
        node.status = calculated;
        return calculated;
    }
    pub fn filter(self: *Diff, s: bool, d: bool, o: bool) !void {
        self.s = s;
        self.d = d;
        self.o = o;
        _ = try self.list();
    }
    pub fn deleteLeft(self: *Diff, node: *Node) !void {
        try self.lft.deleteTree(self.io, node.path);
    }
    pub fn deleteRight(self: *Diff, node: *Node) !void {
        try self.rgt.deleteTree(self.io, node.path);
    }
    pub fn copyToRight(self: *Diff, node: *Node) !void {
        if (node.type == .directory) {
            for (node.children.items) |item| {
                try self.copyToRight(item);
            }
            return;
        }
        try self.lft.copyFile(node.path, self.rgt, node.path, self.io, .{ .make_path = true });
    }
    pub fn copyToLeft(self: *Diff, node: *Node) !void {
        if (node.type == .directory) {
            for (node.children.items) |item| {
                try self.copyToLeft(item);
            }
            return;
        }
        try self.rgt.copyFile(node.path, self.lft, node.path, self.io, .{ .make_path = true });
    }
};

