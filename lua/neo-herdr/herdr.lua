-- neo-herdr: thin async client over the `herdr` CLI.
-- Every call shells out with vim.system (non-blocking) and returns results
-- on the main loop via vim.schedule, so callers can touch the Neovim API freely.
--
-- NOTE ON JSON: herdr's automation surface prints JSON for most commands, but
-- the exact schema of `agent list` is not pinned down in the public docs. All
-- schema assumptions live in `extract_agents` / `M.list` below so there is a
-- single place to adjust once we've seen real output on your machine.

local M = {}

local config = { herdr_cmd = "herdr" }

function M.setup(cfg)
  config = vim.tbl_deep_extend("force", config, cfg or {})
end

local function run(args, on_done)
  local cmd = vim.list_extend({ config.herdr_cmd }, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      on_done(res)
    end)
  end)
end

local function ok(res)
  return res.code == 0
end

local function decode(str)
  if not str or str == "" then
    return nil
  end
  local decoded_ok, val = pcall(vim.json.decode, str)
  if not decoded_ok then
    return nil
  end
  return val
end

-- Pull a list of agents out of whatever `agent list` returned. Handles the
-- likely JSON shapes (.result.agents / .agents / bare array / first nested
-- array) and normalises each entry to { name, pane, state, raw }.
local function extract_agents(decoded)
  if type(decoded) ~= "table" then
    return {}
  end

  local arr
  if type(decoded.result) == "table" and decoded.result.agents then
    arr = decoded.result.agents
  elseif decoded.agents then
    arr = decoded.agents
  elseif vim.islist and vim.islist(decoded) then
    arr = decoded
  elseif #decoded > 0 then
    arr = decoded
  else
    for _, v in pairs(decoded) do
      if type(v) == "table" and #v > 0 then
        arr = v
        break
      end
    end
  end

  if type(arr) ~= "table" then
    return {}
  end

  local out = {}
  for _, e in ipairs(arr) do
    if type(e) == "table" then
      table.insert(out, {
        name = e.name or e.agent_name, -- NOT e.agent (that's the program)
        title = e.terminal_title_stripped or e.terminal_title,
        program = e.agent or e.program,
        pane = e.pane_id or e.pane or e.paneId or e.paneID,
        state = e.agent_status or e.status or e.state,
        raw = e,
      })
    end
  end
  return out
end

-- Pull the raw agents array (full fields) straight from the CLI JSON.
local function raw_agents(decoded)
  if type(decoded) == "table" and type(decoded.result) == "table" and decoded.result.agents then
    return decoded.result.agents
  end
  return nil
end

-- Fallback when `agent list` is not JSON: treat each non-empty line's first
-- whitespace-delimited token as an agent name.
local function parse_agent_lines(stdout)
  local out = {}
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local token = line:match("^%s*([%w%-_:]+)")
    if token and token:match("^[a-z]") then
      table.insert(out, { name = token, raw = line })
    end
  end
  return out
end

--- List live agents. cb(agents, err). Each agent: { name, pane, state, raw }.
function M.list(cb)
  run({ "agent", "list" }, function(res)
    if not ok(res) then
      cb(nil, res.stderr ~= "" and res.stderr or ("exit " .. tostring(res.code)))
      return
    end
    local agents = extract_agents(decode(res.stdout))
    if #agents == 0 then
      agents = parse_agent_lines(res.stdout)
    end
    cb(agents, nil)
  end)
end

--- Raw agent objects (full fields) for the dashboard's CLI-poll path.
function M.agents_raw(cb)
  run({ "agent", "list" }, function(res)
    if not ok(res) then
      cb(nil, res.stderr ~= "" and res.stderr or ("exit " .. tostring(res.code)))
      return
    end
    local decoded = decode(res.stdout)
    local list = raw_agents(decoded)
    if not list then
      list = extract_agents(decoded) -- tolerant fallback
      if #list == 0 then
        list = parse_agent_lines(res.stdout)
      end
    end
    cb(list or {}, nil)
  end)
end

--- Raw workspace objects for the dashboard's CLI-poll path.
function M.workspaces(cb)
  run({ "workspace", "list" }, function(res)
    if not ok(res) then
      cb(nil, res.stderr ~= "" and res.stderr or ("exit " .. tostring(res.code)))
      return
    end
    local decoded = decode(res.stdout)
    local list = decoded and decoded.result and decoded.result.workspaces
    cb(list or {}, nil)
  end)
end

--- Send a prompt (our "review comment payload") to an agent.
--- opts = { wait = bool, until_states = {..}, timeout = ms }
function M.prompt(target, text, opts, cb)
  opts = opts or {}
  local args = { "agent", "prompt", target, text }
  if opts.wait then
    table.insert(args, "--wait")
    for _, s in ipairs(opts.until_states or {}) do
      table.insert(args, "--until")
      table.insert(args, s)
    end
    if opts.timeout then
      table.insert(args, "--timeout")
      table.insert(args, tostring(opts.timeout))
    end
  end
  run(args, function(res)
    cb(ok(res), ok(res) and res.stdout or res.stderr)
  end)
end

--- Read recent agent output. cb(text, err).
function M.read(target, source, lines, cb)
  local args = { "agent", "read", target }
  if source then
    table.insert(args, "--source")
    table.insert(args, source)
  end
  if lines then
    table.insert(args, "--lines")
    table.insert(args, tostring(lines))
  end
  run(args, function(res)
    if not ok(res) then
      cb(nil, res.stderr ~= "" and res.stderr or ("exit " .. tostring(res.code)))
      return
    end
    local d = decode(res.stdout)
    local text = d and d.result and d.result.read and d.result.read.text
    cb(text or res.stdout, nil)
  end)
end

--- Close a single pane/chat. cb(ok, out).
function M.close_pane(pane_id, cb)
  run({ "pane", "close", pane_id }, function(res)
    cb(ok(res), ok(res) and res.stdout or res.stderr)
  end)
end

--- Rename an agent/chat (its display title). cb(ok, out).
function M.rename_agent(target, name, cb)
  run({ "agent", "rename", target, name }, function(res)
    cb(ok(res), ok(res) and res.stdout or res.stderr)
  end)
end

--- Create a tab (new pane). opts = { workspace_id, focus }. cb(info, err) where
--- info = { tab_id, pane_id, raw } — pane_id is the new tab's root pane, which
--- `agent start` targets (once its shell is ready; see M.wait_pane_ready).
function M.create_tab(opts, cb)
  opts = opts or {}
  local args = { "tab", "create" }
  if opts.focus ~= false then
    table.insert(args, "--focus")
  end
  if opts.workspace_id then
    table.insert(args, "--workspace")
    table.insert(args, opts.workspace_id)
  end
  run(args, function(res)
    if not ok(res) then
      cb(nil, res.stderr ~= "" and res.stderr or ("exit " .. tostring(res.code)))
      return
    end
    local d = decode(res.stdout)
    local r = (d and d.result) or {}
    local tab = r.tab or r.created or r
    local root = r.root_pane or (tab and tab.root_pane)
    cb({
      tab_id = tab and (tab.tab_id or tab.id),
      pane_id = (root and root.pane_id) or (tab and tab.pane_id),
      raw = r,
    }, nil)
  end)
end

--- Poll until a pane's shell has reached its prompt (a non-empty terminal
--- title), then cb(ready:bool). A freshly-created tab's pane isn't an
--- "available shell" for `agent start` until this happens (~0.5s).
function M.wait_pane_ready(pane_id, cb, _attempt)
  _attempt = _attempt or 1
  M.panes(function(panes)
    for _, p in ipairs(panes or {}) do
      if (p.pane_id or p.pane) == pane_id then
        local title = p.terminal_title_stripped or p.terminal_title
        if title and title ~= "" then
          cb(true)
          return
        end
        break
      end
    end
    if _attempt >= 20 then
      cb(false)
      return
    end
    vim.defer_fn(function()
      M.wait_pane_ready(pane_id, cb, _attempt + 1)
    end, 250)
  end)
end

--- List panes. cb(panes, err).
function M.panes(cb)
  run({ "pane", "list" }, function(res)
    if not ok(res) then
      cb(nil, res.stderr ~= "" and res.stderr or ("exit " .. tostring(res.code)))
      return
    end
    local d = decode(res.stdout)
    cb(d and d.result and d.result.panes or {}, nil)
  end)
end

--- Start an interactive agent in an existing (shell-ready) pane. cb(ok, out).
--- timeout_ms is herdr's interactive-readiness wait (default 30000; >3000).
function M.start_agent(pane_id, kind, name, timeout_ms, cb)
  local args = { "agent", "start", name, "--kind", kind, "--pane", pane_id }
  if timeout_ms then
    table.insert(args, "--timeout")
    table.insert(args, tostring(timeout_ms))
  end
  run(args, function(res)
    cb(ok(res), ok(res) and res.stdout or res.stderr)
  end)
end

--- Send raw keys to an agent (e.g. { "esc" } or { "ctrl+c" }).
function M.send_keys(target, keys, cb)
  local args = { "agent", "send-keys", target }
  vim.list_extend(args, keys)
  run(args, function(res)
    cb(ok(res), ok(res) and res.stdout or res.stderr)
  end)
end

return M
