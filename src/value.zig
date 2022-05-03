const std = @import("std");

const OpCode = @import("bytecode.zig").OpCode;

pub const ValueType = enum(u8) {
    number,
    @"bool",
    nil,

    const Self = @This();

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        switch (self) {
            .number, .@"bool", .nil => try std.fmt.formatBuf(@tagName(self), options, writer),
        }
    }
};

pub const TypeSet = std.enums.EnumSet(ValueType);
pub const numTypeSet = blk: {
    var set = TypeSet{};
    set.insert(ValueType.number);
    break :blk set;
};
// pub const boolTypeSet = (TypeSet{}).insert(ValueType.@"bool");
// pub const nilTypeSet = (TypeSet{}).insert(ValueType.nil);
// pub const nonNilTypeSet = fullTypeSet.remove(ValueType.nil);
// pub const numStrTypeSet

pub const Value = union(ValueType) {
    const Self = @This();
    number: f64,
    @"bool": bool,
    nil: void,

    pub fn init(val: anytype) Self {
        const T = @TypeOf(val);
        return switch (@typeInfo(T)) {
            .Float, .Int, .ComptimeFloat, .ComptimeInt => .{ .number = val },
            .Bool => .{ .@"bool" = val },
            .Void => .{ .nil = {} },
            else => @compileError("invalid value type: " ++ @typeName(T)),
        };
    }

    pub fn set(self: *Self, val: anytype) void {
        const T = @TypeOf(val);
        switch (@typeInfo(T)) {
            .Float, .Int, .ComptimeFloat, .ComptimeInt => self.number = val,
            .Bool => self.@"bool" = val,
            .Void => self.nil = {},
            else => @compileError("invalid value type: " ++ @typeName(T)),
        }
    }

    pub fn @"type"(self: Self) ValueType {
        return @as(ValueType, self);
    }

    pub fn asNumber(self: Self) f64 {
        return self.number;
    }

    pub fn asBool(self: Self) bool {
        return self.@"bool";
    }

    pub fn isEqual(self: Self, other: Self) bool {
        if (self.type() != other.type()) return false;
        return switch (self.type()) {
            .number => self.number == other.number,
            .@"bool" => self.bool == other.bool,
            .nil => true,
        };
    }

    /// All values, regardless of type, have a `true` boolean value except for `0`, `nil`, and `false`.
    pub fn isFalsey(self: Self) bool {
        return self.type() == ValueType.nil or
            (self.type() == ValueType.bool and !self.bool) or
            (self.type() == ValueType.number and self.number == 0);
    }

    // TOOD: Should this take pointers to `self` and `other`, updating `self` in place?
    // Switch is compiled differently for each case resulting in the removal of runtime opcode
    // check.
    pub inline fn binOp(self: Self, comptime op: OpCode, other: Self) Self {
        return Value.init(switch (op) {
            .add => self.number + other.number,
            .sub => self.number - other.number,
            .mul => self.number * other.number,
            .div => self.number / other.number,
            .gt => self.number > other.number,
            .ge => self.number >= other.number,
            .lt => self.number < other.number,
            .le => self.number <= other.number,
            .eq => self.isEqual(other),
            .neq => !self.isEqual(other),
            else => @compileError("invalid binary operator: " ++ @tagName(op)),
        });
    }

    // pub inline fn binOp(self: *Self, comptime op: OpCode, other: Self) void {
    //     switch (op) {
    //         .add => self.number += other.number,
    //         .sub => self.number -= other.number,
    //         .mul => self.number *= other.number,
    //         .div => self.number /= other.number,
    //         else => @compileError("invalid operator: " ++ @tagName(op)),
    //     }
    // }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .number => |val| {
                try std.fmt.formatType(
                    val,
                    if (fmt.len == 0) "d" else fmt,
                    options,
                    writer,
                    std.fmt.default_max_depth,
                );
            },
            .@"bool" => |val| {
                try std.fmt.formatType(
                    val,
                    fmt,
                    options,
                    writer,
                    std.fmt.default_max_depth,
                );
            },
            .nil => try writer.print("nil", .{}),
        }
    }
};
