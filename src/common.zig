//! Zig port of ZodEgine_Libs/QZod_DnSeparate/common.cpp: small utility
//! functions used all over the engine. Exported with the C ABI; the C++
//! declarations are in src/zod_zig.h and the COMMON namespace wrappers in
//! common.h / common.cpp.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// Monotonic clock reading in nanoseconds.
fn monotonicNs() i128 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Reference point for zod_current_time(); 0 until the first call.
var time_origin_ns = std.atomic.Value(i64).init(0);

/// Seconds since the first call (the game only uses differences). The C++
/// version used gettimeofday(); a monotonic clock doesn't jump when the
/// system time changes.
pub export fn zod_current_time() f64 {
    const now: i64 = @intCast(monotonicNs());
    var origin = time_origin_ns.load(.acquire);
    if (origin == 0) {
        // Several threads may race here; whoever wins sets the origin.
        origin = time_origin_ns.cmpxchgStrong(0, now, .acq_rel, .acquire) orelse now;
    }
    return @as(f64, @floatFromInt(now - origin)) / std.time.ns_per_s;
}

pub export fn zod_uni_pause(m_sec: c_int) void {
    if (m_sec <= 0) return;
    const ms: u64 = @intCast(m_sec);
    var req: c.timespec = .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    var rem: c.timespec = undefined;
    // Resume after signals until the full time has passed.
    while (c.nanosleep(&req, &rem) != 0 and c.errno(@as(c_int, -1)) == .INTR) req = rem;
}

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

/// Copy the next `split`-separated token of `message`, starting at
/// `*initial`, into `dest` (always NUL-terminated if d_size > 0) and advance
/// `*initial` past the separator.
pub export fn zod_split(dest: [*]u8, message: [*]const u8, split: u8, initial: *c_int, d_size: c_int, m_size: c_int) void {
    var i: c_int = initial.*;
    var a: c_int = 0;

    while (i < m_size) : (i += 1) {
        const ch = message[@intCast(i)];
        if (ch == 0 or ch == split) break;
        if (a < d_size) {
            dest[@intCast(a)] = ch;
            a += 1;
        }
    }

    if (a < d_size) {
        dest[@intCast(a)] = 0;
    } else if (d_size > 0) {
        dest[@intCast(d_size - 1)] = 0;
    }

    // Like the C++ code, stay on a terminating NUL, otherwise skip the
    // separator. (Reading message[m_size] is what the original did too.)
    initial.* = if (message[@intCast(i)] == 0) i else i + 1;
}

/// Cut the string at the first '\r' or '\n'.
pub export fn zod_clean_newline(message: [*]u8, size: c_int) void {
    var i: usize = 0;
    while (i < size) : (i += 1) {
        switch (message[i]) {
            '\r', '\n' => {
                message[i] = 0;
                return;
            },
            0 => return,
            else => {},
        }
    }
}

/// ASCII lower-case `m_size` bytes in place.
pub export fn zod_lcase(message: ?[*]u8, m_size: c_int) void {
    const msg = message orelse return;
    var i: usize = 0;
    while (i < m_size) : (i += 1) msg[i] = std.ascii.toLower(msg[i]);
}

pub export fn zod_good_user_char(ch: c_int) bool {
    if (ch < 0 or ch > 255) return false;
    const b: u8 = @intCast(ch);
    return std.ascii.isAlphanumeric(b) or switch (b) {
        ' ', '@', '.', '_', '-' => true,
        else => false,
    };
}

/// A valid player/login name: allowed characters only, not empty, no
/// leading/trailing spaces and no double spaces.
pub export fn zod_good_user_string(message: [*:0]const u8) bool {
    return goodUserString(std.mem.span(message));
}

fn goodUserString(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!zod_good_user_char(ch)) return false;
    if (std.mem.indexOf(u8, s, "  ") != null) return false;
    return s[0] != ' ' and s[s.len - 1] != ' ';
}

/// Lower-case hex of `size` bytes into `out`, which must hold 2*size+1 bytes.
pub export fn zod_data_to_hex(data: [*]const u8, size: c_int, out: [*]u8) void {
    const n: usize = if (size > 0) @intCast(size) else 0;
    const hex = "0123456789abcdef";
    for (data[0..n], 0..) |byte, i| {
        out[2 * i] = hex[byte >> 4];
        out[2 * i + 1] = hex[byte & 0xf];
    }
    out[2 * n] = 0;
}

