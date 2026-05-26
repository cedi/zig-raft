//! The log module provides all the primitives required for working with the
//! Raft command log.
//! It provides the simple Command type, but also the log storage and the
//! structs to serialize the WAL (to disk) in it's own, native binary format.

pub const Command = @import("command.zig").Command;
pub const SetCommand = @import("command.zig").SetCommand;
pub const DeleteCommand = @import("command.zig").DeleteCommand;
pub const GetCommand = @import("command.zig").GetCommand;
pub const Payload = @import("payload.zig").Payload;
pub const Entry = @import("entry.zig").Entry;
pub const Log = @import("store.zig").Log;

test {
    _ = @import("command.zig");
    _ = @import("payload.zig");
    _ = @import("entry.zig");
    _ = @import("store.zig");
}
