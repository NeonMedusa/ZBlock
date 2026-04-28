const std = @import("std");
const ecs = @import("ecs");

// override the EntityTraits used by ecs
pub const EntityTraits = ecs.EntityTraitsType(.medium);

pub const Velocity = struct { x: f32, y: f32 };
pub const Position = struct { x: f32, y: f32 };

const total_entities: usize = 10000;

/// logs the timing for views vs non-owning groups vs owning groups with 1,000,000 entities
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var reg = ecs.Registry.init(std.heap.c_allocator);
    defer reg.deinit();

    createEntities(&reg, io);
    owningGroup(&reg, io);
}

fn createEntities(reg: *ecs.Registry, io: std.Io) void {
    var r = std.Random.DefaultPrng.init(666);

    var start = std.Io.Timestamp.now(io, .awake);
    var i: usize = 0;
    while (i < total_entities) : (i += 1) {
        const e1 = reg.create();
        reg.add(e1, Position{ .x = 1, .y = r.random().float(f32) * 100 });
        reg.add(e1, Velocity{ .x = 1, .y = r.random().float(f32) * 100 });
    }

    const end = std.Io.Timestamp.now(io, .awake);
    const elapsed = start.durationTo(end);
    std.debug.print("create {d} entities: {d}\n", .{ total_entities, @as(f64, @floatFromInt(elapsed.nanoseconds)) / 1000000000 });
}

fn owningGroup(reg: *ecs.Registry, io: std.Io) void {
    var group = reg.group(.{ Velocity, Position }, .{}, .{});

    const SortContext = struct {
        fn sort(_: void, a: Position, b: Position) bool {
            return a.y < b.y;
        }
    };

    var start = std.Io.Timestamp.now(io, .awake);
    group.sort(Position, {}, SortContext.sort);
    var end = std.Io.Timestamp.now(io, .awake);
    var elapsed = start.durationTo(end);
    std.debug.print("group (sort): {d}\n", .{@as(f64, @floatFromInt(elapsed.nanoseconds)) / 1000000000});

    start = std.Io.Timestamp.now(io, .awake);
    group.sort(Position, {}, SortContext.sort);
    end = std.Io.Timestamp.now(io, .awake);
    elapsed = start.durationTo(end);
    std.debug.print("group (sort 2): {d}\n", .{@as(f64, @floatFromInt(elapsed.nanoseconds)) / 1000000000});
}
