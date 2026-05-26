const std = @import("std");
const log = @import("log");

/// AppendEntries RPC arguments (§5.3).
/// Sent by the leader to replicate log entries and as heartbeat.
pub const AppendEntriesRequest = struct {
    term: u64,
    leaderId: u64,
    prevLogIndex: u64,
    prevLogTerm: u64,
    lastCommitIdx: u64,
    entry: ?log.Payload,

    pub fn deinit(self: *AppendEntriesRequest, allocator: std.mem.Allocator) void {
        if (self.entry) |*e| e.deinit(allocator);
    }

    pub fn dupe(self: AppendEntriesRequest, allocator: std.mem.Allocator) !AppendEntriesRequest {
        return .{
            .term = self.term,
            .leaderId = self.leaderId,
            .prevLogIndex = self.prevLogIndex,
            .prevLogTerm = self.prevLogTerm,
            .entry = if (self.entry) |e| try e.dupe(allocator) else null,
            .lastCommitIdx = self.lastCommitIdx,
        };
    }

    pub fn serialize(self: AppendEntriesRequest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeInt(u64, self.leaderId, .little);
        try writer.writeInt(u64, self.prevLogIndex, .little);
        try writer.writeInt(u64, self.prevLogTerm, .little);
        try writer.writeInt(u64, self.lastCommitIdx, .little);
        if (self.entry) |*e| try e.serialize(writer);
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: *std.Io.Reader) !AppendEntriesRequest {
        const term = try reader.takeInt(u64, .little);
        const leaderId = try reader.takeInt(u64, .little);
        const prevLogIndex = try reader.takeInt(u64, .little);
        const prevLogTerm = try reader.takeInt(u64, .little);
        const lastCommitIdx = try reader.takeInt(u64, .little);
        const entry = try log.Payload.deserialize(allocator, reader);

        return AppendEntriesRequest{
            .term = term,
            .leaderId = leaderId,
            .prevLogIndex = prevLogIndex,
            .prevLogTerm = prevLogTerm,
            .lastCommitIdx = lastCommitIdx,
            .entry = entry,
        };
    }
};

pub const AppendEntriesResponse = struct {
    term: u64,
    success: bool,

    pub fn serialize(self: AppendEntriesResponse, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeInt(bool, self.success, .little);
    }

    pub fn deserialize(reader: *std.Io.Reader) !AppendEntriesResponse {
        const term = try reader.takeInt(u64, .little);
        const success = try reader.takeInt(bool, .little);

        return AppendEntriesResponse{
            .term = term,
            .success = success,
        };
    }
};

/// RequestVote RPC arguments (§5.2).
pub const RequestVoteRequest = struct {
    term: u64,
    candidateId: u64,
    lastLogIdx: u64,
    lastLogTerm: u64,

    pub fn serialize(self: RequestVoteRequest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeInt(u64, self.candidateId, .little);
        try writer.writeInt(u64, self.lastLogIdx, .little);
        try writer.writeInt(u64, self.lastLogTerm, .little);
    }

    pub fn deserialize(reader: *std.Io.Reader) !RequestVoteRequest {
        const term = try reader.takeInt(u64, .little);
        const candidateId = try reader.takeInt(u64, .little);
        const lastLogIdx = try reader.takeInt(u64, .little);
        const lastLogTerm = try reader.takeInt(u64, .little);

        return RequestVoteRequest{
            .term = term,
            .candidateId = candidateId,
            .lastLogIdx = lastLogIdx,
            .lastLogTerm = lastLogTerm,
        };
    }
};

pub const RequestVoteResponse = struct {
    term: u64,
    voteGranted: bool,

    pub fn serialize(self: RequestVoteResponse, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeInt(bool, self.voteGranted, .little);
    }

    pub fn deserialize(reader: *std.Io.Reader) !RequestVoteResponse {
        const term = try reader.takeInt(u64, .little);
        const voteGranted = try reader.takeInt(bool, .little);

        return RequestVoteResponse{
            .term = term,
            .voteGranted = voteGranted,
        };
    }
};
