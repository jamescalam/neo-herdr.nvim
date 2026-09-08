-- neo-herdr: thin async client over the `herdr` CLI.
-- Every call shells out with vim.system (non-blocking) and returns results
-- on the main loop via vim.schedule, so callers can touch the Neovim API freely.
--
-- All commands run against ONE herdr session (config.session, default "nvim")
-- by prefixing `--session <name>`; M.argv builds that argv so attach/terminal
-- code uses the exact same session as the request/response calls.
--
-- Errors: herdr prints `{"id":..,"error":{"code":..,"message":..}}` on stderr
-- with exit 1. M.errinfo decodes that so callers can branch on `code`
-- (agent_not_found, agent_pane_busy, agent_name_taken, server_not_running…).

local M = {}

local config = { herdr_cmd = "herdr", session = nil }

function M.setup(cfg)
  config = vim.tbl_deep_extend("force", config, cfg or {})
end

function M.session()
  return config.session
end

--- Full argv for a herdr invocation, including the session selector.
function M.argv(args)
  local cmd = { config.herdr_cmd }
  if config.session and config.session ~= "" then
    table.insert(cmd, "--session")
    table.insert(cmd, config.session)
  end
  vim.list_extend(cmd, args)
  return cmd
end

local function run(args, on_done)
  vim.system(M.argv(args), { text = true }, function(res)
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

--- Decode a failed result into { code, message, text }. `text` is a short
--- human string ("code: message"), suitable for vim.notify.
function M.errinfo(res)
  local info = { code = nil, message = nil, text = nil }
  local raw = (res.stderr and res.stderr ~= "") and res.stderr or res.stdout or ""
  -- herdr may print several JSON lines; take the first that carries an error.
  for line in raw:gmatch("[^\r\n]+") do
    local d = decode(line)
    if d and type(d.error) == "table" then
      info.code = d.error.code
      info.message = d.error.message
      break
    end
  end
  if not info.code and raw:match("%S") then
    info.message = vim.trim(raw)
  end
  if info.code then
    info.text = info.code .. (info.message and (": " .. info.message) or "")
  else
    info.text = info.message or ("exit " .. tostring(res.code))
  end
  return info
end

--- Extract the error code prefix from a string produced by errinfo().text.
function M.code_of(err)
  if type(err) ~= "string" then
    return nil
  end
  return err:match("^([%w_]+):")
end

local function fail(res)
  return M.errinfo(res).text
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

--- Server status. cb({ running, socket, version }, err). `herdr status --json`
--- answers even when nothing is running, so this is the cheap liveness probe.
function M.status(cb)
  run({ "status", "--json" }, function(res)
    local d = decode(res.stdout)
    local s = d and d.server
    if type(s) ~= "table" then
      cb(nil, fail(res))
      return
    end
    cb({
      running = s.running == true or s.status == "running",
      socket = s.socket,
      version = s.version,
      raw = d,
    }, nil)
  end)
end

--- List live agents. cb(agents, err). Each agent: { name, pane, state, raw }.
function M.list(cb)
  run({ "agent", "list" }, function(res)
    if not ok(res) then
      cb(nil, fail(res))
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
      cb(nil, fail(res))
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

--- Names currently in use by live agents (for picking a unique default).
function M.agent_names(cb)
  M.agents_raw(function(list)
    local names = {}
    for _, a in ipairs(list or {}) do
      local n = a.name or a.agent_name
      if type(n) == "string" and n ~= "" then
        names[n] = true
      end
    end
    cb(names)
  end)
end

--- Raw workspace objects for the dashboard's CLI-poll path.
function M.workspaces(cb)
  run({ "workspace", "list" }, function(res)
    if not ok(res) then
      cb(nil, fail(res))
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
    cb(ok(res), ok(res) and res.stdout or fail(res))
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
      cb(nil, fail(res))
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
    cb(ok(res), ok(res) and res.stdout or fail(res))
  end)
end

--- Rename an agent/chat (its display title). cb(ok, out).
function M.rename_agent(target, name, cb)
  run({ "agent", "rename", target, name }, function(res)
    cb(ok(res), ok(res) and res.stdout or fail(res))
  end)
end

--- Create a tab (new pane). opts = { workspace_id, focus }. cb(info, err) where
--- info = { tab_id, pane_id, raw } — pane_id is the new tab's root pane, which
--- `agent start` targets (once its shell is ready; see M.start_agent's retry).
function M.create_tab(opts, cb)
  opts = opts or {}
  local args = { "tab", "create" }
  if opts.focus == false then
    table.insert(args, "--no-focus")
  else
    table.insert(args, "--focus")
  end
  if opts.workspace_id then
    table.insert(args, "--workspace")
    table.insert(args, opts.workspace_id)
  end
  run(args, function(res)
    if not ok(res) then
      cb(nil, fail(res))
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

--- The whole live session in one call: { workspaces, tabs, panes, agents, … }.
--- cb(snapshot, err).
function M.snapshot(cb)
  run({ "api", "snapshot" }, function(res)
    if not ok(res) then
      cb(nil, fail(res))
      return
    end
    local d = decode(res.stdout)
    local snap = d and d.result and (d.result.snapshot or d.result)
    if type(snap) ~= "table" or not snap.panes then
      cb(nil, "unexpected snapshot shape")
      return
    end
    cb(snap, nil)
  end)
end

--- Create a workspace (with its first tab + root pane). opts = { cwd, focus }.
--- cb(info, err) where info = { workspace_id, tab_id, pane_id, raw }.
function M.create_workspace(opts, cb)
  opts = opts or {}
  local args = { "workspace", "create" }
  if opts.cwd then
    table.insert(args, "--cwd")
    table.insert(args, opts.cwd)
  end
  if opts.focus == false then
    table.insert(args, "--no-focus")
  end
  run(args, function(res)
    if not ok(res) then
      cb(nil, fail(res))
      return
    end
    local d = decode(res.stdout)
    local r = (d and d.result) or {}
    local ws, tab, root = r.workspace or {}, r.tab or {}, r.root_pane or {}
    cb({
      workspace_id = ws.workspace_id or ws.id or root.workspace_id,
      tab_id = tab.tab_id or root.tab_id,
      pane_id = root.pane_id,
      raw = r,
    }, nil)
  end)
end

--- List panes. cb(panes, err).
function M.panes(cb)
  run({ "pane", "list" }, function(res)
    if not ok(res) then
      cb(nil, fail(res))
      return
    end
    local d = decode(res.stdout)
    cb(d and d.result and d.result.panes or {}, nil)
  end)
end

--- Start an interactive agent in an existing shell pane. cb(ok, out, code).
--- herdr answers `agent_pane_busy` until the pane's shell is at its prompt
--- (measured: busy at ~10ms after `tab create`, available by ~250ms), so we
--- retry that one code every 250ms for up to `opts.busy_retry_ms` (default 5s).
--- opts = { timeout_ms = herdr's readiness wait (>3000), busy_retry_ms, args = {…} }
function M.start_agent(pane_id, kind, name, opts, cb)
  opts = opts or {}
  local args = { "agent", "start", name, "--kind", kind, "--pane", pane_id }
  if opts.timeout_ms then
    table.insert(args, "--timeout")
    table.insert(args, tostring(opts.timeout_ms))
  end
  if opts.args and #opts.args > 0 then
    table.insert(args, "--")
    vim.list_extend(args, opts.args)
  end
  local deadline = vim.uv.now() + (opts.busy_retry_ms or 5000)
  local function attempt()
    run(args, function(res)
      if ok(res) then
        cb(true, res.stdout, nil)
        return
      end
      local e = M.errinfo(res)
      if e.code == "agent_pane_busy" and vim.uv.now() < deadline then
        vim.defer_fn(attempt, 250)
        return
      end
      cb(false, e.text, e.code)
    end)
  end
  attempt()
end

--- Send raw keys to an agent (e.g. { "esc" } or { "ctrl+c" }).
function M.send_keys(target, keys, cb)
  local args = { "agent", "send-keys", target }
  vim.list_extend(args, keys)
  run(args, function(res)
    cb(ok(res), ok(res) and res.stdout or fail(res))
  end)
end

--- Stop the server this session talks to. cb(ok, out).
function M.server_stop(cb)
  run({ "server", "stop" }, function(res)
    cb(ok(res), ok(res) and res.stdout or fail(res))
  end)
end

--- Synchronous variants for VimLeavePre, where async callbacks never run.
function M.server_stop_sync(timeout_ms)
  local res = vim.system(M.argv({ "server", "stop" }), { text = true }):wait(timeout_ms or 3000)
  return res and res.code == 0, res and fail(res) or "timeout"
end

function M.agents_raw_sync(timeout_ms)
  local res = vim.system(M.argv({ "agent", "list" }), { text = true }):wait(timeout_ms or 2000)
  if not res or res.code ~= 0 then
    return nil
  end
  return raw_agents(decode(res.stdout)) or {}
end

return M
