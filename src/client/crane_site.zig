//! The construction site a crane sets up while repairing a building or a
//! bridge (ECraneConco): a cement mixer, two cones and a sign travel from
//! the crane to the building's entrance, where one robot works a
//! jackhammer and another reads the plans. When the repair stops,
//! everything travels back into the crane.

const std = @import("std");
const k = @import("../game/constants.zig");
const gfx = @import("gfx.zig");
const sprites = @import("sprites.zig");

const Image = gfx.Image;
const Art = sprites.CraneSite;

const Kind = enum { conco, cone0, cone1, jack, paper, sign };

/// One thing on the site, moving from where it starts to where it goes.
const Item = struct {
    kind: Kind,
    x: i32,
    y: i32,
    start_x: i32,
    start_y: i32,
    dest_x: i32,
    dest_y: i32,
    w: i32,
    h: i32,

    /// Centered on (cx, cy), not moving yet.
    fn init(kind: Kind, cx: i32, cy: i32, w: i32, h: i32) Item {
        const x = cx - (w >> 1);
        const y = cy - (h >> 1);
        return .{ .kind = kind, .x = x, .y = y, .start_x = x, .start_y = y, .dest_x = x, .dest_y = y, .w = w, .h = h };
    }

    fn move(i: *Item, done: f64) void {
        i.x = i.start_x + int(@as(f64, @floatFromInt(i.dest_x - i.start_x)) * done);
        i.y = i.start_y + int(@as(f64, @floatFromInt(i.dest_y - i.start_y)) * done);
    }

    /// Go back to be centered on (cx, cy) from where it is.
    fn returnTo(i: *Item, cx: i32, cy: i32) void {
        i.start_x = i.x;
        i.start_y = i.y;
        i.dest_x = cx - (i.w >> 1);
        i.dest_y = cy - (i.h >> 1);
    }

    /// Items lower on the screen are drawn later.
    fn lessThan(_: void, a: Item, b: Item) bool {
        return a.y + a.h < b.y + b.h;
    }
};

fn int(v: f64) i32 {
    return @intFromFloat(@trunc(v));
}

/// How long everything takes to travel, seconds.
const travel_time = 0.8;

