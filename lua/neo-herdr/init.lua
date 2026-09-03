-- neo-herdr.nvim
-- A Neovim client for herdr. Two planes:
--   Control (native buffers): live dashboard + prompt / review comments / read
--     / send-keys, over herdr's CLI and Unix socket.
--   Terminal (:terminal): attach an agent's real PTY (herdr agent attach) so
--     nvim renders the live pane — no terminal emulator reimplemented.

local herdr = require("neo-herdr.herdr")
local comments = require("neo-herdr.comments")
local marks = require("neo-herdr.marks")

local M = {}

local NS = "[neo-herdr] "

local function notify(msg, level)
  vim.notify(NS .. msg, level or vim.log.levels.INFO)
end

--- Default payload formatter for the review-comment batch.
local function default_format(batch)
  local lines = { "Code review notes from Neovim:", "" }
  for i, c in ipairs(batch) do
    local loc = (c.e and c.e ~= c.s) and string.format("%s:%d-%d", c.file, c.s, c.e)
      or string.format("%s:%d", c.file, c.s)
    table.insert(lines, string.format("%d. %s", i, loc))
    for _, sl in ipairs(c.snippet or {}) do
      table.insert(lines, "     | " .. sl)
    end
    for _, nl in ipairs(vim.split(c.note or "", "\n", { plain = true })) do
      table.insert(lines, "   " .. nl)
    end
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

M.config = {
  herdr_cmd = "herdr",
  agent = nil, -- pin a target (name or pane id); nil = resolve at send
  prompt = { wait = false, until_states = {}, timeout = nil },
  snippet_max = 40,
  read = { source = "recent-unwrapped", lines = 200 },
  format = default_format,
  dashboard = {
    side = "right", -- herd area (chat+nav) on the "right" or "left"; editor gets the rest
    herd_width = 0.30, -- herd area as a fraction of the tab (<=1) or absolute columns (>1)
    nav_width = 0.30, -- nav as a fraction of the herd area (<=1) or absolute columns (>1)
    nav_min = 12, -- floor for the nav column, in columns (keeps it readable)
    editor = true, -- include an editor/cursor window taking the remaining width
    hide_tab = true, -- hide the herd tabpage from the built-in tabline (see README)
    help = true, -- show the keybindings help pane under the chat (toggle with ?)
    notifier = true, -- Opera-GX-style notifier float (blocked/working/done circles)
    use_socket = true, -- prefer socket; falls back to CLI poll
    socket_path = nil, -- override $HERDR_SOCKET_PATH resolution
    auto_refresh = true, -- timer + manual; false = manual only
    poll_interval = 4000, -- ms (backstop / CLI fallback)
    chat_header = true, -- winbar on the chat window: workspace › agent + status
    separators = { -- dotted dividers between the herd tab's windows
      dotted = true,
      vert = "┊", -- set false on `dotted` to keep solid separators
    },
  },
  attach = {
    detach_hint = true,
    attach_args = {}, -- e.g. { "--takeover" }
    -- Window navigation out of the chat terminal. Each key leaves terminal mode
    -- and replays through your own normal-mode mappings; <C-w> is Vim's window
    -- prefix. Add directional keys (e.g. "<C-h>") to `keys`, or enable = false.
    nav = {
      enable = true,
      prefix = "<C-w>",
      keys = {},
    },
  },
  keymaps = {
    prefix = "<leader>h",
    add = "c", -- add review comment (normal line / visual range)
    send = "s", -- send comment batch
    list = "l", -- list pending comments
    clear = "x", -- clear pending comments
    pick_agent = "a", -- pick & pin target agent
    read = "r", -- read recent output of resolved agent
    dashboard = "d", -- toggle the live dashboard
    tile = "t", -- tile all agents as terminal panes
    insert = "i", -- jump into the chat window and start typing
  },
}

-- Runtime-pinned agent (set by pick_agent).
local pinned_agent = nil

