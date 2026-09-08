-- neo-herdr: canonical in-memory model of herdr's workspaces + panes/agents.
-- Fed by socket snapshots (pane.list / workspace.list / agent.list), socket
-- status events, and/or CLI polling. Emits on_change so the dashboard can redraw.
--
-- PANES are the unit (herdr keeps a pane alive as a plain shell after its
-- agent exits). Agent NAMES only exist on `agent.list` — `pane.list` never
-- carries them — so snapshots merge the two by pane_id.

local M = {}

local agents = {} -- pane_id -> row
local workspaces = {} -- key -> workspace
local tabs = {} -- tab_id -> { label, number }
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

-- Normalise a herdr PANE object. A pane with a non-null `agent` is a live
-- agent; without one it's a shell we still list (labelled "terminal") so it
-- doesn't vanish from the nav and can be closed/reused.
local function normalize_agent(a)
  local program = denull(a.agent) or denull(a.program) or denull(a.kind) or denull(a.tool)
  return {
    name = denull(a.name) or denull(a.agent_name), -- from agent.list (merged below)
    title = denull(a.terminal_title_stripped) or denull(a.terminal_title) or denull(a.title),
    label = denull(a.label), -- explicit pane label, if set
    program = program,
    is_shell = program == nil, -- no running agent → a plain shell
    pane_id = a.pane_id or a.pane or a.paneId or a.paneID,
    tab_id = denull(a.tab_id),
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

--- Target string for CLI/socket ops. Pane ids are stable for the pane's
--- lifetime, names are not (rename, exit), so always prefer the pane id.
function M.target_of(a)
  return a.pane_id or a.name
end

--- Human display label for a row: explicit agent name, else the live terminal
--- title, else the program. Shells show "terminal" (or an explicit pane label).
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
  if a.title and a.title ~= "" then
    return a.title
  end
  return a.program or a.pane_id or "?"
end

--- Program column: agents show their program (claude/codex/…); shells "shell".
function M.program_label(a)
  if a.program and a.program ~= "" then
    return a.program
  end
  return "shell"
end

--- The tab's display label as herdr shows it (from the snapshot's tab list;
--- tab ids themselves are opaque, e.g. "w1:tC"), or nil.
function M.tab_label(a)
  local t = a.tab_id and tabs[a.tab_id]
  if t then
    return t.label or (t.number and tostring(t.number)) or nil
  end
  return nil
end

--- Short pane id ("w1:p3" → "p3").
function M.short_pane(a)
  return (a.pane_id and a.pane_id:match("([^:]+)$")) or a.pane_id
end

--- Replace the full pane set (and optionally workspaces / agent names / tabs)
--- from a snapshot. `agent_list` (raw agent objects) supplies names;
--- `tab_list` supplies display labels.
function M.set_snapshot(pane_list, workspace_list, agent_list, tab_list)
  if tab_list then
    tabs = {}
    for _, t in ipairs(tab_list) do
      local tid = t.tab_id or t.id
      if tid then
        tabs[tid] = { label = denull(t.label), number = denull(t.number) }
      end
    end
  end
  local names = {}
  for _, ag in ipairs(agent_list or {}) do
    local pid = ag.pane_id or ag.pane
    local n = denull(ag.name) or denull(ag.agent_name)
    if pid and n then
      names[pid] = n
    end
  end
  agents = {}
  for _, a in ipairs(pane_list or {}) do
    local n = normalize_agent(a)
    if n.pane_id and names[n.pane_id] then
      n.name = names[n.pane_id]
    end
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

function M.clear()
  agents = {}
  emit()
end

--- Apply a pane.agent_status_changed event (fast path, no full refetch).
function M.apply_status_event(d)
  local key = d.pane_id or d.pane
  if not key then
    return
  end
  local a = agents[key] or normalize_agent({ pane_id = key })
  a.workspace_id = d.workspace_id or a.workspace_id
  a.status = denull(d.agent_status) or a.status
  local prog = denull(d.agent)
  if prog then
    a.program = prog
    a.is_shell = false
  end
  a.custom_status = denull(d.custom_status)
  if denull(d.title) then
    a.title = d.title
  end
  agents[key] = a
  emit()
end

--- Apply a pane.exited / pane.closed event.
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

--- Find a row by pane id (or, as a fallback, by live name).
function M.find_pane(pane_id)
  if not pane_id then
    return nil
  end
  if agents[pane_id] then
    return agents[pane_id]
  end
  for _, a in pairs(agents) do
    if a.name == pane_id then
      return a
    end
  end
  return nil
end
M.find_target = M.find_pane

--- Rows grouped for rendering: returns a sorted list of
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
      -- Live agents first, plain shells ("terminal") after; then by tab order.
      local xs, ys = x.is_shell and 1 or 0, y.is_shell and 1 or 0
      if xs ~= ys then
        return xs < ys
      end
      local tx = (tabs[x.tab_id or ""] and tabs[x.tab_id].number) or math.huge
      local ty = (tabs[y.tab_id or ""] and tabs[y.tab_id].number) or math.huge
      if tx ~= ty then
        return tx < ty
      end
      return (x.pane_id or "") < (y.pane_id or "")
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

--- Names in use by live agents.
function M.names()
  local out = {}
  for _, a in pairs(agents) do
    if a.name then
      out[a.name] = true
    end
  end
  return out
end

return M
