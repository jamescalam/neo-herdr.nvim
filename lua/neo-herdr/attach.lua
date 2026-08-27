-- neo-herdr: open a herdr agent's live pane inside a Neovim :terminal.
--
-- We do NOT render terminal frames ourselves. `herdr agent attach <target>`
-- is a real interactive PTY (detach with herdr's own ctrl+b q); Neovim's
-- built-in terminal emulator renders it. This is the whole trick behind the
-- "full multiplexer in nvim" without reimplementing a terminal.

local M = {}

local config = {
  herdr_cmd = "herdr",
  detach_hint = true,
  attach_args = {},
  -- Typing this key on an EMPTY agent prompt drops into Neovim (command line)
  -- instead of going to the agent. Set switch_on_empty=false to disable.
  switch_key = ":",
  switch_on_empty = true,
  -- Window navigation out of the (terminal-mode) chat pane. Each configured key
  -- leaves terminal mode and REPLAYS itself through your normal-mode mappings,
  -- so your own window bindings work from inside the chat. `prefix` defaults to
  -- Vim's window-command prefix (<C-w>), so <C-w>h/j/k/l/w/p all work; add your
  -- own directional keys (e.g. <C-h>) to `keys` if you use those instead.
  nav = {
    enable = true,
    prefix = "<C-w>",
    keys = {},
  },
}

function M.setup(cfg)
  config = vim.tbl_deep_extend("force", config, cfg or {})
end

-- Heuristic: is the agent's input prompt empty? We look only to the LEFT of the
-- terminal cursor for typed word-characters — agent placeholder/ghost text and
-- box borders sit to the right of (or are non-word around) the cursor, so an
-- untouched prompt has no %w to its left.
local function input_is_empty()
  local ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok then
    return false
  end
  local col = cur[2]
  local line = vim.api.nvim_get_current_line()
  return line:sub(1, col):find("%w") == nil
end

-- On an attached agent terminal, make `switch_key` on an empty prompt leave
-- terminal mode into Neovim's command line; otherwise pass it to the agent.
local function setup_switch_key(buf)
  if not config.switch_key or config.switch_on_empty == false then
    return
  end
  vim.keymap.set("t", config.switch_key, function()
    if input_is_empty() then
      local keys = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true) .. config.switch_key
      vim.api.nvim_feedkeys(keys, "n", false)
    else
      local chan = vim.b[buf].terminal_job_id
      if chan then
        vim.api.nvim_chan_send(chan, config.switch_key)
      end
    end
  end, {
    buffer = buf,
    desc = "neo-herdr: " .. config.switch_key .. " on empty prompt → Neovim",
  })
end

-- Let standard window navigation work from inside the chat terminal. Terminal
-- mode swallows keys, so each configured key first leaves terminal mode
-- (<C-\><C-n>) and then replays itself in normal mode — where either Vim's
-- builtin <C-w> prefix or the user's own window mappings take over.
local function setup_nav_keys(buf)
  local nav = config.nav or {}
  if nav.enable == false then
    return
  end
  local esc = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
  local function tmap(lhs)
    if not lhs or lhs == "" then
      return
    end
    local rhs = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.keymap.set("t", lhs, function()
      vim.api.nvim_feedkeys(esc, "n", false) -- leave terminal mode (no remap)
      vim.api.nvim_feedkeys(rhs, "m", false) -- replay key THROUGH user mappings
    end, { buffer = buf, desc = "neo-herdr: window nav (" .. lhs .. ")" })
  end
  tmap(nav.prefix)
  for _, k in ipairs(nav.keys or {}) do
    tmap(k)
  end
end

-- Open a terminal running `cmd` in the CURRENT window. jobstart({term=true})
-- (and termopen) require the current buffer to be a clean, empty, unmodified
-- one, so we `:enew` first to guarantee that regardless of what the window held
-- (a split's scratch, the chat placeholder, or a user file — hidden, not lost).
-- Returns (buf, jobid).
local function term_open(cmd)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  local jid
  if vim.fn.has("nvim-0.11") == 1 then
    jid = vim.fn.jobstart(cmd, { term = true })
  else
    jid = vim.fn.termopen(cmd)
  end
  return buf, jid
end

local function attach_cmd(target)
  local cmd = { config.herdr_cmd, "agent", "attach", target }
  for _, a in ipairs(config.attach_args or {}) do
    table.insert(cmd, a)
  end
  return cmd
end

--- Open one agent's live terminal. split = "vsplit" | "split" | "tab" | "here".
function M.attach(target, split)
  if not target or target == "" then
    vim.notify("[neo-herdr] no target to attach", vim.log.levels.WARN)
    return
  end
  split = split or "vsplit"
  if split == "vsplit" then
    vim.cmd("botright vsplit")
  elseif split == "split" then
    vim.cmd("botright split")
  elseif split == "tab" then
    vim.cmd("tabnew")
  end -- "here" reuses current window

  local buf, jid = term_open(attach_cmd(target))
  if jid and jid > 0 then
    vim.b[buf].neo_herdr_target = target
    vim.b[buf].neo_herdr = true -- marker for tabline/bufferline filters
    -- Keep the agent terminal out of the buffer list (`:enew` creates a listed
    -- buffer) so it doesn't show up in bufferline/:ls as a stray "tab".
    pcall(function()
      vim.bo[buf].buflisted = false
    end)
    pcall(vim.api.nvim_buf_set_name, buf, "herdr://attach/" .. target)
    setup_switch_key(buf)
    setup_nav_keys(buf)
    if config.detach_hint then
      vim.notify("[neo-herdr] attached " .. target .. " — detach with ctrl+b q, or close the split")
    end
    vim.cmd("startinsert")
  else
    vim.notify("[neo-herdr] failed to launch attach for " .. target, vim.log.levels.ERROR)
  end
  return buf
end

--- Tile several agents as terminal panes in a fresh tab (columns, wrapping to
--- a second row past `cols`). This is the "full multiplexer" layout.
function M.tile(targets, cols)
  targets = targets or {}
  if #targets == 0 then
    vim.notify("[neo-herdr] no agents to tile", vim.log.levels.WARN)
    return
  end
  cols = cols or math.min(#targets, 3)

  vim.cmd("tabnew")
  -- first pane reuses the new tab's window
  M.attach(targets[1], "here")
  for i = 2, #targets do
    if (i - 1) % cols == 0 then
      -- start a new row: go to first window, split below
      vim.cmd("wincmd t")
      vim.cmd("botright split")
    else
      vim.cmd("vsplit")
    end
    M.attach(targets[i], "here")
  end
  vim.cmd("wincmd =")
end

return M
