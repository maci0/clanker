// Minimal wasm32-freestanding module used by the M1 smoke test:
// verifies that wasm code emitted by this Zig version executes under wasm3.
export fn add(a: i32, b: i32) callconv(.c) i32 {
    return a + b;
}

export fn no_args() callconv(.c) i32 {
    return 42;
}
