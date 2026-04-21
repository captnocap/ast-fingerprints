-- Löve port of ts-parse viewer (treemap of AST contracts).
-- Native: love viewer-love <contract.json>
-- Web: drop a contract.json onto the canvas.

local viewer = require('viewer')

local GRID_COLS = 6          -- individual mode: fixed columns, auto rows
local TILED_SIDE = 12        -- tiled mode: packed NxN grid, wraps/repeats
local mode = 'individual'    -- or 'tiled'
local scroll_y = 0           -- pixels scrolled in individual mode
local files = {}             -- { path, root, count, max_end, kind, start, end_, fc, ns }
local status = "drop a contract.json (or pass one on the cli)"

-- HSV -> RGB (0..1 channels for love.graphics)
local function hsv(h_in, s, v)
  local h = h_in % 360
  local cc = v * s
  local hp = h / 60
  local xx = cc * (1 - math.abs((hp % 2) - 1))
  local r, g, b = 0, 0, 0
  if hp < 1 then r, g = cc, xx
  elseif hp < 2 then r, g = xx, cc
  elseif hp < 3 then g, b = cc, xx
  elseif hp < 4 then g, b = xx, cc
  elseif hp < 5 then r, b = xx, cc
  else r, b = cc, xx end
  local m = v - cc
  return r + m, g + m, b + m
end

local function color_for(kind_id, depth, t, in_scan)
  local base_h = (kind_id * 137) % 360
  local h = base_h + t * 22 + depth * 7
  if in_scan then h = h + 55 end
  local wave = math.sin(t * 2.2 - depth * 0.55)
  local v = 0.62 + 0.18 * wave
  local s = 0.55
  if in_scan then v = math.min(1, v + 0.25); s = 0.78 end
  return hsv(h, s, v)
end

local function draw_node(f, node, x, y, w, h, depth, t, scan_pos)
  if w < 1 or h < 1 or node == 0 then return end
  local idx = node
  local ns_, ne = f.start[idx], f.end_[idx]
  local in_scan = scan_pos >= ns_ and scan_pos < ne
  local r, g, b = color_for(f.kind[idx], depth, t, in_scan)
  love.graphics.setColor(r, g, b, 1)
  love.graphics.rectangle('fill', x, y, w, h)
  if w >= 3 and h >= 3 then
    local o = in_scan and 0.94 or 0.07
    love.graphics.setColor(o, o, o, 1)
    love.graphics.rectangle('line', x, y, w, h)
  end

  local fc = f.fc[idx]
  if fc == 0 then return end

  local total = 0
  local it = fc
  while it ~= 0 do
    local s_, e_ = f.start[it], f.end_[it]
    total = total + (e_ > s_ and (e_ - s_) or 1)
    it = f.ns[it]
  end
  if total == 0 then return end

  local horizontal = (depth % 2) == 0
  local pad = (w > 24 and h > 24) and 1 or 0
  local ix, iy = x + pad, y + pad
  local iw, ih = w - 2 * pad, h - 2 * pad

  if horizontal then
    local cx = ix
    it = fc
    while it ~= 0 do
      local s_, e_ = f.start[it], f.end_[it]
      local span = e_ > s_ and (e_ - s_) or 1
      local cw = iw * span / total
      draw_node(f, it, cx, iy, cw, ih, depth + 1, t, scan_pos)
      cx = cx + cw
      it = f.ns[it]
    end
  else
    local cy = iy
    it = fc
    while it ~= 0 do
      local s_, e_ = f.start[it], f.end_[it]
      local span = e_ > s_ and (e_ - s_) or 1
      local chh = ih * span / total
      draw_node(f, it, ix, cy, iw, chh, depth + 1, t, scan_pos)
      cy = cy + chh
      it = f.ns[it]
    end
  end
end

