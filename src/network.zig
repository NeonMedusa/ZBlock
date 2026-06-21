const winsock = @import("winsock.zig");
// network.zig — 局域网联机网络模块（TCP，直接 posix socket）
// 包格式：u32(tag + serial) | payload
// tag=0: ClientInput（客机位置+方块操作）, tag=1: ServerState（快照+block_updates[]）

const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const Vec3i = @import("algebra.zig").Vec3i;
const ECS = @import("zigecs");

pub const SERVER_PORT: u16 = 9123;

/// 客户端 → 服务端：客机位置/朝向/方块操作（不含移动意图，物理在客机本地跑）
pub const ClientInput = struct {
    serial: u32,
    pos: Vec3,
    cam_yaw: f32,
    cam_pitch: f32,
    break_block: bool,
    place_block: bool,
    hotbar_slot: u32,
    target: Vec3i = Vec3i.zero,
    place_face: u8 = 0,
    attack_entity: bool = false,
    attack_target_raw: u32 = 0, // 服务端 ECS.Entity 编码为 u32
};

/// 服务端 → 客户端：实体状态快照
pub const EntitySnapshot = struct {
    player_id: u32,
    entity: ECS.Entity, // 完整 ECS 实体（index+version），精确匹配
    pos: Vec3,
    facing_yaw: f32,
    facing_pitch: f32,
};

/// 方块增量更新（嵌入 ServerState，不消耗额外 tag）
pub const BlockUpdate = struct {
    x: i32,
    y: i32,
    z: i32,
    block_id: u16,
    facing: u8,
    origin_player_id: u32, // 发起者，网络线程据此跳过发给发起者
};

/// 掉落更新（嵌入 ServerState）
pub const DropUpdate = struct {
    item_id: u32,
    count: u32,
    target_player_id: u32,
};

pub const ServerState = struct {
    serial: u32,
    tick_count: u64, // 服务端 tick 序号（插值时间线用）
    host_time: i64,  // 主机发送时的单调时钟 ns（延迟测量用）
    entities: []const EntitySnapshot,
    block_updates: []const BlockUpdate,
    drops: []const DropUpdate,
};

/// 设置 socket 接收超时（Windows 用 DWORD 毫秒，其他平台用 timeval）
pub fn setRecvTimeout(fd: winsock.socket_t) void {
    if (@import("builtin").os.tag == .windows) {
        // Windows: SO_RCVTIMEO 期望 DWORD（毫秒）
        const ms: u32 = 1;
        _ = winsock.setsockopt(fd, winsock.SOL_SOCKET, winsock.SO_RCVTIMEO, @ptrCast(&ms), @sizeOf(@TypeOf(ms)));
    } else {
        const tv = winsock.timeval{ .sec = 0, .usec = 1000 };
        _ = winsock.setsockopt(fd, winsock.SOL_SOCKET, winsock.SO_RCVTIMEO, &std.mem.toBytes(tv));
    }
}

/// 创建一个 TCP socket 并监听
pub fn listen(port: u16) winsock.socket_t {
    const fd = winsock.socket(winsock.AF_INET, winsock.SOCK_STREAM, winsock.IPPROTO_TCP);
    if (fd < 0) return -1;
    _ = winsock.setsockopt(fd, winsock.SOL_SOCKET, winsock.SO_REUSEADDR, @ptrCast(&@as(i32, 1)), @sizeOf(i32));
    var addr = winsock.sockaddr_in{
        .family = @as(u16, @intCast(winsock.AF_INET)),
        .port = @byteSwap(port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };
    if (winsock.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) { _ = winsock.closesocket(fd); return -1; }
    if (winsock.listen(fd, 4) != 0) { _ = winsock.closesocket(fd); return -1; }
    return fd;
}

/// 连接到服务端
pub fn connect(host: [4]u8, port: u16) winsock.socket_t {
    const fd = winsock.socket(winsock.AF_INET, winsock.SOCK_STREAM, winsock.IPPROTO_TCP);
    if (fd < 0) return -1;
    const host_int = @as(u32, @bitCast(host));
    var addr = winsock.sockaddr_in{
        .family = @as(u16, @intCast(winsock.AF_INET)),
        .port = @byteSwap(port),
        .addr = host_int,
        .zero = [_]u8{0} ** 8,
    };
    if (winsock.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) { _ = winsock.closesocket(fd); return -1; }
    return fd;
}

/// 发送 ClientInput（阻塞）
pub fn sendInput(fd: winsock.socket_t, input: *const ClientInput) void {
    const tag: u32 = 0;
    var buf: [4 + @sizeOf(ClientInput)]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], tag << 30 | (input.serial & 0x3FFFFFFF), .little);
    const ptr: [*]const u8 = @ptrCast(input);
    @memcpy(buf[4..], ptr[0..@sizeOf(ClientInput)]);
    _ = winsock.@"send"(fd, &buf, @intCast(buf.len), 0);
}

