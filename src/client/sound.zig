//! Sound effects, voices and music (ZSoundEngine, ZMusicEngine) on SDL3
//! audio: each sound playing has an audio stream bound to the device,
//! which mixes them and converts formats; music is decoded from OGG with
//! stb_vorbis into a stream of its own, topped up every frame (`pump`).
//! Without an audio device everything here quietly does nothing.

const std = @import("std");
const c = @import("c");
const k = @import("../game/constants.zig");
const portrait = @import("portrait.zig");

/// Sound effects played where things happen (only heard on screen).
pub const Effect = enum {
    psycho_fire,
    ricochet,
    explosion,
    light_explosion,
    light_fire,
    medium_fire,
    heavy_fire,
    pyro_fire,
    laser_fire,
    rifle_fire,
    gun_fire,
    gatling_fire,
    turret_explosion,
    jeep_fire,
    tough_fire,
    missile_fire,
    throw_grenade,
    bat_chirp,
    crow,
};

/// The computer's announcements (the COMP_MSG sound ids).
pub const Computer = enum {
    vehicle,
    robot,
    gun,
    starting_manufacture,
    manufacturing_canceled,
    starting_repair,
    vehicle_repaired,
    territory_lost,
    radar_activated,
    fort_under_attack,
};

/// Background loops while buildings are in view.
pub const Loop = enum { radar, factory };

const Def = struct {
    file: []const u8,
    volume: u8 = 40,
    /// Random extra volume up to this.
    shift: u8 = 20,
    /// Least time between two plays.
    gap: f64 = 0,
};

fn effectDefs(e: Effect) []const Def {
    const explosions = [_]Def{
        .{ .file = "explosion_0.wav", .volume = 30 }, .{ .file = "explosion_1.wav", .volume = 30 },
        .{ .file = "explosion_2.wav", .volume = 30 }, .{ .file = "explosion_3.wav", .volume = 30 },
        .{ .file = "explosion_4.wav", .volume = 30 },
    };
    return switch (e) {
        .psycho_fire => &.{.{ .file = "MACHGUN2.wav" }},
        .ricochet => &.{.{ .file = "RICOCH1.wav" }},
        .explosion => &explosions,
        .light_explosion => explosions[0..2],
        .light_fire => &.{.{ .file = "LTANKGUN.wav", .volume = 25 }},
        .medium_fire => &.{.{ .file = "MTANKGUN.wav", .volume = 25 }},
        .heavy_fire => &.{.{ .file = "HTANKGUN.wav", .volume = 25 }},
        .pyro_fire => &.{.{ .file = "FLAMER.wav", .volume = 20, .shift = 10 }},
        .laser_fire => &.{.{ .file = "LASERGUN.wav", .volume = 20, .shift = 10 }},
        .rifle_fire => &.{.{ .file = "RIFLE3.wav", .volume = 10, .shift = 10 }},
        .gun_fire => &.{.{ .file = "LTGUN.wav" }},
        .gatling_fire => &.{.{ .file = "GATTGUN.wav" }},
        .turret_explosion => &.{.{ .file = "METGRND.wav" }},
        .jeep_fire => &.{.{ .file = "JEEPMGUN.wav", .gap = 0.15 }},
        .tough_fire => &.{.{ .file = "MOBIMISS.wav" }},
        .missile_fire => &.{.{ .file = "MOBIMIS2.wav" }},
        .throw_grenade => &.{.{ .file = "GRENLOBX.wav" }},
        .bat_chirp => &.{.{ .file = "BATCHIRP.wav" }},
        .crow => &.{.{ .file = "CROW2.wav" }},
    };
}

fn computerFile(m: Computer) []const u8 {
    return switch (m) {
        .vehicle => "comp_vehicle_manufactured.wav",
        .robot => "comp_robot_manufactured.wav",
        .gun => "comp_gun_manufactured.wav",
        .starting_manufacture => "comp_starting_manufacture.wav",
        .manufacturing_canceled => "comp_manufacturing_canceled.wav",
        .starting_repair => "comp_starting_repair.wav",
        .vehicle_repaired => "comp_vehicle_repaired.wav",
        .territory_lost => "comp_territory_lost.wav",
        .radar_activated => "comp_radar_activated.wav",
        .fort_under_attack => "comp_fort_under_attack.wav",
    };
}

