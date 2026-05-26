const std = @import("std");
const log = @import("log");
const state = @import("state");
const transport = @import("transport");
const test_transport = @import("noop_transport.zig");

pub const NodeState = enum(u8) {
    follower = 0,
    leader = 1,
    candidate = 2,
};

pub const ElectionResult = enum {
    won,
    lost,
    timeout,
};

/// Raft node implementing the core protocol from the Raft paper.
pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    transport: *transport.Transport,
    nodeId: u64,

    // persistent state on all servers
    currentTerm: u64,
    votedFor: ?u64,

    log: log.Log,
    state: state.Store,

    // volatile state on all servers
    commitIndex: u64,
    nodeState: NodeState,

    // volatile state on leaders
    /// Maps peerId to matchIndex.
    peerIndex: std.AutoHashMap(u64, u64),

    // Per-process counter to ensure unique PRNG seeds across nodes.
    var next_node_id: u64 = 1;

    pub fn init(allocator: std.mem.Allocator, t: *transport.Transport) RaftNode {
        var prng = std.Random.DefaultPrng.init(@intFromPtr(t) +% next_node_id);

        // wrapping add: won't panic on overflow
        next_node_id +%= 1;

        return .{
            .allocator = allocator,
            .transport = t,
            .nodeId = prng.random().int(u64),
            .currentTerm = 0,
            .votedFor = null,
            .log = .init(allocator),
            .state = .init(allocator),
            .commitIndex = 0,
            .nodeState = NodeState.follower,
            .peerIndex = .init(allocator),
        };
    }

    /// Call after init once the struct has a stable address.
    /// init() returns by value, so asPeer() pointers captured
    /// inside init would dangle after the copy.
    pub fn register(self: *RaftNode) !void {
        // cannot be moved inside init() because init() returns by value (i.e. a copy)
        // asPeer() captures `@ptrCase(&node)`, the return node copies the struct to the
        // caller's stack. this causes the peer in the transport still pointing to the
        // old local inside init's stack frame which no longer exists.
        // Alternative: `init()` returns a pointer (`!*RaftNode`) but that would require
        // heap-allocation and requires us to call `allocator.destroy(self)` in `deinit`.
        // It works, but is not very zig idiomatic
        try self.transport.register(self.nodeId, self.asPeer());
    }

    pub fn deinit(self: *RaftNode) void {
        self.transport.unregister(self.nodeId);
        self.peerIndex.deinit();
        self.state.deinit();
        self.log.deinit();
    }

    pub fn addPeer(self: *RaftNode, peerId: u64) !void {
        try self.peerIndex.put(peerId, 0);
    }

    pub fn asPeer(self: *RaftNode) transport.Peer {
        return .{
            .ptr = @ptrCast(self),
            .requestVoteFn = &handleRequestVote,
            .appendEntriesFn = &handleAppendEntries,
        };
    }

    fn clusterSize(self: *const RaftNode) u32 {
        return self.peerIndex.count() + 1;
    }

    fn majority(self: *const RaftNode) u32 {
        return self.clusterSize() / 2 + 1;
    }

    fn lastLogInfo(self: *const RaftNode) struct { index: u64, term: u64 } {
        if (self.log.len() > 0) {
            const last = self.log.at(self.log.len() - 1).?;
            return .{ .index = self.log.len() - 1, .term = last.term };
        }
        return .{ .index = 0, .term = 0 };
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

    /// §5.2: election timeout for case (c) "no winner". Currently unused
    /// because the synchronous transport completes RPCs instantly.
    /// Will be wired into the run() event loop.
    pub fn startElection(self: *RaftNode, timeout_ms: u64) !ElectionResult {
        _ = timeout_ms; // TODO: wire into run() event loop

        self.currentTerm += 1;
        self.votedFor = self.nodeId;
        self.nodeState = .candidate;

        var votes: u64 = 1;
        const last = self.lastLogInfo();

        var it = self.peerIndex.iterator();
        while (it.next()) |entry| {
            const reply = self.transport.sendRequestVote(entry.key_ptr.*, .{
                .term = self.currentTerm,
                .candidateId = self.nodeId,
                .lastLogIdx = last.index,
                .lastLogTerm = last.term,
            }) catch continue;

            if (reply.term > self.currentTerm) {
                self.currentTerm = reply.term;
                self.nodeState = .follower;
                self.votedFor = null;
                return .lost;
            }

            if (reply.voteGranted) {
                votes += 1;
            }
        }

        if (votes >= self.majority()) {
            self.nodeState = .leader;
            return .won;
        }

        self.nodeState = .follower;
        return .lost;
    }

    fn handleRequestVote(ctx: *anyopaque, req: transport.RequestVoteRequest) transport.RequestVoteResponse {
        const self: *RaftNode = @ptrCast(@alignCast(ctx));
        const granted = self.requestVote(req.term, req.candidateId, req.lastLogIdx, req.lastLogTerm);
        return .{ .term = self.currentTerm, .voteGranted = granted };
    }

    /// RequestVote RPC handler
    pub fn requestVote(self: *RaftNode, term: u64, candidateId: u64, prevLogIndex: u64, prevLogTerm: u64) bool {
        // 1. Reply false if term < currentTerm (§5.1)
        if (term < self.currentTerm) {
            return false;
        }

        // If votedFor is null or candidateId
        if (self.votedFor != null and self.votedFor.? != candidateId) {
            return false;
        }

        // candidate’s log must be at least as up-to-date (§5.2, §5.4)
        const lastLogTerm: u64 = if (self.log.len() > 0) self.log.at(self.log.len() - 1).?.term else 0;
        const lastLogIndex: u64 = if (self.log.len() > 0) self.log.len() - 1 else 0;

        // §5.4.1: later term wins; same term, longer log wins
        if (prevLogTerm < lastLogTerm) {
            return false;
        }

        if (prevLogTerm == lastLogTerm and prevLogIndex < lastLogIndex) {
            return false;
        }

        self.votedFor = candidateId;
        return true;
    }

    /// §5.3: Log replication
    pub fn replicateEntry(self: *RaftNode, cmd: log.Command) !u64 {
        try self.log.append(self.currentTerm, cmd);
        _ = try self.state.apply(cmd);
        const newIndex = self.log.len() - 1;
        self.commitIndex = newIndex;

        const prevLogIndex: u64 = if (newIndex > 0) newIndex - 1 else 0;
        const prevLogTerm: u64 = if (newIndex > 0) self.log.at(newIndex - 1).?.term else 0;

        var acks: u64 = 1;

        var it = self.peerIndex.iterator();
        while (it.next()) |entry| {
            const payload = self.log.at(newIndex).?.dupe(self.allocator) catch continue;
            const reply = self.transport.sendAppendEntries(entry.key_ptr.*, .{
                .term = self.currentTerm,
                .leaderId = self.nodeId,
                .prevLogIndex = prevLogIndex,
                .prevLogTerm = prevLogTerm,
                .lastCommitIdx = self.commitIndex,
                .entry = payload,
            }) catch continue;

            if (reply.success) {
                acks += 1;
                entry.value_ptr.* = newIndex;
            }
        }

        return acks;
    }

    fn handleAppendEntries(ctx: *anyopaque, req: transport.AppendEntriesRequest) transport.AppendEntriesResponse {
        const self: *RaftNode = @ptrCast(@alignCast(ctx));
        if (req.entry) |entry| {
            _ = self.appendEntry(req.prevLogIndex, req.prevLogTerm, log.Entry.init(entry)) catch {
                return .{ .term = self.currentTerm, .success = false };
            };
            return .{ .term = self.currentTerm, .success = true };
        }
        return .{ .term = self.currentTerm, .success = true };
    }

    /// §5.3: AppendEntries RPC handler.
    pub fn appendEntry(self: *RaftNode, prevLogIndex: u64, prevLogTerm: u64, cmd: log.Entry) !?[]const u8 {
        // 1. Reply false if leaderTerm < currentTerm (§5.1)
        const leaderTerm = cmd.payload.term;
        if (leaderTerm < self.currentTerm) {
            return error.NotCurrentTerm;
        }

        if (leaderTerm > self.currentTerm) {
            self.currentTerm = leaderTerm;
            self.nodeState = NodeState.follower;
        }

        // 2. Reply false if log doesn’t contain an entry at prevLogIndex
        //    whose term matches prevLogTerm (§5.3)
        if (prevLogIndex > 0) {
            const prevLog = self.log.at(prevLogIndex) orelse return error.PrevIndexNotExist;
            if (prevLog.term != prevLogTerm) {
                return error.PrevIndexTermMismatch;
            }
        }

        // 3. If an existing entry conflicts with a new one (same index
        // but different terms), delete the existing entry and all that
        // follow it (§5.3)
        if (self.log.at(cmd.payload.index)) |existing| {
            if (existing.term != cmd.payload.term) {
                self.log.truncateFrom(cmd.payload.index);
            }
        }

        // 4. Append any new entries not already in the log
        if (cmd.payload.index >= self.log.len()) {
            try self.log.append(cmd.payload.term, cmd.payload.cmd);
        } else {
            var unused = cmd.payload.cmd;
            unused.deinit(self.allocator);
        }
        const result = self.state.apply(cmd.payload.cmd);

        // 5. If leaderCommit > commitIndex, set commitIndex = min(leaderCommit, last new entry)
        self.commitIndex = cmd.payload.index;

        return result;
    }
};

