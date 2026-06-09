// bitstream.zig — 位读写工具
const std = @import("std");

/// 从 buf 的 bit_offset 位开始读取 bits 位（随机访问，常数时间）
pub fn readBits(buf: []const u8, bit_offset: usize, bits: u5) u32 {
    const byte_pos = bit_offset >> 3;
    const bit_shift = @as(u5, @intCast(bit_offset & 7));
    if (bit_shift + bits <= 8) {
        return (@as(u32, buf[byte_pos]) >> @as(u3, @intCast(bit_shift))) & ((@as(u32, 1) << bits) - 1);
    }
    const v = @as(u32, buf[byte_pos]) | (@as(u32, buf[byte_pos + 1]) << 8);
    return (v >> @as(u3, @intCast(bit_shift))) & ((@as(u32, 1) << bits) - 1);
}

/// 向 buf 的 bit_offset 位写入 value 的低 bits 位（随机访问，常数时间）
pub fn writeBits(buf: []u8, bit_offset: usize, value: u32, bits: u5) void {
    const byte_pos = bit_offset >> 3;
    const bit_shift = @as(u5, @intCast(bit_offset & 7));
    const mask = (@as(u32, 1) << bits) - 1;
    const v = value & mask;
    if (bit_shift + bits <= 8) {
        const smask = @as(u8, @intCast(mask << @as(u3, @intCast(bit_shift))));
        buf[byte_pos] = (buf[byte_pos] & ~smask) | @as(u8, @intCast(v << @as(u3, @intCast(bit_shift))));
    } else {
        const low_bits: u5 = 8 - bit_shift;
        const low_shift: u3 = @intCast(bit_shift);
        const v_low = v & ((@as(u32, 1) << low_bits) - 1);
        buf[byte_pos] = (buf[byte_pos] & ~@as(u8, @intCast(((@as(u32, 1) << low_bits) - 1) << @as(u3, @intCast(bit_shift))))) | @as(u8, @intCast(v_low << low_shift));
        const high_bits: u5 = bits - low_bits;
        const v_high = v >> low_bits;
        buf[byte_pos + 1] = @as(u8, @intCast(@as(u32, buf[byte_pos + 1]) & ~((@as(u32, 1) << high_bits) - 1))) | @as(u8, @intCast(v_high));
    }
}

pub const BitWriter = struct {
    buf: []u8,
    byte_pos: usize = 0,
    bit_pos: u4 = 0,

    pub fn write(self: *BitWriter, value: u32, bits: u32) void {
        var v = value;
        var remaining = bits;
        while (remaining > 0) {
            const space = 8 - self.bit_pos;
            const take = @min(space, remaining);
            const mask = (@as(u32, 1) << take) - 1;
            self.buf[self.byte_pos] |= @as(u8, @intCast((v & mask) << @as(u3, @intCast(self.bit_pos))));
            v >>= take;
            self.bit_pos += take;
            remaining -= take;
            if (self.bit_pos == 8) {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }
    }

    pub fn finish(self: *BitWriter) usize {
        if (self.bit_pos > 0) self.byte_pos += 1;
        return self.byte_pos;
    }
};

pub const BitReader = struct {
    buf: []const u8,
    byte_pos: usize = 0,
    bit_pos: u4 = 0,

    pub fn read(self: *BitReader, bits: u32) u32 {
        var result: u32 = 0;
        var remaining = bits;
        var shift: u32 = 0;
        while (remaining > 0) {
            const space = 8 - self.bit_pos;
            const take = @min(space, remaining);
            const mask = (@as(u32, 1) << take) - 1;
            result |= (@as(u32, self.buf[self.byte_pos] >> @as(u3, @intCast(self.bit_pos))) & mask) << @as(u5, @intCast(shift));
            shift += take;
            self.bit_pos += take;
            remaining -= take;
            if (self.bit_pos == 8) {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }
        return result;
    }
};