local function ingest_contract_string(s)
  local ok, err = pcall(viewer.load_string, s)
  if not ok then status = "parse error: " .. tostring(err); return end
  local n = #viewer.data.files
  files = {}
  for i = 1, n do
    if viewer.file_count(i) > 0 then
      local kind, start, end_, fc, ns_, max_end = viewer.arrays(i)
      files[#files + 1] = {
        path = viewer.file_path(i),
        repo = viewer.file_repo(i),
        root = viewer.file_root(i),
        count = viewer.file_count(i),
        max_end = max_end,
        kind = kind, start = start, end_ = end_,
        fc = fc, ns = ns_,
      }
    end
  end
  status = string.format("%d files (of %d) — [t] toggle mode, [scroll] in individual",
    #files, n)
  scroll_y = 0
  if love.window and love.window.setTitle then
    pcall(love.window.setTitle, "TS AST Grid — " .. status)
  end
end

function love.load(arg)
  love.graphics.setBackgroundColor(18/255, 18/255, 22/255)
  -- Web / packaged: try bundled default contract first.
  if love.filesystem.getInfo('default-contract.json') then
    ingest_contract_string(love.filesystem.read('default-contract.json'))
  end
  -- Native CLI: love viewer-love path/to/contract.json
  local cli = arg and arg[1]
  if cli and cli ~= '' then
    local fh = io.open(cli, 'r')
    if fh then
      local s = fh:read('*a'); fh:close()
      ingest_contract_string(s)
    end
  end
end

function love.filedropped(file)
  file:open('r')
  local s = file:read()
  file:close()
  ingest_contract_string(s)
end

function love.keypressed(k)
  if k == 'escape' or k == 'q' then love.event.quit()
  elseif k == 't' then
    mode = (mode == 'individual') and 'tiled' or 'individual'
    scroll_y = 0
  end
end

function love.wheelmoved(_, dy)
  if mode == 'individual' then
    -- Normalize: native gives dy=±1 per notch; love.js / browsers can send
    -- dy=±100+ per notch. Clamp to a unit step, then scale by a fraction of
    -- a cell so one notch moves ~half a row.
    local step = (dy > 0 and 1 or -1)
    local w, h = love.graphics.getDimensions()
    local cell = w / GRID_COLS
    scroll_y = math.max(0, scroll_y - step * cell * 0.5)
  end
end

local function cell_under_mouse(w, h)
  -- Returns the file index under the mouse, or nil. Mirrors the layout math
  -- used by love.draw so they stay in sync.
  if #files == 0 then return nil end
  local mx, my = love.mouse.getPosition()
  if mode == 'tiled' then
    local side = math.min(w, h)
    local off_x = (w - side) * 0.5
    local off_y = (h - side) * 0.5
    local cell = side / TILED_SIDE
    local col = math.floor((mx - off_x) / cell)
    local row = math.floor((my - off_y) / cell)
    if col < 0 or col >= TILED_SIDE or row < 0 or row >= TILED_SIDE then return nil end
    local i = row * TILED_SIDE + col
    return ((i % #files) + 1)
  else
    local cell = w / GRID_COLS
    local col = math.floor(mx / cell)
    local row = math.floor((my + scroll_y) / cell)
    if col < 0 or col >= GRID_COLS then return nil end
    local idx = row * GRID_COLS + col + 1
    if idx < 1 or idx > #files then return nil end
    return idx
  end
end

local function draw_tooltip(w, h)
  local idx = cell_under_mouse(w, h)
  if not idx then return end
  local f = files[idx]
  local label = f.path
  if f.repo then label = f.repo .. '  ·  ' .. label end
  local fw = love.graphics.getFont():getWidth(label)
  local fh = love.graphics.getFont():getHeight()
  local mx, my = love.mouse.getPosition()
  local pad = 6
  local bx = math.min(mx + 14, w - fw - pad * 2 - 2)
  local by = math.min(my + 14, h - fh - pad * 2 - 2)
  love.graphics.setColor(0, 0, 0, 0.8)
  love.graphics.rectangle('fill', bx, by, fw + pad * 2, fh + pad * 2, 4, 4)
  love.graphics.setColor(1, 1, 1, 0.95)
  love.graphics.print(label, bx + pad, by + pad)
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  if #files == 0 then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(status, 0, h / 2 - 10, w, 'center')
    return
  end

  local t = love.timer.getTime()
  local gap = 2

  if mode == 'tiled' then
    local side = math.min(w, h)
    local off_x = (w - side) * 0.5
    local off_y = (h - side) * 0.5
    local cell = side / TILED_SIDE
    local total_cells = TILED_SIDE * TILED_SIDE
    for i = 0, total_cells - 1 do
      local col = i % TILED_SIDE
      local row = math.floor(i / TILED_SIDE)
      local cx = off_x + col * cell + gap
      local cy = off_y + row * cell + gap
      local cw, ch = cell - 2 * gap, cell - 2 * gap
      local f = files[(i % #files) + 1]
      local phase = i * 0.31
      local tt = t + phase
      local tri = math.abs(((tt * 0.35) % 2) - 1)
      local scan_pos = math.floor((1 - tri) * f.max_end)
      draw_node(f, f.root, cx, cy, cw, ch, 0, tt, scan_pos)
    end
  else
    -- individual: one file per cell, GRID_COLS wide, scrolls vertically.
    local cell = w / GRID_COLS
    local rows = math.ceil(#files / GRID_COLS)
    local total_h = rows * cell
    local max_scroll = math.max(0, total_h - h)
    if scroll_y > max_scroll then scroll_y = max_scroll end
    for i = 1, #files do
      local col = (i - 1) % GRID_COLS
      local row = math.floor((i - 1) / GRID_COLS)
      local cx = col * cell + gap
      local cy = row * cell + gap - scroll_y
      local cw, ch = cell - 2 * gap, cell - 2 * gap
      if cy + ch >= 0 and cy <= h then
        local f = files[i]
        local phase = i * 0.31
        local tt = t + phase
        local tri = math.abs(((tt * 0.35) % 2) - 1)
        local scan_pos = math.floor((1 - tri) * f.max_end)
        draw_node(f, f.root, cx, cy, cw, ch, 0, tt, scan_pos)
      end
    end
  end

  love.graphics.setColor(1, 1, 1, 0.55)
  love.graphics.print(status .. "  mode=" .. mode, 8, 8)
  draw_tooltip(w, h)
end
