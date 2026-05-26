const transport = @import("transport");

/// Noop transport for unit tests that don't need inter-node RPCs.
pub const NoopTransport = struct {
    iface: transport.Transport,

    const vtable: transport.Transport.VTable = .{
        .sendRquestVote = &struct {
            fn f(_: *anyopaque, _: u64, _: transport.RequestVoteRequest) transport.Transport.TransportError!transport.RequestVoteResponse {
                return error.PeerNotFound;
            }
        }.f,
        .sendAppendEntries = &struct {
            fn f(_: *anyopaque, _: u64, _: transport.AppendEntriesRequest) transport.Transport.TransportError!transport.AppendEntriesResponse {
                return error.PeerNotFound;
            }
        }.f,
        .register = &struct {
            fn f(_: *anyopaque, _: u64, _: transport.Peer) transport.Transport.RegisterError!void {}
        }.f,
        .unregister = &struct {
            fn f(_: *anyopaque, _: u64) void {}
        }.f,
    };

    pub fn init() NoopTransport {
        return .{ .iface = .{ .ptr = undefined, .vtable = &vtable } };
    }

    pub fn interface(self: *NoopTransport) *transport.Transport {
        return &self.iface;
    }
};
