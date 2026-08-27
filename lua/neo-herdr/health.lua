-- :checkhealth neo-herdr
local M = {}

function M.check()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local err = health.error or health.report_error

  start("neo-herdr")

  local cmd = require("neo-herdr").config.herdr_cmd or "herdr"
  if vim.fn.executable(cmd) == 1 then
    ok("`" .. cmd .. "` found on PATH")
  else
    err("`" .. cmd .. "` not executable", { "Set config.herdr_cmd to the herdr binary path" })
    return
  end

  local res = vim.system({ cmd, "agent", "list" }, { text = true }):wait()
  if res.code == 0 then
    ok("`" .. cmd .. " agent list` succeeded")
    if res.stdout and res.stdout ~= "" then
      ok("agent list output:\n" .. res.stdout)
    else
      warn("agent list returned no output (no live agents, or run inside a herdr workspace)")
    end
  else
    warn("`agent list` failed (code " .. tostring(res.code) .. "): " .. (res.stderr or ""))
  end

  -- Socket (used by the dashboard for live state).
  local sock = require("neo-herdr.socket").resolve_path(require("neo-herdr").config.dashboard.socket_path)
  if vim.uv.fs_stat(sock) then
    ok("herdr socket present: " .. sock)
  else
    warn("herdr socket not found at " .. sock, {
      "Dashboard falls back to CLI polling.",
      "Set $HERDR_SOCKET_PATH or run nvim from inside a herdr session for live events.",
    })
  end
end

return M
