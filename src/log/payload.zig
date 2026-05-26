const std = @import("std");
const command = @import("command.zig");

/// A Command with its log index and election term.
pub const Payload = struct {
    index: u64,
    term: u64,
    cmd: command.Command,

    pub fn init(index: u64, term: u64, cmd: command.Command) Payload {
        return Payload{
            .index = index,
            .term = term,
            .cmd = cmd,
        };
    }

    pub fn dupe(self: Payload, allocator: std.mem.Allocator) !Payload {
        const cmd = try self.cmd.dupe(allocator);
        return init(self.index, self.term, cmd);
    }

    pub fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
        self.cmd.deinit(allocator);
    }

    pub fn serialize(self: Payload, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u64, self.index, .little);
        try writer.writeInt(u64, self.term, .little);
        try self.cmd.serialize(writer);
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Payload {
        const index = try reader.takeInt(u64, .little);
        const term = try reader.takeInt(u64, .little);
        const cmd = try command.Command.deserialize(allocator, reader);

        return Payload{
            .index = index,
            .term = term,
            .cmd = cmd,
        };
    }
};

test "payload serialize" {
    const allocator = std.testing.allocator;

    const setCmd = command.Command{ .set = try command.SetCommand.init(allocator, "hello", "world") };
    var cmd = Payload.init(1, 1, setCmd);
    defer cmd.deinit(allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try cmd.serialize(&writer);

    const expected = [_]u8{
        1, 0, 0, 0, 0, 0, 0, 0, // index
        1, 0, 0, 0, 0, 0, 0, 0, // term
        0, // tag = set
        5, 0, 0, 0, // key_len
        'h', 'e', 'l', 'l', 'o', // key
        5, 0, 0, 0, // val_len
        'w', 'o', 'r', 'l', 'd', // value
    };

    try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
}

test "payload round trip" {
    const allocator = std.testing.allocator;

    const cmd = command.Command{ .set = try command.SetCommand.init(allocator, "delta", "echo") };
    var original = Payload.init(7, 42, cmd);
    defer original.deinit(allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try original.serialize(&writer);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var decoded = try Payload.deserialize(allocator, &reader);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(original.index, decoded.index);
    try std.testing.expectEqual(original.term, decoded.term);
    try std.testing.expectEqualSlices(u8, original.cmd.set.key, decoded.cmd.set.key);
    try std.testing.expectEqualSlices(u8, original.cmd.set.value, decoded.cmd.set.value);
}
