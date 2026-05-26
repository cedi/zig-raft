const std = @import("std");

/// Set a key to a specific value
pub const SetCommand = struct {
    key: []u8,
    value: []u8,

    pub fn init(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !SetCommand {
        return SetCommand{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        };
    }

    pub fn dupe(self: SetCommand, allocator: std.mem.Allocator) !SetCommand {
        return init(allocator, self.key, self.value);
    }

    pub fn deinit(self: *SetCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }

    pub fn serialize(self: SetCommand, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u32, @intCast(self.key.len), .little);
        try writer.writeAll(self.key);
        try writer.writeInt(u32, @intCast(self.value.len), .little);
        try writer.writeAll(self.value);
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: *std.Io.Reader) !SetCommand {
        const key_len = try reader.takeInt(u32, .little);
        const key = try allocator.alloc(u8, key_len);
        errdefer allocator.free(key);

        try reader.readSliceAll(key);

        const val_len = try reader.takeInt(u32, .little);
        const val = try allocator.alloc(u8, val_len);
        errdefer allocator.free(val);

        try reader.readSliceAll(val);

        return SetCommand{
            .key = key,
            .value = val,
        };
    }
};

/// Delete a key
pub const DeleteCommand = struct {
    key: []u8,

    pub fn init(allocator: std.mem.Allocator, key: []const u8) !DeleteCommand {
        return DeleteCommand{
            .key = try allocator.dupe(u8, key),
        };
    }

    pub fn dupe(self: DeleteCommand, allocator: std.mem.Allocator) !DeleteCommand {
        return init(allocator, self.key);
    }

    pub fn deinit(self: *DeleteCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }

    pub fn serialize(self: DeleteCommand, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u32, @intCast(self.key.len), .little);
        try writer.writeAll(self.key);
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: *std.Io.Reader) !DeleteCommand {
        const key_len = try reader.takeInt(u32, .little);
        const key = try allocator.alloc(u8, key_len);
        errdefer allocator.free(key);

        try reader.readSliceAll(key);

        return DeleteCommand{
            .key = key,
        };
    }
};

/// Read a key. Goes through the log like writes, making it trivially linearizable.
pub const GetCommand = struct {
    key: []u8,

    pub fn init(allocator: std.mem.Allocator, key: []const u8) !GetCommand {
        return GetCommand{
            .key = try allocator.dupe(u8, key),
        };
    }

    pub fn dupe(self: GetCommand, allocator: std.mem.Allocator) !GetCommand {
        return init(allocator, self.key);
    }

    pub fn deinit(self: *GetCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }

    pub fn serialize(self: GetCommand, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u32, @intCast(self.key.len), .little);
        try writer.writeAll(self.key);
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: *std.Io.Reader) !GetCommand {
        const key_len = try reader.takeInt(u32, .little);
        const key = try allocator.alloc(u8, key_len);
        errdefer allocator.free(key);

        try reader.readSliceAll(key);

        return GetCommand{
            .key = key,
        };
    }
};

/// Wire-format tag for Command deserialization.
pub const CommandTag = enum(u8) {
    set = 0,
    delete = 1,
    get = 2,
};

/// A single Raft command (set, delete, or get).
pub const Command = union(CommandTag) {
    set: SetCommand,
    delete: DeleteCommand,
    get: GetCommand,

    pub fn dupe(self: Command, allocator: std.mem.Allocator) !Command {
        return switch (self) {
            .set => |s| .{ .set = try s.dupe(allocator) },
            .delete => |d| .{ .delete = try d.dupe(allocator) },
            .get => |g| .{ .get = try g.dupe(allocator) },
        };
    }

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .set => |*set| set.deinit(allocator),
            .delete => |*del| del.deinit(allocator),
            .get => |*get| get.deinit(allocator),
        }
    }

    /// Serialize to wire format.
    pub fn serialize(self: Command, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u8, @intFromEnum(self), .little);
        switch (self) {
            .set => |set| try set.serialize(writer),
            .delete => |del| try del.serialize(writer),
            .get => |get| try get.serialize(writer),
        }
    }

    /// Deserialize from wire format.
    pub fn deserialize(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Command {
        const tag_byte = try reader.takeInt(u8, .little);
        const tag = std.enums.fromInt(CommandTag, tag_byte) orelse return error.InvalidCommandTag;
        return switch (tag) {
            .set => .{ .set = try SetCommand.deserialize(allocator, reader) },
            .delete => .{ .delete = try DeleteCommand.deserialize(allocator, reader) },
            .get => .{ .get = try GetCommand.deserialize(allocator, reader) },
        };
    }
};

