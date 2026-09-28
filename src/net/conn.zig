//! Non-blocking TCP connections carrying framed protocol messages (replaces
//! socket_handler.cpp, server_socket.cpp and client_socket.cpp).
//!
//! Uses the C socket API directly (std.c), which behaves the same on macOS
//! and Linux. Unlike the original, outgoing data is buffered so partial
//! sends never lose or corrupt messages.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const c = std.c;

pub const default_port = 8000;

/// Bytes a peer may have buffered before we consider it dead (the original
/// dropped data beyond MAX_DATA_STORED).
const max_buffered = 4 << 20;

const send_flags: u32 = if (@hasDecl(c.MSG, "NOSIGNAL")) c.MSG.NOSIGNAL | c.MSG.DONTWAIT else c.MSG.DONTWAIT;

pub const Error = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    ResolveFailed,
    ConnectFailed,
} || std.mem.Allocator.Error;

/// A received message. `payload` is valid until the next `receive` call.
pub const Frame = struct {
    id: protocol.Message,
    payload: []const u8,
};

pub const Conn = struct {
    fd: c.fd_t,
    /// Peer IPv4 address as text.
    address: [16]u8 = @splat(0),
    in: std.ArrayList(u8) = .empty,
    /// Start of unprocessed data in `in`.
    in_pos: usize = 0,
    out: std.ArrayList(u8) = .empty,
    open: bool = true,

    fn init(fd: c.fd_t, addr: c.sockaddr.in) Conn {
        disableSigpipe(fd);
        var conn: Conn = .{ .fd = fd };
        const ip: [4]u8 = @bitCast(addr.addr);
        _ = std.fmt.bufPrint(&conn.address, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
        return conn;
    }

    /// Blocking connect to `host:port`.
    pub fn connect(host: [:0]const u8, port: u16) Error!Conn {
        const addr = try resolve(host, port);
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.ConnectFailed;
        setNoDelay(fd);
        return init(fd, addr);
    }

    pub fn deinit(conn: *Conn, gpa: std.mem.Allocator) void {
        conn.close();
        conn.in.deinit(gpa);
        conn.out.deinit(gpa);
    }

    pub fn close(conn: *Conn) void {
        if (!conn.open) return;
        _ = c.close(conn.fd);
        conn.open = false;
    }

    pub fn addressSlice(conn: *const Conn) []const u8 {
        return std.mem.sliceTo(&conn.address, 0);
    }

    /// Queue a message and try to send it right away.
    pub fn send(conn: *Conn, gpa: std.mem.Allocator, id: protocol.Message, payload: []const u8) std.mem.Allocator.Error!void {
        if (!conn.open) return;
        if (conn.out.items.len + payload.len > max_buffered) {
            // The peer isn't reading; give up on it.
            conn.close();
            return;
        }
        var header: [protocol.header_size]u8 = undefined;
        std.mem.writeInt(i32, header[0..4], @intCast(payload.len), .little);
        std.mem.writeInt(i32, header[4..8], @intFromEnum(id), .little);
        try conn.out.appendSlice(gpa, &header);
        try conn.out.appendSlice(gpa, payload);
        conn.flush();
    }

    /// Send a fixed-size packet struct.
    pub fn sendPacket(conn: *Conn, gpa: std.mem.Allocator, id: protocol.Message, packet: anytype) std.mem.Allocator.Error!void {
        try conn.send(gpa, id, protocol.bytesOf(&packet));
    }

    /// Send a C string (with its terminating 0, like the original).
    pub fn sendString(conn: *Conn, gpa: std.mem.Allocator, id: protocol.Message, text: []const u8) std.mem.Allocator.Error!void {
        if (!conn.open) return;
        var header: [protocol.header_size]u8 = undefined;
        std.mem.writeInt(i32, header[0..4], @intCast(text.len + 1), .little);
        std.mem.writeInt(i32, header[4..8], @intFromEnum(id), .little);
        try conn.out.appendSlice(gpa, &header);
        try conn.out.appendSlice(gpa, text);
        try conn.out.append(gpa, 0);
        conn.flush();
    }

    /// Send as much buffered output as the socket takes without blocking.
    pub fn flush(conn: *Conn) void {
        while (conn.open and conn.out.items.len > 0) {
            const n = c.send(conn.fd, conn.out.items.ptr, conn.out.items.len, send_flags);
            if (n < 0) {
                switch (c.errno(n)) {
                    .AGAIN, .INTR => return,
                    else => return conn.close(),
                }
            }
            const sent: usize = @intCast(n);
            std.mem.copyForwards(u8, conn.out.items, conn.out.items[sent..]);
            conn.out.shrinkRetainingCapacity(conn.out.items.len - sent);
        }
    }

    /// Read whatever arrived. Call `next` afterwards to get the messages.
    pub fn receive(conn: *Conn, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        // Drop the messages returned since the last call.
        if (conn.in_pos > 0) {
            const rest = conn.in.items[conn.in_pos..];
            std.mem.copyForwards(u8, conn.in.items, rest);
            conn.in.shrinkRetainingCapacity(rest.len);
            conn.in_pos = 0;
        }
        conn.flush();
        while (conn.open) {
            try conn.in.ensureUnusedCapacity(gpa, 64 * 1024);
            const buf = conn.in.unusedCapacitySlice();
            const n = c.recv(conn.fd, buf.ptr, buf.len, @intCast(c.MSG.DONTWAIT));
            if (n == 0) return conn.close(); // peer closed
            if (n < 0) {
                switch (c.errno(n)) {
                    .AGAIN, .INTR => return,
                    else => return conn.close(),
                }
            }
            conn.in.items.len += @intCast(n);
            if (conn.in.items.len > max_buffered) return conn.close();
        }
    }

    /// The next complete message received, if any.
    pub fn next(conn: *Conn) ?Frame {
        const data = conn.in.items[conn.in_pos..];
        if (data.len < protocol.header_size) return null;
        const size = std.mem.readInt(i32, data[0..4], .little);
        const id = std.mem.readInt(i32, data[4..8], .little);
        if (size < 0 or size > max_buffered) {
            // Garbage: the stream can't be trusted any more.
            conn.close();
            return null;
        }
        const total = protocol.header_size + @as(usize, @intCast(size));
        if (data.len < total) return null;
        conn.in_pos += total;
        return .{ .id = @enumFromInt(id), .payload = data[protocol.header_size..total] };
    }
};

pub const Listener = struct {
    fd: c.fd_t,

    pub fn listen(port: u16) Error!Listener {
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        const on: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &on, @sizeOf(c_int));
        const addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.BindFailed;
        if (c.listen(fd, 16) != 0) return error.ListenFailed;
        return .{ .fd = fd };
    }

    pub fn deinit(l: *Listener) void {
        _ = c.close(l.fd);
    }

    /// A new connection if one is waiting (never blocks).
    pub fn accept(l: *Listener) ?Conn {
        var pfd = [_]c.pollfd{.{ .fd = l.fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&pfd, 1, 0) <= 0) return null;
        var addr: c.sockaddr.in = undefined;
        var len: c.socklen_t = @sizeOf(c.sockaddr.in);
        const fd = c.accept(l.fd, @ptrCast(&addr), &len);
        if (fd < 0) return null;
        setNoDelay(fd);
        return Conn.init(fd, addr);
    }
};

