const std = @import("std");
const payload = @import("payload.zig");
const command = @import("command.zig");

/// WAL entry: length-prefixed payload with CRC32 integrity check.
pub const Entry = struct {
    payload: payload.Payload,

    /// Takes ownership of `data`. Call `deinit(allocator)` with the same
    /// allocator that owns the payload's backing memory.
    pub fn init(data: payload.Payload) Entry {
        return Entry{ .payload = data };
    }

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }

    pub fn dupe(self: Entry, allocator: std.mem.Allocator) !Entry {
        return init(self.payload.dupe(allocator));
    }

    /// Serialize to wire format with CRC32 calculation.
    pub fn serialize(self: Entry, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try self.payload.serialize(&aw.writer);
        const bytes = aw.written();

        const length: u32 = @intCast(bytes.len);
        const crc = std.hash.Crc32.hash(bytes);

        try writer.writeInt(u32, length, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeAll(bytes);
    }

    /// Deserialize from wire format. Returns `error.CrcMismatch` on corruption.
    pub fn deserialize(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Entry {
        const length = try reader.takeInt(u32, .little);
        const crc = try reader.takeInt(u32, .little);

        // CRC must pass before we trust the payload bytes.
        const buffer = try allocator.alloc(u8, length);
        defer allocator.free(buffer);
        try reader.readSliceAll(buffer);

        if (std.hash.Crc32.hash(buffer) != crc) return error.CrcMismatch;

        var buf_reader = std.Io.Reader.fixed(buffer);
        const data = try payload.Payload.deserialize(allocator, &buf_reader);

        return Entry.init(data);
    }
};

test "entry serialize" {
    const allocator = std.testing.allocator;

    const cmd = command.Command{ .set = try command.SetCommand.init(allocator, "hello", "world") };
    const data = payload.Payload.init(1, 1, cmd);
    var entry = Entry.init(data);
    defer entry.deinit(allocator);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try entry.serialize(allocator, &writer);

    const payload_bytes = [_]u8{
        1, 0, 0, 0, 0, 0, 0, 0, // index (u64)
        1, 0, 0, 0, 0, 0, 0, 0, // term (u64)
        0, // tag = set
        5, 0, 0, 0, // key_len
        'h', 'e', 'l', 'l', 'o', // key
        5, 0, 0, 0, // val_len
        'w', 'o', 'r', 'l', 'd', // value
    };
    var expected_buf: [128]u8 = undefined;
    var ew = std.Io.Writer.fixed(&expected_buf);
    try ew.writeInt(u32, @intCast(payload_bytes.len), .little);
    try ew.writeInt(u32, std.hash.Crc32.hash(&payload_bytes), .little);
    try ew.writeAll(&payload_bytes);

    try std.testing.expectEqualSlices(u8, ew.buffered(), writer.buffered());
}

test "entry round trip" {
    const allocator = std.testing.allocator;

    const cmd = command.Command{ .delete = try command.DeleteCommand.init(allocator, "foxtrot") };
    const data = payload.Payload.init(99, 3, cmd);
    var original = Entry.init(data);
    defer original.deinit(allocator);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try original.serialize(allocator, &writer);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var decoded = try Entry.deserialize(allocator, &reader);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(original.payload.index, decoded.payload.index);
    try std.testing.expectEqual(original.payload.term, decoded.payload.term);
    try std.testing.expectEqualSlices(u8, original.payload.cmd.delete.key, decoded.payload.cmd.delete.key);
}

test "entry deserialize detects corruption" {
    const allocator = std.testing.allocator;

    const cmd = command.Command{ .delete = try command.DeleteCommand.init(allocator, "foxtrot") };
    const data = payload.Payload.init(1, 1, cmd);
    var entry = Entry.init(data);
    defer entry.deinit(allocator);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try entry.serialize(allocator, &writer);

    // Flip a byte somewhere inside the payload region (past the 8-byte header).
    buf[10] ^= 0xFF;

    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.CrcMismatch,
        Entry.deserialize(allocator, &reader),
    );
}
