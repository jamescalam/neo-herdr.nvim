-- neo-herdr: the live sidebar. Renders herdr workspaces/agents with state
-- glyphs and per-row actions. Data comes from the socket (snapshot + pushed
-- status events) with a CLI poll as a correctness backstop.

local socket = require("neo-herdr.socket")
local state = require("neo-herdr.state")

local M = {}

local NS = vim.api.nvim_create_namespace("neo_herdr_dashboard")
local HELP_NS = vim.api.nvim_create_namespace("neo_herdr_help")

local D = {
  win = nil,
  buf = nil,
  line_target = {}, -- 1-indexed line -> agent target string
  poll_timer = nil,
  started = false, -- controller (socket/poll) wired up
  subscribed = false,
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

-- Explicit, status-driven glyph colors (like herdr's own UI). Set as defaults so
-- a colorscheme or user `:highlight NeoHerdr* …` still wins, but they render the
-- right color even when the theme leaves Diagnostic* groups undefined.
local STATUS_COLORS = {
  NeoHerdrWorking = { fg = "#e5c07b", ctermfg = 179 }, -- amber — actively working
  NeoHerdrIdle = { fg = "#828997", ctermfg = 245 }, -- grey — idle / waiting
  NeoHerdrBlocked = { fg = "#e06c75", ctermfg = 204 }, -- red — blocked, needs input
  NeoHerdrDone = { fg = "#98c379", ctermfg = 114 }, -- green — done ✓
  NeoHerdrUnknown = { fg = "#5c6370", ctermfg = 240 }, -- dim — no agent (shell)
}

local function define_highlights()
  local function link(name, target)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
  end
  -- Set unconditionally (no `default`): an earlier version may have linked these
  -- groups to Diagnostic* — and a reload doesn't clear that — so a default set
  -- would be a silent no-op and the glyphs would stay uncolored. To recolor,
  -- override in a ColorScheme autocmd (ours re-applies on ColorScheme too).
  for name, c in pairs(STATUS_COLORS) do
    vim.api.nvim_set_hl(0, name, { fg = c.fg, ctermfg = c.ctermfg })
  end
  link("NeoHerdrHeader", "Title")
  link("NeoHerdrFocused", "Title")
  link("NeoHerdrWs", "Directory")
  link("NeoHerdrProgram", "Comment")
  link("NeoHerdrDim", "NonText")
end

-- ── Controller: keep `state` fresh from socket + poll ──────────────────────
--
-- herdr's socket is one-request-per-connection, so snapshots use request_once
-- (fresh connection each). Live status flips ride a separate persistent
-- subscription. A poll timer is the correctness backstop and also picks up
-- newly-created panes (re-subscribing when the pane set changes).

local function on_event(name, data)
  if name == "pane.agent_status_changed" then
    state.apply_status_event(data)
  elseif name == "pane.exited" then
    state.remove_pane(data)
  end
end

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
  if #ids == 0 then
    socket.close_subscription()
    return
  end
  local subs = {}
  for _, pid in ipairs(ids) do
    table.insert(subs, { type = "pane.agent_status_changed", pane_id = pid })
    table.insert(subs, { type = "pane.exited", pane_id = pid })
  end
  socket.subscribe({
    subscriptions = subs,
    on_event = on_event,
    on_status = function()
      if D.buf and vim.api.nvim_buf_is_valid(D.buf) then
        M.render() -- refresh the header live/… indicator
      end
    end,
    path = cfg.socket_path,
  })
end

-- Panes (not just agents) are the canonical rows: herdr keeps a pane alive as a
-- shell after its agent exits, and we want those to stay visible (as "terminal")
-- so they don't vanish and can be closed/reused.
local function cli_snapshot()
  local H = require("neo-herdr.herdr")
  H.panes(function(panes, err)
    if err or not panes then
      return
    end
    H.workspaces(function(ws)
      D.mode = "cli-poll"
      state.set_snapshot(panes, ws or nil)
    end)
  end)
end

local function refresh()
  local cfg = D.config or {}
  if cfg.use_socket == false then
    cli_snapshot()
    return
  end
  socket.request_once("pane.list", vim.empty_dict(), function(ares, aerr)
    if aerr or not ares or not ares.panes then
      cli_snapshot() -- socket unavailable; fall back
      return
    end
    socket.request_once("workspace.list", nil, function(wres)
      D.mode = "socket"
      state.set_snapshot(ares.panes, wres and wres.workspaces or nil)
      ensure_subscription(cfg)
    end, cfg.socket_path)
  end, cfg.socket_path)
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
  refresh()
  if cfg.auto_refresh ~= false then
    D.poll_timer = vim.fn.timer_start(cfg.poll_interval or 4000, function()
      if D.buf and vim.api.nvim_buf_is_valid(D.buf) then
        refresh()
      end
    end, { ["repeat"] = -1 })
  end
end

-- ── Rendering ──────────────────────────────────────────────────────────────

local function conn_label()
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

-- Keep the chat window's winbar in sync with the agent it's showing. The colors
-- deliberately reuse the dashboard's groups (NeoHerdrWs / status glyph /
-- NeoHerdrFocused) so the header reads as the same row you selected on the right.
-- Forward-declared so M.render (defined below) can call it as an upvalue.
local update_chat_header

update_chat_header = function()
  if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    return
  end
  if D.config and D.config.chat_header == false then
    return
  end
  local target = D.chat_target
  if not target then
    vim.wo[D.chat_win].winbar = "%#NeoHerdrDim# neo-herdr — pick an agent (→) and press <CR>"
    return
  end
  local a = state.find_target(target)
  if not a then
    vim.wo[D.chat_win].winbar = "%#NeoHerdrHeader# " .. stl_esc(target)
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

function M.render()
  if not (D.buf and vim.api.nvim_buf_is_valid(D.buf)) then
    return
  end
  local lines = {}
  local hls = {} -- { line0, col_start, col_end, group }
  D.line_target = {}

  local function add(text, groups)
    table.insert(lines, text)
    local l0 = #lines - 1
    for _, g in ipairs(groups or {}) do
      table.insert(hls, { l0, g[1], g[2], g[3] })
    end
    return l0
  end

  add("  HERDR  ·  " .. conn_label(), { { 2, 7, "NeoHerdrHeader" }, { 9, 999, "NeoHerdrDim" } })
  add("", {})

  -- Size row text to the nav column's actual width (it's proportional now).
  local width = (D.win and vim.api.nvim_win_is_valid(D.win)) and vim.api.nvim_win_get_width(D.win) or 40

  local groups = state.grouped()
  if #groups == 0 then
    add("  (no panes)", { { 0, 999, "NeoHerdrDim" } })
  end

  for _, grp in ipairs(groups) do
    if grp.ws then
      local label = "▾ " .. (grp.ws.name or grp.ws.id)
      local branch = grp.ws.branch and ("  (" .. grp.ws.branch .. ")") or ""
      add(label .. branch, {
        { 0, #label, "NeoHerdrWs" },
        { #label, #label + #branch, "NeoHerdrDim" },
      })
    end
    for _, a in ipairs(grp.agents) do
      local status = (a.status or "unknown"):lower()
      local glyph = GLYPH[status] or GLYPH.unknown
      local mark = a.focused and "▸" or " "
      local prog = state.program_label(a)
      -- content = " ▸● " (4) + title + " " + program
      local budget = (width - 1) - 4 - (prog ~= "" and (#prog + 1) or 0)
      local title = truncate(state.display_name(a), math.max(6, budget))
      local left = " " .. mark .. glyph .. " " .. title
      local pad_n = math.max(1, (width - 1) - vim.fn.strdisplaywidth(left) - #prog)
      local full = left .. string.rep(" ", pad_n) .. prog
      -- Byte offsets into `left`: " "(1) + mark + glyph + " "(1) + title. The
      -- glyph highlight MUST start on the glyph's first byte or Neovim won't
      -- color the multibyte cell (it renders white).
      local glyph_col = 1 + #mark
      local title_col = glyph_col + #glyph + 1 -- past the glyph and its trailing space
      local l0 = add(full, {
        { glyph_col, glyph_col + #glyph, STATUS_HL[status] or "NeoHerdrIdle" },
        { #left + pad_n, 999, "NeoHerdrProgram" },
      })
      if a.focused then
        table.insert(hls, { l0, title_col, #left, "NeoHerdrFocused" })
      end
      D.line_target[l0 + 1] = state.target_of(a)
    end
  end

  add("", {})
  add("  ? help", { { 0, 999, "NeoHerdrDim" } })

  vim.bo[D.buf].modifiable = true
  vim.api.nvim_buf_set_lines(D.buf, 0, -1, false, lines)
  vim.bo[D.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(D.buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_add_highlight, D.buf, NS, h[4], h[1], h[2], h[3])
  end

  update_chat_header()
end

-- ── Row actions ─────────────────────────────────────────────────────────────

local function target_under_cursor()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return D.line_target[line]
end

local function with_target(fn)
  return function()
    local t = target_under_cursor()
    if not t then
      vim.notify("[neo-herdr] no agent on this line", vim.log.levels.WARN)
      return
    end
    fn(t)
  end
end

-- The full agent object under the cursor (for actions needing pane_id etc.).
local function agent_under_cursor()
  local t = target_under_cursor()
  return t and state.find_target(t) or nil
end

local function with_agent(fn)
  return function()
    local a = agent_under_cursor()
    if not a then
      vim.notify("[neo-herdr] no agent on this line", vim.log.levels.WARN)
      return
    end
    fn(a)
  end
end

-- Remember one attached terminal buffer per target so we can re-display it
-- instead of spawning a second `herdr agent attach` (herdr only allows one
-- attached client per pane — a second attach fails with "already has an
-- attached client"). Drop the entry when its process exits so a later open
-- re-attaches cleanly.
local function cache_chat_buf(target, buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  D.chat_bufs = D.chat_bufs or {}
  D.chat_bufs[target] = buf
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      if D.chat_bufs and D.chat_bufs[target] == buf then
        D.chat_bufs[target] = nil
      end
    end,
  })
end

-- Open an agent's live terminal in the herd tab's chat window, reusing the
-- window AND any terminal we already attached for this target.
local function open_in_chat(target)
  local A = require("neo-herdr.attach")
  D.chat_target = target
  D.chat_bufs = D.chat_bufs or {}

  if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    local buf = A.attach(target, "vsplit")
    D.chat_win = vim.api.nvim_get_current_win()
    cache_chat_buf(target, buf)
    update_chat_header()
    return
  end

  vim.api.nvim_set_current_win(D.chat_win)
  local existing = D.chat_bufs[target]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    -- Already attached earlier this session → just show it again. No re-attach.
    vim.api.nvim_win_set_buf(D.chat_win, existing)
    if vim.bo[existing].buftype == "terminal" then
      vim.cmd("startinsert")
    end
  else
    cache_chat_buf(target, A.attach(target, "here"))
  end
  update_chat_header()
end

-- ── Window management (dedicated tabpage) ────────────────────────────────────

local function setup_chat_placeholder(win)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].neo_herdr = true
  pcall(vim.api.nvim_buf_set_name, buf, "neo-herdr://chat")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "",
    "  neo-herdr",
    "",
    "  Pick an agent in the dashboard (→) and press <CR>",
    "  to open its live chat here.",
    "",
  })
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(win, buf)
  D.chat_buf = buf
end

-- Single source of truth for the nav's row actions: used to BOTH bind the keys
-- and render the help pane, so the two can never drift apart.
local function action_list()
  local nh = function()
    return require("neo-herdr")
  end
  return {
    { key = "<CR>", desc = "open chat", fn = with_target(function(t)
      open_in_chat(t)
    end) },
    { key = "n", desc = "new chat", fn = function()
      nh().new_chat(agent_under_cursor())
    end },
    { key = "x", desc = "close chat", fn = with_agent(function(a)
      nh().close_chat(a)
    end) },
    { key = "c", desc = "rename", fn = with_agent(function(a)
      nh().rename_chat(a)
    end) },
    { key = "p", desc = "prompt", fn = with_target(function(t)
      nh().prompt_agent(t)
    end) },
    { key = "r", desc = "read", fn = with_target(function(t)
      nh().read_target(t)
    end) },
    { key = "a", desc = "send keys", fn = with_target(function(t)
      nh().send_keys_target(t)
    end) },
    { key = "R", desc = "refresh", fn = function()
      refresh()
    end },
    { key = "?", desc = "toggle help", fn = function()
      M.toggle_help()
    end },
    { key = "q", desc = "close herd", fn = function()
      M.close()
    end },
  }
end

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

-- Render the action list into the help buffer as a compact grid that reflows to
-- the help window's width. Returns the number of rows used (for sizing).
local function render_help()
  if not (D.help_buf and vim.api.nvim_buf_is_valid(D.help_buf)) then
    return 0
  end
  local width = (D.help_win and vim.api.nvim_win_is_valid(D.help_win))
      and vim.api.nvim_win_get_width(D.help_win)
    or 40
  local lines, hls = {}, {}
  local line, col = "  ", 2
  local function flush()
    lines[#lines + 1] = line
    line, col = "  ", 2
  end
  for _, ac in ipairs(action_list()) do
    local cell = ac.key .. " " .. ac.desc
    if col > 2 and (col + #cell) > (width - 2) then
      flush()
    end
    local l0 = #lines -- the line this cell lands on once flushed
    hls[#hls + 1] = { l0, col, col + #ac.key, "NeoHerdrHeader" }
    hls[#hls + 1] = { l0, col + #ac.key, col + #cell, "NeoHerdrDim" }
    line = line .. cell .. "   "
    col = col + #cell + 3
  end
  if col > 2 then
    flush()
  end

  vim.bo[D.help_buf].modifiable = true
  vim.api.nvim_buf_set_lines(D.help_buf, 0, -1, false, lines)
  vim.bo[D.help_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(D.help_buf, HELP_NS, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_add_highlight, D.help_buf, HELP_NS, h[4], h[1], h[2], h[3])
  end
  return #lines
end

local function setup_dashboard_buf(win)
  D.win = win
  D.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, D.buf)

  vim.bo[D.buf].buftype = "nofile"
  vim.bo[D.buf].bufhidden = "wipe"
  vim.bo[D.buf].swapfile = false
  vim.bo[D.buf].filetype = "neoherdr"
  vim.b[D.buf].neo_herdr = true
  vim.api.nvim_buf_set_name(D.buf, "neo-herdr://dashboard")
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixwidth = true

  for _, ac in ipairs(action_list()) do
    vim.keymap.set("n", ac.key, ac.fn, { buffer = D.buf, nowait = true, silent = true })
  end
end

-- Draw only the *interior* herd divider as a dotted line, so the herd windows
-- read as one grouped sub-area (nvim's term is "windows"; "pane" is tmux) while
-- the boundary to the editor / rest of Neovim stays a normal solid line.
--
-- A vertical separator is owned by the window on its LEFT (fillchars is
-- window-local). In the herd tab [ editor │ chat │ dashboard ] the only divider
-- interior to the herd area is chat│dashboard, owned by `chat`; dotting just the
-- chat window styles that one line and leaves editor│chat (owned by the editor
-- window) untouched. When there's no editor pane, chat is leftmost so its only
-- divider is the interior one — same call, still correct.
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

-- Build the whole herd workspace in its own tabpage. The herd area (chat + nav)
-- takes a slice of the tab; the editor / cursor window takes the rest:
--   side="right":  [ editor | chat | nav ]
--   side="left":   [ chat | nav | editor ]
-- Chat always sits immediately left of nav, so it owns (and dots) their divider.
local function build_tab(cfg)
  D.chat_target = nil
  D.chat_bufs = {}
  vim.cmd("tabnew")
  D.tab = vim.api.nvim_get_current_tabpage()
  -- Tag the tabpage so a tabline (built-in or a plugin) can filter it out.
  pcall(vim.api.nvim_tabpage_set_var, D.tab, "neo_herdr", true)

  local has_editor = cfg.editor ~= false
  local side = cfg.side or "right"
  local total = vim.o.columns
  local herd_w = has_editor and resolve_w(cfg.herd_width, total, 0.30) or total
  local nav_w = resolve_w(cfg.nav_width, herd_w, 0.30)
  nav_w = math.max(nav_w, cfg.nav_min or 12)
  nav_w = math.min(nav_w, math.max(1, herd_w - 10)) -- leave room for chat
  local chat_w = herd_w - nav_w

  local first = vim.api.nvim_get_current_win()
  if not has_editor then
    -- No editor pane: the tab is just [ chat | nav ].
    D.main_win = nil
    D.win = first
    vim.cmd("leftabove vsplit")
    D.chat_win = vim.api.nvim_get_current_win()
  elseif side == "left" then
    -- [ chat | nav | editor ]; `first` is the editor on the right.
    D.main_win = first
    vim.cmd("leftabove vsplit")
    D.win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vsplit")
    D.chat_win = vim.api.nvim_get_current_win()
  else
    -- [ editor | chat | nav ]; `first` is the editor on the left.
    D.main_win = first
    vim.cmd("rightbelow vsplit")
    D.chat_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    D.win = vim.api.nvim_get_current_win()
  end

  -- The editor pane's starting buffer is a listed [No Name] (from :tabnew);
  -- unlist it so it isn't a stray entry in bufferline/:ls. Real files opened
  -- here later become normal listed buffers again.
  if has_editor and D.main_win and vim.api.nvim_win_is_valid(D.main_win) then
    pcall(function()
      vim.bo[vim.api.nvim_win_get_buf(D.main_win)].buflisted = false
    end)
  end

  setup_dashboard_buf(D.win) -- also sets winfixwidth on the nav column
  setup_chat_placeholder(D.chat_win)

  -- Size the herd columns; the editor (if any) absorbs the remainder.
  pcall(vim.api.nvim_win_set_width, D.win, nav_w)
  if has_editor then
    pcall(vim.api.nvim_win_set_width, D.chat_win, chat_w)
  end

  style_separators(cfg)

  vim.api.nvim_create_autocmd("TabClosed", {
    callback = function()
      if D.tab and not vim.api.nvim_tabpage_is_valid(D.tab) then
        -- Tab closed out from under us (e.g. :tabclose) — detach the terminals
        -- so their `herdr agent attach` processes don't linger.
        for _, b in pairs(D.chat_bufs or {}) do
          if b and vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
          end
        end
        D.chat_bufs = {}
        D.tab, D.win, D.buf, D.chat_win, D.main_win, D.chat_target = nil, nil, nil, nil, nil, nil
        D.help_win = nil
      end
    end,
  })
end

-- ── Hiding the herd tab from the tabline ─────────────────────────────────────
--
-- The herd workspace is a real tabpage, so a tabline enumerating tabpages shows
-- it next to your code tabs. There's no native "hidden tabpage" flag, so we tag
-- ours (nvim_tabpage_set_var neo_herdr) and, if you're on the *built-in* tabline,
-- swap in a near-identical one that skips tagged tabs. A plugin-drawn tabline is
-- left untouched — use the tag in its own filter instead (see README).

-- Global so 'tabline' can call it as %!v:lua.neo_herdr_tabline().
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
        .. "%" .. nr .. "T"
        .. " " .. nr .. " " .. name .. mod .. " "
    end
  end
  out[#out + 1] = "%#TabLineFill#%T"
  return table.concat(out)
end

-- Install our tabline only when the built-in one is active (empty 'tabline') or
-- already ours — never clobber a plugin/user-defined tabline. A plugin tabline
-- (e.g. bufferline) is left alone; its buffer/tab filtering is covered instead
-- by the unlisted herd buffers + the `neo_herdr` tab/buffer tags.
local function ensure_tab_hidden(cfg)
  if not cfg or cfg.hide_tab == false then
    return
  end
  local tl = vim.o.tabline
  if tl == "" or tl:find("neo_herdr_tabline", 1, true) then
    vim.o.tabline = "%!v:lua.neo_herdr_tabline()"
  end
end

function M.is_open()
  return D.tab ~= nil and vim.api.nvim_tabpage_is_valid(D.tab)
end

function M.open(cfg)
  D.config = cfg or D.config or {}
  define_highlights()
  if not D.hl_autocmd then
    -- A :colorscheme wipes highlights; re-apply our status colors after it.
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
  M.render()
  if D.config.help ~= false then
    M.toggle_help(true)
  end
  if D.win and vim.api.nvim_win_is_valid(D.win) then
    vim.api.nvim_set_current_win(D.win) -- leave cursor in the dashboard to navigate
  end
end

function M.close()
  -- Detach every attached terminal (deleting the buffer SIGHUPs its
  -- `herdr agent attach`), so processes don't linger and a later reopen can
  -- attach cleanly instead of hitting "already has an attached client".
  for _, b in pairs(D.chat_bufs or {}) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  D.chat_bufs = {}
  if M.is_open() then
    local n = vim.api.nvim_tabpage_get_number(D.tab)
    local ok = pcall(vim.cmd, n .. "tabclose")
    if not ok then
      -- Last tabpage: close the herd windows individually instead.
      for _, w in ipairs({ D.win, D.chat_win }) do
        if w and vim.api.nvim_win_is_valid(w) then
          pcall(vim.api.nvim_win_close, w, true)
        end
      end
    end
  end
  D.tab, D.win, D.buf, D.chat_win, D.main_win, D.chat_target = nil, nil, nil, nil, nil, nil
  D.help_win = nil
end

function M.toggle(cfg)
  if M.is_open() then
    M.close()
  else
    M.open(cfg)
  end
end

--- Target string of the agent currently shown in the chat window, or nil.
function M.chat_target()
  return D.chat_target
end

--- Jump to the herd chat window and, if it holds a live terminal, start typing.
--- Returns "typing" | "placeholder" | "closed".
function M.focus_chat()
  if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
    return "closed"
  end
  if M.is_open() then
    vim.api.nvim_set_current_tabpage(D.tab) -- may be on another tab
  end
  vim.api.nvim_set_current_win(D.chat_win)
  if vim.bo[vim.api.nvim_win_get_buf(D.chat_win)].buftype == "terminal" then
    vim.cmd("startinsert")
    return "typing"
  end
  return "placeholder"
end

--- Toggle the keybindings help pane (a short window under the chat). Pass true
--- to force it on, false to force off, nil to flip.
function M.toggle_help(force)
  local visible = D.help_win and vim.api.nvim_win_is_valid(D.help_win)
  local want = force
  if want == nil then
    want = not visible
  end
  if want and not visible then
    if not (D.chat_win and vim.api.nvim_win_is_valid(D.chat_win)) then
      return
    end
    local cur = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(D.chat_win)
    vim.cmd("belowright split")
    local w = vim.api.nvim_get_current_win()
    D.help_win = w
    vim.api.nvim_win_set_buf(w, ensure_help_buf())
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].wrap = false
    vim.wo[w].cursorline = false
    vim.wo[w].signcolumn = "no"
    vim.wo[w].winfixheight = true
    local rows = render_help()
    pcall(vim.api.nvim_win_set_height, w, math.max(1, rows))
    if vim.api.nvim_win_is_valid(cur) then
      vim.api.nvim_set_current_win(cur) -- keep focus where it was (the nav)
    end
  elseif not want and visible then
    pcall(vim.api.nvim_win_close, D.help_win, true)
    D.help_win = nil
  end
end

--- Called on VimLeavePre to release socket + timer cleanly.
function M.shutdown()
  if D.poll_timer then
    pcall(vim.fn.timer_stop, D.poll_timer)
    D.poll_timer = nil
  end
  pcall(socket.close_subscription)
end

return M
