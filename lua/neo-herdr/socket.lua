-- neo-herdr: client for herdr's Unix socket (NDJSON JSON-RPC).
--
-- IMPORTANT: herdr's socket is one-request-per-connection — it closes the pipe
-- after answering a single request. So each request/response call opens its own
-- short-lived connection (M.request_once). Event subscriptions are the
-- exception: events.subscribe keeps its connection open and streams
-- {"event","data"} lines, so that lives on a dedicated persistent connection
-- (M.subscribe) with auto-reconnect + re-subscribe.
--
-- Subscription replies worth knowing about (verified against herdr 0.8.0):
--   {"id":"sub","result":{"type":"subscription_started"}}   — live
--   {"id":"sub:sub:<n>:probe","error":{"code":"pane_not_found"}} — the n-th
--     (0-based) per-pane subscription named a pane that no longer exists; the
--     WHOLE subscription is rejected. We surface that as on_error(n+1, err) so
--     the caller can drop the pane and resubscribe instead of looping.

local uv = vim.uv or vim.loop

local M = {}

local defaults = { session = nil }

function M.setup(cfg)
  defaults = vim.tbl_deep_extend("force", defaults, cfg or {})
end

--- Resolve the socket path following herdr's documented precedence, with the
--- plugin's configured session taking the place of $HERDR_SESSION.
function M.resolve_path(explicit, session)
  if explicit and explicit ~= "" then
    return explicit
  end
  local env = vim.env.HERDR_SOCKET_PATH
  if env and env ~= "" then
    return env
  end
  local cfg = vim.env.XDG_CONFIG_HOME
  if not cfg or cfg == "" then
    cfg = (vim.env.HOME or "") .. "/.config"
  end
  local base = cfg .. "/herdr"
  session = session or defaults.session or vim.env.HERDR_SESSION
  if session and session ~= "" then
    return base .. "/sessions/" .. session .. "/herdr.sock"
  end
  return base .. "/herdr.sock"
end

-- ── One-shot request/response ────────────────────────────────────────────────

--- Open a fresh connection, send one request, return its response. cb(result, err).
function M.request_once(method, params, cb, path)
  path = path or M.resolve_path(nil)
  local pipe = uv.new_pipe(false)
  local buf = ""
  local done = false
  local function finish(result, err)
    if done then
      return
    end
    done = true
    pcall(function()
      pipe:read_stop()
    end)
    pcall(function()
      pipe:close()
    end)
    if cb then
      vim.schedule(function()
        cb(result, err)
      end)
    end
  end
  pipe:connect(path, function(cerr)
    if cerr then
      finish(nil, { message = tostring(cerr) })
      return
    end
    pipe:read_start(function(rerr, chunk)
      if rerr then
        finish(nil, { message = tostring(rerr) })
      elseif not chunk then
        finish(nil, { message = "closed before response" })
      else
        buf = buf .. chunk
        local nl = buf:find("\n", 1, true)
        if nl then
          local line = buf:sub(1, nl - 1)
          local ok, msg = pcall(vim.json.decode, line)
          if ok and type(msg) == "table" then
            finish(msg.result, msg.error)
          else
            finish(nil, { message = "decode failed" })
          end
        end
      end
    end)
    local payload = { id = "nh", method = method, params = params or vim.empty_dict() }
    local okj, line = pcall(vim.json.encode, payload)
    if not okj then
      finish(nil, { message = "encode failed" })
      return
    end
    pipe:write(line .. "\n")
  end)
end

-- ── Persistent event subscription ────────────────────────────────────────────

local SUB = {
  pipe = nil,
  want = false,
  connected = false,
  live = false, -- server acknowledged subscription_started
  buf = "",
  subs = nil,
  on_event = nil,
  on_status = nil,
  on_error = nil,
  path = nil,
  reconnect = nil,
}

local function sub_down(err)
  SUB.connected = false
  SUB.live = false
  if SUB.pipe then
    pcall(function()
      SUB.pipe:read_stop()
    end)
    pcall(function()
      SUB.pipe:close()
    end)
    SUB.pipe = nil
  end
  SUB.buf = ""
  if SUB.on_status then
    vim.schedule(function()
      SUB.on_status(false, err)
    end)
  end
  if SUB.want and not SUB.reconnect then
    local t = uv.new_timer()
    SUB.reconnect = t
    t:start(1500, 0, function()
      t:stop()
      t:close()
      SUB.reconnect = nil
      if SUB.want then
        M._sub_open()
      end
    end)
  end
end

local function handle_line(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not (ok and type(msg) == "table") then
    return
  end
  if msg.event then
    if SUB.on_event then
      local name, data = msg.event, msg.data or {}
      vim.schedule(function()
        SUB.on_event(name, data)
      end)
    end
    return
  end
  if msg.error then
    local idx = tostring(msg.id or ""):match("^sub:sub:(%d+):probe$")
    local err = msg.error
    -- A rejected subscription: stop reconnecting with the same list; the
    -- caller decides what to resubscribe.
    SUB.want = false
    if SUB.on_error then
      vim.schedule(function()
        SUB.on_error(idx and (tonumber(idx) + 1) or nil, err)
      end)
    end
    return
  end
  if type(msg.result) == "table" and msg.result.type == "subscription_started" then
    SUB.live = true
    if SUB.on_status then
      vim.schedule(function()
        SUB.on_status(true)
      end)
    end
  end
end

function M._sub_open()
  local pipe = uv.new_pipe(false)
  SUB.pipe = pipe
  SUB.buf = ""
  pipe:connect(SUB.path, function(cerr)
    if cerr then
      sub_down({ message = tostring(cerr) })
      return
    end
    SUB.connected = true
    pipe:read_start(function(rerr, chunk)
      if rerr then
        sub_down({ message = tostring(rerr) })
      elseif not chunk then
        sub_down(nil)
      else
        SUB.buf = SUB.buf .. chunk
        while true do
          local nl = SUB.buf:find("\n", 1, true)
          if not nl then
            break
          end
          local line = SUB.buf:sub(1, nl - 1)
          SUB.buf = SUB.buf:sub(nl + 1)
          if line ~= "" then
            handle_line(line)
          end
        end
      end
    end)
    local payload = { id = "sub", method = "events.subscribe", params = { subscriptions = SUB.subs } }
    local okj, line = pcall(vim.json.encode, payload)
    if okj then
      pipe:write(line .. "\n")
    end
  end)
end

--- opts = { subscriptions, on_event = fn(name,data), on_status = fn(up,err),
---          on_error = fn(index|nil, err), path? }
function M.subscribe(opts)
  M.close_subscription()
  SUB.subs = opts.subscriptions
  SUB.on_event = opts.on_event
  SUB.on_status = opts.on_status
  SUB.on_error = opts.on_error
  SUB.path = opts.path or M.resolve_path(nil)
  SUB.want = true
  M._sub_open()
end

function M.close_subscription()
  SUB.want = false
  if SUB.reconnect then
    pcall(function()
      SUB.reconnect:stop()
      SUB.reconnect:close()
    end)
    SUB.reconnect = nil
  end
  sub_down(nil)
end

--- Are we currently receiving live events (server acknowledged)?
function M.is_live()
  return SUB.connected and SUB.live
end

return M
