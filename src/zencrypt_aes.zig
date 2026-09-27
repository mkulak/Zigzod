//! Zig port of ZodEgine_Libs/QZod_DnSeparate/zencrypt_aes.cpp: AES in ECB
//! mode, one 16-byte block at a time. Used for the registration key file
//! and one server message. The hand-written AES of the C++ version is
//! replaced by std.crypto.core.aes (identical output, see the tests).
//!
//! `class ZEncryptAES` stays declared in C++ (zencrypt_aes.h) because ZCore
//! embeds it; it only stores the key, and its methods call these functions.

const std = @import("std");
const aes = std.crypto.core.aes;

const block_len = 16;

/// Must match `class ZEncryptAES` in zencrypt_aes.h.
pub const ZEncryptAES = extern struct {
    /// 0 until a key is set, then 128 or 256.
    key_bits: c_int = 0,
    key: [32]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(ZEncryptAES) == 36);
    }

    /// Set the key (`size` in bits). Returns false for unsupported sizes.
    /// The original also accepted 192-bit keys, which the game never uses
    /// and std.crypto doesn't provide.
    pub fn setKey(self: *ZEncryptAES, key: []const u8, size: c_int) bool {
        const n: usize = switch (size) {
            128 => 16,
            256 => 32,
            else => return false,
        };
        self.key = @splat(0);
        @memcpy(self.key[0..n], key[0..n]);
        self.key_bits = size;
        return true;
    }

    /// Encrypt or decrypt `in_size` bytes. Like the original, a trailing
    /// partial block is processed as a whole block, so both buffers must be
    /// padded to a multiple of 16 bytes.
    pub fn process(self: *const ZEncryptAES, comptime direction: enum { encrypt, decrypt }, input: [*]const u8, in_size: usize, output: [*]u8) void {
        switch (self.key_bits) {
            128 => processWith(aes.Aes128, self.key[0..16].*, direction == .encrypt, input, in_size, output),
            256 => processWith(aes.Aes256, self.key, direction == .encrypt, input, in_size, output),
            // No key set: the original ran zero rounds on uninitialized data.
            else => @memset(output[0..roundUp(in_size)], 0),
        }
    }
};

fn roundUp(n: usize) usize {
    return std.mem.alignForward(usize, n, block_len);
}

fn processWith(comptime Aes: type, key: [Aes.key_bits / 8]u8, encrypt: bool, input: [*]const u8, in_size: usize, output: [*]u8) void {
    var i: usize = 0;
    if (encrypt) {
        const ctx = Aes.initEnc(key);
        while (i < in_size) : (i += block_len) ctx.encrypt(output[i..][0..block_len], input[i..][0..block_len]);
    } else {
        const ctx = Aes.initDec(key);
        while (i < in_size) : (i += block_len) ctx.decrypt(output[i..][0..block_len], input[i..][0..block_len]);
    }
}

pub export fn zod_aes_init(self: *ZEncryptAES) void {
    self.* = .{};
}

pub export fn zod_aes_set_key(self: *ZEncryptAES, key: [*]const u8, size: c_int) c_int {
    const n: usize = if (size == 256) 32 else 16;
    return @intFromBool(self.setKey(key[0..n], size));
}

pub export fn zod_aes_encrypt(self: *const ZEncryptAES, input: [*]const u8, in_size: c_int, output: [*]u8) void {
    if (in_size > 0) self.process(.encrypt, input, @intCast(in_size), output);
}

pub export fn zod_aes_decrypt(self: *const ZEncryptAES, input: [*]const u8, in_size: c_int, output: [*]u8) void {
    if (in_size > 0) self.process(.decrypt, input, @intCast(in_size), output);
}

// Expected values below were produced by the original C++ implementation.

fn hexToBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "same output as the C++ version with the game's key" {
    const game_key = [16]u8{ 0xFE, 0xEA, 0x42, 0x35, 0x78, 0x02, 0x57, 0xEC, 0xEE, 0x92, 0x11, 0x58, 0xC2, 0x5d, 0xC3, 0x23 };
    var z: ZEncryptAES = .{};
    try std.testing.expect(z.setKey(&game_key, 128));

    var input: [32]u8 = undefined;
    @memcpy(input[0..16], "hello there\x00\x0d\x0e\x0f\x10");
    for (input[16..], 16..) |*b, i| b.* = @truncate(i * 37 + 5);

    var enc: [32]u8 = undefined;
    zod_aes_encrypt(&z, &input, input.len, &enc);
    try std.testing.expectEqualSlices(u8, &hexToBytes("5c2d12874729aef8ccea2581e44241c450f0fe21ddbd8cdb2661f8e7125b17d1"), &enc);

    var dec: [32]u8 = undefined;
    zod_aes_decrypt(&z, &enc, enc.len, &dec);
    try std.testing.expectEqualSlices(u8, &input, &dec);
}

test "FIPS-197 vectors" {
    var key: [32]u8 = undefined;
    var pt: [16]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i);
    for (&pt, 0..) |*b, i| b.* = @intCast(i * 0x11);

    var z: ZEncryptAES = .{};
    var out: [16]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 1), zod_aes_set_key(&z, &key, 128));
    zod_aes_encrypt(&z, &pt, 16, &out);
    try std.testing.expectEqualSlices(u8, &hexToBytes("69c4e0d86a7b0430d8cdb78070b4c55a"), &out);

    try std.testing.expectEqual(@as(c_int, 1), zod_aes_set_key(&z, &key, 256));
    zod_aes_encrypt(&z, &pt, 16, &out);
    try std.testing.expectEqualSlices(u8, &hexToBytes("8ea2b7ca516745bfeafc49904b496089"), &out);

    try std.testing.expectEqual(@as(c_int, 0), zod_aes_set_key(&z, &key, 100));
}
