-- neo-herdr: client for herdr's Unix socket (NDJSON JSON-RPC).
--
-- IMPORTANT: herdr's socket is one-request-per-connection — it closes the pipe
-- after answering a single request. So each request/response call opens its own
-- short-lived connection (M.request_once). Event subscriptions are the
-- exception: events.subscribe keeps its connection open and streams
-- {"event","data"} lines, so that lives on a dedicated persistent connection
-- (M.subscribe) with auto-reconnect + re-subscribe.

local uv = vim.uv or vim.loop

local M = {}

--- Resolve the socket path following herdr's documented precedence.
function M.resolve_path(explicit)
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
  local session = vim.env.HERDR_SESSION
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
  buf = "",
  subs = nil,
  on_event = nil,
  on_status = nil,
  path = nil,
  reconnect = nil,
}

local function sub_down(err)
  SUB.connected = false
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
    if SUB.on_status then
      vim.schedule(function()
        SUB.on_status(true)
      end)
    end
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
            local ok, msg = pcall(vim.json.decode, line)
            if ok and type(msg) == "table" and msg.event and SUB.on_event then
              local name, data = msg.event, msg.data or {}
              vim.schedule(function()
                SUB.on_event(name, data)
              end)
            end
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

--- opts = { subscriptions, on_event = fn(name,data), on_status = fn(up,err), path? }
function M.subscribe(opts)
  M.close_subscription()
  SUB.subs = opts.subscriptions
  SUB.on_event = opts.on_event
  SUB.on_status = opts.on_status
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

--- Are we currently receiving live events?
function M.is_live()
  return SUB.connected
end

return M