/// 接收 ClientInput（非阻塞，true=有新数据，false=断线，WouldBlock=无数据）
pub fn recvInput(fd: winsock.socket_t, input: *ClientInput) bool {
    var buf: [4 + @sizeOf(ClientInput)]u8 = undefined;
    const n = recvAll(fd, &buf);
    if (n == 0) return false;
    if (n < @sizeOf(@TypeOf(buf))) return false; // 数据不完整，下次再收
    const tag = std.mem.readInt(u32, buf[0..4], .little) >> 30;
    if (tag != 0) return false;
    input.serial = std.mem.readInt(u32, buf[0..4], .little) & 0x3FFFFFFF;
    const ptr: [*]u8 = @ptrCast(input);
    @memcpy(ptr[0..@sizeOf(ClientInput)], buf[4..]);
    return true;
}

/// 发送 ServerState（阻塞）
pub fn sendState(fd: winsock.socket_t, state: *const ServerState) void {
    const tag: u32 = 1;
    const bu_count_u32: u32 = @intCast(state.block_updates.len);
    const drop_count_u32: u32 = @intCast(state.drops.len);
    const payload_len = 8 + 8 + 8 + state.entities.len * @sizeOf(EntitySnapshot) + 4 + state.block_updates.len * @sizeOf(BlockUpdate) + 4 + state.drops.len * @sizeOf(DropUpdate);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    buf.ensureTotalCapacity(std.heap.page_allocator, payload_len) catch {};
    buf.items.len = payload_len;
    std.mem.writeInt(u32, buf.items[0..4], tag << 30 | (state.serial & 0x3FFFFFFF), .little);
    const count_u32: u32 = @intCast(state.entities.len);
    std.mem.writeInt(u32, buf.items[4..8], count_u32, .little);
    std.mem.writeInt(i64, buf.items[8..16], state.host_time, .little);
    std.mem.writeInt(u64, buf.items[16..24], state.tick_count, .little);
    var offset: usize = 24;
    for (state.entities) |*e| {
        @memcpy(buf.items[offset..][0..@sizeOf(EntitySnapshot)], std.mem.asBytes(e));
        offset += @sizeOf(EntitySnapshot);
    }
    std.mem.writeInt(u32, buf.items[offset..][0..4], bu_count_u32, .little);
    offset += 4;
    for (state.block_updates) |*u| {
        @memcpy(buf.items[offset..][0..@sizeOf(BlockUpdate)], std.mem.asBytes(u));
        offset += @sizeOf(BlockUpdate);
    }
    std.mem.writeInt(u32, buf.items[offset..][0..4], drop_count_u32, .little);
    offset += 4;
    for (state.drops) |*d| {
        @memcpy(buf.items[offset..][0..@sizeOf(DropUpdate)], std.mem.asBytes(d));
        offset += @sizeOf(DropUpdate);
    }
    _ = winsock.@"send"(fd, buf.items.ptr, @intCast(buf.items.len), 0);
}

/// 发送区块数据（tag=2）。origin 为 chunk 原点，palette_json 和 index_data 与存档格式相同
pub fn sendChunk(fd: winsock.socket_t, serial: u32, origin_x: i32, origin_z: i32, palette_json: []const u8, index_data: []const u8) void {
    // 总大小: 4+4+4+4+palette_json.len+4+index_data.len
    const total = 4 + 4 + 4 + 4 + palette_json.len + 4 + index_data.len;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    buf.ensureTotalCapacity(std.heap.page_allocator, total) catch {};
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

    _ = winsock.@"send"(fd, buf.items.ptr, @intCast(buf.items.len), 0);
}

/// 发送 welcome（无 tag，裸 4 字节）：分配 player_id 给新连接的客机
pub fn sendWelcome(fd: winsock.socket_t, player_id: u32) void {
    _ = winsock.@"send"(fd, @ptrCast(&player_id), 4, 0);
}

pub fn recvWelcome(fd: winsock.socket_t) u32 {
    var pid: u32 = undefined;
    _ = recvAll(fd, std.mem.asBytes(&pid));
    return pid;
}

/// 发送区块卸载指令（tag=3）
pub fn sendChunkUnload(fd: winsock.socket_t, origin_x: i32, origin_z: i32) void {
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @as(u32, 3) << 30, .little);
    std.mem.writeInt(i32, buf[4..8], origin_x, .little);
    std.mem.writeInt(i32, buf[8..12], origin_z, .little);
    _ = winsock.@"send"(fd, &buf, @intCast(buf.len), 0);
}

