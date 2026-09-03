-- neo-herdr: GitHub-style inline markers for PENDING review comments.
-- While a comment sits in the batch (added but not yet sent), we draw it in the
-- source buffer: a gutter sign, a subtle highlight over the commented range, and
-- the note itself as virtual lines beneath it. Extmarks track edits, so the
-- marker follows the code. Sending (or clearing) the batch removes the markers.

local M = {}

local NS = vim.api.nvim_create_namespace("neo_herdr_comments")
local placed = {} -- { { buf, id }, ... } for teardown

local function define_hl()
  local function link(name, target)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
  end
  link("NeoHerdrCommentSign", "DiagnosticInfo") -- gutter bar + left rail
  link("NeoHerdrCommentHead", "Title") -- "pending review" header
  link("NeoHerdrCommentBody", "Comment") -- the note text
  link("NeoHerdrCommentLine", "CursorLine") -- subtle range background
end

local function build_vlines(note)
  local SIGN = "NeoHerdrCommentSign"
  local vlines = {
    { { "▌ ", SIGN }, { "💬 pending review comment", "NeoHerdrCommentHead" } },
  }
  for _, nl in ipairs(vim.split(note or "", "\n", { plain = true })) do
    vlines[#vlines + 1] = { { "▌ ", SIGN }, { nl, "NeoHerdrCommentBody" } }
  end
  return vlines
end

-- Core: place the marker over [s0, e0] (0-indexed buffer lines) in `buf`.
local function set_marker(buf, s0, e0, note)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local last = vim.api.nvim_buf_line_count(buf)
  s0 = math.max(0, math.min(s0, last - 1))
  e0 = math.max(s0, math.min(e0, last - 1))
  local end_line = vim.api.nvim_buf_get_lines(buf, e0, e0 + 1, false)[1] or ""
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, NS, s0, 0, {
    end_row = e0,
    end_col = #end_line,
    hl_group = "NeoHerdrCommentLine",
    hl_eol = true,
    sign_text = "▌",
    sign_hl_group = "NeoHerdrCommentSign",
    virt_lines = build_vlines(note),
    virt_lines_above = false,
  })
  if ok then
    placed[#placed + 1] = { buf = buf, id = id }
    return id
  end
end

-- Draw the marker for one comment. c = { bufnr, s, e, note }. Stashes the
-- extmark handle on c (c._mark) so it can be removed individually.
function M.place(c)
  define_hl()
  local id = set_marker(c.bufnr, (c.s or 1) - 1, (c.e or c.s or 1) - 1, c.note)
  if id then
    c._mark = { buf = c.bufnr, id = id }
  end
end

-- Place a marker at an explicit 0-indexed line (used by the review view, whose
-- diff buffer lines don't correspond to file lines).
function M.place_line(buf, line0, note)
  define_hl()
  return set_marker(buf, line0, line0, note)
end

-- Drop every marker in one buffer (the review re-renders diffs in place).
function M.clear_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
  end
  for i = #placed, 1, -1 do
    if placed[i].buf == buf then
      table.remove(placed, i)
    end
  end
end

-- Remove a single comment's marker (e.g. when it's individually removed).
function M.remove(c)
  local m = c and c._mark
  if m and vim.api.nvim_buf_is_valid(m.buf) then
    pcall(vim.api.nvim_buf_del_extmark, m.buf, NS, m.id)
  end
  if c then
    c._mark = nil
  end
end

-- Remove every pending marker (on send or clear).
function M.clear()
  for _, m in ipairs(placed) do
    if vim.api.nvim_buf_is_valid(m.buf) then
      pcall(vim.api.nvim_buf_del_extmark, m.buf, NS, m.id)
    end
  end
  placed = {}
end

return M
