-- neo-herdr: lifecycle of the herdr server behind the herd tab.
--
-- The plugin runs against a DEDICATED herdr session (config.session, default
-- "nvim") so it never starts or stops the server behind the user's own `herdr`
-- TUI. On open we probe `herdr status --json`; if nothing is running we launch
-- a headless `herdr --session <name> server`, detached so it outlives Neovim
-- when policy says to leave it, and poll status until it answers.
--
-- Stopping is the dangerous half: `herdr server stop` SIGHUPs every pane
-- process, i.e. it kills running agents. So `autostop` defaults to "owned"
-- (only a server this Neovim started), and `confirm` asks first whenever an
-- agent is still working or blocked.

local herdr = require("neo-herdr.herdr")

local M = {}

local cfg = {
  session = "nvim", -- nil = herdr's default session (shared with the TUI)
  autostart = true,
  autostop = "owned", -- "owned" | "always" | "never"
  confirm = true, -- ask before stopping while an agent is working/blocked
  start_timeout = 10000, -- ms to wait for a freshly started server
}

local S = { owned = false, job = nil, starting = false }

function M.setup(c)
  cfg = vim.tbl_deep_extend("force", cfg, c or {})
end

function M.config()
  return cfg
end

function M.owned()
  return S.owned
end

--- cb(status, err) — status = { running, socket, version }.
function M.status(cb)
  herdr.status(cb)
end

--- Launch a headless server for our session and wait until it answers.
--- cb(ok, err).
function M.start(cb)
  if S.starting then
    cb(false, "already starting")
    return
  end
  S.starting = true
  local argv = herdr.argv({ "server" })
  local job = vim.fn.jobstart(argv, {
    detach = true,
    stdin = "null",
    on_exit = function(_, code)
      -- A quick exit here means it failed to bind/start (e.g. already running
      -- elsewhere with an incompatible version). Status polling reports it.
      if S.job and code ~= 0 then
        S.job = nil
      end
    end,
  })
  if not job or job <= 0 then
    S.starting = false
    cb(false, "could not launch `" .. table.concat(argv, " ") .. "`")
    return
  end
  S.job = job
  local deadline = vim.uv.now() + (cfg.start_timeout or 10000)
  local function poll()
    herdr.status(function(st)
      if st and st.running then
        S.starting = false
        S.owned = true
        cb(true, nil)
        return
      end
      if vim.uv.now() >= deadline then
        S.starting = false
        cb(false, "server did not come up within " .. tostring(cfg.start_timeout) .. "ms")
        return
      end
      vim.defer_fn(poll, 250)
    end)
  end
  vim.defer_fn(poll, 150)
end

--- Make sure a server is reachable, starting one if policy allows.
--- cb(ok, how, err) — how = "existing" | "started".
function M.ensure(cb)
  herdr.status(function(st, err)
    if st and st.running then
      cb(true, "existing", nil)
      return
    end
    if st == nil and err and not herdr.code_of(err) then
      -- The CLI itself failed (not installed / not executable).
      cb(false, nil, err)
      return
    end
    if cfg.autostart == false then
      cb(false, nil, "herdr server is not running (autostart is off)")
      return
    end
    M.start(function(ok, e)
      cb(ok, ok and "started" or nil, e)
    end)
  end)
end

--- Does policy allow stopping right now?
function M.should_stop()
  if cfg.autostop == "never" then
    return false
  end
  if cfg.autostop == "owned" and not S.owned then
    return false
  end
  return true
end

local function busy_agents(list)
  local busy = {}
  for _, a in ipairs(list or {}) do
    local st = tostring(a.agent_status or a.status or ""):lower()
    if st == "working" or st == "blocked" then
      busy[#busy + 1] = (a.name or a.pane_id or "?") .. " (" .. st .. ")"
    end
  end
  return busy
end

--- Stop the server (async). cb(ok, out).
function M.stop(cb)
  herdr.server_stop(function(ok, out)
    if ok then
      S.owned = false
      S.job = nil
    end
    if cb then
      cb(ok, out)
    end
  end)
end

--- Apply the autostop policy on herd close. Asynchronous; confirms via
--- vim.ui.select when agents are mid-work. cb(stopped:boolean) optional.
function M.maybe_stop(on_done)
  on_done = on_done or function() end
  if S.stopping or not M.should_stop() then
    on_done(false)
    return
  end
  S.stopping = true
  local function cb(v)
    S.stopping = false
    on_done(v)
  end
  local function go()
    M.stop(function(ok, out)
      if ok then
        vim.notify("[neo-herdr] herdr server stopped" .. (cfg.session and (" (session " .. cfg.session .. ")") or ""))
      else
        vim.notify("[neo-herdr] server stop failed: " .. tostring(out), vim.log.levels.ERROR)
      end
      cb(ok)
    end)
  end
  if not cfg.confirm then
    go()
    return
  end
  herdr.agents_raw(function(list)
    local busy = busy_agents(list)
    if #busy == 0 then
      go()
      return
    end
    vim.ui.select({ "Stop server (kills them)", "Leave it running" }, {
      prompt = "Agents still busy: " .. table.concat(busy, ", "),
    }, function(choice)
      if choice and choice:match("^Stop") then
        go()
      else
        cb(false)
      end
    end)
  end)
end

--- Same policy, but synchronous — for VimLeavePre, where nothing async runs.
function M.maybe_stop_sync()
  if not M.should_stop() then
    return false
  end
  if cfg.confirm then
    local busy = busy_agents(herdr.agents_raw_sync(2000))
    if #busy > 0 then
      local answer = vim.fn.confirm(
        "neo-herdr: agents still busy (" .. table.concat(busy, ", ") .. ").\nStop the herdr server and kill them?",
        "&Stop\n&Leave running",
        2
      )
      if answer ~= 1 then
        return false
      end
    end
  end
  local ok = herdr.server_stop_sync(3000)
  if ok then
    S.owned = false
    S.job = nil
  end
  return ok
end

return M
