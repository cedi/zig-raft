//! The node package implements a full raft node

pub const RaftNode = @import("raft_node.zig").RaftNode;
pub const NodeState = @import("raft_node.zig").NodeState;
pub const ElectionResult = @import("raft_node.zig").ElectionResult;

test {
    _ = @import("raft_node.zig");
}
