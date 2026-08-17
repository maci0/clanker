//! The one number that explains every `config.max_tokens` in
//! `tools/manifests/`. Host-tested so the guests that compute a per-call
//! budget and the descriptors that grant one cannot drift on the reason.
//!
//! `max_tokens` bounds *output*, and on a reasoning model the reasoning trace
//! is output: the provider fills `reasoning_content` first and only then emits
//! `content`. A budget sized for the answer alone is therefore spent before a
//! visible token exists, and the provider still answers 200 — empty `content`,
//! `finish_reason: "length"`. Every guest sees is an empty string.
//!
//! Capabilities cannot gate this. `sampling.hasThinking` reads
//! `Model.capabilities`, which `applyCatalogSpecs` fills from the models.dev
//! snapshot and leaves empty when `state/models-dev.json` is absent — and
//! `load` never downloads it. A checkout that has not run
//! `clanker providers refresh` reports no capabilities for any model, so a
//! capability-gated budget is exactly the no-op the bug needs it not to be.
//! Every grant here is therefore sized for a reasoning model unconditionally.

const std = @import("std");

/// Output tokens to add on top of what the answer itself needs.
///
/// Measured, not guessed: the autolearn synthesis — one 16 KiB prompt, a
/// roadmap section out — spent 4458 completion tokens on `deepseek-v4-pro`
/// against ~1900 tokens of section, so ~2500 went to reasoning. 4096 covers
/// that with room for a longer prompt while still bounding a runaway call,
/// which is the reason the grant is a ceiling at all.
pub const reasoning_headroom: u32 = 4096;

/// The budget a call needs when the model may reason first. `content_tokens`
/// is what the answer alone would take.
///
/// Saturating: a caller that asks for a content budget near `maxInt(u32)` gets
/// the ceiling rather than a wrapped, tiny budget — the exact shape that made
/// this bug silent in the first place.
pub fn withHeadroom(content_tokens: u32) u32 {
    return std.math.add(u32, content_tokens, reasoning_headroom) catch std.math.maxInt(u32);
}

test "withHeadroom covers the answer and the reasoning that precedes it" {
    // A one-word answer is still a reasoning-model call: the headroom, not the
    // content, is what the budget is for.
    try std.testing.expectEqual(@as(u32, 4096), withHeadroom(0));
    try std.testing.expectEqual(@as(u32, 4596), withHeadroom(500));
    try std.testing.expectEqual(@as(u32, 6144), withHeadroom(2048));

    // The measured autolearn spend must fit inside a budget derived for it.
    try std.testing.expect(withHeadroom(1900) >= 4458);
}

test "withHeadroom saturates instead of wrapping to a tiny budget" {
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), withHeadroom(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), withHeadroom(std.math.maxInt(u32) - 1));
}
