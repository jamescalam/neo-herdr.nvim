-- neo-herdr: the herd tab. Renders herdr workspaces/panes as two-line rows with
-- state glyphs and per-row actions, hosts the chat terminal, and draws a
-- context-aware keybinding bar under chat + nav. Data comes from the socket
-- (snapshot + pushed events) with a CLI poll as a correctness backstop, against
-- a server this module starts on demand (see server.lua).

local socket = require("neo-herdr.socket")
local state = require("neo-herdr.state")
local server = require("neo-herdr.server")

local M = {}

local NS = vim.api.nvim_create_namespace("neo_herdr_dashboard")
local HELP_NS = vim.api.nvim_create_namespace("neo_herdr_help")
local STATUS_NS = vim.api.nvim_create_namespace("neo_herdr_notifier")
local AUG = "neo_herdr_dashboard"

local D = {
  tab = nil,
  win = nil, -- nav window
  buf = nil, -- nav buffer (bufhidden=hide; survives layout rebuilds)
  chat_win = nil,
  main_win = nil,
  help_win = nil,
  help_buf = nil,
  status_win = nil,
  status_buf = nil,
  chat_pane = nil, -- pane id shown in the chat window
  chat_bufs = {}, -- pane id -> attached terminal buffer
  line_target = {}, -- 1-indexed nav line -> pane id
  row_lines = {}, -- first line (1-indexed) of every row, in order
  poll_timer = nil,
  started = false, -- controller (state listener + poll timer) wired up
  sub_sig = nil,
  sub_panes = nil, -- pane ids in the current subscription, in order
  server_state = "unknown", -- unknown | starting | running | stopped
  server_err = nil,
  mode = nil, -- data source: socket | cli-poll
  config = nil,
}

local function truncate(s, n)
  s = s or ""
  if vim.fn.strchars(s) <= n then
    return s
  end
  return vim.fn.strcharpart(s, 0, math.max(1, n - 1)) .. "…"
end

local GLYPH = { working = "●", idle = "○", blocked = "◉", done = "✓", unknown = "·" }
local STATUS_HL = {
  working = "NeoHerdrWorking",
  idle = "NeoHerdrIdle",
  blocked = "NeoHerdrBlocked",
  done = "NeoHerdrDone",
  unknown = "NeoHerdrUnknown",
}
local STATUS_WORD = { working = "working", idle = "idle", blocked = "needs input", done = "done" }