/// Case-insensitive "name ends with ext".
pub export fn zod_has_extension(name: [*:0]const u8, ext: [*:0]const u8) bool {
    return std.ascii.endsWithIgnoreCase(std.mem.span(name), std.mem.span(ext));
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

pub export fn zod_points_within_distance(x1: c_int, y1: c_int, x2: c_int, y2: c_int, distance: c_int) bool {
    // quick bounding-box rejection
    if (x2 < x1 - distance or x2 > x1 + distance) return false;
    if (y2 < y1 - distance or y2 > y1 + distance) return false;

    // inside the inscribed square (side = distance * sin 45°)
    const inner: c_int = @intFromFloat(@floor(@as(f64, @floatFromInt(distance)) * 0.707106781 + 0.5));
    const dx: c_int = @intCast(@abs(x1 - x2));
    const dy: c_int = @intCast(@abs(y1 - y2));
    if (dx < inner and dy < inner) return true;

    const d2: f64 = @floatFromInt(dx * dx + dy * dy);
    return @sqrt(d2) <= @as(f64, @floatFromInt(distance));
}

pub export fn zod_points_within_area(px: c_int, py: c_int, ax: c_int, ay: c_int, aw: c_int, ah: c_int) bool {
    return px >= ax and py >= ay and px <= ax + aw and py <= ay + ah;
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

pub export fn zod_create_folder(foldername: [*:0]const u8) void {
    if (builtin.os.tag == .windows) @compileError("not supported");
    if (c.mkdir(foldername, 0o775) == 0) return;
    const err = c.errno(@as(c_int, -1));
    if (err != .EXIST) {
        _ = c.printf("create_folder: could not create '%s' (errno %d)\n", foldername, @as(c_int, @intFromEnum(err)));
    }
}

pub export fn zod_file_can_be_written(filename: [*:0]const u8) bool {
    const fp = c.fopen(filename, "a") orelse return false;
    _ = c.fclose(fp);
    return true;
}

/// Called with the name of every regular file in `foldername` ("" = ".").
pub const FileCallback = *const fn (ctx: ?*anyopaque, name: [*:0]const u8) callconv(.c) void;

pub export fn zod_directory_filelist(foldername: [*:0]const u8, callback: FileCallback, ctx: ?*anyopaque) void {
    const folder: [*:0]const u8 = if (foldername[0] == 0) "." else foldername;
    const dir = c.opendir(folder) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        if (entry.type == c.DT.REG) callback(ctx, @ptrCast(&entry.name));
    }
}

// ---------------------------------------------------------------------------
// Debug output (stdout via printf, so it interleaves with the C++ output)
// ---------------------------------------------------------------------------

pub export fn zod_print_dump(message: [*]const u8, size: c_int, name: [*:0]const u8) void {
    _ = c.printf("raw dump:%s:", name);
    var i: usize = 0;
    // The C++ version passed (signed) char to %x, so negative bytes printed
    // as ffffffxx; keep that.
    while (i < size) : (i += 1) _ = c.printf("%2.2x ", @as(c_int, @as(i8, @bitCast(message[i]))));
    _ = c.printf("\n");
}

extern "c" fn time(t: ?*c.time_t) c.time_t;
extern "c" fn localtime(t: *const c.time_t) ?*anyopaque;
extern "c" fn asctime(tm: *const anyopaque) ?[*:0]const u8;
extern "c" fn fprintf(fp: *c.FILE, format: [*:0]const u8, ...) c_int;

/// Append a time-stamped line to reg_log.txt.
pub export fn zod_printd_reg(message: [*:0]const u8) void {
    var now = time(null);
    var timebuf: [100]u8 = undefined;
    timebuf[0] = 0;
    if (localtime(&now)) |tm| if (asctime(tm)) |s| {
        const str = std.mem.span(s);
        const n = @min(str.len, timebuf.len - 1);
        @memcpy(timebuf[0..n], str[0..n]);
        timebuf[n] = 0;
    };
    zod_clean_newline(&timebuf, timebuf.len);

    const ofp = c.fopen("reg_log.txt", "a") orelse return;
    defer _ = c.fclose(ofp);
    _ = fprintf(ofp, "%-12s :: %s\n", @as([*:0]const u8, @ptrCast(&timebuf)), message);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "split walks through tokens" {
    const msg = "abc,de,,f";
    var buf: [8]u8 = undefined;
    var pos: c_int = 0;
    const expect = [_][]const u8{ "abc", "de", "", "f" };
    for (expect) |want| {
        zod_split(&buf, msg, ',', &pos, buf.len, msg.len);
        try std.testing.expectEqualStrings(want, std.mem.sliceTo(&buf, 0));
    }
    try std.testing.expectEqual(@as(c_int, msg.len), pos);
}

test "split truncates to destination size" {
    const msg = "abcdefgh";
    var buf: [4]u8 = undefined;
    var pos: c_int = 0;
    zod_split(&buf, msg, ' ', &pos, buf.len, msg.len);
    try std.testing.expectEqualStrings("abc", std.mem.sliceTo(&buf, 0));
}

test "clean_newline" {
    var s = "hello\r\nworld".*;
    zod_clean_newline(&s, s.len);
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(&s, 0));
}

test "good_user_string" {
    try std.testing.expect(goodUserString("Player_1 x@y.z"));
    try std.testing.expect(!goodUserString(""));
    try std.testing.expect(!goodUserString(" lead"));
    try std.testing.expect(!goodUserString("trail "));
    try std.testing.expect(!goodUserString("dou  ble"));
    try std.testing.expect(!goodUserString("bad!"));
}

test "points_within_distance matches a plain distance check" {
    var x: c_int = -30;
    while (x <= 30) : (x += 1) {
        var y: c_int = -30;
        while (y <= 30) : (y += 1) {
            const d: c_int = 20;
            const want = @sqrt(@as(f64, @floatFromInt(x * x + y * y))) <= @as(f64, @floatFromInt(d));
            try std.testing.expectEqual(want, zod_points_within_distance(0, 0, x, y, d));
        }
    }
}

test "hex and extension helpers" {
    var out: [9]u8 = undefined;
    zod_data_to_hex(&[_]u8{ 0x00, 0xab, 0x10, 0xff }, 4, &out);
    try std.testing.expectEqualStrings("00ab10ff", std.mem.sliceTo(&out, 0));
    try std.testing.expect(zod_has_extension("Level1.MAP", ".map"));
    try std.testing.expect(!zod_has_extension("map", ".map"));
}

test "current_time is monotonic and starts near zero" {
    const t1 = zod_current_time();
    zod_uni_pause(5);
    const t2 = zod_current_time();
    try std.testing.expect(t1 >= 0 and t2 - t1 >= 0.004);
}
