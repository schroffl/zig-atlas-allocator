const std = @import("std");
const svg = @import("./svg.zig");
const Self = @This();

pub const Error = std.mem.Allocator.Error || error{OutOfSpace};

pub const Allocation = struct {
    pub const Id = u64;

    /// The unique id of this allocation
    id: Id,

    /// The allocated slot on the atlas
    rectangle: Rectangle,
};

pub const Rectangle = struct {
    position: Position,
    size: Size,
};

pub const Position = struct {
    x: usize,
    y: usize,
};

pub const Size = struct {
    width: usize,
    height: usize,

    pub fn area(self: Size) usize {
        return self.width * self.height;
    }
};

pub const DumpConfig = struct {
    waste: bool = true,
    names: bool = true,
    coords: bool = false,
    stroke: bool = false,
    unused: bool = false,
};

const Shelf = struct {
    y: usize,
    height: usize,
    root: *Block,

    pub fn find(self: Shelf, size: Size) ?*Block {
        var it = self.iterate();

        return while (it.next()) |block| {
            if (block.size.width >= size.width and !block.in_use)
                break block;
        } else null;
    }

    pub fn iterate(self: Shelf) Iterator {
        return Iterator{ .current = self.root };
    }

    const Iterator = struct {
        current: ?*Block,

        pub fn next(self: *Iterator) ?*Block {
            const ret = self.current;
            self.current = if (self.current) |c| c.next else null;
            return ret;
        }
    };
};

const Block = struct {
    id: usize,
    offset: usize,
    size: Size,
    in_use: bool = false,

    prev: ?*Block = null,
    next: ?*Block = null,

    /// Debug information
    name: ?[]const u8 = null,
};

const BlockId = struct {
    shelf_idx: usize,
    block_id: usize,

    fn decode(id: usize) BlockId {
        return .{
            .shelf_idx = (id >> 48) & 0xffff,
            .block_id = id & 0xffffff,
        };
    }

    fn encode(self: BlockId) usize {
        return (@intCast(u16, self.shelf_idx) << 48) | @intCast(u48, self.block_id);
    }
};

width: usize,
height: usize,
allocator: std.mem.Allocator,
shelves: std.ArrayList(Shelf),
id: Allocation.Id = 0,

usage_threshold: f32,

pub fn init(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    usage_threshold: ?f32,
) Self {
    return Self{
        .allocator = allocator,
        .width = width,
        .height = height,
        .shelves = std.ArrayList(Shelf).init(allocator),
        .usage_threshold = usage_threshold orelse 0.8,
    };
}

pub fn deinit(self: *Self) void {
    for (self.shelves.items) |shelf| {
        var it = shelf.iterate();

        // This depends on the implementation of the iterator. Maybe its safer
        // to walk the list manually here?
        while (it.next()) |block| {
            if (block.name) |name| {
                self.allocator.free(name);
            }

            self.allocator.destroy(block);
        }
    }

    self.shelves.deinit();
}

/// Allocate space for the given rectangle size.
pub fn allocate(self: *Self, size: Size) Error!Allocation {
    return self.allocateNamed(size, null);
}

