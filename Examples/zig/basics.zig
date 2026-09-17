const std = @import("std");

const Point = struct {
    x: i32,
    y: i32,

    fn norm(self: Point) i32 {
        return self.x * self.x + self.y * self.y;
    }
};

fn fib(n: i32) i32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn classify(n: i32) []const u8 {
    return switch (n) {
        0 => "zero",
        1...9 => "small",
        else => "large",
    };
}

pub fn main() void {
    std.debug.print("Hello, Zig!\n", .{});

    var sum: i32 = 0;
    var i: i32 = 1;
    while (i <= 10) : (i += 1) {
        sum += i;
    }
    std.debug.print("sum = {d}\n", .{sum});
    std.debug.print("{d}\n", .{fib(15)});

    const xs = [_]i32{ 5, 2, 9, 1 };
    for (xs) |x| {
        std.debug.print("{d} ", .{x});
    }
    std.debug.print("\n", .{});

    const p = Point{ .x = 3, .y = 4 };
    std.debug.print("{d}\n", .{p.norm()});

    std.debug.print("{s} {s} {s}\n", .{ classify(0), classify(5), classify(50) });

    var total: i32 = 0;
    for (xs) |x| {
        if (x > 2) total += x;
    }
    std.debug.print("{d}\n", .{total});

    std.debug.print("{d} {d}\n", .{ 7 / 2, 7 % 3 });
    std.debug.print("{s}\n", .{"hello" ++ " " ++ "world"});
}
