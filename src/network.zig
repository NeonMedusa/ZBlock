// network.zig — 局域网联机网络模块（TCP，直接 posix socket）
// 包格式：u32(tag + serial) | payload
// tag=0: ClientInput, tag=1: ServerState

const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;

pub const SERVER_PORT: u16 = 9123;

/// 客户端 → 服务端：输入意图（含动作请求）
pub const ClientInput = struct {
    serial: u32,
    move_dir: Vec3,
    jump: bool,
    sprint: bool,
    sneak: bool,
    cam_yaw: f32,
    cam_pitch: f32,
    break_block: bool,
    place_block: bool,
    attack: bool,
    hotbar_slot: u32, // 客机当前选中的热栏槽位
    wants_fly: bool,
};

/// 服务端 → 客户端：实体状态快照
pub const EntitySnapshot = struct {
    player_id: u32,
    pos: Vec3,
    facing_yaw: f32,
    facing_pitch: f32,
};

pub const ServerState = struct {
    serial: u32,
    host_time: i64, // 主机发送时的单调时钟 ns
    entities: []const EntitySnapshot,
};

/// 设置 socket 接收超时（Windows 用 DWORD 毫秒，其他平台用 timeval）
pub fn setRecvTimeout(fd: std.posix.socket_t) void {
    if (@import("builtin").os.tag == .windows) {
        // Windows: SO_RCVTIMEO 期望 DWORD（毫秒）
        const ms: u32 = 1;
        _ = std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&ms)) catch {};
    } else {
        const tv = std.posix.timeval{ .sec = 0, .usec = 1000 };
        _ = std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};
    }
}

/// 创建一个 TCP socket 并监听
pub fn listen(port: u16) !std.posix.socket_t {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(fd);
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(i32, 1)));
    var addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
    try std.posix.listen(fd, 4);
    return fd;
}

/// 连接到服务端
pub fn connect(host: [4]u8, port: u16) !std.posix.socket_t {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(fd);
    var addr = std.net.Address.initIp4(host, port);
    try std.posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

/// 发送 ClientInput（阻塞）
pub fn sendInput(fd: std.posix.socket_t, input: *const ClientInput) !void {
    const tag: u32 = 0;
    var buf: [4 + @sizeOf(ClientInput)]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], tag << 30 | (input.serial & 0x3FFFFFFF), .little);
    const ptr: [*]const u8 = @ptrCast(input);
    @memcpy(buf[4..], ptr[0..@sizeOf(ClientInput)]);
    _ = try std.posix.send(fd, &buf, 0);
}

/// 接收 ClientInput（非阻塞，true=有新数据，false=断线，WouldBlock=无数据）
pub fn recvInput(fd: std.posix.socket_t, input: *ClientInput) !bool {
    var buf: [4 + @sizeOf(ClientInput)]u8 = undefined;
    const n = recvAll(fd, &buf) catch |err| switch (err) {
        error.ConnectionResetByPeer => return false,
        error.WouldBlock, error.ConnectionTimedOut => return error.WouldBlock,
        else => return err,
    };
    if (n == 0) return error.WouldBlock;
    if (n < buf.len) return error.WouldBlock; // 数据不完整，下次再收
    const tag = std.mem.readInt(u32, buf[0..4], .little) >> 30;
    if (tag != 0) return false;
    input.serial = std.mem.readInt(u32, buf[0..4], .little) & 0x3FFFFFFF;
    const ptr: [*]u8 = @ptrCast(input);
    @memcpy(ptr[0..@sizeOf(ClientInput)], buf[4..]);
    return true;
}

/// 发送 ServerState（阻塞）
pub fn sendState(fd: std.posix.socket_t, state: *const ServerState) !void {
    const tag: u32 = 1;
    const payload_len = 8 + 8 + state.entities.len * @sizeOf(EntitySnapshot);
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.heap.page_allocator);
    try buf.ensureTotalCapacity(std.heap.page_allocator, payload_len);
    buf.items.len = payload_len;
    std.mem.writeInt(u32, buf.items[0..4], tag << 30 | (state.serial & 0x3FFFFFFF), .little);
    const count_u32: u32 = @intCast(state.entities.len);
    std.mem.writeInt(u32, buf.items[4..8], count_u32, .little);
    // host_time（单调时钟 ns，用于延迟测量）
    std.mem.writeInt(i64, buf.items[8..16], state.host_time, .little);
    var offset: usize = 16;
    for (state.entities) |*e| {
        @memcpy(buf.items[offset..][0..@sizeOf(EntitySnapshot)], std.mem.asBytes(e));
        offset += @sizeOf(EntitySnapshot);
    }
    _ = try std.posix.send(fd, buf.items, 0);
}

/// 发送区块数据（tag=2）。origin 为 chunk 原点，palette_json 和 index_data 与存档格式相同
pub fn sendChunk(fd: std.posix.socket_t, serial: u32, origin_x: i32, origin_z: i32, palette_json: []const u8, index_data: []const u8) !void {
    // 总大小: 4+4+4+4+palette_json.len+4+index_data.len
    const total = 4 + 4 + 4 + 4 + palette_json.len + 4 + index_data.len;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.heap.page_allocator);
    try buf.ensureTotalCapacity(std.heap.page_allocator, total);
    buf.items.len = total;

    var off: usize = 0;
    std.mem.writeInt(u32, buf.items[off..][0..4], @as(u32, 2) << 30 | (serial & 0x3FFFFFFF), .little);
    off += 4;
    std.mem.writeInt(i32, buf.items[off..][0..4], origin_x, .little);
    off += 4;
    std.mem.writeInt(i32, buf.items[off..][0..4], origin_z, .little);
    off += 4;
    // palette JSON
    std.mem.writeInt(u32, buf.items[off..][0..4], @as(u32, @intCast(palette_json.len)), .little);
    off += 4;
    @memcpy(buf.items[off..][0..palette_json.len], palette_json);
    off += palette_json.len;
    // index_data
    std.mem.writeInt(u32, buf.items[off..][0..4], @as(u32, @intCast(index_data.len)), .little);
    off += 4;
    @memcpy(buf.items[off..][0..index_data.len], index_data);

    _ = try std.posix.send(fd, buf.items, 0);
}