/// Allocate space for the given rectangle size. You may optionally assign a
/// name for clearer debugging.
pub fn allocateNamed(
    self: *Self,
    /// The size of the rectangle you want to allocate
    size: Size,
    /// An optional name for this allocation. The name is duplicated using the
    /// underlying `std.mem.Allocator`.
    name: ?[]const u8,
) Error!Allocation {

    // TODO Should this return an error instead?
    std.debug.assert(size.width > 0 and size.height > 0);

    // The lower the score, the better
    var best_score: usize = std.math.maxInt(usize);
    var pick: ?*Shelf = null;

    var summed_height: usize = 0;

    // First we calculate the score for the existing shelves
    for (self.shelves.items) |*shelf| {
        summed_height += shelf.height;

        // The shelf is too small
        if (shelf.height < size.height) continue;

        // The shelf is tall enough, but there's no slot that can hold the allocation
        if (shelf.find(size) == null) continue;

        // How much height do we waste?
        const score = shelf.height - size.height;

        // If we waste less height than the current candidate, this is our new pick
        if (score < best_score) {
            best_score = score;
            pick = shelf;
        }
    }

    const shelf = blk: {
        const leftover_height = self.height - summed_height;
        const new_shelf_fits = leftover_height >= size.height;

        // There's not even enough space for a new shelf
        if (!new_shelf_fits) {

            // We actually have found a pick, but were just checking if a new shelf is better.
            // Since a new shelf is not possible, we use the pick.
            if (pick) |p| break :blk p;

            // No new shelf is possible _and_ we haven't found a pick.
            // Last resort: Maybe we can resize the last shelf to the required height.
            if (self.shelves.items.len > 0) {
                var last_shelf = &self.shelves.items[self.shelves.items.len - 1];

                // Success: The shelf can be resized to hold the height of the new allocation
                //          and also has a block to accommodate the width.
                if (last_shelf.height + leftover_height >= size.height and last_shelf.find(size) != null) {
                    last_shelf.height = size.height;
                    break :blk last_shelf;
                }
            }

            return error.OutOfSpace;
        }

        // If the pick wastes too much space it might be better to create a new
        // shelf.
        if (pick) |p| {
            const usage = @intToFloat(f32, size.height) / @intToFloat(f32, p.height);

            if (usage >= self.usage_threshold) {
                break :blk p;
            }
        }

        var new = try self.shelves.addOne();
        var root = try self.allocator.create(Block);

        root.* = .{
            .id = self.acquireId(),
            .offset = 0,
            .size = .{
                .width = self.width,
                .height = size.height,
            },
        };

        new.* = .{
            .y = summed_height,
            .height = size.height,
            .root = root,
        };

        break :blk new;
    };

    const duped_name = if (name) |n| self.allocator.dupe(u8, n) catch unreachable else null;

    // Actually allocate the block in the shelf.
    const block = blk: {
        var dst = shelf.find(size) orelse return error.OutOfSpace;

        // We only need to split the block if it doesn't fit exactly.
        if (size.width != dst.size.width) {
            var new = try self.allocator.create(Block);

            new.* = .{
                .id = self.acquireId(),
                .offset = dst.offset + size.width,
                .size = .{
                    .width = dst.size.width - size.width,
                    .height = shelf.height,
                },
                .in_use = false,

                .prev = dst,
                .next = dst.next,
            };

            if (dst.next) |n| n.prev = new;
            dst.next = new;
        }

        // We don't free the old name, because a block that's not in use
        // should not have one.
        dst.name = duped_name;

        dst.in_use = true;
        dst.size = size;

        break :blk dst;
    };

    return Allocation{
        .id = block.id,
        .rectangle = .{
            .position = .{
                .x = block.offset,
                .y = shelf.y,
            },
            .size = block.size,
        },
    };
}

/// Free the given allocation. This invalidates the allocated rectangle.
pub fn free(self: *Self, allocation: Allocation) void {
    var shelf_i: usize = undefined;
    var block = blk: for (self.shelves.items, 0..) |shelf, i| {
        var it = shelf.iterate();
        shelf_i = i;

        while (it.next()) |b| {
            if (b.id == allocation.id) break :blk b;
        }
    } else return;

    block.in_use = false;
    if (block.name) |name| self.allocator.free(name);
    block.name = null;

    // Find all unused blocks before the one that will be freed.
    while (true) {
        if (block.prev == null or block.prev.?.in_use) break;
        block = block.prev.?;
    }

    // Now we walk the list from our starting point and merge to the right
    // until the first block that has `in_use = true` again.
    while (true) {
        const next = block.next orelse break;

        if (next.in_use) break;

        block.size.width += next.size.width;
        block.next = next.next;
        if (block.next) |n| n.prev = block;

        // We don't free the name, because the next block should not have on
        // anways: It's in_use=false
        self.allocator.destroy(next);
    }

    // Check if we can remove the shelf
    {
        const shelf = self.shelves.items[shelf_i];
        var it = shelf.iterate();

        // Determine if the shelf is completely empty, which would allow us to
        // free the whole row.
        const is_empty = while (it.next()) |b| {
            if (b.in_use) break false;
        } else true;

        // It's not empty => bail
        if (!is_empty) return;

        // If it's the top shelf we simply remove it
        if (shelf_i == self.shelves.items.len - 1) {
            it = shelf.iterate();
            while (it.next()) |b| {
                if (b.name) |name| self.allocator.free(name);
                self.allocator.destroy(b);
            }

            _ = self.shelves.pop();
        }
    }
}

/// Find the allocation with the given id.
pub fn get(self: Self, allocation_id: Allocation.Id) ?Allocation {
    var shelf: Shelf = undefined;
    var block = blk: for (self.shelves.items) |sh| {
        shelf = sh;
        var it = sh.iterate();

        while (it.next()) |b| {
            if (b.id == allocation_id) break :blk b;
        }
    } else return null;

    return Allocation{
        .id = block.id,
        .rectangle = .{
            .position = .{
                .x = block.offset,
                .y = shelf.y,
            },
            .size = block.size,
        },
    };
}

/// Calculate the amount of wasted space.
pub fn waste(self: Self) usize {
    var sum: usize = 0;

    for (self.shelves.items) |shelf| {
        var it = shelf.iterate();

        while (it.next()) |block| {
            if (!block.in_use) continue;
            const h_diff = shelf.height - block.size.height;
            sum += block.size.width * h_diff;
        }
    }

    return sum;
}

/// Calculate the ratio of wasted space to the covered area.
pub fn wastePercentage(self: Self) f32 {
    return @intToFloat(f32, self.waste()) / @intToFloat(f32, self.coverage());
}

