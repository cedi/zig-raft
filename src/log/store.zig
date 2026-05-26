const std = @import("std");
const payload = @import("payload.zig");
const command = @import("command.zig");

/// In-memory Raft log. Takes ownership of appended entries.
pub const Log = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(payload.Payload),

    pub fn init(allocator: std.mem.Allocator) Log {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Log) void {
        for (self.entries.items) |*p| p.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn append(self: *Log, term: u64, p: command.Command) !void {
        var owned = p;
        errdefer owned.deinit(self.allocator);

        const item = payload.Payload.init(self.len(), term, p);
        try self.entries.append(self.allocator, item);
    }

    pub fn len(self: *const Log) usize {
        return self.entries.items.len;
    }

    pub fn at(self: *const Log, index: usize) ?*const payload.Payload {
        if (index >= self.entries.items.len) return null;
        return &self.entries.items[index];
    }

    /// Remove entries from `from` onward, freeing their owned memory.
    pub fn truncateFrom(self: *Log, from: usize) void {
        for (self.entries.items[from..]) |*p| p.deinit(self.allocator);
        self.entries.shrinkRetainingCapacity(from);
    }
};

test "empty log has length 0" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 0), log.len());
    try std.testing.expect(log.at(0) == null);
}

test "log appends and reads back" {
    const allocator = std.testing.allocator;

    var log = Log.init(allocator);
    defer log.deinit();

    const set_cmd = command.Command{ .set = try command.SetCommand.init(allocator, "k1", "v1") };
    try log.append(0, set_cmd);

    const del_cmd = command.Command{ .delete = try command.DeleteCommand.init(allocator, "k1") };
    try log.append(0, del_cmd);

    try std.testing.expectEqual(@as(usize, 2), log.len());

    const first = log.at(0).?;
    try std.testing.expectEqual(@as(u64, 0), first.index);
    try std.testing.expectEqual(@as(u64, 0), first.term);
    try std.testing.expectEqualSlices(u8, "k1", first.cmd.set.key);
    try std.testing.expectEqualSlices(u8, "v1", first.cmd.set.value);

    const second = log.at(1).?;
    try std.testing.expectEqual(@as(u64, 1), second.index);
    try std.testing.expectEqualSlices(u8, "k1", second.cmd.delete.key);

    try std.testing.expect(log.at(2) == null);
}
