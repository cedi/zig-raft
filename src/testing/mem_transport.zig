const std = @import("std");
const transport_mod = @import("transport");
const Transport = transport_mod.Transport;

/// In-memory transport for testing. Routes RPCs between registered peers
/// without serialization or networking.
pub const MemTransport = struct {
    allocator: std.mem.Allocator,
    peers: std.AutoHashMap(u64, Transport.Peer),
    iface: Transport,

    const vtable: Transport.VTable = .{
        .sendRquestVote = &sendRequestVoteImpl,
        .sendAppendEntries = &sendAppendEntriesImpl,
        .register = &registerImpl,
        .unregister = &unregisterImpl,
    };

    pub fn init(allocator: std.mem.Allocator) MemTransport {
        return .{
            .allocator = allocator,
            .peers = .init(allocator),
            .iface = .{ .ptr = undefined, .vtable = &vtable },
        };
    }

    pub fn deinit(self: *MemTransport) void {
        self.peers.deinit();
    }

    pub fn transport(self: *MemTransport) *Transport {
        self.iface.ptr = @ptrCast(self);
        return &self.iface;
    }

    fn registerImpl(ctx: *anyopaque, id: u64, peer: Transport.Peer) Transport.RegisterError!void {
        const self: *MemTransport = @ptrCast(@alignCast(ctx));
        self.peers.put(id, peer) catch return error.OutOfMemory;
    }

    fn unregisterImpl(ctx: *anyopaque, id: u64) void {
        const self: *MemTransport = @ptrCast(@alignCast(ctx));
        _ = self.peers.remove(id);
    }

    fn sendRequestVoteImpl(ctx: *anyopaque, peerId: u64, request: transport_mod.RequestVoteRequest) Transport.TransportError!transport_mod.RequestVoteResponse {
        const self: *MemTransport = @ptrCast(@alignCast(ctx));
        const peer = self.peers.get(peerId) orelse return error.PeerNotFound;
        return peer.requestVoteFn(peer.ptr, request);
    }

    fn sendAppendEntriesImpl(ctx: *anyopaque, peerId: u64, request: transport_mod.AppendEntriesRequest) Transport.TransportError!transport_mod.AppendEntriesResponse {
        const self: *MemTransport = @ptrCast(@alignCast(ctx));
        const peer = self.peers.get(peerId) orelse return error.PeerNotFound;
        return peer.appendEntriesFn(peer.ptr, request);
    }
};
