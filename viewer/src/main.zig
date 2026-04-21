const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

const viewer_lua = @embedFile("viewer.lua");

const WIN_W: c_int = 1024;
const WIN_H: c_int = 1024;
const GRID_SIDE: usize = 12; // nearest perfect square to 139 files (144 cells)

const File = struct {
    path: [:0]u8,
    root: u32,
    count: u32,
    max_end: u32,
    kind: []u32,
    start: []u32,
    end_: []u32,
    first_child: []u32,
    next_sibling: []u32,

    fn deinit(self: *File, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.kind);
        alloc.free(self.start);
        alloc.free(self.end_);
        alloc.free(self.first_child);
        alloc.free(self.next_sibling);
    }
};

fn luaPanic(L: ?*c.lua_State, what: []const u8) noreturn {
    const msg = c.lua_tolstring(L, -1, null);
    const s = if (msg != null) std.mem.span(msg) else "(no message)";
    std.debug.print("lua error during {s}: {s}\n", .{ what, s });
    std.process.exit(1);
}

fn luaCall(L: ?*c.lua_State, nargs: c_int, nres: c_int, what: []const u8) void {
    if (c.lua_pcall(L, nargs, nres, 0) != 0) luaPanic(L, what);
}

fn loadViewerModule(L: ?*c.lua_State) void {
    if (c.luaL_loadbuffer(L, viewer_lua.ptr, viewer_lua.len, "viewer.lua") != 0)
        luaPanic(L, "loadbuffer viewer.lua");
    luaCall(L, 0, 1, "viewer.lua init");
    c.lua_setfield(L, c.LUA_GLOBALSINDEX, "viewer");
}

fn pushViewerFn(L: ?*c.lua_State, name: [*:0]const u8) void {
    c.lua_getfield(L, c.LUA_GLOBALSINDEX, "viewer");
    c.lua_getfield(L, -1, name);
    c.lua_remove(L, -2);
}

fn callLoad(L: ?*c.lua_State, path: [*:0]const u8) u32 {
    pushViewerFn(L, "load");
    c.lua_pushstring(L, path);
    luaCall(L, 1, 1, "viewer.load");
    const n: u32 = @intCast(c.lua_tointeger(L, -1));
    c.lua_settop(L, -2);
    return n;
}

fn callIntArg(L: ?*c.lua_State, fn_name: [*:0]const u8, arg: u32) c.lua_Integer {
    pushViewerFn(L, fn_name);
    c.lua_pushinteger(L, @intCast(arg));
    luaCall(L, 1, 1, "viewer int call");
    const r = c.lua_tointeger(L, -1);
    c.lua_settop(L, -2);
    return r;
}

fn callStrArg(L: ?*c.lua_State, fn_name: [*:0]const u8, arg: u32, alloc: std.mem.Allocator) ![:0]u8 {
    pushViewerFn(L, fn_name);
    c.lua_pushinteger(L, @intCast(arg));
    luaCall(L, 1, 1, "viewer str call");
    const s = c.lua_tolstring(L, -1, null);
    const out = try alloc.dupeZ(u8, std.mem.span(s));
    c.lua_settop(L, -2);
    return out;
}

fn loadFile(L: ?*c.lua_State, alloc: std.mem.Allocator, idx: u32) !File {
    const path = try callStrArg(L, "file_path", idx, alloc);
    errdefer alloc.free(path);
    const root: u32 = @intCast(callIntArg(L, "file_root", idx));
    const count: u32 = @intCast(callIntArg(L, "file_count", idx));

    // Call viewer.arrays(idx) -> kind, start, end, firstChild, nextSibling
    pushViewerFn(L, "arrays");
    c.lua_pushinteger(L, @intCast(idx));
    luaCall(L, 1, 5, "viewer.arrays");

    const base_top = c.lua_gettop(L) - 5;
    var arrays: [5][]u32 = undefined;
    inline for (0..5) |k| {
        arrays[k] = try alloc.alloc(u32, count);
        const stack_idx: c_int = base_top + 1 + @as(c_int, @intCast(k));
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            _ = c.lua_rawgeti(L, stack_idx, @intCast(i + 1));
            arrays[k][i] = @intCast(c.lua_tointeger(L, -1));
            c.lua_settop(L, -2);
        }
    }
    c.lua_settop(L, -6); // pop 5 arrays

    var max_end: u32 = 0;
    for (arrays[2]) |e| if (e > max_end) { max_end = e; };

    return .{
        .path = path,
        .root = root,
        .count = count,
        .max_end = max_end,
        .kind = arrays[0],
        .start = arrays[1],
        .end_ = arrays[2],
        .first_child = arrays[3],
        .next_sibling = arrays[4],
    };
}