--- Resolve which agent to talk to, then cb(target).
local function resolve_agent(cb)
  local fixed = pinned_agent or M.config.agent
  if fixed then
    cb(fixed)
    return
  end
  herdr.list(function(agents, err)
    if err then
      notify("could not list agents: " .. err, vim.log.levels.ERROR)
      return
    end
    if not agents or #agents == 0 then
      notify("no live agents in this workspace", vim.log.levels.WARN)
      return
    end
    if #agents == 1 then
      cb(agents[1].name or agents[1].pane)
      return
    end
    vim.ui.select(agents, {
      prompt = "Which agent?",
      format_item = function(a)
        local label = a.name or a.title or a.pane or "?"
        if a.state then
          label = label .. "  (" .. a.state .. ")"
        end
        return label
      end,
    }, function(choice)
      if choice then
        cb(choice.name or choice.pane)
      end
    end)
  end)
end

--- Resolve the send target, preferring the agent currently open in the chat
--- window; falls back to the pinned/picked agent. cb(target).
local function resolve_target(cb)
  local dash = require("neo-herdr.dashboard")
  local t = dash.chat_target and dash.chat_target()
  if t and t ~= "" then
    cb(t)
    return
  end
  resolve_agent(cb)
end

local function open_scratch(name, text)
  vim.cmd("botright vsplit")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

-- ── Target-taking actions (used by the dashboard) ───────────────────────────

