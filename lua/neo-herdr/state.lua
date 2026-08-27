-- neo-herdr: canonical in-memory model of herdr's workspaces + agents.
-- Fed by socket snapshots (agent.list / workspace.list), socket status events,
-- and/or CLI polling. Emits on_change so the dashboard can redraw.

local M = {}

local agents = {} -- key (pane_id or name) -> agent
local workspaces = {} -- key -> workspace
local listeners = {}

local function emit()
  for _, fn in ipairs(listeners) do
    pcall(fn)
  end
end

function M.on_change(fn)
  table.insert(listeners, fn)
end

-- nil-out JSON null (vim.json.decode yields vim.NIL for null).
local function denull(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return v
end

-- Normalise a herdr PANE object (the canonical unit — herdr keeps a pane alive
-- as a plain shell after its agent exits). A pane with a non-null `agent` is a
-- live agent; without one it's a shell we still list (labelled "terminal") so it
-- doesn't vanish from the nav and can still be closed/reused.
local function normalize_agent(a)
  local program = denull(a.agent) or denull(a.program) or denull(a.kind) or denull(a.tool)
  return {
    name = denull(a.name) or denull(a.agent_name), -- explicit rename; usually nil
    title = denull(a.terminal_title_stripped) or denull(a.terminal_title) or denull(a.title),
    label = denull(a.label), -- explicit pane label, if set
    program = program,
    is_shell = program == nil, -- no running agent → a plain shell
    pane_id = a.pane_id or a.pane or a.paneId or a.paneID,
    workspace_id = a.workspace_id or a.workspace or a.ws,
    status = denull(a.agent_status) or denull(a.status) or denull(a.state),
    custom_status = denull(a.custom_status),
    focused = a.focused,
    cwd = denull(a.cwd) or denull(a.foreground_cwd),
    raw = a,
  }
end

local function agent_key(a)
  return a.pane_id or a.name
end

--- Best target string for CLI/socket ops: prefer live name, else pane id.
function M.target_of(a)
  return a.name or a.pane_id
end

--- Human display label for a row. Shells show "terminal" (or an explicit pane
--- label) rather than their long shell-prompt title.
function M.display_name(a)
  if a.name and a.name ~= "" then
    return a.name
  end
  if a.is_shell then
    if a.label and a.label ~= "" then
      return a.label
    end
    return "terminal"
  end
  return a.title or a.pane_id or "?"
end

--- Right-hand column label. Agents show their program (claude/codex/…); shells
--- show the short pane id (e.g. "p1D") so several terminals are distinguishable.
function M.program_label(a)
  if a.program and a.program ~= "" then
    return a.program
  end
  if a.is_shell then
    return (a.pane_id and a.pane_id:match("([^:]+)$")) or "shell"
  end
  return ""
end

--- Replace the full agent set (and optionally workspaces) from a snapshot.
function M.set_snapshot(agent_list, workspace_list)
  agents = {}
  for _, a in ipairs(agent_list or {}) do
    local n = normalize_agent(a)
    local key = agent_key(n)
    if key then
      agents[key] = n
    end
  end
  if workspace_list then
    workspaces = {}
    for _, w in ipairs(workspace_list) do
      local key = w.id or w.workspace_id or w.name
      if key then
        workspaces[key] = {
          id = key,
          name = w.label or w.name or w.title or (w.worktree and w.worktree.repo_name) or key,
          number = w.number,
          raw = w,
        }
      end
    end
  end
  emit()
end

--- Apply a pane.agent_status_changed event (fast path, no full refetch).
function M.apply_status_event(d)
  local key = d.pane_id or d.pane
  if not key then
    return
  end
  local a = agents[key] or { pane_id = key }
  a.workspace_id = d.workspace_id or a.workspace_id
  a.status = d.agent_status or a.status
  a.program = d.agent or a.program
  a.custom_status = d.custom_status
  agents[key] = a
  emit()
end

--- Apply a pane.exited event.
function M.remove_pane(d)
  local key = d and (d.pane_id or d.pane)
  if key and agents[key] then
    agents[key] = nil
    emit()
  end
end

function M.workspace(id)
  return workspaces[id]
end

--- Find an agent by its target string (live name or pane id). Used by the
--- chat header to keep the label + status glyph live as events arrive.
function M.find_target(target)
  if not target then
    return nil
  end
  for _, a in pairs(agents) do
    if a.name == target or a.pane_id == target or M.target_of(a) == target then
      return a
    end
  end
  return nil
end

--- Agents grouped for rendering: returns a sorted list of
--- { ws = {id,name,branch}|nil, agents = { ...sorted } }.
function M.grouped()
  local by_ws = {}
  local order = {}
  for _, a in pairs(agents) do
    local wid = a.workspace_id or "_"
    if not by_ws[wid] then
      by_ws[wid] = {}
      table.insert(order, wid)
    end
    table.insert(by_ws[wid], a)
  end
  table.sort(order, function(x, y)
    local wx, wy = workspaces[x], workspaces[y]
    local nx = (wx and wx.number) or math.huge
    local ny = (wy and wy.number) or math.huge
    if nx ~= ny then
      return nx < ny
    end
    return tostring(x) < tostring(y)
  end)
  local groups = {}
  for _, wid in ipairs(order) do
    local list = by_ws[wid]
    table.sort(list, function(x, y)
      -- Live agents first, plain shells ("terminal") after.
      local xs, ys = x.is_shell and 1 or 0, y.is_shell and 1 or 0
      if xs ~= ys then
        return xs < ys
      end
      return (x.name or x.title or x.pane_id or "") < (y.name or y.title or y.pane_id or "")
    end)
    table.insert(groups, {
      ws = workspaces[wid] or (wid ~= "_" and { id = wid, name = wid } or nil),
      agents = list,
    })
  end
  return groups
end

function M.count()
  local n = 0
  for _ in pairs(agents) do
    n = n + 1
  end
  return n
end

function M.pane_ids()
  local ids = {}
  for _, a in pairs(agents) do
    if a.pane_id then
      table.insert(ids, a.pane_id)
    end
  end
  return ids
end

return M