/// 接收区块数据。返回的 palette_json 和 index_data 需要调用者释放
pub fn recvChunk(fd: winsock.socket_t, allocator: std.mem.Allocator) ?struct { origin_x: i32, origin_z: i32, palette: []u8, data: []u8 } {
    var header: [16]u8 = undefined;
    const n = recvAll(fd, &header);
    if (n == 0) return null;
    const tag = std.mem.readInt(u32, header[0..4], .little) >> 30;
    if (tag != 2) return null;
    const origin_x = std.mem.readInt(i32, header[4..8], .little);
    const origin_z = std.mem.readInt(i32, header[8..12], .little);
    const pal_len = std.mem.readInt(u32, header[12..16], .little);
    if (pal_len > 1024 * 64) return null;

    const pal_buf = allocator.alloc(u8, pal_len) catch return null;
    errdefer allocator.free(pal_buf);
    _ = recvAll(fd, pal_buf);

    var data_len_buf: [4]u8 = undefined;
    _ = recvAll(fd, &data_len_buf);
    const data_len = std.mem.readInt(u32, &data_len_buf, .little);
    if (data_len > 1024 * 256) return null;

    const data_buf = allocator.alloc(u8, data_len) catch return null;
    errdefer allocator.free(data_buf);
    _ = recvAll(fd, data_buf);

    return .{ .origin_x = origin_x, .origin_z = origin_z, .palette = pal_buf, .data = data_buf };
}

/// 接收区块卸载指令（tag=3），返回 (origin_x, origin_z)
pub fn recvChunkUnload(fd: winsock.socket_t) ?struct { x: i32, z: i32 } {
    var header: [12]u8 = undefined;
    const n = recvAll(fd, &header);
    if (n < 12) return null;
    const tag = std.mem.readInt(u32, header[0..4], .little) >> 30;
    if (tag != 3) return null;
    return .{ .x = std.mem.readInt(i32, header[4..8], .little), .z = std.mem.readInt(i32, header[8..12], .little) };
}

/// 接收 ServerState（非阻塞，true=有新数据，false=断线，WouldBlock=无数据）
pub fn recvState(fd: winsock.socket_t, allocator: std.mem.Allocator, state: *ServerState) bool {
    var header: [24]u8 = undefined;
    const n = recvAll(fd, &header);
    if (n == 0) return false;
    if (n < header.len) return false;
    const tag = std.mem.readInt(u32, header[0..4], .little) >> 30;
    if (tag != 1) return false;
    state.serial = std.mem.readInt(u32, header[0..4], .little) & 0x3FFFFFFF;
    const count = std.mem.readInt(u32, header[4..8], .little);
    state.host_time = std.mem.readInt(i64, header[8..16], .little);
    state.tick_count = std.mem.readInt(u64, header[16..24], .little);
    if (count > 64) return false;
    const snapshots = allocator.alloc(EntitySnapshot, count) catch return false;
    if (count > 0) {
        const snap_bytes = recvAll(fd, std.mem.sliceAsBytes(snapshots));
        if (snap_bytes == 0) return false;
    }
    state.entities = snapshots;

    // 读取方块增量更新
    var bu_header: [4]u8 = undefined;
    if (recvAll(fd, &bu_header) < 4) return false;
    const bu_count = std.mem.readInt(u32, &bu_header, .little);
    if (bu_count > 256) return false;
    const updates = allocator.alloc(BlockUpdate, bu_count) catch return false;
    if (bu_count > 0) {
        const bu_bytes = recvAll(fd, std.mem.sliceAsBytes(updates));
        if (bu_bytes == 0) return false;
    }
    state.block_updates = updates;

    // 读取掉落更新
    var drop_header: [4]u8 = undefined;
    if (recvAll(fd, &drop_header) < 4) return false;
    const drop_count = std.mem.readInt(u32, &drop_header, .little);
    if (drop_count > 64) return false;
    const drops = allocator.alloc(DropUpdate, drop_count) catch return false;
    if (drop_count > 0) {
        const drop_bytes = recvAll(fd, std.mem.sliceAsBytes(drops));
        if (drop_bytes == 0) return false;
    }
    state.drops = drops;
    return true;
}

/// 读取数据包的前 2 bit 标签（不消耗数据）
pub fn peekTag(fd: winsock.socket_t) u32 {
    var header: [4]u8 = undefined;
    const n = winsock.@"recv"(fd, &header, header.len, winsock.MSG_PEEK);
    if (n < 0) return 0;
    if (n < 4) return 0;
    return std.mem.readInt(u32, &header, .little) >> 30;
}

/// 保证收满 len 字节（或返回 0）
fn recvAll(fd: winsock.socket_t, buf: []u8) usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = winsock.@"recv"(fd, buf[off..].ptr, @intCast(buf[off..].len), 0);
        if (n < 0) return 0;
        if (n == 0) return off;
        off += @as(usize, @intCast(n));
    }
    return off;
}