test "requestVote: valid" {
    const allocator = std.testing.allocator;

    var raft_log = log.Log.init(allocator);
    defer raft_log.deinit();

    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "alice", "engineer") });
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "bob", "manager") });
    try raft_log.append(1, .{ .set = try log.SetCommand.init(allocator, "alice", "principal") });
    try raft_log.append(1, .{ .delete = try log.DeleteCommand.init(allocator, "bob") });

    var noop = test_transport.NoopTransport.init();
    var node = RaftNode.init(allocator, noop.interface());
    defer node.deinit();

    _ = try node.withWal(raft_log);

    try std.testing.expect(node.requestVote(2, 2, 3, 1));
}

test "requestVote: invalid" {
    const allocator = std.testing.allocator;

    var raft_log = log.Log.init(allocator);
    defer raft_log.deinit();

    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "alice", "engineer") });
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "bob", "manager") });
    try raft_log.append(1, .{ .set = try log.SetCommand.init(allocator, "alice", "principal") });
    try raft_log.append(1, .{ .delete = try log.DeleteCommand.init(allocator, "bob") });

    var noop = test_transport.NoopTransport.init();
    var node = RaftNode.init(allocator, noop.interface());
    defer node.deinit();

    _ = try node.withWal(raft_log);

    try std.testing.expectEqual(1, node.currentTerm);

    // invalid term
    try std.testing.expectEqual(false, node.requestVote(0, 2, 3, 1));

    // invalid prevLogIndex
    try std.testing.expectEqual(false, node.requestVote(2, 2, 2, 1));
    // invalid prevLogTerm
    try std.testing.expectEqual(false, node.requestVote(2, 2, 3, 0));

    // test two nodes requesting votes, but already voted
    try std.testing.expectEqual(true, node.requestVote(2, 2, 3, 1));
    try std.testing.expectEqual(false, node.requestVote(2, 3, 3, 1));
}