// ----- HSV -> RGB -----
const Rgb = struct { r: u8, g: u8, b: u8 };
fn hsvToRgb(h_in: f32, s: f32, v: f32) Rgb {
    const h = @mod(h_in, 360.0);
    const cc = v * s;
    const hp = h / 60.0;
    const xx = cc * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var r: f32 = 0; var g: f32 = 0; var b: f32 = 0;
    if (hp < 1) { r = cc; g = xx; }
    else if (hp < 2) { r = xx; g = cc; }
    else if (hp < 3) { g = cc; b = xx; }
    else if (hp < 4) { g = xx; b = cc; }
    else if (hp < 5) { r = xx; b = cc; }
    else              { r = cc; b = xx; }
    const m = v - cc;
    return .{
        .r = @intFromFloat((r + m) * 255.0),
        .g = @intFromFloat((g + m) * 255.0),
        .b = @intFromFloat((b + m) * 255.0),
    };
}

fn colorFor(kind_id: u32, depth: u32, t: f32, in_scan: bool) Rgb {
    // Base hue from kind, rotating slowly over time, with a depth offset so
    // nested levels don't all match in lockstep.
    const base_h: f32 = @floatFromInt((kind_id *% 137) % 360);
    const depth_f: f32 = @floatFromInt(depth);
    var h: f32 = base_h + t * 22.0 + depth_f * 7.0;
    if (in_scan) h += 55.0;

    // Brightness wave radiating outward from shallow -> deep.
    const wave = std.math.sin(t * 2.2 - depth_f * 0.55);
    var v: f32 = 0.62 + 0.18 * wave;
    var s: f32 = 0.55;
    if (in_scan) {
        v = @min(1.0, v + 0.25);
        s = 0.78;
    }
    return hsvToRgb(h, s, v);
}