/// A WAV file in memory.
const Clip = struct {
    data: [*]u8,
    len: u32,
    spec: c.SDL_AudioSpec,

    fn load(path: [:0]const u8) ?Clip {
        var spec: c.SDL_AudioSpec = undefined;
        var data: [*c]u8 = null;
        var len: u32 = 0;
        if (!c.SDL_LoadWAV(path.ptr, &spec, &data, &len)) return null;
        return .{ .data = data, .len = len, .spec = spec };
    }

    fn deinit(clip: Clip) void {
        c.SDL_free(clip.data);
    }
};

/// A loaded sound and when it may play again.
const Slot = struct {
    clip: ?Clip = null,
    def: Def,
    next: f64 = 0,
};

const channels = 32;
const voices = 75;
const losing_lines = 10;

pub const Sounds = struct {
    on: bool = false,
    device: c.SDL_AudioDeviceID = 0,
    /// Sounds play on these (a free one each time).
    streams: [channels]?*c.SDL_AudioStream = @splat(null),
    /// Volume, 0 to 1.
    master: f32 = 1,
    effects: [@typeInfo(Effect).@"enum".fields.len][5]Slot = undefined,
    computer: [@typeInfo(Computer).@"enum".fields.len]Slot = undefined,
    losing_lines: [losing_lines]Slot = undefined,
    /// The robots' lines, ROB01..ROB75.
    voice: [voices]Slot = undefined,
    loops: [2]Slot = undefined,
    loop_streams: [2]?*c.SDL_AudioStream = @splat(null),
    loop_on: [2]bool = @splat(false),
    music: Music = .{},

    /// Open the audio device and load everything (`assets` is the folder
    /// with sounds/).
    pub fn init(s: *Sounds, assets: []const u8) void {
        s.* = .{};
        s.clearSlots();
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
            std.log.info("no sound: {s}", .{c.SDL_GetError()});
            return;
        }
        s.device = c.SDL_OpenAudioDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, null);
        if (s.device == 0) {
            std.log.info("no sound: {s}", .{c.SDL_GetError()});
            c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
            return;
        }
        s.on = true;
        for (&s.streams) |*st| st.* = s.newStream();
        for (&s.loop_streams) |*st| st.* = s.newStream();
        s.music.stream = s.newStream();

        var buf: [512]u8 = undefined;
        for (&s.effects, 0..) |*slots, i| {
            for (effectDefs(@enumFromInt(i)), 0..) |d, j| slots[j] = load(assets, d, &buf);
        }
        for (&s.computer, 0..) |*slot, i| slot.* = load(assets, .{ .file = computerFile(@enumFromInt(i)) }, &buf);
        for (&s.losing_lines, 0..) |*slot, i| {
            var name: [32]u8 = undefined;
            slot.* = load(assets, .{ .file = std.fmt.bufPrint(&name, "comp_youre_losing_{d:0>2}.wav", .{i}) catch continue }, &buf);
        }
        for (&s.voice, 1..) |*slot, i| {
            var name: [16]u8 = undefined;
            slot.* = load(assets, .{ .file = std.fmt.bufPrint(&name, "ROB{d:0>2}.wav", .{i}) catch continue }, &buf);
        }
        s.loops = .{
            load(assets, .{ .file = "radar_sound.wav", .volume = 20 }, &buf),
            load(assets, .{ .file = "ROBFACT5.wav", .volume = 5 }, &buf),
        };
        s.music.load(assets);
        s.music.setGain(s.master);
    }

    /// A stream bound to the device (its input format is set per sound).
    fn newStream(s: *Sounds) ?*c.SDL_AudioStream {
        var spec: c.SDL_AudioSpec = undefined;
        if (!c.SDL_GetAudioDeviceFormat(s.device, &spec, null)) return null;
        const st = c.SDL_CreateAudioStream(&spec, &spec) orelse return null;
        if (!c.SDL_BindAudioStream(s.device, st)) {
            c.SDL_DestroyAudioStream(st);
            return null;
        }
        return st;
    }

    /// Volume in quarters: 0 (off) to 4 (full).
    pub fn setVolume(s: *Sounds, quarters: u8) void {
        s.master = @as(f32, @floatFromInt(@min(quarters, 4))) / 4;
        if (!s.on) return;
        for (s.loop_streams, s.loops) |st, slot| if (st) |x| {
            _ = c.SDL_SetAudioStreamGain(x, s.gain(slot.def.volume));
        };
        s.music.setGain(s.master);
    }

    /// Gain for a sound of `volume` (0..128, like SDL_mixer's).
    fn gain(s: *const Sounds, volume: u32) f32 {
        return @as(f32, @floatFromInt(@min(volume, 128))) / 128 * s.master;
    }

    fn clearSlots(s: *Sounds) void {
        for (&s.effects) |*slots| slots.* = @splat(.{ .def = .{ .file = "" } });
        s.computer = @splat(.{ .def = .{ .file = "" } });
        s.losing_lines = @splat(.{ .def = .{ .file = "" } });
        s.voice = @splat(.{ .def = .{ .file = "" } });
        s.loops = @splat(.{ .def = .{ .file = "" } });
    }

    fn load(assets: []const u8, d: Def, buf: []u8) Slot {
        const path = std.fmt.bufPrintZ(buf, "{s}/sounds/{s}", .{ assets, d.file }) catch return .{ .def = d };
        const clip = Clip.load(path);
        if (clip == null) std.log.warn("could not load sound {s}", .{path});
        return .{ .clip = clip, .def = d };
    }

    pub fn deinit(s: *Sounds) void {
        if (!s.on) return;
        c.SDL_CloseAudioDevice(s.device);
        for (s.streams ++ s.loop_streams) |st| if (st) |x| c.SDL_DestroyAudioStream(x);
        s.music.deinit();
        for (&s.effects) |*slots| for (slots) |slot| if (slot.clip) |cl| cl.deinit();
        for ([_][]Slot{ &s.computer, &s.losing_lines, &s.voice, &s.loops }) |list| for (list) |slot| if (slot.clip) |cl| cl.deinit();
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
    }

    /// Start `clip` on stream `st`.
    fn start(st: *c.SDL_AudioStream, clip: Clip, gain_: f32) void {
        _ = c.SDL_ClearAudioStream(st);
        _ = c.SDL_SetAudioStreamFormat(st, &clip.spec, null);
        _ = c.SDL_SetAudioStreamGain(st, gain_);
        _ = c.SDL_PutAudioStreamData(st, clip.data, @intCast(clip.len));
    }

    fn play(s: *Sounds, slot: *Slot, time: f64, rng: std.Random) void {
        if (!s.on) return;
        const clip = slot.clip orelse return;
        if (time < slot.next) return;
        slot.next = time + slot.def.gap + 0.01 * @as(f64, @floatFromInt(rng.uintLessThan(u32, 31)));
        const volume = @as(u32, slot.def.volume) + rng.uintLessThan(u32, @max(slot.def.shift, 1));
        // The first stream with nothing left to play.
        for (s.streams) |st| if (st) |x| if (c.SDL_GetAudioStreamQueued(x) == 0) {
            start(x, clip, s.gain(volume));
            return;
        };
    }

    /// `time` is real time.
    pub fn effect(s: *Sounds, e: Effect, time: f64, rng: std.Random) void {
        const n = effectDefs(e).len;
        s.play(&s.effects[@intFromEnum(e)][rng.uintLessThan(usize, n)], time, rng);
    }

    pub fn announce(s: *Sounds, m: Computer, time: f64, rng: std.Random) void {
        s.play(&s.computer[@intFromEnum(m)], time, rng);
    }

    pub fn losing(s: *Sounds, time: f64, rng: std.Random) void {
        s.play(&s.losing_lines[rng.uintLessThan(usize, losing_lines)], time, rng);
    }

    /// Line `n` (1..75) of the robots.
    fn say(s: *Sounds, n: u8, time: f64, rng: std.Random) void {
        if (n < 1 or n > voices) return;
        s.play(&s.voice[n - 1], time, rng);
    }

    /// The line that goes with a portrait animation (PlayAnimSound).
    pub fn speak(s: *Sounds, anim: portrait.Anim, time: f64, rng: std.Random) void {
        const line: u8 = switch (anim) {
            .yes_sir, .yes_sir_salute => if (rng.boolean()) 1 else 2,
            .yes_sir3 => 3,
            .unit_reporting1 => 4,
            .unit_reporting2 => if (rng.boolean()) 5 else 6,
            .grunts_reporting => 7,
            .psychos_reporting => 8,
            .snipers_reporting => 9,
            .toughs_reporting => 10,
            .lasers_reporting => 11,
            .pyros_reporting => 12,
            .were_on_our_way => 13,
            .here_we_go => 14,
            .youve_got_it => 15,
            .moving_in => 16,
            .okay => 17,
            .alright => 18,
            .no_problem => 19,
            .over_n_out => 20,
            .affirmative => 21,
            .going_in, .going_in_thumbs_up => 22,
            .lets_do_it => 23,
            .lets_get_em => 24,
            .were_under_attack => 25,
            .i_said_were_under_attack => 26,
            .help_help => 27,
            .theyre_all_over_us => 28,
            .were_losing_it => 29,
            .aaahhh => 30,
            .for_christ_sake => 32,
            .youre_joking => 33,
            .no_way => 34,
            .forget_it => 35,
            .get_outta_here => 36,
            .target_destroyed => 37,
            .good_hit => 40,
            .nice_one => 41,
            .oh_yeah => 42,
            .gotcha => 43,
            .smokin => 44,
            .cool => 45,
            .wipe_out => 46,
            .territory_taken => 49,
            .fire_extinguished => 50,
            .gun_captured => 51,
            .vehicle_captured => 52,
            .grenades_collected => 53,
            // Six cheers when winning, seven insults when losing.
            .end_won1, .end_won2, .end_won3 => 61 + rng.uintLessThan(u8, 6),
            .end_lost1, .end_lost2, .end_lost3 => 67 + rng.uintLessThan(u8, 7),
            else => return,
        };
        s.say(line, time, rng);
    }

    /// Keep a loop playing (or stop it).
    pub fn loop(s: *Sounds, l: Loop, playing: bool) void {
        if (!s.on) return;
        const i = @intFromEnum(l);
        const st = s.loop_streams[i] orelse return;
        if (playing == s.loop_on[i]) return;
        s.loop_on[i] = playing;
        if (!playing) {
            _ = c.SDL_ClearAudioStream(st);
            return;
        }
        const clip = s.loops[i].clip orelse return;
        start(st, clip, s.gain(s.loops[i].def.volume));
    }

    /// Top up the loops and the music; call every frame.
    pub fn pump(s: *Sounds) void {
        if (!s.on) return;
        for (s.loop_streams, s.loops, s.loop_on) |st, slot, on| {
            const x = st orelse continue;
            const clip = slot.clip orelse continue;
            if (on and c.SDL_GetAudioStreamQueued(x) < clip.len) _ = c.SDL_PutAudioStreamData(x, clip.data, @intCast(clip.len));
        }
        s.music.pump();
    }
};

