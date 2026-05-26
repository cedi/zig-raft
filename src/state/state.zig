//! Root file of the `state` module. Anything `pub` here is visible to other
//! modules that import `state`. Files inside this directory are internal and
//! only visible via re-exports below.

pub const Store = @import("kv.zig").Store;

test {
    _ = @import("kv.zig");
}