pub const Site = struct {
    team: k.Team,
    items: [@typeInfo(Kind).@"enum".fields.len]Item,
    phase: enum { arriving, working, leaving } = .arriving,
    travel_start: f64,
    /// The mixer (and the sign) unfold as they arrive: 7 folded, 0 open.
    conco_i: u8 = 7,
    jack_i: u1 = 0,
    next_jack_time: f64 = 0,
    paper_i: u8 = 0,
    pointing: bool = false,
    next_paper_time: f64 = 0,

    /// A crane at (crane_x, crane_y) starts repairing the building in
    /// `b` (pixels).
    pub fn start(art: *const Art, team: k.Team, crane_x: i32, crane_y: i32, b: gfx.Rect, is_bridge: bool, rng: std.Random, time: f64) Site {
        const t = @intFromEnum(team);
        const conco = art.conco[t][0];
        const cone = art.cone[t];
        const sign = art.sign[t];
        const cx = crane_x + 16;
        const cy = crane_y + 16;
        var s: Site = .{ .team = team, .travel_start = time, .items = .{
            .init(.conco, cx, cy, conco.width(), conco.height()),
            .init(.cone0, cx, cy, cone.width(), cone.height()),
            .init(.cone1, cx, cy, cone.width(), cone.height()),
            .init(.jack, cx, cy, 16, 16),
            .init(.paper, cx, cy, 16, 16),
            .init(.sign, cx, cy, sign.width(), sign.height()),
        } };
        s.place(cx, cy, b, is_bridge, rng);
        s.sort();
        return s;
    }

    fn item(s: *Site, kind: Kind) *Item {
        return &s.items[@intFromEnum(kind)];
    }

    /// Where everything goes: in front of the building's entrance (below
    /// it), or at the end of the bridge the crane is at.
    fn place(s: *Site, cx: i32, cy: i32, b: gfx.Rect, is_bridge: bool, rng: std.Random) void {
        const conco_gap = 12;
        const cone_gap = 6;
        const cone_spread = 18;
        const sign_gap = 6;
        const bcx = b.x + (b.w >> 1);
        const bcy = b.y + (b.h >> 1);
        const conco = s.item(.conco);
        const cone0 = s.item(.cone0);
        const cone1 = s.item(.cone1);
        const sign = s.item(.sign);
        const cw = conco.w;
        const ch = conco.h;
        const kw = cone0.w;
        const kh = cone0.h;

        for ([_]Kind{ .jack, .paper }) |kind| workerSpot(s.item(kind), cx, cy, b, is_bridge, rng);

        const horizontal_bridge = is_bridge and b.w > b.h;
        if (horizontal_bridge) {
            const from_right = cx > bcx;
            conco.dest_x = if (from_right) b.x + b.w + conco_gap else b.x - (conco_gap + cw);
            conco.dest_y = bcy - (ch >> 1);
            cone0.dest_x = if (from_right) b.x + b.w + cone_gap else b.x - (cone_gap + kw);
            cone1.dest_x = cone0.dest_x;
            cone0.dest_y = bcy - (kh + cone_spread);
            cone1.dest_y = bcy + cone_spread;
            sign.dest_x = if (from_right) conco.dest_x - (sign_gap + sign.w) else conco.dest_x + cw + sign_gap;
            sign.dest_y = (conco.dest_y + (ch >> 1)) - (sign.h >> 1);
            return;
        }
        // Buildings are entered from below; vertical bridges from the end
        // the crane is at.
        const from_top = is_bridge and cy < bcy;
        conco.dest_x = bcx - (cw >> 1);
        conco.dest_y = if (from_top) b.y - (conco_gap + ch) else b.y + b.h + conco_gap;
        cone0.dest_x = bcx - (kw + cone_spread);
        cone1.dest_x = bcx + cone_spread;
        cone0.dest_y = if (from_top) b.y - (cone_gap + kh) else b.y + b.h + cone_gap;
        cone1.dest_y = cone0.dest_y;
        sign.dest_x = (conco.dest_x + (cw >> 1)) - (sign.w >> 1);
        sign.dest_y = conco.dest_y - (sign.h + 1);
    }

    /// Somewhere near the entrance (or on the bridge) for a worker.
    fn workerSpot(i: *Item, cx: i32, cy: i32, b: gfx.Rect, is_bridge: bool, rng: std.Random) void {
        const gap = 16;
        const spread = 32;
        if (b.w - 16 <= 0 or b.h - 16 <= 0) return;
        const r = struct {
            fn below(g: std.Random, n: i32) i32 {
                return g.intRangeLessThan(i32, 0, n);
            }
        }.below;
        const bcx = b.x + (b.w >> 1);
        const bcy = b.y + (b.h >> 1);
        if (!is_bridge) {
            i.dest_x = b.x + r(rng, b.w - 16);
            i.dest_y = b.y + b.h + gap + r(rng, spread);
        } else if (b.w > b.h) {
            if (rng.boolean()) {
                i.dest_x = if (cx > bcx) b.x + b.w + gap + r(rng, spread) else b.x - (gap + r(rng, spread));
                i.dest_y = b.y + r(rng, b.h - 16);
            } else {
                // On the bridge.
                i.dest_x = b.x + r(rng, b.w - 16);
                i.dest_y = b.y + 16 + r(rng, 16);
            }
        } else {
            if (rng.boolean()) {
                i.dest_x = b.x + r(rng, b.w - 16);
                i.dest_y = if (cy < bcy) b.y - (gap + r(rng, spread)) + 16 else b.y + b.h + gap + r(rng, spread);
            } else {
                i.dest_x = b.x + 16 + r(rng, 16);
                i.dest_y = b.y + r(rng, b.h - 16);
            }
        }
    }

    fn sort(s: *Site) void {
        std.mem.sort(Item, &s.items, {}, Item.lessThan);
    }

    /// The repair stopped: pack up into the crane at (crane_x, crane_y).
    pub fn leave(s: *Site, crane_x: i32, crane_y: i32, time: f64) void {
        s.phase = .leaving;
        s.travel_start = time;
        for (&s.items) |*i| i.returnTo(crane_x + 16, crane_y + 16);
    }

    /// False once everything is back in the crane.
    pub fn update(s: *Site, rng: std.Random, time: f64) bool {
        if (time >= s.next_jack_time) {
            s.next_jack_time = time + 0.045 + 0.001 * @as(f64, @floatFromInt(rng.uintLessThan(u32, 20)));
            s.jack_i +%= 1;
        }
        if (time >= s.next_paper_time) s.readPlans(rng, time);

        switch (s.phase) {
            .working => {},
            .arriving, .leaving => {
                const done = (time - s.travel_start) / travel_time;
                if (done >= 1) {
                    if (s.phase == .leaving) return false;
                    s.phase = .working;
                    s.conco_i = 0;
                    for (&s.items) |*i| i.move(1);
                } else {
                    const folded = if (s.phase == .arriving) 1 - done else done;
                    s.conco_i = @intFromFloat(std.math.clamp(7 * folded, 0, 7));
                    for (&s.items) |*i| i.move(@max(done, 0));
                }
                s.sort();
            },
        }
        return true;
    }

    /// The worker with the plans turns pages and now and then points.
    fn readPlans(s: *Site, rng: std.Random, time: f64) void {
        s.next_paper_time = time + 0.15 + 0.01 * @as(f64, @floatFromInt(rng.uintLessThan(u32, 20)));
        if (s.pointing) {
            if (s.paper_i >= 2) {
                s.paper_i = 0;
                s.pointing = false;
            } else {
                s.paper_i += 1;
                s.next_paper_time = time + 0.3 + 0.01 * @as(f64, @floatFromInt(rng.uintLessThan(u32, 30)));
            }
        } else if (rng.uintLessThan(u32, 10) == 0) {
            s.paper_i = 0;
            s.pointing = true;
        } else {
            s.paper_i = 1 - @min(s.paper_i, 1);
        }
    }

    pub fn draw(s: *const Site, cv: gfx.Canvas, art: *const Art) void {
        const t = @intFromEnum(s.team);
        const working = s.phase == .working;
        for (s.items) |i| {
            const img: Image = switch (i.kind) {
                .conco => art.conco[t][s.conco_i],
                .sign => if (working) art.sign[t] else art.sign_flip[t][s.conco_i],
                .cone0, .cone1 => if (working) art.cone[t] else art.cone_no_shadow[t],
                .jack => if (working) art.jackhammer[t][s.jack_i] else travelling(art, t, i),
                .paper => if (!working)
                    travelling(art, t, i)
                else if (s.pointing)
                    art.point[t][@min(s.paper_i, 2)]
                else
                    art.paper[t][@min(s.paper_i, 1)],
            };
            cv.draw(img, i.x, i.y);
        }
    }

    fn travelling(art: *const Art, t: usize, i: Item) Image {
        const dx = i.dest_x - i.start_x;
        return if (dx > 0) art.travel_right[t] else if (dx < 0) art.travel_left[t] else art.travel_updown[t];
    }
};

test "the site arrives, works and packs up" {
    const a = try @import("assets.zig").Assets.init(std.testing.allocator, "bin/assets");
    defer a.deinit();
    const all = try sprites.Sprites.load(a);
    var prng = std.Random.DefaultPrng.init(3);
    const building: gfx.Rect = .{ .x = 200, .y = 100, .w = 64, .h = 48 };
    var s = Site.start(&all.crane.site, .blue, 100, 300, building, false, prng.random(), 10);
    try std.testing.expect(s.update(prng.random(), 10.4));
    try std.testing.expect(s.phase == .arriving and s.conco_i > 0 and s.conco_i < 7);
    try std.testing.expect(s.update(prng.random(), 11));
    try std.testing.expect(s.phase == .working and s.conco_i == 0);
    // The mixer stands in front of the entrance, below the building.
    for (s.items) |i| if (i.kind == .conco) try std.testing.expect(i.y > building.y + building.h);
    s.leave(100, 300, 12);
    try std.testing.expect(s.update(prng.random(), 12.5));
    try std.testing.expect(!s.update(prng.random(), 13));
}
