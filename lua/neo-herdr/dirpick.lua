-- neo-herdr: native floating directory picker. A one-line path prompt over a
-- fuzzy-filtered list of the directories under that path, all plain Neovim
-- (floats, a prompt buffer, matchfuzzypos). No picker plugin involved.
--
-- The prompt holds a path. Everything up to its last `/` is the directory
-- being browsed (relative to the starting root, or absolute / `~`); what
-- follows the last `/` filters the list. So `../` browses the parent,
-- `../../` its parent, `apps/` a child, `~/code/` anywhere.
--
--   <Tab> / <Right>  complete the selection into the prompt (browse into it)
--   <CR>             pick the selection (or the typed path, if it exists)
--   <BS>             with nothing to filter: go up one directory
--   <S-Tab>          go up one directory
--   <C-n>/<C-p>, <Down>/<Up>, <C-j>/<C-k>  move
--   <Esc>/<C-c>      cancel

local M = {}

local NS = vim.api.nvim_create_namespace("neo_herdr_dirpick")
local AUG = "neo_herdr_dirpick"
local PROMPT = "› "
local SELF = "." -- the row that means "this directory itself"

M.defaults = {
  depth = 3, -- how deep below the browsed directory to list
  hidden = false, -- include dot-directories
  ignore = { ".git", "node_modules", ".venv", "venv", "__pycache__", ".cache", "dist", "build", "target" },
  max = 5000, -- stop listing past this many directories
}

-- ── Paths ────────────────────────────────────────────────────────────────────

local function basename(p)
  return p:match("([^/]+)/?$") or p
end

--- Split a prompt into the directory part (ending in `/`, or "") and the
--- filter fragment after it.
local function split_prompt(text)
  local dir, frag = text:match("^(.*/)([^/]*)$")
  if not dir then
    return "", text
  end
  return dir, frag
end

--- Absolute directory a prompt's directory part points at, relative to
--- `base`. `..` and `~` are resolved. Trailing slash stripped (except "/").
local function resolve(base, dir)
  local p
  if dir == "" then
    p = base
  elseif dir:sub(1, 1) == "/" or dir:sub(1, 1) == "~" then
    p = dir
  else
    p = vim.fs.joinpath(base, dir)
  end
  p = vim.fs.normalize(p)
  if #p > 1 then
    p = p:gsub("/+$", "")
  end
  return p
end

--- Directory part with its last component removed: the parent of what it
--- browses. `..`-only parts (and "") go up by appending another `../`.
local function parent_dir(dir)
  if dir:match("^/+$") then
    return "/"
  end
  local trimmed = dir:gsub("/+$", "")
  local last = basename(trimmed)
  if trimmed == "" or trimmed == "~" or last == ".." or last == "." then
    return dir .. "../"
  end
  local up = trimmed:match("^(.*/)[^/]+$") or ""
  return up
end

-- ── Listing / filtering ──────────────────────────────────────────────────────