-- Explicit, status-driven glyph colors (like herdr's own UI). Set as defaults so
-- a colorscheme or user `:highlight NeoHerdr* …` still wins, but they render the
-- right color even when the theme leaves Diagnostic* groups undefined.
local STATUS_COLORS = {
  NeoHerdrWorking = { fg = "#e5c07b", ctermfg = 179 }, -- amber — actively working
  NeoHerdrIdle = { fg = "#828997", ctermfg = 245 }, -- grey — idle / waiting
  NeoHerdrBlocked = { fg = "#e06c75", ctermfg = 204 }, -- red — blocked, needs input
  NeoHerdrBlockedDim = { fg = "#7a3b42", ctermfg = 95 }, -- the notifier's "off" phase while flashing
  NeoHerdrDone = { fg = "#98c379", ctermfg = 114 }, -- green — done ✓
  NeoHerdrUnknown = { fg = "#5c6370", ctermfg = 240 }, -- dim — no agent (shell)
}

local function define_highlights()
  local function link(name, target)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
  end
  for name, c in pairs(STATUS_COLORS) do
    vim.api.nvim_set_hl(0, name, { fg = c.fg, ctermfg = c.ctermfg })
  end
  link("NeoHerdrHeader", "Title")
  link("NeoHerdrName", "Normal")
  link("NeoHerdrFocused", "Title")
  link("NeoHerdrWs", "Directory")
  link("NeoHerdrProgram", "Comment")
  link("NeoHerdrSecondary", "Comment")
  link("NeoHerdrDim", "NonText")
  link("NeoHerdrCurrent", "Visual") -- row shown in the chat: whole-row background
  link("NeoHerdrCurrentBar", "Title") -- …and its ▎ edge bar in the sign column
  link("NeoHerdrKey", "Title") -- keys in the help bar
  link("NeoHerdrContext", "IncSearch") -- [NAV] / [CHAT] context label
  link("NeoHerdrNotifierEdge", "WinSeparator")
  link("NeoHerdrNotifierOff", "NonText")
end

-- ── Controller: keep `state` fresh from socket + poll ──────────────────────

local refresh -- forward

local function set_server_state(s, err)
  D.server_state = s
  D.server_err = err
  if s ~= "running" then
    D.mode = nil
    pcall(socket.close_subscription)
    D.sub_sig, D.sub_panes = nil, nil
    state.clear()
  end
  if D.buf and vim.api.nvim_buf_is_valid(D.buf) then
    M.render()
  end
end

local function on_event(name, data)
  if name == "pane.agent_status_changed" then
    state.apply_status_event(data)
  elseif name == "pane.exited" or name == "pane.closed" then
    state.remove_pane(data)
    refresh() -- rebuild the subscription without the dead pane
  elseif name == "pane.created" or name == "pane.agent_detected" then
    refresh()
  end
end

-- Global (no pane id) subscriptions: herdr never probes these, so they can't
-- be rejected, and they cover new/closed panes without waiting for the poll.
local GLOBAL_SUBS = { "pane.created", "pane.closed", "pane.exited", "pane.agent_detected" }

local function ensure_subscription(cfg)
  if cfg.use_socket == false then
    return
  end
  local ids = state.pane_ids()
  table.sort(ids)
  local sig = table.concat(ids, ",")
  if sig == D.sub_sig then
    return -- pane set unchanged; existing subscription still covers it
  end
  D.sub_sig = sig
  D.sub_panes = ids
  local subs = {}
  for _, t in ipairs(GLOBAL_SUBS) do
    table.insert(subs, { type = t })
  end
  for _, pid in ipairs(ids) do
    table.insert(subs, { type = "pane.agent_status_changed", pane_id = pid })
  end
  socket.subscribe({
    subscriptions = subs,
    on_event = on_event,
    on_status = function()
      if D.buf and vim.api.nvim_buf_is_valid(D.buf) then
        M.render() -- refresh the header live/… indicator
      end
    end,
    on_error = function(index, err)
      -- A per-pane subscription named a pane that just went away: drop it and
      -- resubscribe from a fresh snapshot instead of retrying the same list.
      local pane_idx = index and (index - #GLOBAL_SUBS) or nil
      local pid = pane_idx and D.sub_panes and D.sub_panes[pane_idx]
      if pid then
        state.remove_pane({ pane_id = pid })
      end
      D.sub_sig = nil
      vim.defer_fn(refresh, 200)
      if not pid then
        vim.notify("[neo-herdr] event subscription rejected: " .. vim.inspect(err), vim.log.levels.WARN)
      end
    end,
    path = socket.resolve_path(cfg.socket_path),
  })
end

-- One `session.snapshot` carries workspaces, tabs, panes AND agents (names),
-- so a refresh is a single round trip on either transport.
local function apply_snapshot(snap)
  state.set_snapshot(snap.panes, snap.workspaces, snap.agents, snap.tabs)
end

-- CLI fallback snapshot (also what tells us the server went away).
local function cli_snapshot()
  local H = require("neo-herdr.herdr")
  H.snapshot(function(snap, err)
    if err or not snap then
      if H.code_of(err) == "server_not_running" then
        set_server_state("stopped")
      end
      return
    end
    D.mode = "cli-poll"
    apply_snapshot(snap)
  end)
end

refresh = function()
  if D.server_state ~= "running" then
    return
  end
  local cfg = D.config or {}
  if cfg.use_socket == false then
    cli_snapshot()
    return
  end
  local path = socket.resolve_path(cfg.socket_path)
  socket.request_once("session.snapshot", vim.empty_dict(), function(res, err)
    local snap = res and (res.snapshot or res)
    if err or type(snap) ~= "table" or not snap.panes then
      cli_snapshot() -- socket unavailable; fall back (and detect a dead server)
      return
    end
    D.mode = "socket"
    apply_snapshot(snap)
    ensure_subscription(cfg)
  end, path)
end
M.refresh = refresh

local function start_controller(cfg)
  if D.started then
    return
  end
  D.started = true
  state.on_change(function()
    if D.buf and vim.api.nvim_buf_is_valid(D.buf) then
      M.render()
    end
  end)
  if cfg.auto_refresh ~= false then
    D.poll_timer = vim.fn.timer_start(cfg.poll_interval or 4000, function()
      if not (D.buf and vim.api.nvim_buf_is_valid(D.buf)) then
        return
      end
      if D.server_state == "running" then
        refresh()
      elseif D.server_state == "stopped" then
        -- Auto-recover if someone started the server behind our back.
        server.status(function(st)
          if st and st.running and D.server_state == "stopped" then
            set_server_state("running")
            refresh()
          end
        end)
      end
    end, { ["repeat"] = -1 })
  end
end

--- Probe/start the server, then load. Safe to call repeatedly.
local function connect_server()
  set_server_state("starting")
  server.ensure(function(ok, how, err)
    if not M.is_open() then
      return
    end
    if ok then
      set_server_state("running")
      if how == "started" then
        local s = server.config().session
        vim.notify("[neo-herdr] started herdr server" .. (s and (" (session " .. s .. ")") or ""))
      end
      refresh()
    else
      set_server_state("stopped", err)
      vim.notify("[neo-herdr] " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

function M.start_server()
  if D.server_state == "starting" then
    return
  end
  if not M.is_open() then
    -- No herd tab: just start it and report.
    server.ensure(function(ok, how, err)
      if ok then
        vim.notify("[neo-herdr] herdr server " .. (how == "started" and "started" or "already running"))
      else
        vim.notify("[neo-herdr] " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
    return
  end
  connect_server()
end

-- ── Rendering helpers ────────────────────────────────────────────────────────

local function conn_label()
  if D.server_state == "starting" then
    return "starting server…"
  elseif D.server_state == "stopped" then
    return "server stopped"
  end
  local mode = D.mode or "connecting…"
  if mode == "socket" then
    return socket.is_live() and "socket ●" or "socket"
  end
  return mode
end

-- Escape user text for a winbar/statusline (`%` is a directive there).
local function stl_esc(s)
  return (tostring(s or "")):gsub("%%", "%%%%")
end

-- Keep the chat window's winbar in sync with the pane it's showing.
local update_chat_header

update_chat_header = function()
  if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    return
  end
  if D.config and D.config.chat_header == false then
    return
  end
  local pane = D.chat_pane
  if not pane then
    vim.wo[D.chat_win].winbar = "%#NeoHerdrDim# neo-herdr — pick an agent (→) and press <CR>"
    return
  end
  local a = state.find_pane(pane)
  if not a then
    vim.wo[D.chat_win].winbar = "%#NeoHerdrHeader# " .. stl_esc(pane)
    return
  end
  local status = (a.status or "unknown"):lower()
  local glyph = GLYPH[status] or GLYPH.unknown
  local statushl = STATUS_HL[status] or "NeoHerdrIdle"
  local parts = { " " }
  local ws = state.workspace(a.workspace_id)
  local ws_name = ws and (ws.name or ws.id)
  if ws_name then
    table.insert(parts, "%#NeoHerdrWs#" .. stl_esc(ws_name))
    table.insert(parts, "%#NeoHerdrDim# › ")
  end
  table.insert(parts, "%#" .. statushl .. "#" .. glyph .. " ")
  table.insert(parts, "%#NeoHerdrFocused#" .. stl_esc(state.display_name(a)))
  if a.program and a.program ~= "" then
    table.insert(parts, "%#NeoHerdrProgram#  " .. stl_esc(a.program))
  end
  vim.wo[D.chat_win].winbar = table.concat(parts)
end

-- ── Notifier panel (Opera-GX-style) ─────────────────────────────────────────

-- Notifier icons: each state is drawn as a block of rows. "large" is a 3x2
-- blob (filled when on, hollow when off); "small" is the single ●/○ glyph.
local NOTIFIER_ICONS = {
  large = { on = { "▟█▙", "▜█▛" }, off = { "▗▄▖", "▝▀▘" }, w = 3 },
  small = { on = { "●" }, off = { "○" }, w = 1 },
}

local function notifier_icons()
  local size = D.config and D.config.notifier_size or "large"
  return NOTIFIER_ICONS[size] or NOTIFIER_ICONS.large
end

-- Float size: icon + a space each side + the two edges; three icons with a
-- blank row between, plus the top and bottom of the outline.
local function notifier_dims()
  local ic = notifier_icons()
  return ic.w + 4, 3 * #ic.on + 2 + 2
end

local function seg_line(segs)
  local s, hls, col = "", {}, 0
  for _, seg in ipairs(segs) do
    local t = seg[1]
    if seg[2] then
      hls[#hls + 1] = { col, col + #t, seg[2] }
    end
    s = s .. t
    col = col + #t
  end
  return s, hls
end

local function aggregate_states()
  local blocked, working, done = false, false, false
  for _, grp in ipairs(state.grouped()) do
    for _, a in ipairs(grp.agents) do
      local st = (a.status or ""):lower()
      if st == "blocked" then
        blocked = true
      elseif st == "working" then
        working = true
      elseif st == "done" then
        done = true
      end
    end
  end
  return blocked, working, done
end

local function ensure_status_buf()
  if D.status_buf and vim.api.nvim_buf_is_valid(D.status_buf) then
    return D.status_buf
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  vim.b[b].neo_herdr = true
  D.status_buf = b
  return b
end

local function status_geometry()
  if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    return nil
  end
  return {
    relative = "win",
    win = D.chat_win,
    anchor = "NE",
    row = 0,
    col = 0,
    width = select(1, notifier_dims()),
    height = select(2, notifier_dims()),
    focusable = false,
    style = "minimal",
    border = "none",
    zindex = 30,
    noautocmd = true,
  }
end

local update_status

update_status = function()
  if not (D.status_win and vim.api.nvim_win_is_valid(D.status_win)) then
    return
  end
  if not (D.status_buf and vim.api.nvim_buf_is_valid(D.status_buf)) then
    return
  end
  local blocked, working, done = aggregate_states()
  local cfg = D.config or {}

  -- Slow flash of the blocked icon: a repeating timer flips the phase and
  -- re-renders while any agent is blocked; it stops as soon as none is.
  local period = cfg.notifier_blink
  if period == nil then
    period = 800
  end
  if blocked and period and period > 0 then
    if not D.blink_timer then
      D.blink_on = true
      D.blink_timer = vim.fn.timer_start(period, function()
        D.blink_on = not D.blink_on
        update_status()
      end, { ["repeat"] = -1 })
    end
  elseif D.blink_timer then
    pcall(vim.fn.timer_stop, D.blink_timer)
    D.blink_timer, D.blink_on = nil, true
  end

  local circles = {
    { on = blocked, hl = (blocked and D.blink_timer and not D.blink_on) and "NeoHerdrBlockedDim" or "NeoHerdrBlocked" },
    { on = working, hl = "NeoHerdrWorking" },
    { on = done, hl = "NeoHerdrDone" },
  }
  local ic = notifier_icons()
  local E = "NeoHerdrNotifierEdge"
  local bar = string.rep("─", ic.w + 2)
  local gap = string.rep(" ", ic.w + 2)
  local lines, all = {}, {}
  local function push(s, hls)
    lines[#lines + 1] = s
    local r = #lines - 1
    for _, h in ipairs(hls) do
      all[#all + 1] = { r, h[1], h[2], h[3] }
    end
  end
  local function blank()
    push(seg_line({ { "│", E }, { gap }, { "│", E } }))
  end
  local function icon(c)
    local rows = c.on and ic.on or ic.off
    local hl = c.on and c.hl or "NeoHerdrNotifierOff"
    for _, row in ipairs(rows) do
      push(seg_line({ { "│", E }, { " " }, { row, hl }, { " " }, { "│", E } }))
    end
  end
  push(seg_line({ { "╭" .. bar .. "╮", E } }))
  icon(circles[1])
  blank()
  icon(circles[2])
  blank()
  icon(circles[3])
  push(seg_line({ { "╰" .. bar .. "╯", E } }))

  vim.bo[D.status_buf].modifiable = true
  vim.api.nvim_buf_set_lines(D.status_buf, 0, -1, false, lines)
  vim.bo[D.status_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(D.status_buf, STATUS_NS, 0, -1)
  for _, a in ipairs(all) do
    pcall(vim.api.nvim_buf_set_extmark, D.status_buf, STATUS_NS, a[1], a[2], { end_col = a[3], hl_group = a[4] })
  end
end

local function open_status(cfg)
  if cfg and cfg.notifier == false then
    return
  end
  if D.status_win and vim.api.nvim_win_is_valid(D.status_win) then
    return
  end
  local g = status_geometry()
  if not g then
    return
  end
  local win = vim.api.nvim_open_win(ensure_status_buf(), false, g)
  D.status_win = win
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:Normal"
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  update_status()
end

local function close_status()
  if D.status_win and vim.api.nvim_win_is_valid(D.status_win) then
    pcall(vim.api.nvim_win_close, D.status_win, true)
  end
  D.status_win = nil
  if D.blink_timer then
    pcall(vim.fn.timer_stop, D.blink_timer)
    D.blink_timer, D.blink_on = nil, true
  end
end

-- ── Nav rendering (two-line rows) ───────────────────────────────────────────

local function nav_width()
  if D.win and vim.api.nvim_win_is_valid(D.win) then
    return vim.api.nvim_win_get_width(D.win) - 2 -- sign column + right margin
  end
  return 30
end

-- Pane id under the nav cursor (any of the row's lines).
local function pane_at_cursor()
  if not (D.win and vim.api.nvim_win_is_valid(D.win)) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(D.win)[1]
  return D.line_target[line]
end

function M.render()
  if not (D.buf and vim.api.nvim_buf_is_valid(D.buf)) then
    return
  end
  local keep = pane_at_cursor()
  local lines, marks = {}, {}
  D.line_target = {}
  D.row_lines = {}

  local function add(text)
    lines[#lines + 1] = text
    return #lines - 1
  end
  local function hl(l0, c0, c1, group)
    marks[#marks + 1] = { l0, c0, { end_col = c1, hl_group = group } }
  end
  local function whole(l0, group)
    hl(l0, 0, #lines[l0 + 1], group)
  end

  local head = "HERDR"
  local conn = "  ·  " .. conn_label()
  local l0 = add(head .. conn)
  hl(l0, 0, #head, "NeoHerdrHeader")
  hl(l0, #head, #head + #conn, "NeoHerdrDim")
  add("")

  local width = nav_width()
  D.rendered_w = width

  if D.server_state == "stopped" then
    whole(add("herdr server is not running"), "NeoHerdrBlocked")
    if D.server_err then
      whole(add(truncate(tostring(D.server_err), width)), "NeoHerdrDim")
    end
    add("")
    l0 = add("S  start server")
    hl(l0, 0, 1, "NeoHerdrKey")
    hl(l0, 1, #lines[l0 + 1], "NeoHerdrDim")
  elseif D.server_state == "starting" then
    whole(add("starting herdr server…"), "NeoHerdrWorking")
  else
    local groups = state.grouped()
    if #groups == 0 then
      whole(add("(no panes)  n new chat"), "NeoHerdrDim")
    end
    for _, grp in ipairs(groups) do
      if grp.ws then
        local label = "▾ " .. truncate(grp.ws.name or grp.ws.id, width - 2)
        whole(add(label), "NeoHerdrWs")
      end
      for _, a in ipairs(grp.agents) do
        local status = (a.status or "unknown"):lower()
        if a.is_shell then
          status = "unknown"
        end
        local glyph = GLYPH[status] or GLYPH.unknown
        local name = truncate(state.display_name(a), math.max(4, width - 2))
        local l1 = add(glyph .. " " .. name)
        hl(l1, 0, #glyph, STATUS_HL[status] or "NeoHerdrIdle")
        hl(l1, #glyph + 1, #lines[l1 + 1], a.is_shell and "NeoHerdrSecondary" or "NeoHerdrName")

        -- Secondary line, most important first (truncation eats from the end):
        -- program · status/custom status · tab N (· pane id for shells).
        local parts = { state.program_label(a) }
        if a.custom_status and a.custom_status ~= "" then
          parts[#parts + 1] = a.custom_status
        elseif not a.is_shell and STATUS_WORD[status] and status ~= "idle" then
          parts[#parts + 1] = STATUS_WORD[status]
        end
        local tl = state.tab_label(a)
        if tl then
          parts[#parts + 1] = "tab " .. tl
        end
        if a.is_shell then
          parts[#parts + 1] = state.short_pane(a) or ""
        end
        local l2 = add("  " .. truncate(table.concat(parts, " · "), math.max(4, width - 2)))
        whole(l2, "NeoHerdrSecondary")
        add("")

        D.line_target[l1 + 1] = a.pane_id
        D.line_target[l2 + 1] = a.pane_id
        D.row_lines[#D.row_lines + 1] = l1 + 1
        if a.pane_id and a.pane_id == D.chat_pane then
          for _, l in ipairs({ l1, l2 }) do
            marks[#marks + 1] = { l, 0, {
              line_hl_group = "NeoHerdrCurrent",
              sign_text = "▎",
              sign_hl_group = "NeoHerdrCurrentBar",
              priority = 50,
            } }
          end
        end
      end
    end
  end

  whole(add("? help"), "NeoHerdrDim")

  vim.bo[D.buf].modifiable = true
  vim.api.nvim_buf_set_lines(D.buf, 0, -1, false, lines)
  vim.bo[D.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(D.buf, NS, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, D.buf, NS, m[1], m[2], m[3])
  end

  -- Keep the cursor on the same row across re-renders.
  if keep and D.win and vim.api.nvim_win_is_valid(D.win) then
    for l, pid in pairs(D.line_target) do
      if pid == keep and (l == D.row_lines[1] or vim.tbl_contains(D.row_lines, l)) then
        pcall(vim.api.nvim_win_set_cursor, D.win, { l, 0 })
        break
      end
    end
  end

  update_chat_header()
  update_status()
end

-- j/k move by ROW (two lines + spacer), never landing on spacers/headers.
local function move_row(delta)
  local rows = D.row_lines
  if #rows == 0 then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local idx
  for i, l in ipairs(rows) do
    if cur >= l then
      idx = i
    end
  end
  local target
  if delta > 0 then
    target = rows[math.min(#rows, (idx or 0) + 1)]
  else
    if idx and cur > rows[idx] then
      target = rows[idx] -- from a row's 2nd line / spacer: first line of that row
    else
      target = rows[math.max(1, (idx or 1) - 1)]
    end
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
end

-- ── Row actions ─────────────────────────────────────────────────────────────

local function agent_under_cursor()
  local pid = D.line_target[vim.api.nvim_win_get_cursor(0)[1]]
  return pid and state.find_pane(pid) or nil
end

local function with_agent(fn)
  return function()
    local a = agent_under_cursor()
    if not a then
      vim.notify("[neo-herdr] no pane on this line", vim.log.levels.WARN)
      return
    end
    fn(a)
  end
end

-- ── Chat window ─────────────────────────────────────────────────────────────

local function show_placeholder(win, note_lines)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].neo_herdr = true
  pcall(vim.api.nvim_buf_set_name, buf, "neo-herdr://chat")
  local lines = {
    "",
    "  neo-herdr",
    "",
    "  Pick an agent in the nav (→) and press <CR>",
    "  to open its live chat here. On a terminal",
    "  row, <CR> starts an agent in that pane.",
    "",
  }
  for _, l in ipairs(note_lines or {}) do
    lines[#lines + 1] = "  " .. l
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(win, buf)
end

-- Last few non-empty lines of a terminal buffer (why did it end?).
local function term_tail(buf, n)
  local out = {}
  local ok, ls = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok then
    return out
  end
  for i = #ls, 1, -1 do
    if ls[i]:match("%S") then
      table.insert(out, 1, ls[i])
      if #out >= n then
        break
      end
    end
  end
  return out
end

-- Remember one attached terminal per PANE so we re-display it instead of
-- spawning a second attach. When its process ends (pane closed, agent gone,
-- detached), drop it and, if it's on screen, put the placeholder back.
local function cache_chat_buf(pane_id, buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  D.chat_bufs = D.chat_bufs or {}
  D.chat_bufs[pane_id] = buf
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if D.chat_bufs and D.chat_bufs[pane_id] == buf then
          D.chat_bufs[pane_id] = nil
        end
        if D.chat_win and vim.api.nvim_win_is_valid(D.chat_win) and vim.api.nvim_win_get_buf(D.chat_win) == buf then
          local tail = term_tail(buf, 3)
          local note = { "chat " .. pane_id .. " ended." }
          if #tail > 0 then
            note[#note + 1] = "last output:"
            for _, l in ipairs(tail) do
              note[#note + 1] = "  " .. truncate(l, 200)
            end
          end
          if D.chat_pane == pane_id then
            D.chat_pane = nil
          end
          show_placeholder(D.chat_win, note)
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
          M.render()
          refresh()
        end
      end)
    end,
  })
end

local function job_alive(buf)
  local jid = vim.b[buf].terminal_job_id
  if not jid then
    return false
  end
  local ok, res = pcall(vim.fn.jobwait, { jid }, 0)
  return ok and res[1] == -1
end

-- Show a pane's live terminal in the chat window, reusing the window AND any
-- terminal we already attached for this pane.
local function open_in_chat(pane_id)
  local A = require("neo-herdr.attach")
  D.chat_pane = pane_id
  D.chat_bufs = D.chat_bufs or {}

  if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    local buf = A.attach(pane_id, "vsplit")
    D.chat_win = vim.api.nvim_get_current_win()
    cache_chat_buf(pane_id, buf)
    M.render()
    return
  end

  vim.api.nvim_set_current_win(D.chat_win)
  local existing = D.chat_bufs[pane_id]
  if existing and vim.api.nvim_buf_is_valid(existing) and job_alive(existing) then
    vim.api.nvim_win_set_buf(D.chat_win, existing)
    vim.cmd("startinsert")
  else
    D.chat_bufs[pane_id] = nil
    cache_chat_buf(pane_id, A.attach(pane_id, "here"))
  end
  M.render()
end

-- <CR> on a row: agents attach; shells offer to start an agent (attach would
-- fail with agent_not_found — herdr only attaches panes hosting an agent).
local function open_row(a)
  if a.is_shell then
    require("neo-herdr").start_chat_in_pane(a)
    return
  end
  open_in_chat(a.pane_id)
end

--- Open a pane's chat by id (used after `agent start` succeeds — the snapshot
--- may still call it a shell for a moment, so this skips the shell check).
function M.open_pane(pane_id)
  if not M.is_open() then
    return
  end
  open_in_chat(pane_id)
end

-- ── Nav buffer + actions ─────────────────────────────────────────────────────

-- Single source of truth for the nav's row actions: used to BOTH bind the keys
-- and render the help bar, so the two can never drift apart.
local function action_list()
  local nh = function()
    return require("neo-herdr")
  end
  return {
    { key = "<CR>", desc = "open / start", fn = with_agent(open_row) },
    { key = "n", desc = "new chat", fn = function()
      nh().new_chat(agent_under_cursor())
    end },
    { key = "w", desc = "new workspace", fn = function()
      nh().new_workspace()
    end },
    { key = "x", desc = "close", fn = with_agent(function(a)
      nh().close_chat(a)
    end) },
    { key = "c", desc = "rename", fn = with_agent(function(a)
      nh().rename_chat(a)
    end) },
    { key = "p", desc = "prompt", fn = with_agent(function(a)
      nh().prompt_agent(a.pane_id)
    end) },
    { key = "r", desc = "read", fn = with_agent(function(a)
      nh().read_target(a.pane_id)
    end) },
    { key = "a", desc = "send keys", fn = with_agent(function(a)
      nh().send_keys_target(a.pane_id)
    end) },
    { key = "R", desc = "refresh", fn = function()
      refresh()
    end },
    { key = "S", desc = "start server", fn = function()
      M.start_server()
    end },
    { key = "?", desc = "help", fn = function()
      M.toggle_help()
    end },
    { key = "q", desc = "close herd", fn = function()
      M.close()
    end },
  }
end

local function ensure_nav_buf()
  if D.buf and vim.api.nvim_buf_is_valid(D.buf) then
    return D.buf
  end
  local b = vim.api.nvim_create_buf(false, true)
  D.buf = b
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  vim.bo[b].filetype = "neoherdr"
  vim.b[b].neo_herdr = true
  pcall(vim.api.nvim_buf_set_name, b, "neo-herdr://dashboard")
  require("neo-herdr.attach").setup_mouse_copy(b)
  for _, ac in ipairs(action_list()) do
    vim.keymap.set("n", ac.key, ac.fn, { buffer = b, nowait = true, silent = true })
  end
  for _, k in ipairs({ "j", "<Down>" }) do
    vim.keymap.set("n", k, function()
      move_row(1)
    end, { buffer = b, nowait = true, silent = true })
  end
  for _, k in ipairs({ "k", "<Up>" }) do
    vim.keymap.set("n", k, function()
      move_row(-1)
    end, { buffer = b, nowait = true, silent = true })
  end
  return b
end

local function nav_win_opts(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].winfixwidth = true
  vim.wo[win].foldcolumn = "0"
end

-- ── Help bar (context-aware, spans chat + nav) ──────────────────────────────

local function ensure_help_buf()
  if D.help_buf and vim.api.nvim_buf_is_valid(D.help_buf) then
    return D.help_buf
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  vim.b[b].neo_herdr = true
  pcall(vim.api.nvim_buf_set_name, b, "neo-herdr://help")
  D.help_buf = b
  return b
end

local function help_win_opts(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixheight = true
  vim.wo[win].foldcolumn = "0"
end

-- Keys shown per focused window / mode. Bindings for nav come from the same
-- action_list that binds them; the others describe maps set elsewhere.
local function contexts()
  local nh = require("neo-herdr")
  local km = nh.config.keymaps
  local p = (km and km.prefix) or nil
  local A = require("neo-herdr.attach").config()
  local navp = (A.nav and A.nav.prefix) or "<C-w>"
  local function pk(suffix)
    return p and suffix and (p .. suffix) or nil
  end
  local function editor_keys()
    if not km then
      return {}
    end
    local out = {}
    local function add(key, desc)
      if key then
        out[#out + 1] = { key = key, desc = desc }
      end
    end
    add(pk(km.add), "add comment")
    add(pk(km.send), "send comments")
    add(pk(km.list), "list")
    add(pk(km.clear), "clear")
    add(pk(km.insert), "→ chat")
    add(pk(km.dashboard), "close herd")
    return out
  end
  local chat_insert = {
    { key = A.switch_key or ":", desc = "→ nvim (on empty prompt)" },
    { key = navp .. "h/j/k/l", desc = "windows" },
    { key = "ctrl+b q", desc = "detach (herdr)" },
    { key = "<C-\\><C-n>", desc = "normal mode" },
  }
  local chat_normal = {
    { key = "i", desc = "type" },
    { key = "<C-w>h/l", desc = "windows" },
  }
  if km then
    chat_normal[#chat_normal + 1] = { key = pk(km.send), desc = "send comments" }
    chat_normal[#chat_normal + 1] = { key = pk(km.dashboard), desc = "close herd" }
  end
  return {
    nav = { label = "NAV", keys = action_list() },
    chat_insert = { label = "CHAT · typing", keys = chat_insert },
    chat_normal = { label = "CHAT", keys = chat_normal },
    editor = { label = "EDITOR", keys = editor_keys() },
  }
end

local function current_context()
  local w = vim.api.nvim_get_current_win()
  if w == D.win or w == D.help_win then
    return "nav"
  end
  if w == D.chat_win then
    local m = vim.api.nvim_get_mode().mode
    return m:sub(1, 1) == "t" and "chat_insert" or "chat_normal"
  end
  return "editor"
end

-- Render the active context's keys into the help buffer as a wrapped row of
-- cells. Returns the number of lines used (for sizing).
local function render_help()
  if not (D.help_buf and vim.api.nvim_buf_is_valid(D.help_buf)) then
    return 0
  end
  local width = (D.help_win and vim.api.nvim_win_is_valid(D.help_win)) and vim.api.nvim_win_get_width(D.help_win)
    or 60
  local ctx = contexts()[current_context()] or contexts().nav
  local lines, hls = {}, {}
  local label = " " .. ctx.label .. " "
  local line, col = label .. " ", vim.fn.strdisplaywidth(label) + 1
  local labelbytes = #label
  local function flush()
    lines[#lines + 1] = line
    line, col = string.rep(" ", vim.fn.strdisplaywidth(label) + 1), vim.fn.strdisplaywidth(label) + 1
  end
  hls[#hls + 1] = { 0, 0, labelbytes, "NeoHerdrContext" }
  local first = true
  for _, ac in ipairs(ctx.keys) do
    if ac.key then
      local cell = ac.key .. " " .. ac.desc
      local cw = vim.fn.strdisplaywidth(cell)
      if not first and (col + cw) > (width - 1) then
        flush()
      end
      first = false
      local l0 = #lines
      local bytecol = #line
      hls[#hls + 1] = { l0, bytecol, bytecol + #ac.key, "NeoHerdrKey" }
      hls[#hls + 1] = { l0, bytecol + #ac.key, bytecol + #cell, "NeoHerdrDim" }
      line = line .. cell .. "   "
      col = col + cw + 3
    end
  end
  flush()

  vim.bo[D.help_buf].modifiable = true
  vim.api.nvim_buf_set_lines(D.help_buf, 0, -1, false, lines)
  vim.bo[D.help_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(D.help_buf, HELP_NS, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, D.help_buf, HELP_NS, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  if D.help_win and vim.api.nvim_win_is_valid(D.help_win) then
    pcall(vim.api.nvim_win_set_height, D.help_win, math.max(1, math.min(#lines, 4)))
  end
  return #lines
end

local function in_herd_tab()
  return D.tab and vim.api.nvim_get_current_tabpage() == D.tab
end

-- ── Window management (dedicated tabpage) ────────────────────────────────────

-- Draw only the *interior* herd dividers dotted so the herd windows read as one
-- grouped area while the boundary to the editor stays a normal solid line. A
-- vertical separator is owned by the window on its LEFT: the chat owns
-- chat│nav; the help bar owns nothing vertical.
local function style_separators(cfg)
  local sc = (cfg and cfg.separators) or {}
  if sc.dotted == false then
    return
  end
  if D.chat_win and vim.api.nvim_win_is_valid(D.chat_win) then
    pcall(function()
      vim.wo[D.chat_win].fillchars = "vert:" .. (sc.vert or "┊")
    end)
  end
end

-- Resolve a size that may be a fraction of `base` (v <= 1) or absolute cols.
local function resolve_w(v, base, default)
  v = v or default
  if v <= 1 then
    return math.floor(base * v + 0.5)
  end
  return math.floor(v)
end

-- Floors for the two herd windows. A nav row is "<glyph> <name>" behind a
-- one-column sign column plus a one-column margin, so nav_min - 4 characters of
-- a title stay visible: the default 16 shows the first ~10. chat_min keeps the
-- terminal readable.
local function herd_mins(cfg)
  return math.max(8, math.floor(cfg.nav_min or 16)), math.max(8, math.floor(cfg.chat_min or 40))
end

-- Current widths of the nav and chat windows (nil while the tab is not built).
local function herd_widths()
  if not (D.win and vim.api.nvim_win_is_valid(D.win) and D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    return nil
  end
  return vim.api.nvim_win_get_width(D.win), vim.api.nvim_win_get_width(D.chat_win)
end

local function herd_sizes(cfg)
  local has_editor = cfg.editor ~= false
  local total = vim.o.columns
  local nav_min, chat_min = herd_mins(cfg)
  local herd_w = has_editor and resolve_w(cfg.herd_width, total, 0.34) or total
  -- herd_w counts the nav|chat separator. The herd never resolves below its
  -- floors; on a narrow terminal the editor is what gives way (see fit()).
  herd_w = math.min(total, math.max(herd_w, nav_min + chat_min + 1))
  local nav_w = resolve_w(cfg.nav_width, herd_w, 0.40)
  nav_w = math.min(nav_w, herd_w - chat_min - 1) -- leave room for chat ...
  nav_w = math.max(nav_w, nav_min) -- ... but nav's floor wins when both can't fit
  return has_editor, herd_w, nav_w, math.max(1, herd_w - nav_w - 1)
end

-- Lay the herd out as nav_w + chat_w columns. Size outside-in: fix the editor
-- first so the herd column ends up exactly herd_w wide, then carve nav out of
-- that column. Explicit resizes ignore 'winfixwidth', so this works even
-- though both herd windows pin their width against everything else. Neovim
-- clamps what it cannot honour: when the terminal is narrower than the floors
-- the editor shrinks to 'winminwidth' and the herd takes the rest, the same
-- policy as an nvim-tree/neo-tree sidebar (nothing is hidden).
local function fit(nav_w, chat_w)
  local herd_w = nav_w + chat_w + 1
  if D.main_win and vim.api.nvim_win_is_valid(D.main_win) then
    pcall(vim.api.nvim_win_set_width, D.main_win, math.max(1, vim.o.columns - herd_w - 1))
  end
  if D.win and vim.api.nvim_win_is_valid(D.win) then
    pcall(vim.api.nvim_win_set_width, D.win, nav_w)
  end
  -- Remember what we produced (as Neovim actually applied it) so the
  -- WinResized this triggers is recognised as ours and not re-enforced.
  D.fitted = { herd_widths() }
  D.fit_columns = vim.o.columns
end

-- Resolve the configured sizes against the current terminal and apply them
-- (initial layout and VimResized, like nvim-tree's view.resize()).
local function apply_sizes(cfg)
  local _, _, nav_w, chat_w = herd_sizes(cfg)
  fit(nav_w, chat_w)
end

-- Snap the herd windows back above their floors after any resize (separator
-- drag, :resize, a split elsewhere). Sizes above the floors are the user's
-- and are left alone. Neovim satisfies an explicit resize from the nearest
-- sibling first ('winfixwidth' does not apply to explicit resizes), so the
-- widths alone cannot say what the user did; two hints can. A mouse drag
-- ends with the pointer exactly on the separator's new column (a keyboard
-- resize leaves it stale elsewhere), and a keyboard resize acts on the
-- current window.
local function enforce_mins()
  local nav_w, chat_w = herd_widths()
  if not nav_w then
    return
  end
  local last = D.fitted
  if last and last[1] == nav_w and last[2] == chat_w then
    return -- unchanged since we last laid it out
  end
  local nav_min, chat_min = herd_mins(D.config or {})
  if nav_w >= nav_min and chat_w >= chat_min then
    D.fitted = { nav_w, chat_w }
    return
  end

  local mouse_col = vim.fn.getmousepos().screencol
  local nav_col, chat_col = vim.fn.win_screenpos(D.win)[2], vim.fn.win_screenpos(D.chat_win)[2]
  local on_inner = mouse_col == nav_col - 1 -- nav|chat separator (nav is always right of chat)
  local on_outer = false
  if D.main_win and vim.api.nvim_win_is_valid(D.main_win) then
    local main_col = vim.fn.win_screenpos(D.main_win)[2]
    on_outer = mouse_col == (main_col < chat_col and chat_col - 1 or main_col - 1)
  end
  local cur = vim.api.nvim_get_current_win()
  local herd_cur = cur == D.win or cur == D.chat_win
  local same_total = last and nav_w + chat_w == last[1] + last[2]

  if on_inner or (not on_outer and not herd_cur and same_total) then
    -- The nav|chat separator moved: clamp it inside the herd column as it
    -- last legally was, never growing the column into the editor.
    local herd_w = last and (last[1] + last[2] + 1) or (nav_w + chat_w + 1)
    nav_w = math.max(nav_min, math.min(nav_w, herd_w - chat_min - 1))
    chat_w = math.max(chat_min, herd_w - nav_w - 1)
  elseif herd_cur and not on_outer then
    -- A :resize on a herd window: keep what it asked for, floor its sibling,
    -- and the editor absorbs the difference. If the request itself is below
    -- the floor, stop at the floor and hand the excess back to the sibling so
    -- the herd column does not move.
    local t_w, t_min, o_w, o_min = nav_w, nav_min, chat_w, chat_min
    if cur == D.chat_win then
      t_w, t_min, o_w, o_min = chat_w, chat_min, nav_w, nav_min
    end
    if t_w < t_min then
      o_w, t_w = o_w - (t_min - t_w), t_min
    end
    o_w = math.max(o_w, o_min)
    nav_w, chat_w = t_w, o_w
    if cur == D.chat_win then
      nav_w, chat_w = o_w, t_w
    end
  else
    -- The herd column was squeezed from the editor side: hold the floors and
    -- the editor gets what is left. Nav is not adjacent to that separator,
    -- so it goes back to what it was rather than keeping whatever Neovim's
    -- distribution spilled onto it.
    nav_w = math.max(last and last[1] or nav_w, nav_min)
    chat_w = math.max(chat_w, chat_min)
  end
  fit(nav_w, chat_w)
end

-- Build nav + help bar around the chat window. Precondition: the current
-- window is D.chat_win and it is the ONLY window in the herd frame (nav and
-- bar closed). Splitting the chat horizontally FIRST puts the bar inside the
-- herd column, then the vertical split puts nav beside chat above the bar:
--   ROW[ editor, COL[ ROW[ chat, nav ], bar ] ]
-- which is what makes the bar span chat + nav but not the editor.
local function place_herd(cfg, with_bar)
  vim.api.nvim_set_current_win(D.chat_win)
  if with_bar then
    vim.cmd("belowright split")
    D.help_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(D.help_win, ensure_help_buf())
    help_win_opts(D.help_win)
    vim.api.nvim_set_current_win(D.chat_win)
  end
  vim.cmd("rightbelow vsplit")
  D.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(D.win, ensure_nav_buf())
  nav_win_opts(D.win)
  -- Both herd windows keep their width against 'equalalways', <C-w>= and
  -- window closes, so the herd behaves as one fixed-width sidebar.
  vim.wo[D.chat_win].winfixwidth = true

  apply_sizes(cfg)
  if with_bar then
    render_help()
  end
  style_separators(cfg)
end

-- Release everything the herd tab owns: attach terminals (deleting the buffer
-- closes the pty, the one thing `herdr agent attach` reacts to; Neovim SIGKILLs
-- after 2s), the notifier float, autocmds, and the nav buffer.
local function teardown()
  for _, b in pairs(D.chat_bufs or {}) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  D.chat_bufs = {}
  close_status()
  pcall(vim.api.nvim_del_augroup_by_name, AUG)
  if D.buf and vim.api.nvim_buf_is_valid(D.buf) then
    pcall(vim.api.nvim_buf_delete, D.buf, { force = true })
  end
  D.tab, D.win, D.buf, D.chat_win, D.main_win, D.chat_pane = nil, nil, nil, nil, nil, nil
  D.help_win, D.fitted, D.fit_columns, D.rendered_w = nil, nil, nil, nil
end

local function install_autocmds()
  pcall(vim.api.nvim_del_augroup_by_name, AUG)
  local g = vim.api.nvim_create_augroup(AUG, { clear = true })
  local function refresh_help()
    if in_herd_tab() and D.help_win and vim.api.nvim_win_is_valid(D.help_win) then
      render_help()
    end
  end
  vim.api.nvim_create_autocmd({ "WinEnter", "TermEnter", "TermLeave" }, {
    group = g,
    callback = refresh_help,
  })
  -- Terminal resized: re-resolve the configured widths (fractions included).
  vim.api.nvim_create_autocmd("VimResized", {
    group = g,
    callback = function()
      if in_herd_tab() then
        apply_sizes(D.config or {})
        refresh_help()
      end
    end,
  })
  -- Any window resized in the herd tab: hold the floors, and re-render the
  -- nav when its width changed so titles truncate to the new width.
  vim.api.nvim_create_autocmd("WinResized", {
    group = g,
    callback = function()
      if not in_herd_tab() then
        return
      end
      enforce_mins()
      if D.win and vim.api.nvim_win_is_valid(D.win) and nav_width() ~= D.rendered_w then
        M.render()
      end
      refresh_help()
    end,
  })
  -- Coming back to the herd tab after the terminal changed size while another
  -- tab was current: Neovim scaled the layout, we re-resolve it.
  vim.api.nvim_create_autocmd("TabEnter", {
    group = g,
    callback = function()
      if in_herd_tab() and D.fit_columns and D.fit_columns ~= vim.o.columns then
        apply_sizes(D.config or {})
        refresh_help()
      end
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = g,
    pattern = { "*:t*", "t*:*", "*:n*" },
    callback = function()
      if in_herd_tab() and D.help_win and vim.api.nvim_win_is_valid(D.help_win) then
        render_help()
      end
    end,
  })
end

local function build_tab(cfg)
  D.chat_pane = nil
  D.chat_bufs = {}
  vim.cmd("tabnew")
  D.tab = vim.api.nvim_get_current_tabpage()
  pcall(vim.api.nvim_tabpage_set_var, D.tab, "neo_herdr", true)

  local has_editor = cfg.editor ~= false
  local side = cfg.side or "right"
  local first = vim.api.nvim_get_current_win()
  if not has_editor then
    D.main_win = nil
    D.chat_win = first
  elseif side == "left" then
    D.main_win = first
    vim.cmd("leftabove vsplit")
    D.chat_win = vim.api.nvim_get_current_win()
  else
    D.main_win = first
    vim.cmd("rightbelow vsplit")
    D.chat_win = vim.api.nvim_get_current_win()
  end

  -- The editor pane's starting buffer is a listed [No Name] (from :tabnew);
  -- unlist it so it isn't a stray entry in bufferline/:ls.
  if has_editor and D.main_win and vim.api.nvim_win_is_valid(D.main_win) then
    pcall(function()
      vim.bo[vim.api.nvim_win_get_buf(D.main_win)].buflisted = false
    end)
  end

  show_placeholder(D.chat_win)
  place_herd(cfg, cfg.help ~= false)
  open_status(cfg)
  install_autocmds()

  if not D.tabclosed_autocmd then
    D.tabclosed_autocmd = vim.api.nvim_create_autocmd("TabClosed", {
      callback = function()
        if D.tab and not vim.api.nvim_tabpage_is_valid(D.tab) then
          -- Tab closed out from under us (e.g. :tabclose) — M.close() clears
          -- D.tab first, so this only runs for external closes.
          teardown()
          vim.schedule(function()
            server.maybe_stop()
          end)
        end
      end,
    })
  end
end

-- ── Hiding the herd tab from the tabline ─────────────────────────────────────

function _G.neo_herdr_tabline()
  local cur = vim.api.nvim_get_current_tabpage()
  local out = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local ok, hidden = pcall(vim.api.nvim_tabpage_get_var, tab, "neo_herdr")
    if not (ok and hidden) then
      local nr = vim.api.nvim_tabpage_get_number(tab)
      local win = vim.api.nvim_tabpage_get_win(tab)
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      name = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
      local mod = vim.bo[buf].modified and " ●" or ""
      out[#out + 1] = (tab == cur and "%#TabLineSel#" or "%#TabLine#")
        .. "%"
        .. nr
        .. "T"
        .. " "
        .. nr
        .. " "
        .. name
        .. mod
        .. " "
    end
  end
  out[#out + 1] = "%#TabLineFill#%T"
  return table.concat(out)
end

local function ensure_tab_hidden(cfg)
  if not cfg or cfg.hide_tab == false then
    return
  end
  local tl = vim.o.tabline
  if tl == "" or tl:find("neo_herdr_tabline", 1, true) then
    vim.o.tabline = "%!v:lua.neo_herdr_tabline()"
  end
end

-- ── Public surface ───────────────────────────────────────────────────────────

function M.is_open()
  return D.tab ~= nil and vim.api.nvim_tabpage_is_valid(D.tab)
end

function M.open(cfg)
  D.config = cfg or D.config or {}
  define_highlights()
  if not D.hl_autocmd then
    D.hl_autocmd = vim.api.nvim_create_autocmd("ColorScheme", {
      callback = function()
        define_highlights()
        if D.buf and vim.api.nvim_buf_is_valid(D.buf) then
          M.render()
        end
      end,
    })
  end
  if M.is_open() then
    vim.api.nvim_set_current_tabpage(D.tab)
    if D.win and vim.api.nvim_win_is_valid(D.win) then
      vim.api.nvim_set_current_win(D.win)
    end
    return
  end
  build_tab(D.config)
  ensure_tab_hidden(D.config)
  start_controller(D.config)
  connect_server()
  M.render()
  if D.win and vim.api.nvim_win_is_valid(D.win) then
    vim.api.nvim_set_current_win(D.win) -- leave cursor in the nav
    pcall(vim.api.nvim_win_set_cursor, D.win, { D.row_lines[1] or 1, 0 })
  end
end

function M.close()
  local tab, wins = D.tab, { D.help_win, D.win, D.chat_win }
  teardown() -- clears D.tab first so the TabClosed handler stays out of it
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    local n = vim.api.nvim_tabpage_get_number(tab)
    local ok = pcall(vim.cmd, n .. "tabclose")
    if not ok then
      -- Last tabpage: close the herd windows individually instead.
      for _, w in ipairs(wins) do
        if w and vim.api.nvim_win_is_valid(w) then
          pcall(vim.api.nvim_win_close, w, true)
        end
      end
    end
  end
  server.maybe_stop()
end

function M.toggle(cfg)
  if M.is_open() then
    M.close()
  else
    M.open(cfg)
  end
end

--- Pane id of the chat currently shown, or nil. Valid as a herdr target.
function M.chat_target()
  return D.chat_pane
end

--- "unknown" | "starting" | "running" | "stopped"
function M.server_state()
  return D.server_state
end

--- Jump to the herd chat window and, if it holds a live terminal, start typing.
--- Returns "typing" | "placeholder" | "closed".
function M.focus_chat()
  if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    return "closed"
  end
  if M.is_open() then
    vim.api.nvim_set_current_tabpage(D.tab)
  end
  vim.api.nvim_set_current_win(D.chat_win)
  if vim.bo[vim.api.nvim_win_get_buf(D.chat_win)].buftype == "terminal" then
    vim.cmd("startinsert")
    return "typing"
  end
  return "placeholder"
end

--- Toggle the keybinding bar. Because the bar must sit INSIDE the herd column
--- (so it spans chat + nav), re-showing it rebuilds nav + bar around the chat.
function M.toggle_help(force)
  local visible = D.help_win ~= nil and vim.api.nvim_win_is_valid(D.help_win)
  local want = force
  if want == nil then
    want = not visible
  end
  if want == visible then
    return
  end
  if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  local cur_is_nav = cur == D.win
  if visible then
    pcall(vim.api.nvim_win_close, D.help_win, true)
    D.help_win = nil
  end
  if D.win and vim.api.nvim_win_is_valid(D.win) then
    pcall(vim.api.nvim_win_close, D.win, true) -- nav buffer survives (bufhidden=hide)
  end
  D.win = nil
  place_herd(D.config or {}, want)
  if cur_is_nav then
    vim.api.nvim_set_current_win(D.win)
  elseif vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
  M.render()
end

--- Called on VimLeavePre: release socket + timer, then apply the server
--- policy synchronously (async callbacks never run during exit).
function M.shutdown()
  if D.poll_timer then
    pcall(vim.fn.timer_stop, D.poll_timer)
    D.poll_timer = nil
  end
  pcall(socket.close_subscription)
  pcall(server.maybe_stop_sync)
end

return M
