const std = @import("std");
const log = @import("log");

/// In-memory key-value state machine. All commands go through `apply`;
/// linearization is determined by apply order.
pub const Store = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Writes return null. Reads return a slice borrowed from the store,
    /// valid until the next mutation.
    pub fn apply(self: *Store, cmd: log.Command) !?[]const u8 {
        switch (cmd) {
            .set => |s| {
                try self.setVal(s.key, s.value);
                return null;
            },
            .delete => |d| {
                self.deleteVal(d.key);
                return null;
            },
            .get => |g| return self.map.get(g.key),
        }
    }

    /// Build a Get command and apply it directly (bypasses the log).
    pub fn get(self: *Store, key: []const u8) !?[]const u8 {
        var cmd = log.Command{ .get = try log.GetCommand.init(self.allocator, key) };
        defer cmd.deinit(self.allocator);
        return self.apply(cmd);
    }

    pub fn len(self: *const Store) usize {
        return self.map.count();
    }

    fn setVal(self: *Store, key: []const u8, value: []const u8) !void {
        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.map.put(key_copy, value_copy);
    }

    fn deleteVal(self: *Store, key: []const u8) void {
        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }
};

test "apply set then get" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    var cmd = log.Command{ .set = try log.SetCommand.init(allocator, "foo", "bar") };
    defer cmd.deinit(allocator);

    _ = try store.apply(cmd);

    try std.testing.expectEqualSlices(u8, "bar", (try store.get("foo")).?);
    try std.testing.expect((try store.get("missing")) == null);
}

test "apply set replaces previous value" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    {
        var cmd = log.Command{ .set = try log.SetCommand.init(allocator, "foo", "bar") };
        defer cmd.deinit(allocator);
        _ = try store.apply(cmd);
    }
    {
        var cmd = log.Command{ .set = try log.SetCommand.init(allocator, "foo", "barfoo") };
        defer cmd.deinit(allocator);
        _ = try store.apply(cmd);
    }

    try std.testing.expectEqualSlices(u8, "barfoo", (try store.get("foo")).?);
    try std.testing.expectEqual(@as(usize, 1), store.len());
}

test "apply delete removes value" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    {
        var cmd = log.Command{ .set = try log.SetCommand.init(allocator, "k", "v") };
        defer cmd.deinit(allocator);
        _ = try store.apply(cmd);
    }
    {
        var cmd = log.Command{ .delete = try log.DeleteCommand.init(allocator, "k") };
        defer cmd.deinit(allocator);
        _ = try store.apply(cmd);
    }

    try std.testing.expect((try store.get("k")) == null);
    try std.testing.expectEqual(@as(usize, 0), store.len());
}

test "apply get returns borrowed value" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    {
        var cmd = log.Command{ .set = try log.SetCommand.init(allocator, "k", "v") };
        defer cmd.deinit(allocator);
        _ = try store.apply(cmd);
    }

    var get_cmd = log.Command{ .get = try log.GetCommand.init(allocator, "k") };
    defer get_cmd.deinit(allocator);

    const result = try store.apply(get_cmd);
    try std.testing.expectEqualSlices(u8, "v", result.?);
}

test "replay log to derive state" {
    const allocator = std.testing.allocator;

    var raft_log = log.Log.init(allocator);
    defer raft_log.deinit();

    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "alice", "engineer") });
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "bob", "manager") });
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "alice", "principal") });
    try raft_log.append(0, .{ .delete = try log.DeleteCommand.init(allocator, "bob") });

    var store = Store.init(allocator);
    defer store.deinit();

    // replay loop
    for (0..raft_log.len()) |i| {
        _ = try store.apply(raft_log.at(i).?.cmd);
    }

    try std.testing.expectEqualSlices(u8, "principal", (try store.get("alice")).?);
    try std.testing.expect((try store.get("bob")) == null);
    try std.testing.expectEqual(@as(usize, 1), store.len());
}

test "get goes through apply (linearization point)" {
    const allocator = std.testing.allocator;

    var raft_log = log.Log.init(allocator);
    defer raft_log.deinit();

    // interleaved writes and reads
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "counter", "1") });
    try raft_log.append(0, .{ .get = try log.GetCommand.init(allocator, "counter") });
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "counter", "2") });
    try raft_log.append(0, .{ .get = try log.GetCommand.init(allocator, "counter") });

    var store = Store.init(allocator);
    defer store.deinit();

    // get at index 1 sees write at index 0; get at index 3 sees write at index 2
    const expected_reads = [_]?[]const u8{ null, "1", null, "2" };
    for (0..raft_log.len()) |i| {
        const result = try store.apply(raft_log.at(i).?.cmd);
        if (expected_reads[i]) |expected| {
            try std.testing.expectEqualSlices(u8, expected, result.?);
        } else {
            try std.testing.expect(result == null);
        }
    }
}
