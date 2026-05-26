pub const Transport = @import("transport.zig").Transport;
pub const Peer = Transport.Peer;
pub const AppendEntriesRequest = @import("message.zig").AppendEntriesRequest;
pub const AppendEntriesResponse = @import("message.zig").AppendEntriesResponse;
pub const RequestVoteRequest = @import("message.zig").RequestVoteRequest;
pub const RequestVoteResponse = @import("message.zig").RequestVoteResponse;

test {
    _ = @import("transport.zig");
    _ = @import("message.zig");
}
