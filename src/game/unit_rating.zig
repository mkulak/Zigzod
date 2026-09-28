//! Which units lose against which (ZUnitRating): a unit sent to attack a
//! stronger one refuses ("Forget it!"), and bots avoid bad fights.

const std = @import("std");
const k = @import("constants.zig");

pub const Unit = union(enum) {
    robot: k.Robot,
    vehicle: k.Vehicle,
    cannon: k.Cannon,
};

pub const Outcome = enum { will_die, even, will_kill };

/// Pairs where the first unit dies attacking the second.
const loses = [_][2]Unit{
    .{ .{ .robot = .grunt }, .{ .robot = .psycho } },
    .{ .{ .robot = .grunt }, .{ .robot = .sniper } },
    .{ .{ .robot = .grunt }, .{ .robot = .tough } },
    .{ .{ .robot = .grunt }, .{ .robot = .pyro } },
    .{ .{ .robot = .grunt }, .{ .robot = .laser } },
    .{ .{ .robot = .grunt }, .{ .cannon = .gatling } },
    .{ .{ .robot = .grunt }, .{ .cannon = .gun } },
    .{ .{ .robot = .grunt }, .{ .cannon = .howitzer } },
    .{ .{ .robot = .grunt }, .{ .cannon = .missile_cannon } },
    .{ .{ .robot = .grunt }, .{ .vehicle = .jeep } },
    .{ .{ .robot = .grunt }, .{ .vehicle = .light } },
    .{ .{ .robot = .grunt }, .{ .vehicle = .medium } },
    .{ .{ .robot = .grunt }, .{ .vehicle = .heavy } },
    .{ .{ .robot = .grunt }, .{ .vehicle = .missile_launcher } },
    .{ .{ .robot = .psycho }, .{ .robot = .tough } },
    .{ .{ .robot = .psycho }, .{ .robot = .pyro } },
    .{ .{ .robot = .psycho }, .{ .robot = .laser } },
    .{ .{ .robot = .psycho }, .{ .cannon = .missile_cannon } },
    .{ .{ .robot = .psycho }, .{ .vehicle = .medium } },
    .{ .{ .robot = .psycho }, .{ .vehicle = .heavy } },
    .{ .{ .robot = .psycho }, .{ .vehicle = .missile_launcher } },
    .{ .{ .robot = .sniper }, .{ .robot = .tough } },
    .{ .{ .robot = .sniper }, .{ .robot = .pyro } },
    .{ .{ .robot = .sniper }, .{ .robot = .laser } },
    .{ .{ .robot = .sniper }, .{ .cannon = .missile_cannon } },
    .{ .{ .robot = .sniper }, .{ .vehicle = .missile_launcher } },
    .{ .{ .robot = .tough }, .{ .cannon = .missile_cannon } },
    .{ .{ .robot = .tough }, .{ .vehicle = .missile_launcher } },
    .{ .{ .robot = .pyro }, .{ .cannon = .missile_cannon } },
    .{ .{ .robot = .pyro }, .{ .vehicle = .missile_launcher } },
    .{ .{ .robot = .laser }, .{ .cannon = .missile_cannon } },
    .{ .{ .robot = .laser }, .{ .vehicle = .missile_launcher } },
    .{ .{ .vehicle = .jeep }, .{ .robot = .tough } },
    .{ .{ .vehicle = .jeep }, .{ .robot = .pyro } },
    .{ .{ .vehicle = .jeep }, .{ .robot = .laser } },
    .{ .{ .vehicle = .jeep }, .{ .cannon = .gun } },
    .{ .{ .vehicle = .jeep }, .{ .cannon = .howitzer } },
    .{ .{ .vehicle = .jeep }, .{ .cannon = .missile_cannon } },
    .{ .{ .vehicle = .jeep }, .{ .vehicle = .light } },
    .{ .{ .vehicle = .jeep }, .{ .vehicle = .medium } },
    .{ .{ .vehicle = .jeep }, .{ .vehicle = .heavy } },
    .{ .{ .vehicle = .jeep }, .{ .vehicle = .missile_launcher } },
    .{ .{ .vehicle = .light }, .{ .cannon = .missile_cannon } },
    .{ .{ .vehicle = .light }, .{ .vehicle = .missile_launcher } },
    .{ .{ .vehicle = .medium }, .{ .vehicle = .missile_launcher } },
    .{ .{ .vehicle = .missile_launcher }, .{ .cannon = .howitzer } },
};

/// How a fight of `attacker` against `victim` goes.
pub fn rate(attacker: Unit, victim: Unit) Outcome {
    for (loses) |p| {
        if (std.meta.eql(p[0], attacker) and std.meta.eql(p[1], victim)) return .will_die;
        if (std.meta.eql(p[1], attacker) and std.meta.eql(p[0], victim)) return .will_kill;
    }
    return .even;
}

test "unit ratings" {
    try std.testing.expectEqual(Outcome.will_die, rate(.{ .robot = .grunt }, .{ .vehicle = .heavy }));
    try std.testing.expectEqual(Outcome.will_kill, rate(.{ .vehicle = .heavy }, .{ .robot = .grunt }));
    try std.testing.expectEqual(Outcome.even, rate(.{ .robot = .grunt }, .{ .robot = .grunt }));
}