function M.prompt_agent(target, text)
  local function go(msg)
    if not msg or msg == "" then
      return
    end
    herdr.prompt(target, msg, M.config.prompt, function(ok, out)
      if ok then
        notify("sent to " .. target)
      else
        notify("send failed: " .. (out or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end
  if text then
    go(text)
  else
    vim.ui.input({ prompt = "Prompt " .. target .. ": " }, go)
  end
end

--- Close a single chat (herdr pane close), with a confirm — it's destructive.
function M.close_chat(agent)
  local pane = type(agent) == "table" and agent.pane_id or agent
  if not pane or pane == "" then
    notify("no pane id for this chat", vim.log.levels.WARN)
    return
  end
  local label = type(agent) == "table" and require("neo-herdr.state").display_name(agent) or pane
  local kind = (type(agent) == "table" and agent.is_shell) and "terminal" or "chat"
  vim.ui.select({ "Close " .. kind, "Cancel" }, {
    prompt = "Close '" .. label .. "'? (herdr pane close)",
  }, function(choice)
    if choice ~= "Close " .. kind then
      return
    end
    herdr.close_pane(pane, function(ok, out)
      if ok then
        notify("closed " .. label)
        require("neo-herdr.dashboard").refresh()
      else
        notify("close failed: " .. (out or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end)
end

--- Rename a chat's display title (herdr agent rename).
function M.rename_chat(agent)
  local target = type(agent) == "table" and (agent.name or agent.pane_id) or agent
  if not target or target == "" then
    notify("no target to rename", vim.log.levels.WARN)
    return
  end
  local cur = type(agent) == "table" and (agent.name or agent.title or "") or ""
  vim.ui.input({ prompt = "Rename chat to: ", default = cur }, function(name)
    if not name or name == "" then
      return
    end
    herdr.rename_agent(target, name, function(ok, out)
      if ok then
        notify("renamed to " .. name)
        require("neo-herdr.dashboard").refresh()
      else
        notify("rename failed: " .. (out or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end)
end

-- herdr agent names must be lowercase [a-z0-9_-], 1-32 chars, starting with a
-- letter. Coerce free-form input into a valid name (else the CLI rejects it).
local function sanitize_name(s)
  s = (s or ""):lower():gsub("[^a-z0-9_-]", "-"):gsub("^[^a-z]+", ""):sub(1, 32)
  return s
end

-- Start an agent in a freshly created tab's pane, waiting for its shell to reach
-- a prompt first — a new tab isn't an "available shell" for ~0.5s.
local function start_agent_in_pane(pane_id, kind, name)
  herdr.wait_pane_ready(pane_id, function(ready)
    if not ready then
      notify("the new tab's shell never reached a prompt", vim.log.levels.ERROR)
      return
    end
    herdr.start_agent(pane_id, kind, name, 60000, function(ok, out)
      out = out or ""
      if ok then
        notify("started " .. name .. " (" .. kind .. ")")
        require("neo-herdr.dashboard").refresh()
      elseif out:find("agent_name_taken") then
        notify("name '" .. name .. "' is already taken — pick another", vim.log.levels.ERROR)
      elseif out:find("invalid_agent_name") then
        notify("invalid agent name '" .. name .. "' (use a-z, 0-9, -, _)", vim.log.levels.ERROR)
      else
        notify("agent start failed: " .. out, vim.log.levels.ERROR)
      end
    end)
  end)
end

--- Create a new agent chat: make a fresh tab and start an agent in it. ctx
--- (optional) = the hovered row, used only to default the kind/workspace.
function M.new_chat(ctx)
  local ws = type(ctx) == "table" and ctx.workspace_id or nil
  local default_kind = (type(ctx) == "table" and not ctx.is_shell and ctx.program) or "claude"
  vim.ui.input({ prompt = "Agent kind: ", default = default_kind }, function(kind)
    if not kind or kind == "" then
      return
    end
    vim.ui.input({ prompt = "Name: ", default = kind }, function(rawname)
      local name = sanitize_name((rawname and rawname ~= "") and rawname or kind)
      if name == "" then
        notify("could not derive a valid agent name", vim.log.levels.ERROR)
        return
      end
      herdr.create_tab({ workspace_id = ws, focus = true }, function(info, err)
        if not info or not info.pane_id then
          notify("tab create failed: " .. (err or "no pane id"), vim.log.levels.ERROR)
          return
        end
        start_agent_in_pane(info.pane_id, kind, name)
      end)
    end)
  end)
end

function M.read_target(target)
  herdr.read(target, M.config.read.source, M.config.read.lines, function(text, err)
    if not text then
      notify("read failed: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    open_scratch("herdr://read/" .. target, text)
  end)
end

function M.send_keys_target(target, keys)
  local function go(k)
    if not k or k == "" then
      return
    end
    local list = type(k) == "table" and k or vim.split(k, " ", { trimempty = true })
    herdr.send_keys(target, list, function(ok, out)
      if ok then
        notify("keys sent to " .. target)
      else
        notify("send-keys failed: " .. (out or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end
  if keys then
    go(keys)
  else
    vim.ui.input({ prompt = "Keys to " .. target .. " (e.g. enter): " }, go)
  end
end

-- ── Comment capture / batch ──────────────────────────────────────────────────

-- Resolve the real on-disk path for the current buffer, seeing through
-- diffview:// and fugitive:// git-object buffers so `<leader>hc` works from
-- EITHER diff pane (not just the working-tree side). Returns the absolute path
-- or nil. The line number + snippet are still taken from the visible buffer, so
-- they match exactly what you're looking at (the revision's content on the left
-- side, the working tree on the right).
local function resolve_buffer_file(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end

  if name:match("^fugitive://") then
    local ok, real = pcall(vim.fn["fugitive#Real"], name)
    if ok and type(real) == "string" and real ~= "" then
      return real
    end
    return nil
  end

  if name:match("^diffview://") then
    local ok, lib = pcall(require, "diffview.lib")
    if not (ok and lib and lib.get_current_view) then
      return nil
    end
    local view = lib.get_current_view()
    local entry = view and (view.cur_entry or (view.panel and view.panel.cur_file))
    if not entry then
      return nil
    end
    if type(entry.absolute_path) == "string" and entry.absolute_path ~= "" then
      return entry.absolute_path
    end
    -- Fall back to toplevel + relative path across diffview versions.
    local top = (view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel)
      or (view.git_ctx and view.git_ctx.toplevel)
    if top and type(entry.path) == "string" and entry.path ~= "" then
      return top .. "/" .. entry.path
    end
    return nil
  end

  return name -- ordinary file buffer (incl. diffview's working-tree pane)
end

local function capture(range)
  local buf = vim.api.nvim_get_current_buf()
  local abs = resolve_buffer_file(buf)
  if not abs then
    notify("can't resolve a real file for this buffer (unsaved, or a git-diff view)", vim.log.levels.WARN)
    return nil
  end
  local file = vim.fn.fnamemodify(abs, ":.")
  local s = range and range.s or vim.fn.line(".")
  local e = range and range.e or s
  if s > e then
    s, e = e, s
  end
  local snippet = {}
  local raw = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
  local max = M.config.snippet_max
  for i, l in ipairs(raw) do
    if i > max then
      table.insert(snippet, string.format("... (%d more lines)", #raw - max))
      break
    end
    table.insert(snippet, l)
  end
  return { file = file, s = s, e = e, snippet = snippet, bufnr = buf }
end

function M.add_comment(opts)
  opts = opts or {}
  local c = capture(opts.range)
  if not c then
    return
  end
  local function finish(note)
    if not note or note == "" then
      notify("comment cancelled (empty note)")
      return
    end
    c.note = note
    local n = comments.add(c)
    marks.place(c) -- persist an inline marker until sent/cleared
    local loc = (c.e ~= c.s) and string.format("%s:%d-%d", c.file, c.s, c.e)
      or string.format("%s:%d", c.file, c.s)
    notify(string.format("added comment %d on %s", n, loc))
  end
  if opts.note then
    finish(opts.note)
  else
    vim.ui.input({ prompt = "Review note: " }, finish)
  end
end

function M.send()
  if comments.count() == 0 then
    notify("no pending comments to send", vim.log.levels.WARN)
    return
  end
  local payload = M.config.format(comments.all())
  local n = comments.count()
  resolve_target(function(target)
    herdr.prompt(target, payload, M.config.prompt, function(ok, out)
      if ok then
        -- Delivered to the agent (shows in its chat) — the review batch is done.
        notify(string.format("sent %d comment(s) to %s", n, target))
        comments.clear()
        marks.clear() -- pending markers go away once sent
      else
        notify("send failed: " .. (out or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.send_message(text)
  local function go(msg)
    if not msg or msg == "" then
      return
    end
    resolve_agent(function(target)
      M.prompt_agent(target, msg)
    end)
  end
  if text then
    go(text)
  else
    vim.ui.input({ prompt = "Message to agent: " }, go)
  end
end

function M.list_comments()
  local all = comments.all()
  if #all == 0 then
    notify("no pending comments")
    return
  end
  local lines = { "Pending review comments:" }
  for i, c in ipairs(all) do
    local loc = (c.e ~= c.s) and string.format("%s:%d-%d", c.file, c.s, c.e)
      or string.format("%s:%d", c.file, c.s)
    table.insert(lines, string.format("  %d. %s — %s", i, loc, (c.note or ""):gsub("\n", " ")))
  end
  notify(table.concat(lines, "\n"))
end

function M.clear()
  local n = comments.count()
  comments.clear()
  marks.clear()
  notify(string.format("cleared %d comment(s)", n))
end

-- ── Public API for companion packages (e.g. neo-reviewr) ─────────────────────
-- Stable surface so a separate review UI can push comments into the same batch,
-- reuse the inline-marker rendering, and hand off to the same send/clear flow.

--- Add a fully-formed comment to the pending batch (no capture/prompt).
--- c = { file, s, e?, snippet?, note }. Returns the batch index, or nil.
function M.add_comment_data(c)
  if type(c) ~= "table" or not c.file or not c.s or not c.note then
    return nil
  end
  c.e = c.e or c.s
  c.snippet = c.snippet or {}
  return comments.add(c)
end

--- Read-only view of the pending comments (for a companion UI to re-render).
function M.comments()
  return comments.all()
end

--- Draw / clear the shared inline comment marker on an arbitrary buffer line.
function M.place_marker(buf, line0, note)
  return marks.place_line(buf, line0, note)
end

function M.clear_markers_in(buf)
  marks.clear_buf(buf)
end

function M.pick_agent()
  herdr.list(function(agents, err)
    if err then
      notify("could not list agents: " .. err, vim.log.levels.ERROR)
      return
    end
    if not agents or #agents == 0 then
      notify("no live agents", vim.log.levels.WARN)
      return
    end
    vim.ui.select(agents, {
      prompt = "Pin target agent",
      format_item = function(a)
        local label = a.name or a.title or a.pane or "?"
        if a.state then
          label = label .. "  (" .. a.state .. ")"
        end
        return label
      end,
    }, function(choice)
      if choice then
        pinned_agent = choice.name or choice.pane
        notify("target agent pinned: " .. pinned_agent)
      end
    end)
  end)
end

function M.set_agent(target)
  pinned_agent = target
end

function M.read_agent()
  resolve_agent(function(target)
    M.read_target(target)
  end)
end

-- ── Dashboard / terminal facades ─────────────────────────────────────────────

function M.dashboard()
  require("neo-herdr.dashboard").toggle(M.config.dashboard)
end

--- Jump straight into the open herd chat and start typing.
function M.focus_chat()
  local status = require("neo-herdr.dashboard").focus_chat()
  if status == "closed" then
    notify("no herd chat open — run the dashboard and pick an agent", vim.log.levels.WARN)
  elseif status == "placeholder" then
    notify("no agent in the chat yet — pick one in the dashboard (<CR>)")
  end
end

function M.attach()
  resolve_agent(function(target)
    require("neo-herdr.attach").attach(target, "vsplit")
  end)
end

function M.tile()
  herdr.list(function(agents, err)
    if err or not agents or #agents == 0 then
      notify("no agents to tile", vim.log.levels.WARN)
      return
    end
    local targets = {}
    for _, a in ipairs(agents) do
      table.insert(targets, a.name or a.pane)
    end
    require("neo-herdr.attach").tile(targets)
  end)
end

-- ── Registration ─────────────────────────────────────────────────────────────

local function register(cfg)
  local cmd = vim.api.nvim_create_user_command
  cmd("NeoHerdrComment", function(a)
    if a.range and a.range > 0 then
      M.add_comment({ range = { s = a.line1, e = a.line2 } })
    else
      M.add_comment()
    end
  end, { range = true, desc = "Add a herdr review comment" })
  cmd("NeoHerdrSend", function()
    M.send()
  end, { desc = "Send pending review comments to the agent" })
  cmd("NeoHerdrMessage", function(a)
    M.send_message(a.args ~= "" and a.args or nil)
  end, { nargs = "?", desc = "Send an ad-hoc message to the agent" })
  cmd("NeoHerdrList", function()
    M.list_comments()
  end, { desc = "List pending review comments" })
  cmd("NeoHerdrClear", function()
    M.clear()
  end, { desc = "Clear pending review comments" })
  cmd("NeoHerdrPickAgent", function()
    M.pick_agent()
  end, { desc = "Pin the target herdr agent" })
  cmd("NeoHerdrRead", function()
    M.read_agent()
  end, { desc = "Peek recent agent output" })
  cmd("NeoHerdrDashboard", function()
    M.dashboard()
  end, { desc = "Toggle the herdr dashboard sidebar" })
  cmd("NeoHerdrChat", function()
    M.focus_chat()
  end, { desc = "Jump into the herd chat and start typing" })
  cmd("NeoHerdrAttach", function(a)
    if a.args ~= "" then
      require("neo-herdr.attach").attach(a.args, "vsplit")
    else
      M.attach()
    end
  end, { nargs = "?", desc = "Attach an agent's live terminal" })
  cmd("NeoHerdrTile", function()
    M.tile()
  end, { desc = "Tile all agents as terminal panes" })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      pcall(function()
        require("neo-herdr.dashboard").shutdown()
      end)
    end,
  })

  local km = cfg.keymaps
  if km == false then
    return
  end
  local p = km.prefix
  local function map(mode, suffix, rhs, desc)
    if suffix then
      vim.keymap.set(mode, p .. suffix, rhs, { desc = "neo-herdr: " .. desc })
    end
  end
  map("n", km.add, function()
    M.add_comment()
  end, "add comment (line)")
  map("x", km.add, ":<C-u>NeoHerdrComment<CR>", "add comment (range)")
  map("n", km.send, function()
    M.send()
  end, "send comments")
  map("n", km.list, function()
    M.list_comments()
  end, "list comments")
  map("n", km.clear, function()
    M.clear()
  end, "clear comments")
  map("n", km.pick_agent, function()
    M.pick_agent()
  end, "pick agent")
  map("n", km.read, function()
    M.read_agent()
  end, "read agent output")
  map("n", km.dashboard, function()
    M.dashboard()
  end, "toggle dashboard")
  map("n", km.tile, function()
    M.tile()
  end, "tile agents")
  map("n", km.insert, function()
    M.focus_chat()
  end, "focus chat & type")
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if opts and opts.format then
    M.config.format = opts.format
  end
  herdr.setup({ herdr_cmd = M.config.herdr_cmd })
  require("neo-herdr.attach").setup(vim.tbl_extend("force", { herdr_cmd = M.config.herdr_cmd }, M.config.attach))
  register(M.config)
end

return M