test "replay WAL" {
    const allocator = std.testing.allocator;

    var raft_log = log.Log.init(allocator);
    defer raft_log.deinit();

    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "alice", "engineer") });
    try raft_log.append(0, .{ .set = try log.SetCommand.init(allocator, "bob", "manager") });
    try raft_log.append(1, .{ .set = try log.SetCommand.init(allocator, "alice", "principal") });
    try raft_log.append(1, .{ .delete = try log.DeleteCommand.init(allocator, "bob") });

    var noop = test_transport.NoopTransport.init();
    var node = RaftNode.init(allocator, noop.interface());
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

    var noop = test_transport.NoopTransport.init();
    var node = RaftNode.init(allocator, noop.interface());
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

    var noop = test_transport.NoopTransport.init();
    var node = RaftNode.init(allocator, noop.interface());
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

test "appendEntry: conflicting entry truncates log" {
    const allocator = std.testing.allocator;

    var noop = test_transport.NoopTransport.init();
    var node = RaftNode.init(allocator, noop.interface());
    defer node.deinit();

    // entries from old leader in term 1
    _ = try node.appendEntry(0, 0, .{ .payload = .{ .index = 0, .term = 1, .cmd = .{ .set = try log.SetCommand.init(allocator, "a", "1") } } });
    _ = try node.appendEntry(0, 1, .{ .payload = .{ .index = 1, .term = 1, .cmd = .{ .set = try log.SetCommand.init(allocator, "b", "2") } } });
    _ = try node.appendEntry(1, 1, .{ .payload = .{ .index = 2, .term = 1, .cmd = .{ .set = try log.SetCommand.init(allocator, "c", "3") } } });
    try std.testing.expectEqual(@as(usize, 3), node.log.len());

    // new leader sends entry at index 1 with term 2, conflicting with existing
    _ = try node.appendEntry(0, 1, .{ .payload = .{ .index = 1, .term = 2, .cmd = .{ .set = try log.SetCommand.init(allocator, "b", "new") } } });

    // entries at index 1 and 2 were truncated, replaced with the new one
    try std.testing.expectEqual(@as(usize, 2), node.log.len());
    try std.testing.expectEqual(@as(u64, 1), node.log.at(0).?.term);
    try std.testing.expectEqual(@as(u64, 2), node.log.at(1).?.term);
}

test "appendEntry: duplicate entry is idempotent" {
    const allocator = std.testing.allocator;

    var noop = test_transport.NoopTransport.init();
    var node = RaftNode.init(allocator, noop.interface());
    defer node.deinit();

    _ = try node.appendEntry(0, 0, .{ .payload = .{ .index = 0, .term = 1, .cmd = .{ .set = try log.SetCommand.init(allocator, "a", "1") } } });
    try std.testing.expectEqual(@as(usize, 1), node.log.len());

    // same index, same term: should not append a duplicate
    _ = try node.appendEntry(0, 1, .{ .payload = .{ .index = 0, .term = 1, .cmd = .{ .set = try log.SetCommand.init(allocator, "a", "1") } } });
    try std.testing.expectEqual(@as(usize, 1), node.log.len());
}