test "set command serialize" {
    const allocator = std.testing.allocator;

    var cmd = try SetCommand.init(allocator, "hello", "world");
    defer cmd.deinit(allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try cmd.serialize(&writer);

    const expected = [_]u8{
        5, 0, 0, 0, // key_len
        'h', 'e', 'l', 'l', 'o', // key
        5, 0, 0, 0, // val_len
        'w', 'o', 'r', 'l', 'd', // value
    };

    try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
}

test "delete command serialize" {
    const allocator = std.testing.allocator;

    var cmd = try DeleteCommand.init(allocator, "hello");
    defer cmd.deinit(allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try cmd.serialize(&writer);

    const expected = [_]u8{
        5, 0, 0, 0, // key_len
        'h', 'e', 'l', 'l', 'o', // key
    };

    try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
}

test "get command serialize" {
    const allocator = std.testing.allocator;

    var cmd = try GetCommand.init(allocator, "hello");
    defer cmd.deinit(allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try cmd.serialize(&writer);

    const expected = [_]u8{
        5, 0, 0, 0, // key_len
        'h', 'e', 'l', 'l', 'o', // key
    };

    try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
}

test "command serialize" {
    const allocator = std.testing.allocator;

    var setCmd = Command{ .set = try SetCommand.init(allocator, "hello", "world") };
    defer setCmd.deinit(allocator);

    var setBuf: [64]u8 = undefined;
    var setWriter = std.Io.Writer.fixed(&setBuf);

    try setCmd.serialize(&setWriter);

    const expectedSet = [_]u8{
        0, // tag = set
        5, 0, 0, 0, // key_len
        'h', 'e', 'l', 'l', 'o', // key
        5, 0, 0, 0, // val_len
        'w', 'o', 'r', 'l', 'd', // value
    };

    try std.testing.expectEqualSlices(u8, &expectedSet, setWriter.buffered());

    var delCmd = Command{ .delete = try DeleteCommand.init(allocator, "hello") };
    defer delCmd.deinit(allocator);

    var delBuf: [64]u8 = undefined;
    var delWriter = std.Io.Writer.fixed(&delBuf);

    try delCmd.serialize(&delWriter);

    const expectedDel = [_]u8{
        1, // tag = delete
        5, 0, 0, 0, // key_len
        'h', 'e', 'l', 'l', 'o', // key
    };

    try std.testing.expectEqualSlices(u8, &expectedDel, delWriter.buffered());
}

test "command round trip set" {
    const allocator = std.testing.allocator;

    var original = Command{ .set = try SetCommand.init(allocator, "foo", "bar") };
    defer original.deinit(allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try original.serialize(&writer);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var decoded = try Command.deserialize(allocator, &reader);
    defer decoded.deinit(allocator);

    try std.testing.expectEqualSlices(u8, original.set.key, decoded.set.key);
    try std.testing.expectEqualSlices(u8, original.set.value, decoded.set.value);
}

test "command round trip delete" {
    const allocator = std.testing.allocator;

    var original = Command{ .delete = try DeleteCommand.init(allocator, "foobar") };
    defer original.deinit(allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try original.serialize(&writer);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var decoded = try Command.deserialize(allocator, &reader);
    defer decoded.deinit(allocator);

    try std.testing.expectEqualSlices(u8, original.delete.key, decoded.delete.key);
}

test "command round trip get" {
    const allocator = std.testing.allocator;

    var original = Command{ .get = try GetCommand.init(allocator, "lookup") };
    defer original.deinit(allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try original.serialize(&writer);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var decoded = try Command.deserialize(allocator, &reader);
    defer decoded.deinit(allocator);

    try std.testing.expectEqualSlices(u8, original.get.key, decoded.get.key);
}

test "command deserialize rejects unknown tag" {
    const bytes = [_]u8{ 42, 0, 0, 0, 0 };
    var reader = std.Io.Reader.fixed(&bytes);
    try std.testing.expectError(
        error.InvalidCommandTag,
        Command.deserialize(std.testing.allocator, &reader),
    );
}
