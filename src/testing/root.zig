const std = @import("std");
const log = @import("log");
const node = @import("node");
const transport = @import("transport");

pub const MemTransport = @import("mem_transport.zig").MemTransport;

const RaftNode = node.RaftNode;
const NodeState = node.NodeState;

test {
    _ = @import("mem_transport.zig");
}

test "three nodes: leader election succeeds" {
    const allocator = std.testing.allocator;

    var mem = MemTransport.init(allocator);
    defer mem.deinit();

    var node_a = RaftNode.init(allocator, mem.transport(), .{});
    defer node_a.deinit();
    try node_a.register();

    var node_b = RaftNode.init(allocator, mem.transport(), .{});
    defer node_b.deinit();
    try node_b.register();

    var node_c = RaftNode.init(allocator, mem.transport(), .{});
    defer node_c.deinit();
    try node_c.register();

    try node_a.addPeer(node_b.nodeId);
    try node_a.addPeer(node_c.nodeId);

    const result = try node_a.startElection();
    try std.testing.expectEqual(node.ElectionResult.won, result);
    try std.testing.expectEqual(NodeState.leader, node_a.nodeState);
    try std.testing.expectEqual(@as(u64, 1), node_a.currentTerm);
    try std.testing.expectEqual(node_a.nodeId, node_a.votedFor.?);

    try std.testing.expectEqual(node_a.nodeId, node_b.votedFor.?);
    try std.testing.expectEqual(node_a.nodeId, node_c.votedFor.?);
}

test "three nodes: second candidate wins in higher term" {
    const allocator = std.testing.allocator;

    var mem = MemTransport.init(allocator);
    defer mem.deinit();

    var node_a = RaftNode.init(allocator, mem.transport(), .{});
    defer node_a.deinit();
    try node_a.register();

    var node_b = RaftNode.init(allocator, mem.transport(), .{});
    defer node_b.deinit();
    try node_b.register();

    var node_c = RaftNode.init(allocator, mem.transport(), .{});
    defer node_c.deinit();
    try node_c.register();

    try node_a.addPeer(node_b.nodeId);
    try node_a.addPeer(node_c.nodeId);

    try node_c.addPeer(node_a.nodeId);
    try node_c.addPeer(node_b.nodeId);

    // node_a wins term 1
    try std.testing.expectEqual(node.ElectionResult.won, try node_a.startElection());
    try std.testing.expectEqual(@as(u64, 1), node_a.currentTerm);

    // node_c starts election in term 2; peers adopt the higher term
    // and grant votes (votes don't carry across terms)
    const result = try node_c.startElection();
    try std.testing.expectEqual(node.ElectionResult.won, result);
    try std.testing.expectEqual(@as(u64, 2), node_c.currentTerm);

    // node_a should have stepped down
    try std.testing.expectEqual(NodeState.follower, node_a.nodeState);
}

test "three nodes: leader replicates entry to followers" {
    const allocator = std.testing.allocator;

    var mem = MemTransport.init(allocator);
    defer mem.deinit();

    var leader = RaftNode.init(allocator, mem.transport(), .{});
    defer leader.deinit();
    try leader.register();

    var follower_a = RaftNode.init(allocator, mem.transport(), .{});
    defer follower_a.deinit();
    try follower_a.register();

    var follower_b = RaftNode.init(allocator, mem.transport(), .{});
    defer follower_b.deinit();
    try follower_b.register();

    try leader.addPeer(follower_a.nodeId);
    try leader.addPeer(follower_b.nodeId);

    try std.testing.expectEqual(node.ElectionResult.won, try leader.startElection());

    const acks = try leader.replicateEntry(.{ .set = try log.SetCommand.init(allocator, "key", "value") });
    try std.testing.expectEqual(@as(u64, 3), acks);

    try std.testing.expectEqual(@as(usize, 1), leader.log.len());
    try std.testing.expectEqual(@as(usize, 1), follower_a.log.len());
    try std.testing.expectEqual(@as(usize, 1), follower_b.log.len());

    try std.testing.expectEqualSlices(u8, "value", (try leader.state.get("key")).?);
    try std.testing.expectEqualSlices(u8, "value", (try follower_a.state.get("key")).?);
    try std.testing.expectEqualSlices(u8, "value", (try follower_b.state.get("key")).?);
}

test "tick-driven: election happens after timeout" {
    const allocator = std.testing.allocator;

    var mem = MemTransport.init(allocator);
    defer mem.deinit();

    const config = node.Config{
        .election_timeout_min = 10,
        .election_timeout_max = 15,
        .heartbeat_interval = 3,
    };

    var node_a = RaftNode.init(allocator, mem.transport(), config);
    defer node_a.deinit();
    try node_a.register();

    var node_b = RaftNode.init(allocator, mem.transport(), config);
    defer node_b.deinit();
    try node_b.register();

    var node_c = RaftNode.init(allocator, mem.transport(), config);
    defer node_c.deinit();
    try node_c.register();

    try node_a.addPeer(node_b.nodeId);
    try node_a.addPeer(node_c.nodeId);
    try node_b.addPeer(node_a.nodeId);
    try node_b.addPeer(node_c.nodeId);
    try node_c.addPeer(node_a.nodeId);
    try node_c.addPeer(node_b.nodeId);

    // all start as followers
    try std.testing.expectEqual(NodeState.follower, node_a.nodeState);
    try std.testing.expectEqual(NodeState.follower, node_b.nodeState);
    try std.testing.expectEqual(NodeState.follower, node_c.nodeState);

    // all start at term 0
    try std.testing.expectEqual(0, node_a.currentTerm);
    try std.testing.expectEqual(0, node_b.currentTerm);
    try std.testing.expectEqual(0, node_c.currentTerm);

    // tick past election timeout; at least one node should become leader
    for (0..20) |_| {
        try node_a.tick();
        try node_b.tick();
        try node_c.tick();
    }

    var leaders: u32 = 0;
    if (node_a.nodeState == .leader) leaders += 1;
    if (node_b.nodeState == .leader) leaders += 1;
    if (node_c.nodeState == .leader) leaders += 1;
    try std.testing.expect(leaders >= 1);

    // some term > 0 was established
    const max_term = @max(node_a.currentTerm, @max(node_b.currentTerm, node_c.currentTerm));
    try std.testing.expect(max_term > 0);
}

test "tick-driven: leader heartbeats prevent follower elections" {
    const allocator = std.testing.allocator;

    var mem = MemTransport.init(allocator);
    defer mem.deinit();

    const config = node.Config{
        .election_timeout_min = 10,
        .election_timeout_max = 15,
        .heartbeat_interval = 3,
    };

    var node_a = RaftNode.init(allocator, mem.transport(), config);
    defer node_a.deinit();
    try node_a.register();

    var node_b = RaftNode.init(allocator, mem.transport(), config);
    defer node_b.deinit();
    try node_b.register();

    try node_a.addPeer(node_b.nodeId);
    try node_b.addPeer(node_a.nodeId);

    // node_a wins election directly
    try std.testing.expectEqual(node.ElectionResult.won, try node_a.startElection());

    // tick both nodes many times; leader sends heartbeats, follower stays follower
    for (0..100) |_| {
        try node_a.tick();
        try node_b.tick();
    }

    try std.testing.expectEqual(NodeState.leader, node_a.nodeState);
    try std.testing.expectEqual(NodeState.follower, node_b.nodeState);
}