// ---------------------------------------------------------------------------
// Music
// ---------------------------------------------------------------------------

pub const Danger = enum { calm, attacking, fort };

/// Planet music: one long piece per planet with calm, fighting and
/// "fort under attack" parts; the music jumps to a part fitting how the
/// game goes.
pub const Music = struct {
    pieces: [3]?*c.stb_vorbis = @splat(null),
    stream: ?*c.SDL_AudioStream = null,
    playing: ?k.Planet = null,
    danger: Danger = .calm,
    /// A new danger level is taken on only after it held for a while.
    wanted: Danger = .calm,
    change_at: f64 = 0,
    /// When the current part ends (then another one starts).
    part_ends: ?f64 = null,
    next_check: f64 = 0,

    /// Where the parts start (seconds) and where each level's parts end.
    const Parts = struct { ends: [3]f64, starts: [3][]const f64 };

    const desert: Parts = .{ .ends = .{ 180.23 - 1, 275.87 - 1, 371.47 - 1 }, .starts = .{ &.{ 0, 60, 75, 88.5, 105, 146.3 }, &.{ 180.23, 210 }, &.{ 275.87, 335.77 } } };
    const volcanic: Parts = .{ .ends = .{ 204.31 - 1, 267.174 - 1, 361.34 - 1 }, .starts = .{ &.{ 0, 62.68, 94.73, 141.93, 157.15 }, &.{ 204.31, 235.75 }, &.{ 267.174, 282.89, 330.04 } } };
    const jungle: Parts = .{ .ends = .{ 168.05 - 1, 227.075 - 1, 342.77 - 1 }, .starts = .{ &.{ 0, 46.03, 107.4, 122.74 }, &.{ 168.05, 197.79 }, &.{ 227.075, 256.37, 288.83 } } };

    fn piece(p: k.Planet) usize {
        return switch (p) {
            .desert, .arctic => 0,
            .volcanic, .city => 1,
            .jungle => 2,
        };
    }

    fn parts(p: k.Planet) *const Parts {
        return switch (piece(p)) {
            0 => &desert,
            1 => &volcanic,
            else => &jungle,
        };
    }

    fn load(m: *Music, assets: []const u8) void {
        var buf: [512]u8 = undefined;
        for (&m.pieces, [_][]const u8{ "desert", "volcanic", "jungle" }) |*pc, name| {
            const path = std.fmt.bufPrintZ(&buf, "{s}/sounds/music_{s}.ogg", .{ assets, name }) catch continue;
            var err: c_int = 0;
            pc.* = c.stb_vorbis_open_filename(path.ptr, &err, null);
            if (pc.* == null) std.log.warn("could not load music {s}", .{path});
        }
    }

    fn deinit(m: *Music) void {
        if (m.stream) |st| c.SDL_DestroyAudioStream(st);
        for (m.pieces) |pc| if (pc) |p| c.stb_vorbis_close(p);
    }

    fn setGain(m: *Music, master: f32) void {
        if (m.stream) |st| _ = c.SDL_SetAudioStreamGain(st, 80.0 / 128.0 * master);
    }

    fn current(m: *const Music) ?*c.stb_vorbis {
        return m.pieces[piece(m.playing orelse return null)];
    }

    pub fn start(m: *Music, planet: k.Planet) void {
        const st = m.stream orelse return;
        const v = m.pieces[piece(planet)] orelse return;
        const info = c.stb_vorbis_get_info(v);
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_S16, .channels = info.channels, .freq = @intCast(info.sample_rate) };
        _ = c.SDL_ClearAudioStream(st);
        _ = c.SDL_SetAudioStreamFormat(st, &spec, null);
        _ = c.stb_vorbis_seek_start(v);
        m.playing = planet;
        m.danger = .calm;
        m.wanted = .calm;
        m.part_ends = null;
    }

    /// Keep about a quarter second decoded ahead; the piece repeats.
    fn pump(m: *Music) void {
        const st = m.stream orelse return;
        const v = m.current() orelse return;
        const info = c.stb_vorbis_get_info(v);
        const ch: c_int = @max(info.channels, 1);
        const ahead: c_int = @intCast(info.sample_rate / 4 * @as(c_uint, @intCast(ch)) * 2);
        var buf: [4096]i16 = undefined;
        var restarted = false;
        while (c.SDL_GetAudioStreamQueued(st) < ahead) {
            const n = c.stb_vorbis_get_samples_short_interleaved(v, ch, &buf, buf.len);
            if (n == 0) {
                if (restarted) return;
                restarted = true;
                _ = c.stb_vorbis_seek_start(v);
                continue;
            }
            _ = c.SDL_PutAudioStreamData(st, &buf, n * ch * 2);
        }
    }

    fn jump(m: *Music, time: f64, rng: std.Random) void {
        const planet = m.playing orelse return;
        const p = parts(planet);
        const level = @intFromEnum(m.danger);
        const starts = p.starts[level];
        const at = starts[rng.uintLessThan(usize, starts.len)];
        if (m.current()) |v| {
            const rate: f64 = @floatFromInt(c.stb_vorbis_get_info(v).sample_rate);
            _ = c.stb_vorbis_seek(v, @intFromFloat(at * rate));
            if (m.stream) |st| _ = c.SDL_ClearAudioStream(st);
        }
        m.part_ends = time + (p.ends[level] - at);
        m.change_at = time + @as(f64, switch (m.danger) {
            .calm => 5,
            .attacking => 7,
            .fort => 3,
        });
    }

    /// `danger` is how things look now; the music follows after a delay.
    /// `fort_destroyed` makes changes wait longer.
    pub fn update(m: *Music, danger: Danger, fort_destroyed: bool, time: f64, rng: std.Random) void {
        if (m.playing == null) return;
        if (time >= m.next_check) {
            m.next_check = time + 0.25;
            if (danger != m.wanted) {
                m.wanted = danger;
                m.change_at = @max(m.change_at, time + @as(f64, if (fort_destroyed) 15 else 3));
            }
            if (time >= m.change_at and m.wanted != m.danger) {
                m.danger = m.wanted;
                m.jump(time, rng);
            }
        }
        if (m.part_ends) |end| if (time >= end) m.jump(time, rng);
    }
};

test "music parts" {
    for ([_]k.Planet{ .desert, .volcanic, .jungle, .arctic, .city }) |p| {
        const ps = Music.parts(p);
        for (ps.starts, ps.ends) |starts, end| for (starts) |s| try std.testing.expect(s < end);
    }
}
