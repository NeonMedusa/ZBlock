// bitstream.zig — 位读写工具
const std = @import("std");

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