--- All directories under `root` (relative paths), sorted by depth then name.
--- Returns list, truncated:boolean.
local function scan(root, o)
  local ignore = {}
  for _, n in ipairs(o.ignore or {}) do
    ignore[n] = true
  end
  local function allowed(rel)
    local b = basename(rel)
    if ignore[b] then
      return false
    end
    if not o.hidden and b:sub(1, 1) == "." then
      return false
    end
    return true
  end
  local out, truncated = {}, false
  local ok = pcall(function()
    for name, t in vim.fs.dir(root, { depth = o.depth or 3, skip = allowed }) do
      if t == "link" and allowed(name) then
        -- symlinked directories are listed (not descended into)
        local st = vim.uv.fs_stat(vim.fs.joinpath(root, name))
        t = st and st.type or t
      end
      if t == "directory" and allowed(name) then
        out[#out + 1] = name
        if #out >= (o.max or 5000) then
          truncated = true
          return
        end
      end
    end
  end)
  if not ok then
    return {}, false
  end
  table.sort(out, function(a, b)
    local da, db = select(2, a:gsub("/", "")), select(2, b:gsub("/", ""))
    if da ~= db then
      return da < db
    end
    return a < b
  end)
  return out, truncated
end

--- Filter `items` by `query`. Returns list of { text, cols } where cols are
--- 0-based byte columns of the matched characters (empty for no query).
local function filter(items, query)
  local res = {}
  if query == "" then
    res[1] = { text = SELF, cols = {} }
    for _, it in ipairs(items) do
      res[#res + 1] = { text = it, cols = {} }
    end
    return res
  end
  local m = vim.fn.matchfuzzypos(items, query)
  local texts, positions = m[1], m[2]
  for i, text in ipairs(texts) do
    local cols = {}
    for _, ci in ipairs(positions[i] or {}) do
      cols[#cols + 1] = vim.str_byteindex(text, ci)
    end
    res[#res + 1] = { text = text, cols = cols }
  end
  return res
end

-- ── UI ───────────────────────────────────────────────────────────────────────

local function tilde(p)
  return vim.fn.fnamemodify(p, ":~")
end

-- The dashboard defines the NeoHerdr* groups when it opens; give them
-- defaults here so the picker is styled even before the herd tab has been
-- shown (`default = true` never overrides the dashboard's own definitions).
local function ensure_highlights()
  for name, target in pairs({
    NeoHerdrHeader = "Title",
    NeoHerdrKey = "Title",
    NeoHerdrDim = "NonText",
    NeoHerdrSecondary = "Comment",
    NeoHerdrWs = "Directory",
    NeoHerdrCurrent = "Visual",
    NeoHerdrBlocked = "DiagnosticError",
  }) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local Picker = {}
Picker.__index = Picker

function Picker:geometry()
  local cols, lines = vim.o.columns, vim.o.lines
  local width = math.max(40, math.min(math.floor(cols * 0.6), cols - 4))
  local list_h = math.max(5, math.min(math.floor(lines * 0.5), lines - 8))
  local total = list_h + 1 + 4 -- list + prompt + two borders each
  local row = math.max(0, math.floor((lines - total) / 2))
  local col = math.floor((cols - width) / 2)
  return width, list_h, row, col
end

function Picker:open_windows()
  local width, list_h, row, col = self:geometry()

  self.list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.list_buf].bufhidden = "wipe"
  vim.bo[self.list_buf].buftype = "nofile"
  vim.bo[self.list_buf].filetype = "neoherdr-dirpick"
  self.list_win = vim.api.nvim_open_win(self.list_buf, false, {
    relative = "editor",
    row = row + 3,
    col = col,
    width = width,
    height = list_h,
    style = "minimal",
    border = "rounded",
    footer = { { " <Tab> complete  <CR> pick  <BS> up  <Esc> cancel ", "NeoHerdrDim" } },
    footer_pos = "right",
    zindex = 60,
    noautocmd = true,
  })
  vim.wo[self.list_win].winhighlight = "NormalFloat:Normal,FloatBorder:NeoHerdrDim,CursorLine:NeoHerdrCurrent"
  vim.wo[self.list_win].cursorline = true
  vim.wo[self.list_win].wrap = false
  vim.wo[self.list_win].scrolloff = 2

  self.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.prompt_buf].bufhidden = "wipe"
  vim.bo[self.prompt_buf].buftype = "prompt"
  vim.bo[self.prompt_buf].filetype = "neoherdr-dirpick-prompt"
  vim.fn.prompt_setprompt(self.prompt_buf, PROMPT)
  self.prompt_win = vim.api.nvim_open_win(self.prompt_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = { { " " .. self.title .. " ", "NeoHerdrHeader" } },
    title_pos = "left",
    zindex = 61,
    noautocmd = true,
  })
  vim.wo[self.prompt_win].winhighlight = "NormalFloat:Normal,FloatBorder:NeoHerdrDim"
end

function Picker:text()
  if not (self.prompt_buf and vim.api.nvim_buf_is_valid(self.prompt_buf)) then
    return ""
  end
  local line = vim.api.nvim_buf_get_lines(self.prompt_buf, -2, -1, false)[1] or ""
  return line:sub(#PROMPT + 1)
end

function Picker:set_text(text)
  vim.api.nvim_buf_set_lines(self.prompt_buf, 0, -1, false, { PROMPT .. text })
  vim.api.nvim_win_set_cursor(self.prompt_win, { 1, #PROMPT + #text })
  self:sync()
end

--- Re-derive the browsed directory from the prompt, rescan if it changed,
--- and redraw. Called on every prompt change.
function Picker:sync()
  local dir, frag = split_prompt(self:text())
  local root = resolve(self.base, dir)
  if root ~= self.root then
    self.root = root
    self.valid = vim.fn.isdirectory(root) == 1
    self.items, self.truncated = self.valid and scan(root, self.opts) or {}, false
    local label = self.valid and (" " .. tilde(root) .. (self.truncated and "  (first " .. #self.items .. ")" or "") .. " ")
      or (" " .. tilde(root) .. "  (not a directory) ")
    if self.list_win and vim.api.nvim_win_is_valid(self.list_win) then
      vim.api.nvim_win_set_config(self.list_win, {
        title = { { label, self.valid and "NeoHerdrWs" or "NeoHerdrBlocked" } },
        title_pos = "left",
      })
    end
    self.sel = 1
  end
  if frag ~= self.frag then
    self.sel = 1
  end
  self.frag = frag
  self:render()
end

function Picker:render()
  self.rows = self.valid and filter(self.items, self.frag) or {}
  local lines = {}
  for i, r in ipairs(self.rows) do
    lines[i] = r.text == SELF and "./  (this directory)" or (r.text .. "/")
  end
  if #lines == 0 then
    lines[1] = self.valid and "(no matching directories)" or "(not a directory)"
  end
  vim.bo[self.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.list_buf, 0, -1, false, lines)
  vim.bo[self.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.list_buf, NS, 0, -1)
  for i, r in ipairs(self.rows) do
    if r.text == SELF then
      vim.api.nvim_buf_set_extmark(self.list_buf, NS, i - 1, 3, { end_col = #lines[i], hl_group = "NeoHerdrDim" })
    else
      -- dim the parent path, keep the leaf bright
      local leaf = basename(r.text)
      local leaf_start = #r.text - #leaf
      if leaf_start > 0 then
        vim.api.nvim_buf_set_extmark(self.list_buf, NS, i - 1, 0, { end_col = leaf_start, hl_group = "NeoHerdrSecondary" })
      end
      for _, c in ipairs(r.cols) do
        vim.api.nvim_buf_set_extmark(self.list_buf, NS, i - 1, c, { end_col = c + 1, hl_group = "NeoHerdrKey" })
      end
    end
  end
  if #self.rows == 0 then
    vim.api.nvim_buf_set_extmark(self.list_buf, NS, 0, 0, { end_col = #lines[1], hl_group = "NeoHerdrDim" })
  end
  self.sel = math.max(1, math.min(self.sel or 1, #self.rows))
  self:show_selection()
  -- count, right-aligned on the prompt line
  vim.api.nvim_buf_clear_namespace(self.prompt_buf, NS, 0, -1)
  local count = string.format("%d/%d", #self.rows, #self.items + (self.valid and 1 or 0))
  pcall(vim.api.nvim_buf_set_extmark, self.prompt_buf, NS, 0, 0, {
    virt_text = { { count .. " ", "NeoHerdrDim" } },
    virt_text_pos = "right_align",
  })
end

function Picker:show_selection()
  if #self.rows == 0 then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, self.list_win, { self.sel, 0 })
end

function Picker:move(delta)
  if #self.rows == 0 then
    return
  end
  self.sel = ((self.sel - 1 + delta) % #self.rows) + 1
  self:show_selection()
end

--- Absolute path of the selected row, or nil.
function Picker:selected_path()
  local r = self.rows[self.sel]
  if not r or not self.valid then
    return nil
  end
  if r.text == SELF then
    return self.root
  end
  return vim.fs.joinpath(self.root, r.text)
end

--- The whole prompt as a path, if it names an existing directory.
function Picker:typed_dir()
  local t = self:text()
  if t == "" then
    return nil
  end
  local p = resolve(self.base, t)
  if vim.fn.isdirectory(p) == 1 then
    return p
  end
  return nil
end

--- <Tab>/<Right>: put the selection into the prompt as a directory to browse.
function Picker:complete()
  local r = self.rows[self.sel]
  if not r or not self.valid then
    return
  end
  local dir = split_prompt(self:text())
  if r.text == SELF then
    if dir ~= self:text() then
      self:set_text(dir) -- drop a filter that matched nothing better
    end
    return
  end
  self:set_text(dir .. r.text .. "/")
end

--- <S-Tab> / <BS> on an empty filter: browse the parent directory.
function Picker:up()
  local dir = split_prompt(self:text())
  local from = basename(self.root)
  self:set_text(parent_dir(dir))
  -- land on the directory we came from
  for i, r in ipairs(self.rows) do
    if r.text == from then
      self.sel = i
      break
    end
  end
  self:show_selection()
end

function Picker:accept()
  local p = self:selected_path() or self:typed_dir()
  if not p then
    return -- nothing to pick; stay open
  end
  self:close()
  self.cb(p)
end

function Picker:close()
  if self.closed then
    return
  end
  self.closed = true
  pcall(vim.api.nvim_del_augroup_by_name, AUG)
  vim.cmd("stopinsert")
  for _, w in ipairs({ self.prompt_win, self.list_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if self.prev_win and vim.api.nvim_win_is_valid(self.prev_win) then
    pcall(vim.api.nvim_set_current_win, self.prev_win)
  end
end

function Picker:cancel()
  if self.closed then
    return
  end
  self:close()
  self.cb(nil)
end

function Picker:install_keys()
  local b = self.prompt_buf
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = b, nowait = true, silent = true })
  end
  local both = { "i", "n" }
  map(both, "<CR>", function()
    self:accept()
  end)
  map(both, "<Esc>", function()
    self:cancel()
  end)
  map(both, "<C-c>", function()
    self:cancel()
  end)
  map("n", "q", function()
    self:cancel()
  end)
  for _, k in ipairs({ "<C-n>", "<Down>", "<C-j>" }) do
    map(both, k, function()
      self:move(1)
    end)
  end
  for _, k in ipairs({ "<C-p>", "<Up>", "<C-k>" }) do
    map(both, k, function()
      self:move(-1)
    end)
  end
  map("n", "j", function()
    self:move(1)
  end)
  map("n", "k", function()
    self:move(-1)
  end)
  for _, k in ipairs({ "<Tab>", "<Right>", "<C-l>" }) do
    map(both, k, function()
      self:complete()
    end)
  end
  map(both, "<S-Tab>", function()
    self:up()
  end)
  -- <BS> with nothing to filter goes up a directory; otherwise it is a
  -- backspace. (expr mappings run under textlock, so the up() is scheduled.)
  for _, k in ipairs({ "<BS>", "<C-h>" }) do
    vim.keymap.set("i", k, function()
      local _, frag = split_prompt(self:text())
      if frag == "" then
        vim.schedule(function()
          if not self.closed then
            self:up()
          end
        end)
        return ""
      end
      return "<BS>"
    end, { buffer = b, expr = true, nowait = true, silent = true })
  end

  local g = vim.api.nvim_create_augroup(AUG, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = g,
    buffer = b,
    callback = function()
      self:sync()
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = g,
    buffer = b,
    callback = function()
      -- Leaving the prompt (e.g. clicking elsewhere) cancels.
      vim.schedule(function()
        if not self.closed and vim.api.nvim_get_current_win() ~= self.prompt_win then
          self:cancel()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = g,
    callback = function()
      if self.closed then
        return
      end
      local width, list_h, row, col = self:geometry()
      pcall(vim.api.nvim_win_set_config, self.prompt_win, { relative = "editor", row = row, col = col, width = width, height = 1 })
      pcall(vim.api.nvim_win_set_config, self.list_win, { relative = "editor", row = row + 3, col = col, width = width, height = list_h })
    end,
  })
end

--- Open the picker. opts = { root, title, depth, hidden, ignore, max }.
--- cb(path) with an absolute directory path, or cb(nil) on cancel.
function M.pick(opts, cb)
  opts = vim.tbl_extend("force", M.defaults, opts or {})
  local base = resolve(vim.fn.getcwd(), opts.root or "")
  if vim.fn.isdirectory(base) ~= 1 then
    base = resolve(vim.fn.getcwd(), "")
  end
  local self = setmetatable({
    opts = opts,
    cb = cb or function() end,
    title = opts.title or "Directory",
    prev_win = vim.api.nvim_get_current_win(),
    base = base,
    sel = 1,
    rows = {},
    frag = "",
  }, Picker)
  ensure_highlights()
  self:open_windows()
  self:install_keys()
  self:sync()
  vim.cmd("startinsert!")
  return self
end

-- exposed for tests
M._scan = scan
M._filter = filter
M._split = split_prompt
M._resolve = resolve
M._parent_dir = parent_dir

return M
