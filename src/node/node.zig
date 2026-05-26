//! The node package implements a full raft node

pub const RaftNode = @import("raft_node.zig").RaftNode;

test {
    _ = @import("raft_node.zig");
}
