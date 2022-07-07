const std = @import("std");
const Allocator = std.mem.Allocator;

const OpCode = @import("bytecode.zig").OpCode;
const object = @import("object.zig");
const ObjType = object.ObjType;
const Obj = object.Obj;
const StringObj = object.StringObj;
const TypeError = @import("virt_mach.zig").TypeError;

pub const ValueType = enum(u8) {
    const Self = @This();

    nil,
    @"bool",
    number,
    obj,

    // TODO: Have to figure out a way to print the specific object type instead of just "obj".
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        // switch (self) {
        //     .number, .@"bool", .nil => try std.fmt.formatBuf(@tagName(self), options, writer),
        //     .obj => |obj_type| try obj_type.format(fmt, options, writer),
        // }
        try std.fmt.formatBuf(@tagName(self), options, writer);
    }
};

pub const Value = union(ValueType) {
    const Self = @This();

    nil: void,
    @"bool": bool,
    number: f64,
    obj: *Obj,

    pub fn init(val: anytype) Self {
        const T = @TypeOf(val);
        return switch (@typeInfo(T)) {
            .Void => .{ .nil = {} },
            .Bool => .{ .@"bool" = val },
            .Float, .Int, .ComptimeFloat, .ComptimeInt => .{ .number = val },
            .Pointer => .{ .obj = if (T != *Obj) val.asObj() else val },
            else => @compileError("invalid type of `val` parameter: " ++ @typeName(T)),
        };
    }

    pub fn set(self: *Self, val: anytype) void {
        const T = @TypeOf(val);
        switch (@typeInfo(T)) {
            .Void => self.nil = {},
            .Bool => self.@"bool" = val,
            .Float, .Int, .ComptimeFloat, .ComptimeInt => self.number = val,
            .Pointer => self.obj = if (T != *Obj) val.asObj() else val,
            else => @compileError("invalid type of `val` parameter: " ++ @typeName(T)),
        }
    }

    pub fn @"type"(self: Self) ValueType {
        return @as(ValueType, self);
    }

    pub fn asBool(self: Self) bool {
        return self.@"bool";
    }

    pub fn asNumber(self: Self) f64 {
        return self.number;
    }

    pub fn asObj(self: Self) *Obj {
        return self.obj;
    }

    pub fn isObjType(self: Self, obj_type: ObjType) bool {
        return self.type() == .obj and self.asObj().type == obj_type;
    }

    pub fn isEqual(self: Self, other: Self) bool {
        if (self.type() != other.type()) return false;
        return switch (self.type()) {
            .nil => true,
            .@"bool" => self.bool == other.bool,
            .number => self.number == other.number,
            // Strings can be compared via pointer equality because of interning. If two string
            // objects have the same address they also have the same bytes.
            .obj => self.obj == other.obj,
        };
    }

    // TODO: Should empty string be falsey?
    /// All values, regardless of type, have a `true` boolean value except for `0`, `nil`, and `false`.
    pub fn isFalsey(self: Self) bool {
        return self.type() == ValueType.nil or
            (self.type() == ValueType.bool and !self.bool) or
            (self.type() == ValueType.number and self.number == 0);
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .nil => try writer.writeAll("nil"),
            .@"bool" => |val| {
                try std.fmt.formatType(val, fmt, options, writer, std.fmt.default_max_depth);
            },
            .number => |val| {
                try std.fmt.formatType(
                    val,
                    if (fmt.len == 0) "d" else fmt,
                    options,
                    writer,
                    std.fmt.default_max_depth,
                );
            },
            .obj => |val| {
                try std.fmt.formatType(val, fmt, options, writer, std.fmt.default_max_depth);
            },
        }
    }

    pub fn testingExpectEqual(self: Self, other: Self) !void {
        if (self.type() != .obj) {
            if (!self.isEqual(other)) {
                std.debug.print("expected `{}`, found `{}`\n", .{ self, other });
                return error.testingExpectEqual;
            }
        } else if (other.type() != .obj) {
            std.debug.print("expected `{}`, found `{}`\n", .{ self, other });
            return error.testingExpectEqual;
        } else {
            self.obj.testingExpectEqual(other.obj) catch |err| {
                std.debug.print("expected `{}`, found `{}`\n", .{ self, other });
                return err;
            };
        }
    }
};
