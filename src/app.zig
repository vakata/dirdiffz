const std = @import("std");
const Diff = @import("diff.zig").Diff;
const Node = @import("diff.zig").Node;

pub const Confirm = enum {
    nothing,
    copy_left,
    copy_right,
    delete_left,
    delete_right,
};
pub const Filter = struct {
    same: bool,
    different: bool,
    orphan: bool
};
pub const Meta = struct {
    has_same: bool,
    has_different: bool,
    has_orphan: bool
};
pub const State = struct {
    filter: Filter,
    selected: ?[]u8,
    opened: std.StringHashMap(void),
    scrolled: usize,
    confirm: Confirm,
    help: bool
};
pub const App = struct {
    allocator: std.mem.Allocator,
    diff: *Diff,
    map: std.StringHashMap(Meta),
    nodes: std.ArrayList(*Node),
    state: State,
    dirs: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, diff: *Diff, dirs: []const []const u8) !*App {
        const self = try allocator.create(App);
        self.* = .{
            .allocator = allocator,
            .diff = diff,
            .map = std.StringHashMap(Meta).init(allocator),
            .nodes = .empty,
            .dirs = dirs,
            .state = .{
                .filter = .{
                    .same = true,
                    .different = true,
                    .orphan = true,
                },
                .selected = null,
                .opened = std.StringHashMap(void).init(allocator),
                .confirm = .nothing,
                .scrolled = 0,
                .help = false
            },
        };
        try self.refresh();
        return self;
    }
    pub fn deinit(self: *App) void {
        self.map.deinit();
        self.nodes.deinit(self.allocator);
        var it = self.state.opened.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.state.opened.deinit();
        if (self.state.selected) |s| {
             self.allocator.free(s);
        }
        self.allocator.destroy(self);
    }
    pub fn selected(self: *App) ?*Node {
        if (self.state.selected) |s| {
            return self.entry(s);
        }
        return null;
    }
    pub fn index(self: *App) usize {
        var i: usize = 0;
        if (self.selected()) |sel| {
            for (self.nodes.items,0..) |item,c| {
                if (std.mem.eql(u8, sel.path, item.path)) {
                    i = c;
                    break;
                }
            }
        }
        return i;
    }
    pub fn prev(self: *App) !void {
        var i: usize = self.index();
        if (i > 0) {
            i -= 1;
            if (self.state.selected) |s| {
                self.allocator.free(s);
            }
            self.state.selected = try self.allocator.dupe(u8, self.nodes.items[i].path);
        }
    }
    pub fn next(self: *App) !void {
        var i: usize = self.index();
        if (self.nodes.items.len > 0 and i < self.nodes.items.len - 1) {
            i += 1;
            if (self.state.selected) |s| {
                self.allocator.free(s);
            }
            self.state.selected = try self.allocator.dupe(u8, self.nodes.items[i].path);
        }
    }
    fn entry(self: *App, path: []const u8) ?*Node {
        return self.diff.map.get(path);
    }
    fn meta(self: *App, node: *Node) !*Meta {
        if (!self.map.contains(node.path)) {
            const m: Meta = .{ .has_different = false, .has_same = false, .has_orphan = false };
            try self.map.put(node.path, m);
        }
        return self.map.getPtr(node.path).?;
    }
    fn refresh(self: *App) !void {
        self.map.clearRetainingCapacity();
        for (self.diff.roots.items) |root| {
            _ = try self.refreshRecursive(root);
        }
        try self.flatten();
    }
    fn refreshRecursive(self: *App, node: *Node) !*Meta {
        var m = try self.meta(node);
        if (
            node.type == .file or
            node.type == .mismatch or
            node.status == .left_only or
            node.status == .right_only
        ) {
            return m;
        }
        m.has_same = false;
        m.has_different = false;
        m.has_orphan = false;
        if (node.children.items.len == 0) {
            node.status = .same;
            m.has_same = true;
            return m;
        }
        // only dirs with children from here down
        for (node.children.items) |item| {
            const i = try self.refreshRecursive(item);
            m = try self.meta(node);
            if (i.has_orphan or item.status == .left_only or item.status == .right_only) {
                m.has_orphan = true;
            }
            if (i.has_same or (item.type == .file and item.status == .same)) {
                m.has_same = true;
            }
            if (i.has_different or (item.type == .file and item.status == .different) or item.type == .mismatch) {
                m.has_different = true;
            }
        }
        if (m.has_same and !m.has_different and !m.has_orphan and node.status == .unknown) {
            node.status = .same;
        }
        return m;
    }
    fn flatten(self: *App) !void {
        self.nodes.clearRetainingCapacity();
        // build flat list
        for (self.diff.roots.items) |item| {
            try self.flattenRecursive(item);
        }
        // check if selection is still valid
        if (self.state.selected) |s| {
            var f: bool = false;
            for (self.nodes.items) |item| {
                if (std.mem.eql(u8, item.path, s)) {
                    f = true;
                    break;
                }
            }
            if (!f) {
                self.allocator.free(s);
                self.state.selected = null;
            }
        }
        if (self.state.selected == null and self.nodes.items.len > 0) {
            self.state.selected = try self.allocator.dupe(u8, self.nodes.items[0].path);
        }
    }
    fn flattenRecursive(self: *App, node: *Node) !void {
        const m = try self.meta(node);
        const s = (node.type == .file and node.status == .same) or m.has_same;
        const d = (node.type == .file and node.status == .different) or m.has_different or node.type == .mismatch;
        const o = (node.status == .left_only or node.status == .right_only) or m.has_orphan;
        if (
            (self.state.filter.same and s) or
            (self.state.filter.different and d) or
            (self.state.filter.orphan and o)
        ) {
            try self.nodes.append(self.allocator, node);
            if (!self.state.opened.contains(node.path)) return;
            for (node.children.items) |item| {
                try self.flattenRecursive(item);
            }
        }
    }

    // Operations
    pub fn openAll(self: *App) !void {
        var it = self.state.opened.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.state.opened.clearRetainingCapacity();
        for (self.diff.nodes.items) |item| {
            const key = try self.allocator.dupe(u8, item.path);
            try self.state.opened.put(key, {});
        }
        try self.flatten();
    }
    pub fn closeAll(self: *App) !void {
        var it = self.state.opened.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.state.opened.clearRetainingCapacity();
        try self.flatten();
    }
    pub fn open(self: *App) !void {
        if (self.state.selected) |path| {
            if (!self.state.opened.contains(path)) {
                const key = try self.allocator.dupe(u8, path);
                try self.state.opened.put(key, {});
            }
        }
        try self.flatten();
    }
    pub fn close(self: *App) !void {
        if (self.state.selected) |path| {
            if (self.state.opened.contains(path)) {
                if (self.state.opened.fetchRemove(path)) |item| {
                    self.allocator.free(item.key);
                }
            }
        }
        try self.flatten();
    }
    pub fn toggle(self: *App) !void {
        if (self.state.selected) |path| {
            if (self.state.opened.contains(path)) {
                self.state.opened.put(path, {}) catch {};
            } else {
                _ = self.state.opened.remove(path);
            }
        }
        try self.flatten();
    }
    pub fn clearFilters(self: *App) !void {
        self.state.filter.same = true;
        self.state.filter.different = true;
        self.state.filter.orphan = true;
        try self.flatten();
    }
    pub fn toggleSame(self: *App) !void {
        self.state.filter.same = !self.state.filter.same;
        try self.flatten();
    }
    pub fn toggleDifferent(self: *App) !void {
        self.state.filter.different = !self.state.filter.different;
        try self.flatten();
    }
    pub fn toggleOrphan(self: *App) !void {
        self.state.filter.orphan = !self.state.filter.orphan;
        try self.flatten();
    }
    pub fn toggleHelp(self: *App) void {
        self.state.help = !self.state.help;
    }
    pub fn diffable(self: *App) ?*Node {
        if (self.selected()) |node| {
            if (node.type == .file and node.status != .left_only and node.status != .right_only) {
                return node;
            }
        }
        return null;
    }

    pub fn reload(self: *App) !void {
        try self.diff.refresh();
        try self.refresh();
    }
    pub fn reloadFile(self: *App) !void {
        if (self.selected()) |item| {
            self.diff.diff(item);
            try self.refresh();
        }
    }
    pub fn copyToLeft(self: *App) !void {
        const item = self.selected() orelse return;
        if (self.state.confirm != .copy_left) {
            self.state.confirm = .copy_left;
            return;
        }
        self.state.confirm = .nothing;
        try self.diff.copyToLeft(item);
        try self.refresh();
    }
    pub fn copyToRight(self: *App) !void {
        const item = self.selected() orelse return;
        if (self.state.confirm != .copy_right) {
            self.state.confirm = .copy_right;
            return;
        }
        self.state.confirm = .nothing;
        try self.diff.copyToRight(item);
        try self.refresh();
    }
    pub fn deleteLeft(self: *App) !void {
        const item = self.selected() orelse return;
        if (self.state.confirm != .delete_left) {
            self.state.confirm = .delete_left;
            return;
        }
        self.state.confirm = .nothing;
        try self.diff.deleteLeft(item);
        try self.refresh();
    }
    pub fn deleteRight(self: *App) !void {
        const item = self.selected() orelse return;
        if (self.state.confirm != .delete_right) {
            self.state.confirm = .delete_right;
            return;
        }
        self.state.confirm = .nothing;
        try self.diff.deleteRight(item);
        try self.refresh();
    }
    pub fn left(self: *App) []const u8 {
        return self.dirs[0];
    }
    pub fn right(self: *App) []const u8 {
        return self.dirs[1];
    }
};
