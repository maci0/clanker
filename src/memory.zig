//! memory — re-exports for the layer.

const chunk_mod = @import("memory/chunk.zig");
const vector_mod = @import("memory/vector.zig");
const embedder_mod = @import("memory/embedder.zig");

pub const chunk = chunk_mod;
pub const vector = vector_mod;
pub const embedder = embedder_mod;

pub const Chunk = chunk_mod.Chunk;
pub const Hit = vector_mod.Hit;
