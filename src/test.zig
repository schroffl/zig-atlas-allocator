const std = @import("std");
const ShelfAllocator = @import("./main.zig").ShelfAllocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    var ally = gpa.allocator();
    defer _ = gpa.deinit();

    var file = try std.fs.cwd().createFile("output.svg", .{});
    var out = file.writer();
    defer file.close();

    var shelf_ally = ShelfAllocator.init(ally, 1024, 1024, 0.95);
    defer shelf_ally.deinit();

    std.debug.print("width: {}\nheight: {}\nusage_threshold: {d:.2}%\n", .{
        shelf_ally.width,
        shelf_ally.height,
        shelf_ally.usage_threshold * 100,
    });

    var random = std.rand.DefaultPrng.init(2);
    var rand = random.random();

    var allocs = std.ArrayList(ShelfAllocator.Allocation).init(ally);
    defer allocs.deinit();

    const AllocSize = struct {
        min: ShelfAllocator.Size,
        max: ShelfAllocator.Size,
    };

    const alloc_sizes = &[_]AllocSize{
        .{
            .min = .{ .width = 64, .height = 64 },
            .max = .{ .width = 128, .height = 74 },
        },
    };

    var timer = try std.time.Timer.start();
    var counter: usize = 0;

    for (0..3) |iteration_i| {
        const free_count = allocs.items.len / 4;
        for (0..free_count) |_| {
            if (allocs.items.len == 0) break;

            const idx = rand.intRangeLessThan(usize, 0, allocs.items.len);
            const alloc = allocs.swapRemove(idx);
            shelf_ally.free(alloc);
        }

        const sizes = alloc_sizes[iteration_i % alloc_sizes.len];

        var i: usize = 0;

        timer.reset();

        while (true) : ({
            counter += 1;
            i += 1;
        }) {
            const name = try std.fmt.allocPrint(ally, "{}", .{counter});
            defer ally.free(name);

            const alloc = shelf_ally.allocateNamed(.{
                .width = rand.intRangeAtMost(usize, sizes.min.width, sizes.max.width),
                .height = rand.intRangeAtMost(usize, sizes.min.height, sizes.max.height),
            }, name) catch break;

            try allocs.append(alloc);
        }

        const took_ns = timer.lap();
        const took_ms = @intToFloat(f64, took_ns) / std.time.ns_per_ms;

        std.debug.print("{} Allocations took {d:.3}ms\n", .{ i, took_ms });
    }

    const hash = shelf_ally.hash(0);
    const hash_str = std.fmt.bytesToHex(std.mem.asBytes(&hash), .lower);

    std.debug.print("Hash {s}\n", .{hash_str});
    std.debug.print("Wasted {d:.2}%\n", .{shelf_ally.wastePercentage() * 100});
    std.debug.print("Coverage {d:.2}%\n", .{shelf_ally.coveragePercentage() * 100});

    try shelf_ally.svgdump(out, .{
        .coords = false,
        .names = true,
        .waste = true,
        .unused = false,
        .stroke = true,
    });
}
