//! Utilites for generating SVG visualizations. This is basically translated
//! from the `svg_fmt` rust crate by Nicolas Silva <nical@fastmail.com>

const std = @import("std");

pub const Color = struct {
    pub const black = Color{};
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const red = Color{ .r = 255 };
    pub const green = Color{ .g = 255 };
    pub const blue = Color{ .b = 255 };

    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: f32 = 1,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;
        try writer.print("rgba({}, {}, {}, {d:.})", .{ self.r, self.g, self.b, self.a });
    }

    pub fn fromU32(value: u32) Color {
        return .{
            .r = @intCast(u8, (value >> 24) & 0xff),
            .g = @intCast(u8, (value >> 16) & 0xff),
            .b = @intCast(u8, (value >> 8) & 0xff),
            .a = @intToFloat(f32, value & 0xff) / 0xff,
        };
    }

    pub fn grayscale(value: u8) Color {
        return .{ .r = value, .g = value, .b = value };
    }
};

pub const Fill = union(enum) {
    color: Color,
    none: void,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;

        switch (self) {
            .color => |c| {
                try writer.print("fill: {}", .{c});
            },
            .none => try writer.writeAll("fill: none"),
        }
    }
};

pub const Stroke = union(enum) {
    color: struct {
        color: Color,
        width: f32 = 1,
    },
    none: void,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;

        switch (self) {
            .color => |c| {
                try writer.print("stroke: {}; stroke-width: {d:.}", .{ c.color, c.width });
            },
            .none => try writer.writeAll("stroke: none"),
        }
    }
};

pub const Style = struct {
    fill: Fill = .{ .none = {} },
    stroke: Stroke = .{ .none = {} },

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;
        try writer.print(
            \\{}; {};
        ,
            .{
                self.fill,
                self.stroke,
            },
        );
    }
};

pub const BeginSvg = struct {
    width: f32,
    height: f32,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;
        try writer.print(
            \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {d:.} {d:.}">
        ,
            .{
                self.width,
                self.height,
            },
        );
    }
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    style: Style = .{},

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;
        try writer.print(
            \\<rect x="{d:.}" y="{d:.}" width="{d:.}" height="{d:.}" style="{}" />
        ,
            .{ self.x, self.y, self.w, self.h, self.style },
        );
    }
};

pub const Text = struct {
    pub const AlignmentBaseline = enum {
        auto,
        central,
        after_edge,
        before_edge,

        pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
            _ = options;
            _ = fmt;

            try writer.writeAll("alignment-baseline: ");

            switch (self) {
                .after_edge => try writer.writeAll("after-edge"),
                .before_edge => try writer.writeAll("before-edge"),
                else => try writer.print("{s}", .{@tagName(self)}),
            }
        }
    };

    pub const Anchor = enum {
        middle,
        start,
        end,

        pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
            _ = options;
            _ = fmt;
            try writer.print("text-anchor: {s}", .{@tagName(self)});
        }
    };

    x: f32,
    y: f32,
    size: f32,
    text: []const u8,
    color: Color = .{},
    anchor: Anchor = .start,
    align_baseline: AlignmentBaseline = .auto,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;

        try writer.print(
            \\<text x="{d:.}" y="{d:.}" style="font-size: {d:.}px; fill: {}; {}; {}">{s}</text>
        ,
            .{
                self.x,
                self.y,
                self.size,
                self.color,
                self.align_baseline,
                self.anchor,
                self.text,
            },
        );
    }
};

pub const EndSvg = struct {
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = self;
        _ = options;
        _ = fmt;
        try writer.writeAll("</svg>");
    }
};
