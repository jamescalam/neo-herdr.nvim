-- :checkhealth neo-herdr
local M = {}

function M.check()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local err = health.error or health.report_error

  start("neo-herdr")

  local nh = require("neo-herdr")
  local herdr = require("neo-herdr.herdr")
  local cmd = nh.config.herdr_cmd or "herdr"
  if vim.fn.executable(cmd) == 1 then
    ok("`" .. cmd .. "` found on PATH")
  else
    err("`" .. cmd .. "` not executable", { "Set config.herdr_cmd to the herdr binary path" })
    return
  end

  local session = herdr.session()
  ok("herdr session: " .. (session or "(default)") .. "  — argv: " .. table.concat(herdr.argv({ "…" }), " "))

  local st = vim.system(herdr.argv({ "status", "--json" }), { text = true }):wait()
  local decoded = st.stdout and st.stdout ~= "" and select(2, pcall(vim.json.decode, st.stdout)) or nil
  if type(decoded) == "table" and type(decoded.server) == "table" then
    if decoded.server.running then
      ok("server running (v" .. tostring(decoded.server.version) .. ") at " .. tostring(decoded.server.socket))
    else
      warn("server not running at " .. tostring(decoded.server.socket), {
        "The dashboard starts one automatically when `server.autostart` is true (default).",
        "Or run: " .. table.concat(herdr.argv({ "server" }), " "),
      })
    end
  else
    warn("`status --json` did not return JSON: " .. tostring(st.stderr or st.stdout))
  end

  local res = vim.system(herdr.argv({ "agent", "list" }), { text = true }):wait()
  if res.code == 0 then
    ok("`agent list` succeeded")
    if res.stdout and res.stdout ~= "" then
      ok("agent list output:\n" .. res.stdout)
    else
      warn("agent list returned no output")
    end
  else
    warn("`agent list` failed: " .. herdr.errinfo(res).text)
  end

  -- Socket (used by the dashboard for live state).
  local sock = require("neo-herdr.socket").resolve_path(nh.config.dashboard.socket_path, session)
  if vim.uv.fs_stat(sock) then
    ok("herdr socket present: " .. sock)
  else
    warn("herdr socket not found at " .. sock, {
      "Dashboard falls back to CLI polling until the server is up.",
    })
  end
end

return M