fn resolve(host: [:0]const u8, port: u16) Error!c.sockaddr.in {
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = c.AF.INET;
    hints.socktype = c.SOCK.STREAM;
    var res: ?*c.addrinfo = null;
    if (@intFromEnum(c.getaddrinfo(host.ptr, null, &hints, &res)) != 0) return error.ResolveFailed;
    const info = res orelse return error.ResolveFailed;
    defer c.freeaddrinfo(info);
    var addr: c.sockaddr.in = @as(*const c.sockaddr.in, @ptrCast(@alignCast(info.addr.?))).*;
    addr.port = std.mem.nativeToBig(u16, port);
    return addr;
}

fn setNoDelay(fd: c.fd_t) void {
    // Game messages are small and latency-sensitive.
    const on: c_int = 1;
    _ = c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, &on, @sizeOf(c_int));
}

fn disableSigpipe(fd: c.fd_t) void {
    // Linux uses MSG_NOSIGNAL per send; macOS has a socket option instead.
    if (@hasDecl(c.SO, "NOSIGPIPE")) {
        const on: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &on, @sizeOf(c_int));
    }
}

test "messages go through a real socket pair" {
    const gpa = std.testing.allocator;
    var listener = try Listener.listen(18766);
    defer listener.deinit();

    var client = try Conn.connect("127.0.0.1", 18766);
    defer client.deinit(gpa);
    var server: Conn = while (true) {
        if (listener.accept()) |conn| break conn;
    };
    defer server.deinit(gpa);
    try std.testing.expectEqualStrings("127.0.0.1", server.addressSlice());

    // A large message followed by small ones.
    const big = try gpa.alloc(u8, 300_000);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);
    try client.send(gpa, .store_map, big);
    try client.sendPacket(gpa, .update_health, protocol.ObjectHealth{ .ref_id = 5, .health = 77 });
    try client.sendString(gpa, .send_chat, "hello");

    var got: usize = 0;
    var attempts: usize = 0;
    while (got < 3 and attempts < 10_000) : (attempts += 1) {
        client.flush();
        try server.receive(gpa);
        while (server.next()) |frame| {
            switch (got) {
                0 => {
                    try std.testing.expectEqual(protocol.Message.store_map, frame.id);
                    try std.testing.expectEqualSlices(u8, big, frame.payload);
                },
                1 => try std.testing.expectEqual(@as(i32, 77), protocol.decode(protocol.ObjectHealth, frame.payload).?.health),
                2 => try std.testing.expectEqualStrings("hello", protocol.decodeString(frame.payload)),
                else => unreachable,
            }
            got += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), got);

    // Closing one side is noticed by the other.
    client.close();
    attempts = 0;
    while (server.open and attempts < 10_000) : (attempts += 1) try server.receive(gpa);
    try std.testing.expect(!server.open);
}