/// Calculate the covered area.
pub fn coverage(self: Self) usize {
    var sum: usize = 0;

    for (self.shelves.items) |shelf| {
        var it = shelf.iterate();

        while (it.next()) |block| {
            if (!block.in_use) continue;
            sum += block.size.area();
        }
    }

    return sum;
}

/// Calculate the ratio of covered area to the available area.
pub fn coveragePercentage(self: Self) f32 {
    return @intToFloat(f32, self.coverage()) / @intToFloat(f32, self.width * self.height);
}

/// Calculate a unique hash of all blocks.
/// Useful for regression tests.
pub fn hash(self: Self, seed: u64) u64 {
    var hash_ = std.hash.Wyhash.init(seed);

    for (self.shelves.items) |shelf| {
        var it = shelf.iterate();

        while (it.next()) |block| {
            hash_.update(std.mem.asBytes(&block.in_use));
            hash_.update(std.mem.asBytes(&block.offset));
            hash_.update(std.mem.asBytes(&shelf.y));
            hash_.update(std.mem.asBytes(&block.size.width));
            hash_.update(std.mem.asBytes(&block.size.height));
        }
    }

    return hash_.final();
}

/// Dump a two dimensional SVG image to the given writer for debugging
pub fn svgdump(self: Self, writer: anytype, config: DumpConfig) @TypeOf(writer).Error!void {
    const bg_color = svg.Color.grayscale(42);

    try writer.print("{}", .{
        svg.BeginSvg{
            .width = @intToFloat(f32, self.width),
            .height = @intToFloat(f32, self.height),
        },
    });

    try writer.print("{}", .{
        svg.Rectangle{
            .x = 0,
            .y = 0,
            .w = @intToFloat(f32, self.width),
            .h = @intToFloat(f32, self.height),
            .style = .{
                .fill = .{ .color = bg_color },
            },
        },
    });

    const free_color = svg.Color.fromU32(0x4ae817ff);

    const colors = [_][]const svg.Color{
        &.{
            svg.Color{ .r = 0xc0, .g = 0x86, .b = 0xc1 },
            svg.Color{ .r = 0x86, .g = 0xbb, .b = 0xd8 },
        },
        &.{
            svg.Color{ .r = 0xe9, .g = 0xc4, .b = 0x6a },
            svg.Color{ .r = 0xf4, .g = 0xa2, .b = 0x61 },
        },
    };

    var fmt_buffer: [512]u8 = undefined;

    for (self.shelves.items, 0..) |shelf, i| {
        const color_set = colors[i % colors.len];

        var it = shelf.iterate();
        var idx: usize = 0;

        while (it.next()) |block| {
            const x = @intToFloat(f32, block.offset);
            const y = @intToFloat(f32, shelf.y);
            const w = @intToFloat(f32, block.size.width);
            const h = @intToFloat(f32, block.size.height);

            if (!block.in_use and !config.unused) continue;

            const stroke: svg.Stroke = if (config.stroke) .{
                .color = .{
                    .color = svg.Color.black,
                    .width = 2.0,
                },
            } else .none;

            try writer.print("{}", .{
                svg.Rectangle{
                    .x = x,
                    .y = y,
                    .w = w,
                    .h = h,
                    .style = .{
                        .fill = .{
                            .color = if (block.in_use) color_set[idx % color_set.len] else free_color,
                        },
                        .stroke = stroke,
                    },
                },
            });

            const wasted_height = @intToFloat(f32, shelf.height) - h;

            if (config.waste and wasted_height > 0) {
                try writer.print("{}", .{
                    svg.Rectangle{
                        .x = x,
                        .y = y + h,
                        .w = w,
                        .h = wasted_height,
                        .style = .{
                            .fill = .{ .color = svg.Color.fromU32(0xdd1616ff) },
                            .stroke = stroke,
                        },
                    },
                });
            }

            const pos_text = std.fmt.bufPrint(&fmt_buffer, "({}, {}) {}x{}", .{
                block.offset,     shelf.y,
                block.size.width, block.size.height,
            }) catch unreachable;

            if (config.coords) {
                try writer.print("{}", .{
                    svg.Text{
                        .x = x + 2,
                        .y = y + 2,
                        .size = 8,
                        .text = pos_text,
                        .color = svg.Color.black,
                        .anchor = .start,
                        .align_baseline = .before_edge,
                    },
                });
            }

            if (config.names) {
                if (block.name) |name| {
                    try writer.print("{}", .{
                        svg.Text{
                            .x = x + w / 2,
                            .y = y + h / 2,
                            .size = 14,
                            .text = name,
                            .color = svg.Color.black,
                            .align_baseline = .central,
                            .anchor = .middle,
                        },
                    });
                }
            }

            idx += 1;
        }
    }

    try writer.print("{}", .{svg.EndSvg{}});
}

fn acquireId(self: *Self) Allocation.Id {
    return @atomicRmw(usize, &self.id, .Add, 1, .SeqCst);
}
