const std = @import("std");
const log = @import("log");
const state = @import("state");

pub const NodeState = enum(u8) {
    follower = 0,
    leader = 1,
    candidate = 2,
};

/// RaftNode implements all the primitives for a raft node
pub const RaftNode = struct {
    allocator: std.mem.Allocator,

    // persistent state on all servers
    currentTerm: u64,
    votedFor: u64,

    log: log.Log,
    state: state.Store,

    // volatile state on all servers
    commitIndex: u64,
    nodeState: NodeState,

    // volatile state on leaders
    /// peer is a HashMap peer=lastAppliedIndex to be used for nextIndex and matchIndex on a peer
    peerIndex: std.AutoHashMap(u64, u64),

    pub fn init(allocator: std.mem.Allocator) RaftNode {
        return .{
            .allocator = allocator,
            .currentTerm = 0,
            .votedFor = undefined,
            .log = .init(allocator),
            .state = .init(allocator),
            .commitIndex = 0,
            .nodeState = NodeState.follower,
            .peerIndex = .init(allocator),
        };
    }

    pub fn withWal(self: *RaftNode, wal: log.Log) !*RaftNode {
        var prevLogIndex: u64 = 0;
        var prevLogTerm: u64 = 0;

        for (wal.entries.items) |*payload| {
            const paylaod_copy = try payload.dupe(self.allocator);
            _ = try self.appendEntry(prevLogIndex, prevLogTerm, log.Entry.init(paylaod_copy));
            prevLogIndex = payload.index;
            prevLogTerm = payload.term;
        }

        return self;
    }

    pub fn deinit(self: *RaftNode) void {
        self.peerIndex.deinit();
        self.state.deinit();
        self.log.deinit();
    }

    // Invoked by leader to replicate log entries (§5.3); also used as heartbeat (§5.2).
    pub fn appendEntry(self: *RaftNode, prevLogIndex: u64, prevLogTerm: u64, cmd: log.Entry) !?[]const u8 {
        // 1. Reply false if leaderTerm < currentTerm (§5.1)
        // leader's term can be infered from the loc entry they're sending
        const leaderTerm = cmd.payload.term;
        if (leaderTerm < self.currentTerm) {
            return error.NotCurrentTerm;
        }

        if (leaderTerm > self.currentTerm) {
            self.currentTerm = leaderTerm;
            self.nodeState = NodeState.follower;
        }

        // 2. Reply false if log doesn’t contain an entry at prevLogIndex
        // whose term matches prevLogTerm (§5.3)
        const prevLog = self.log.at(prevLogIndex);
        if (prevLogIndex > 0 and prevLog == null) {
            return error.PrevIndexNotExist;
        }

        if (prevLogIndex > 0 and prevLog.?.term != prevLogTerm) {
            return error.PrevIndexTermMismatch;
        }

        // 3. If an existing entry conflicts with a new one (same index
        // but different terms), delete the existing entry and all that
        // follow it (§5.3)

        // TODO(cedi): to implement...

        // 4. Append any new entries not already in the log
        try self.log.append(cmd.payload.term, cmd.payload.cmd);
        const result = self.state.apply(cmd.payload.cmd);

        // 5. If leaderCommit > commitIndex, set
        // commitIndex = min(leaderCommit, index of last new entry)
        // leader's commitIndex can be infered from the loc entry they're sending
        self.commitIndex = cmd.payload.index;

        return result;
    }
};

test "replay WAL" {
    const allocator = std.testing.allocator;

    var raft_log = log.Log.init(allocator);
    defer raft_log.deinit();

    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "alice", "engineer") });
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "bob", "manager") });
    try raft_log.append(1, .{ .set = try log.SetCommand.init(allocator, "alice", "principal") });
    try raft_log.append(1, .{ .delete = try log.DeleteCommand.init(allocator, "bob") });

    var node = RaftNode.init(allocator);
    defer node.deinit();

    _ = try node.withWal(raft_log);

    try std.testing.expectEqualSlices(u8, "principal", (try node.state.get("alice")).?);
    try std.testing.expect((try node.state.get("bob")) == null);
    try std.testing.expectEqual(@as(usize, 1), node.state.len());
    try std.testing.expectEqual(@as(usize, 4), node.log.len());
    try std.testing.expectEqual(@as(u64, 1), node.currentTerm);
    try std.testing.expectEqual(@as(u64, 3), node.commitIndex);
}

test "appendEntry" {
    const allocator = std.testing.allocator;

    var node = RaftNode.init(allocator);
    defer node.deinit();

    _ = try node.appendEntry(0, 0, .{ .payload = .{ .index = 0, .term = 1, .cmd = .{ .set = try log.SetCommand.init(allocator, "foo", "bar") } } });
    _ = try node.appendEntry(0, 1, .{ .payload = .{ .index = 1, .term = 1, .cmd = .{ .set = try log.SetCommand.init(allocator, "foo", "2342") } } });
    _ = try node.appendEntry(1, 1, .{ .payload = .{ .index = 2, .term = 1, .cmd = .{ .set = try log.SetCommand.init(allocator, "bar", "foo") } } });
    _ = try node.appendEntry(1, 1, .{ .payload = .{ .index = 3, .term = 1, .cmd = .{ .delete = try log.DeleteCommand.init(allocator, "bar") } } });

    try std.testing.expectEqualSlices(u8, "2342", (try node.state.get("foo")).?);
    try std.testing.expectEqual(@as(usize, 1), node.state.len());
    try std.testing.expectEqual(@as(usize, 4), node.log.len());
    try std.testing.expectEqual(@as(u64, 1), node.currentTerm);
    try std.testing.expectEqual(@as(u64, 3), node.commitIndex);
}

test "replay WAL and appendEntry RPC" {
    const allocator = std.testing.allocator;

    var raft_log = log.Log.init(allocator);
    defer raft_log.deinit();

    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "alice", "engineer") });
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "bob", "manager") });
    try raft_log.append(1, .{ .set = try log.SetCommand.init(allocator, "alice", "principal") });
    try raft_log.append(1, .{ .delete = try log.DeleteCommand.init(allocator, "bob") });

    var node = RaftNode.init(allocator);
    defer node.deinit();

    _ = try node.withWal(raft_log);

    var prevIdx = raft_log.len() - 1;
    const prevTerm = raft_log.at(raft_log.len() - 1).?.term;
    var nextIdx = prevIdx + 1;
    const currentTerm = prevTerm + 1;

    _ = try node.appendEntry(prevIdx, prevTerm, .{ .payload = .{ .index = nextIdx, .term = currentTerm, .cmd = .{ .set = try log.SetCommand.init(allocator, "foo", "bar") } } });
    prevIdx = nextIdx;
    nextIdx += 1;
    _ = try node.appendEntry(prevIdx, currentTerm, .{ .payload = .{ .index = nextIdx, .term = currentTerm, .cmd = .{ .set = try log.SetCommand.init(allocator, "foo", "2342") } } });
    prevIdx = nextIdx;
    nextIdx += 1;

    try std.testing.expectEqualSlices(u8, "principal", (try node.state.get("alice")).?);
    try std.testing.expect((try node.state.get("bob")) == null);
    try std.testing.expectEqualSlices(u8, "2342", (try node.state.get("foo")).?);
    try std.testing.expectEqual(@as(u64, currentTerm), node.currentTerm);
    try std.testing.expectEqual(@as(u64, prevIdx), node.commitIndex);
}
