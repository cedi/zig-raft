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

    var node_a = RaftNode.init(allocator, mem.transport());
    defer node_a.deinit();
    try node_a.register();

    var node_b = RaftNode.init(allocator, mem.transport());
    defer node_b.deinit();
    try node_b.register();

    var node_c = RaftNode.init(allocator, mem.transport());
    defer node_c.deinit();
    try node_c.register();

    try node_a.addPeer(node_b.nodeId);
    try node_a.addPeer(node_c.nodeId);

    const result = try node_a.startElection(150);
    try std.testing.expectEqual(node.ElectionResult.won, result);
    try std.testing.expectEqual(NodeState.leader, node_a.nodeState);
    try std.testing.expectEqual(@as(u64, 1), node_a.currentTerm);
    try std.testing.expectEqual(node_a.nodeId, node_a.votedFor.?);

    try std.testing.expectEqual(node_a.nodeId, node_b.votedFor.?);
    try std.testing.expectEqual(node_a.nodeId, node_c.votedFor.?);
}

test "three nodes: second candidate loses election" {
    const allocator = std.testing.allocator;

    var mem = MemTransport.init(allocator);
    defer mem.deinit();

    var node_a = RaftNode.init(allocator, mem.transport());
    defer node_a.deinit();
    try node_a.register();

    var node_b = RaftNode.init(allocator, mem.transport());
    defer node_b.deinit();
    try node_b.register();

    var node_c = RaftNode.init(allocator, mem.transport());
    defer node_c.deinit();
    try node_c.register();

    try node_a.addPeer(node_b.nodeId);
    try node_a.addPeer(node_c.nodeId);

    try node_c.addPeer(node_a.nodeId);
    try node_c.addPeer(node_b.nodeId);

    try std.testing.expectEqual(node.ElectionResult.won, try node_a.startElection(150));
    try std.testing.expectEqual(NodeState.leader, node_a.nodeState);

    const result = try node_c.startElection(150);
    try std.testing.expectEqual(node.ElectionResult.lost, result);
    try std.testing.expectEqual(NodeState.follower, node_c.nodeState);
}

test "three nodes: leader replicates entry to followers" {
    const allocator = std.testing.allocator;

    var mem = MemTransport.init(allocator);
    defer mem.deinit();

    var leader = RaftNode.init(allocator, mem.transport());
    defer leader.deinit();
    try leader.register();

    var follower_a = RaftNode.init(allocator, mem.transport());
    defer follower_a.deinit();
    try follower_a.register();

    var follower_b = RaftNode.init(allocator, mem.transport());
    defer follower_b.deinit();
    try follower_b.register();

    try leader.addPeer(follower_a.nodeId);
    try leader.addPeer(follower_b.nodeId);

    try std.testing.expectEqual(node.ElectionResult.won, try leader.startElection(150));

    const acks = try leader.replicateEntry(.{ .set = try log.SetCommand.init(allocator, "key", "value") });
    try std.testing.expectEqual(@as(u64, 3), acks);

    try std.testing.expectEqual(@as(usize, 1), leader.log.len());
    try std.testing.expectEqual(@as(usize, 1), follower_a.log.len());
    try std.testing.expectEqual(@as(usize, 1), follower_b.log.len());

    try std.testing.expectEqualSlices(u8, "value", (try leader.state.get("key")).?);
    try std.testing.expectEqualSlices(u8, "value", (try follower_a.state.get("key")).?);
    try std.testing.expectEqualSlices(u8, "value", (try follower_b.state.get("key")).?);
}
