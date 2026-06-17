//! Windows socket API wrapper (ws2_32.dll)
//! 提供 POSIX 兼容的 socket 接口

const std = @import("std");

pub const socket_t = i32;

pub const AF_INET = 2;
pub const SOCK_STREAM = 1;
pub const IPPROTO_TCP = 6;
pub const SOL_SOCKET = 0xFFFF;
pub const SO_REUSEADDR = 0x0004;
pub const SO_RCVTIMEO = 0x1006;
pub const MSG_PEEK = 0x0002;

pub const FD_SETSIZE = 64;

pub const fd_set = extern struct {
    fd_count: u32,
    fd_array: [FD_SETSIZE]usize,  // SOCKET = UINT_PTR
};

pub const timeval = extern struct {
    sec: i32,
    usec: i32,
};

pub const sockaddr_in = extern struct {
    family: i16,
    port: u16,
    addr: u32,
    zero: [8]u8 = [_]u8{0} ** 8,
};

pub extern "ws2_32" fn socket(af: i32, socktype: i32, protocol: i32) callconv(.c) socket_t;
pub extern "ws2_32" fn bind(s: socket_t, addr: *const anyopaque, namelen: i32) callconv(.c) i32;
pub extern "ws2_32" fn listen(s: socket_t, backlog: i32) callconv(.c) i32;
pub extern "ws2_32" fn connect(s: socket_t, addr: *const anyopaque, namelen: i32) callconv(.c) i32;
pub extern "ws2_32" fn accept(s: socket_t, addr: ?*anyopaque, addrlen: ?*i32) callconv(.c) socket_t;
pub extern "ws2_32" fn @"send"(s: socket_t, buf: *const anyopaque, len: i32, flags: i32) callconv(.c) i32;
pub extern "ws2_32" fn @"recv"(s: socket_t, buf: *anyopaque, len: i32, flags: i32) callconv(.c) i32;
pub extern "ws2_32" fn closesocket(s: socket_t) callconv(.c) i32;
pub extern "ws2_32" fn setsockopt(s: socket_t, level: i32, optname: i32, optval: *const anyopaque, optlen: i32) callconv(.c) i32;
pub extern "ws2_32" fn select(nfds: i32, readfds: ?*fd_set, writefds: ?*fd_set, exceptfds: ?*fd_set, timeout: ?*timeval) callconv(.c) i32;
pub extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.c) i32;
pub extern "ws2_32" fn WSACleanup() callconv(.c) i32;

/// 初始化 Winsock（在进程启动时调用一次）
pub fn startup() void {
    var data: [512]u8 = undefined;
    if (WSAStartup(0x0202, &data) != 0) {
        @panic("WSAStartup failed");
    }
}