/// 发送区块卸载指令（tag=3）
pub fn sendChunkUnload(fd: std.posix.socket_t, origin_x: i32, origin_z: i32) !void {
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @as(u32, 3) << 30, .little);
    std.mem.writeInt(i32, buf[4..8], origin_x, .little);
    std.mem.writeInt(i32, buf[8..12], origin_z, .little);
    _ = try std.posix.send(fd, &buf, 0);
}

/// 接收区块数据。返回的 palette_json 和 index_data 需要调用者释放
pub fn recvChunk(fd: std.posix.socket_t, allocator: std.mem.Allocator) !?struct { origin_x: i32, origin_z: i32, palette: []u8, data: []u8 } {
    var header: [16]u8 = undefined;
    const n = recvAll(fd, &header) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.ConnectionTimedOut => return null,
        else => return err,
    };
    if (n == 0) return null;
    const tag = std.mem.readInt(u32, header[0..4], .little) >> 30;
    if (tag != 2) return null;
    const origin_x = std.mem.readInt(i32, header[4..8], .little);
    const origin_z = std.mem.readInt(i32, header[8..12], .little);
    const pal_len = std.mem.readInt(u32, header[12..16], .little);
    if (pal_len > 1024 * 64) return null;

    const pal_buf = try allocator.alloc(u8, pal_len);
    errdefer allocator.free(pal_buf);
    _ = try recvAll(fd, pal_buf);

    var data_len_buf: [4]u8 = undefined;
    _ = try recvAll(fd, &data_len_buf);
    const data_len = std.mem.readInt(u32, &data_len_buf, .little);
    if (data_len > 1024 * 256) return null;

    const data_buf = try allocator.alloc(u8, data_len);
    errdefer allocator.free(data_buf);
    _ = try recvAll(fd, data_buf);

    return .{ .origin_x = origin_x, .origin_z = origin_z, .palette = pal_buf, .data = data_buf };
}

/// 接收区块卸载指令（tag=3），返回 (origin_x, origin_z)
pub fn recvChunkUnload(fd: std.posix.socket_t) !?struct { x: i32, z: i32 } {
    var header: [12]u8 = undefined;
    const n = recvAll(fd, &header) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.ConnectionTimedOut, error.WouldBlock => return null,
        else => return err,
    };
    if (n < 12) return null;
    const tag = std.mem.readInt(u32, header[0..4], .little) >> 30;
    if (tag != 3) return null;
    return .{ .x = std.mem.readInt(i32, header[4..8], .little), .z = std.mem.readInt(i32, header[8..12], .little) };
}

/// 接收 ServerState（非阻塞，true=有新数据，false=断线，WouldBlock=无数据）
pub fn recvState(fd: std.posix.socket_t, allocator: std.mem.Allocator, state: *ServerState) !bool {
    var header: [16]u8 = undefined;
    const n = recvAll(fd, &header) catch |err| switch (err) {
        error.ConnectionResetByPeer => return false,
        error.WouldBlock, error.ConnectionTimedOut => return error.WouldBlock,
        else => return err,
    };
    if (n == 0) return error.WouldBlock;
    if (n < header.len) return error.WouldBlock;
    const tag = std.mem.readInt(u32, header[0..4], .little) >> 30;
    if (tag != 1) return false;
    state.serial = std.mem.readInt(u32, header[0..4], .little) & 0x3FFFFFFF;
    const count = std.mem.readInt(u32, header[4..8], .little);
    state.host_time = std.mem.readInt(i64, header[8..16], .little);
    if (count > 64) return false; // sanity
    const snapshots = try allocator.alloc(EntitySnapshot, count);
    if (count > 0) {
        const snap_bytes = try recvAll(fd, std.mem.sliceAsBytes(snapshots));
        if (snap_bytes == 0) return false;
    }
    state.entities = snapshots;
    return true;
}

/// 读取数据包的前 2 bit 标签（不消耗数据）
pub fn peekTag(fd: std.posix.socket_t) !u32 {
    var header: [4]u8 = undefined;
    const n = std.posix.recv(fd, &header, std.posix.MSG.PEEK) catch |err| switch (err) {
        error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
        error.ConnectionTimedOut, error.WouldBlock => return error.WouldBlock,
        else => return err,
    };
    if (n < 4) return error.WouldBlock;
    return std.mem.readInt(u32, &header, .little) >> 30;
}

/// 保证收满 len 字节（或返回 0）
fn recvAll(fd: std.posix.socket_t, buf: []u8) !usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.posix.recv(fd, buf[off..], 0) catch |err| switch (err) {
            error.ConnectionResetByPeer => return 0,
            error.ConnectionTimedOut => return off, // 超时 = 当前没数据，不视为断线
            error.WouldBlock => return off,
            else => return err,
        };
        if (n == 0) return off;
        off += n;
    }
    return off;
}
