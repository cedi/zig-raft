const msg = @import("message.zig");

/// Type-erased transport interface (same pattern as std.mem.Allocator).
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Incoming RPC handler. Built by the node type (see RaftNode.asPeer).
    pub const Peer = struct {
        ptr: *anyopaque,
        requestVoteFn: *const fn (*anyopaque, msg.RequestVoteRequest) msg.RequestVoteResponse,
        appendEntriesFn: *const fn (*anyopaque, msg.AppendEntriesRequest) msg.AppendEntriesResponse,
    };

    pub const VTable = struct {
        sendRquestVote: *const fn (
            ctx: *anyopaque,
            peerId: u64,
            request: msg.RequestVoteRequest,
        ) TransportError!msg.RequestVoteResponse,

        sendAppendEntries: *const fn (
            ctx: *anyopaque,
            peerId: u64,
            request: msg.AppendEntriesRequest,
        ) TransportError!msg.AppendEntriesResponse,

        register: *const fn (
            ctx: *anyopaque,
            id: u64,
            peer: Peer,
        ) RegisterError!void,

        unregister: *const fn (
            ctx: *anyopaque,
            id: u64,
        ) void,
    };

    pub const TransportError = error{
        ConnectionRefused,
        Timeout,
        PeerNotFound,
    };

    pub const RegisterError = error{
        OutOfMemory,
    };

    pub fn sendRequestVote(self: Transport, peerId: u64, request: msg.RequestVoteRequest) TransportError!msg.RequestVoteResponse {
        return self.vtable.sendRquestVote(self.ptr, peerId, request);
    }

    pub fn sendAppendEntries(self: Transport, peerId: u64, request: msg.AppendEntriesRequest) TransportError!msg.AppendEntriesResponse {
        return self.vtable.sendAppendEntries(self.ptr, peerId, request);
    }

    pub fn register(self: Transport, id: u64, peer: Peer) RegisterError!void {
        return self.vtable.register(self.ptr, id, peer);
    }

    pub fn unregister(self: Transport, id: u64) void {
        return self.vtable.unregister(self.ptr, id);
    }
};