// ----- Treemap draw -----
fn drawNode(
    r: *c.SDL_Renderer,
    f: *const File,
    node: u32,
    x: f32, y: f32, w: f32, h: f32,
    depth: u32,
    t: f32,
    scan_pos: u32,
) void {
    if (w < 1.0 or h < 1.0 or node == 0) return;
    const idx = node - 1;
    const ns = f.start[idx];
    const ne = f.end_[idx];
    const in_scan = scan_pos >= ns and scan_pos < ne;
    const col = colorFor(f.kind[idx], depth, t, in_scan);
    _ = c.SDL_SetRenderDrawColor(r, col.r, col.g, col.b, 255);
    const rect = c.SDL_FRect{ .x = x, .y = y, .w = w, .h = h };
    _ = c.SDL_RenderFillRect(r, &rect);

    if (w >= 3.0 and h >= 3.0) {
        const outline: u8 = if (in_scan) 240 else 18;
        _ = c.SDL_SetRenderDrawColor(r, outline, outline, outline, 255);
        _ = c.SDL_RenderRect(r, &rect);
    }

    const fc = f.first_child[idx];
    if (fc == 0) return;

    // Sum source spans of children for proportional layout.
    var total: u64 = 0;
    var it = fc;
    while (it != 0) : (it = f.next_sibling[it - 1]) {
        const s = f.start[it - 1];
        const e = f.end_[it - 1];
        total += if (e > s) e - s else 1;
    }
    if (total == 0) return;

    const horizontal = depth % 2 == 0;
    const pad: f32 = if (w > 24.0 and h > 24.0) 1.0 else 0.0;
    const ix = x + pad;
    const iy = y + pad + (if (horizontal) @as(f32, 0) else @as(f32, 0));
    const iw = w - 2 * pad;
    const ih = h - 2 * pad;

    if (horizontal) {
        var cx = ix;
        it = fc;
        while (it != 0) : (it = f.next_sibling[it - 1]) {
            const s = f.start[it - 1];
            const e = f.end_[it - 1];
            const span: u64 = if (e > s) e - s else 1;
            const cw = iw * @as(f32, @floatFromInt(span)) / @as(f32, @floatFromInt(total));
            drawNode(r, f, it, cx, iy, cw, ih, depth + 1, t, scan_pos);
            cx += cw;
        }
    } else {
        var cy = iy;
        it = fc;
        while (it != 0) : (it = f.next_sibling[it - 1]) {
            const s = f.start[it - 1];
            const e = f.end_[it - 1];
            const span: u64 = if (e > s) e - s else 1;
            const chh = ih * @as(f32, @floatFromInt(span)) / @as(f32, @floatFromInt(total));
            drawNode(r, f, it, ix, cy, iw, chh, depth + 1, t, scan_pos);
            cy += chh;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var contract_arg: ?[]const u8 = null;
    var record_path: ?[]const u8 = null;
    var auto_stop_ms: ?u64 = null;
    {
        var ai: usize = 1;
        while (ai < args.len) : (ai += 1) {
            const a = args[ai];
            if (std.mem.eql(u8, a, "--record") and ai + 1 < args.len) {
                record_path = args[ai + 1];
                ai += 1;
            } else if (std.mem.eql(u8, a, "--seconds") and ai + 1 < args.len) {
                const sec = std.fmt.parseFloat(f64, args[ai + 1]) catch 0.0;
                auto_stop_ms = @intFromFloat(sec * 1000.0);
                ai += 1;
            } else if (contract_arg == null) {
                contract_arg = a;
            }
        }
    }
    if (contract_arg == null) {
        std.debug.print("usage: viewer <contract.json> [--record <out.gif>] [--seconds N]\n", .{});
        return;
    }
    const contract_path = try alloc.dupeZ(u8, contract_arg.?);
    defer alloc.free(contract_path);

    // ---- LuaJIT init ----
    const L_opt = c.luaL_newstate();
    if (L_opt == null) {
        std.debug.print("luaL_newstate failed\n", .{});
        return;
    }
    const L = L_opt;
    defer c.lua_close(L);
    c.luaL_openlibs(L);
    loadViewerModule(L);

    const file_count = callLoad(L, contract_path.ptr);
    std.debug.print("loaded contract: {d} files\n", .{file_count});
    if (file_count == 0) return;

    // ---- SDL3 init ----
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("TS AST Grid", WIN_W, WIN_H, 0);
    if (window == null) {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return;
    }
    defer c.SDL_DestroyWindow(window);

    const renderer_opt = c.SDL_CreateRenderer(window, null);
    if (renderer_opt == null) {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return;
    }
    const renderer = renderer_opt.?;
    defer c.SDL_DestroyRenderer(renderer);

    // ---- Load every non-empty file ----
    var non_empty: u32 = 0;
    {
        var i: u32 = 1;
        while (i <= file_count) : (i += 1) {
            if (callIntArg(L, "file_count", i) > 0) non_empty += 1;
        }
    }
    const files = try alloc.alloc(File, non_empty);
    defer {
        for (files) |*ff| ff.deinit(alloc);
        alloc.free(files);
    }
    {
        var out_idx: u32 = 0;
        var i: u32 = 1;
        while (i <= file_count) : (i += 1) {
            if (callIntArg(L, "file_count", i) > 0) {
                files[out_idx] = try loadFile(L, alloc, i);
                out_idx += 1;
            }
        }
    }
    std.debug.print("loaded {d} non-empty files into {d}x{d} grid\n", .{ files.len, GRID_SIDE, GRID_SIDE });

    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "TS AST Grid — {d} files ({d}x{d})", .{ files.len, GRID_SIDE, GRID_SIDE }) catch "TS AST Grid";
    _ = c.SDL_SetWindowTitle(window, title.ptr);

    // ---- Optional ffmpeg recording pipeline ----
    var rec_child: ?std.process.Child = null;
    var size_buf: [32]u8 = undefined;
    if (record_path) |rp| {
        const size_str = std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ WIN_W, WIN_H }) catch unreachable;
        const argv = [_][]const u8{
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pixel_format", "rgb24",
            "-video_size", size_str,
            "-framerate", "60",
            "-i", "-",
            "-vf", "fps=20,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=3",
            rp,
        };
        var child = std.process.Child.init(&argv, alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch |err| {
            std.debug.print("failed to spawn ffmpeg: {s}\n", .{@errorName(err)});
            return err;
        };
        rec_child = child;
        std.debug.print("recording -> {s} (press Esc/Q to finalize)\n", .{rp});
    }
    defer {
        if (rec_child) |*ch| {
            if (ch.stdin) |stdin| stdin.close();
            ch.stdin = null;
            _ = ch.wait() catch {};
            std.debug.print("ffmpeg finalized\n", .{});
        }
    }

    // ---- Event loop ----
    const start_ms: u64 = c.SDL_GetTicks();
    var running = true;
    while (running) {
        if (auto_stop_ms) |limit| {
            if (c.SDL_GetTicks() - start_ms >= limit) running = false;
        }
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    const k = ev.key.key;
                    if (k == c.SDLK_ESCAPE or k == c.SDLK_Q) running = false;
                },
                else => {},
            }
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 18, 18, 22, 255);
        _ = c.SDL_RenderClear(renderer);

        var w: c_int = WIN_W; var h: c_int = WIN_H;
        _ = c.SDL_GetWindowSize(window, &w, &h);
        const w_f: f32 = @floatFromInt(w);
        const h_f: f32 = @floatFromInt(h);

        // Square draw region centered in the window.
        const side = @min(w_f, h_f);
        const off_x = (w_f - side) * 0.5;
        const off_y = (h_f - side) * 0.5;

        const t: f32 = @as(f32, @floatFromInt(c.SDL_GetTicks())) / 1000.0;

        const cell = side / @as(f32, @floatFromInt(GRID_SIDE));
        const gap: f32 = 2.0;
        const total_cells = GRID_SIDE * GRID_SIDE;

        var i: usize = 0;
        while (i < total_cells) : (i += 1) {
            const col: usize = i % GRID_SIDE;
            const row: usize = i / GRID_SIDE;
            const cx = off_x + @as(f32, @floatFromInt(col)) * cell + gap;
            const cy = off_y + @as(f32, @floatFromInt(row)) * cell + gap;
            const cw = cell - 2 * gap;
            const ch = cell - 2 * gap;

            // Wrap around — duplicates the first (total_cells - files.len) files.
            const f = &files[i % files.len];

            const phase: f32 = @as(f32, @floatFromInt(i)) * 0.31;
            const tt = t + phase;
            const tri = @abs(@mod(tt * 0.35, 2.0) - 1.0);
            const scan_pos: u32 = @intFromFloat(
                (1.0 - tri) * @as(f32, @floatFromInt(f.max_end)),
            );

            drawNode(renderer, f, f.root, cx, cy, cw, ch, 0, tt, scan_pos);
        }

        _ = c.SDL_RenderPresent(renderer);

        if (rec_child) |*ch| captureFrame(renderer, ch) catch |err| {
            std.debug.print("capture error: {s} — stopping recording\n", .{@errorName(err)});
            if (ch.stdin) |stdin| stdin.close();
            ch.stdin = null;
            rec_child = null;
        };

        _ = c.SDL_Delay(16);
    }
}

fn captureFrame(renderer: *c.SDL_Renderer, child: *std.process.Child) !void {
    const surf = c.SDL_RenderReadPixels(renderer, null) orelse return error.ReadPixelsFailed;
    defer c.SDL_DestroySurface(surf);

    const rgb_surf = c.SDL_ConvertSurface(surf, c.SDL_PIXELFORMAT_RGB24) orelse return error.ConvertSurfaceFailed;
    defer c.SDL_DestroySurface(rgb_surf);

    const pitch: usize = @intCast(rgb_surf.*.pitch);
    const sh: usize = @intCast(rgb_surf.*.h);
    const sw: usize = @intCast(rgb_surf.*.w);
    const row_bytes = sw * 3;
    const pixels = @as([*]const u8, @ptrCast(rgb_surf.*.pixels));

    const stdin = child.stdin orelse return error.NoStdin;
    var y: usize = 0;
    while (y < sh) : (y += 1) {
        const row_start = y * pitch;
        try stdin.writeAll(pixels[row_start .. row_start + row_bytes]);
    }
}

