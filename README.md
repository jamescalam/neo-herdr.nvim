# neo-herdr.nvim

A Neovim client for [herdr](https://herdr.dev) — drive the whole herd without
leaving your editor. Two planes, each doing what it's best at:

- **Control plane (native buffers):** a live dashboard of workspaces/agents plus
  actions — send prompts, batch review comments, read output, send keys — over
  herdr's CLI and Unix socket.
- **Terminal plane (`:terminal`):** attach an agent's real PTY with
  `herdr agent attach`, rendered by Neovim's own terminal. No terminal emulator
  is reimplemented; nvim + herdr do the rendering.

## Requirements

- Neovim 0.10+ (`vim.system`, `vim.uv`, `vim.ui.*`)
- `herdr` on `PATH` (0.7.5+). Live events need the socket; otherwise it falls
  back to CLI polling.

## Install (lazy.nvim)

```lua
{
  dir = "~/Documents/aurelio/neo-herdr.nvim",
  name = "neo-herdr",
  lazy = false,
  config = function() require("neo-herdr").setup() end,
}
```

## The herd workspace

`<leader>hd` (or `:NeoHerdrDashboard`) opens a **dedicated tabpage** — fully
independent of your other tabs — laid out like an IDE: your editor / cursor
window keeps most of the space, with a compact herd area (chat + nav) alongside.

```
┌ editor / cursor window ─────────────┬ agent chat ┊ HERDR ┐
│                                     │ (empty —   │▾ spark │
│  open files here, :Neotree, etc.    │  pick an   │ ○ Test │
│                                     │  agent,    │▸○ API… │
│  ~70% of the tab                    │  <CR>)     │▾ acta  │
│                                     │            │ ○ Plan │
└─────────────────────────────────────┴────────────┴────────┘
                                       └──── herd ~30% ──────┘
```

The herd area defaults to ~30% of the tab on the **right** (chat 70% / nav 30%
inside it); tune with `dashboard.herd_width`, `dashboard.nav_width`,
`dashboard.side` (`"right"`/`"left"`), and `dashboard.editor = false` to drop the
editor pane. Widths accept a fraction (`0.30`) or absolute columns (`44`).

Selecting an agent (`<CR>`) opens its live terminal in the middle **chat**
window, with a header (winbar) across the top showing `workspace › ● agent`.
Its colors match the dashboard on the right — workspace, status glyph, and name
use the same highlight groups — so the header names the exact row you selected,
and its status glyph stays live. Toggling the tab off (`<leader>hd` again or
`q`) closes it and returns you to your work — your other tabs are never touched.

The dividers between the herd tab's windows are drawn **dotted** (nvim calls
these "windows"; "pane" is tmux's term) to signal they're one grouped area,
distinct from the solid separators in your normal tabs.

A small **notifier** pill (Opera-GX style) floats at the left edge of the chat —
a narrow, fixed, non-focusable, **transparent** rounded outline (it blends with
the editor like any window) holding three circles that aggregate the whole
herd's state: top `●` **red** if any agent is blocked, mid `●` **amber** if any
is working, bottom `●` **green** if any is done (empty `○` otherwise). The
outline follows your `WinSeparator` color; disable with
`dashboard.notifier = false`.

Agents are labelled by their live terminal title; the focused agent is marked
`▸`. The status glyph is **colored by state** (like herdr's own UI): amber
`●` working · grey `○` idle · red `◉` blocked · green `✓` done · dim `·` no
agent. The plugin sets these (`NeoHerdrWorking/Idle/Blocked/Done/Unknown`) on
open and re-applies on `:colorscheme`; to recolor, set your own in a
`ColorScheme` autocmd. State is pushed live over the socket (`events.subscribe`) with a CLI
poll as a backstop; the header shows `socket ●` (live events), `socket`, or
`cli-poll`.

The nav lists **panes**, not just running agents — the same set herdr shows as
tabs. When an agent exits (e.g. `claude` `/exit`), herdr keeps its pane alive as
a plain shell, so the row **stays** in the nav labelled `terminal` (with its
short pane id, e.g. `p1D`, in the right column) instead of vanishing — you can
still `<CR>` to view it or `x` to close it. Agent rows sort above `terminal`
rows within each workspace.

Row actions (cursor on an agent):

| Key   | Action                                                        |
| ----- | ------------------------------------------------------------- |
| `<CR>`| Open the agent's live chat in the chat window (reuses it)     |
| `n`   | New chat — create a fresh tab and start an agent in it (prompts kind/name)|
| `x`   | Close this chat / terminal (`herdr pane close`, with a confirm) |
| `c`   | Rename this chat (`herdr agent rename`)                       |
| `p`   | Prompt the agent                                              |
| `r`   | Read recent output into a scratch buffer                      |
| `a`   | Send keys (e.g. `enter` to unblock)                           |
| `R`   | Refresh now                                                   |
| `?`   | Toggle the keybindings help pane                              |
| `q`   | Close the whole herd (the dashboard/tab)                      |

Note `q` closes the entire herd tab, while **`x`** closes just the single chat
under the cursor. A short **help pane** under the chat lists these bindings
(toggle with `?`, or `dashboard.help = false` to hide by default); it's rendered
from the same table that binds the keys, so it always matches what's live.

### Switching between agent and Neovim

Inside an attached agent terminal, pressing **`:` on an empty prompt** drops you
into Neovim's command line (leaves terminal mode) instead of sending `:` to the
agent — a vim-like escape hatch back to the editor. Once you've typed anything,
`:` passes straight through to the agent. Configure via `attach.switch_key` /
`attach.switch_on_empty`. (Emptiness is detected heuristically from typed
characters left of the cursor; agent placeholder/ghost text doesn't count.)

**Window navigation.** Terminal mode normally swallows your keys, so from inside
the chat you can still use Vim's window commands: `<C-w>h/j/k/l/w/p` jump to the
editor, the dashboard, or out to another window — each leaves terminal mode and
replays through your own normal-mode mappings. If you navigate with directional
keys instead (e.g. `<C-h>`), add them to `attach.nav.keys` and they'll work the
same way; set `attach.nav.enable = false` to opt out entirely.

## Review-comment workflow (editor side)

| Keys         | Action                                                    |
| ------------ | --------------------------------------------------------- |
| `<leader>hi` | Jump into the open chat window and start typing           |
| `<leader>hc` | Add comment — current line (normal) / selection (visual)  |
| `<leader>hs` | Send the batch to the active chat agent (else pinned/picked), then clear |
| `<leader>hl` / `<leader>hx` | List / clear pending comments              |
| `<leader>ha` | Pick & pin the target agent                               |
| `<leader>hr` | Read recent output of the resolved agent                  |
| `<leader>hd` | Toggle the dashboard                                      |
| `<leader>ht` | Tile all agents as terminal panes (full multiplexer)      |

A review comment carries the **filepath, line/range, the code snippet, and your
note** (see `default_format`); `<leader>hs` delivers the whole batch to the agent
shown in the chat window — so it lands in the same conversation you're looking at
— and clears the pending comments once the send succeeds.

Commands: `:NeoHerdrComment` (range-aware), `:NeoHerdrSend`,
`:NeoHerdrMessage [text]`, `:NeoHerdrList`, `:NeoHerdrClear`,
`:NeoHerdrPickAgent`, `:NeoHerdrRead`, `:NeoHerdrDashboard`, `:NeoHerdrChat`,
`:NeoHerdrAttach [target]`, `:NeoHerdrTile`.

## Configuration (defaults)

```lua
require("neo-herdr").setup({
  herdr_cmd = "herdr",
  agent = nil,            -- pin a target (name or pane id)
  prompt = { wait = false, until_states = {}, timeout = nil },
  snippet_max = 40,
  read = { source = "recent-unwrapped", lines = 200 },
  dashboard = {
    side = "right",       -- herd area (chat+nav) on the "right" or "left"
    herd_width = 0.30,    -- herd area as a fraction of the tab (<=1) or columns (>1)
    nav_width = 0.30,     -- nav as a fraction of the herd area (<=1) or columns (>1)
    nav_min = 12,         -- floor for the nav column, in columns
    editor = true,        -- include an editor/cursor window taking the rest
    hide_tab = true,      -- hide the herd tabpage from the built-in tabline
    help = true,          -- keybindings help pane under the chat (toggle with ?)
    notifier = true,      -- Opera-GX-style notifier float (blocked/working/done)
    use_socket = true,    -- prefer socket; false = CLI poll only
    socket_path = nil,    -- override $HERDR_SOCKET_PATH resolution
    auto_refresh = true,  -- timer + manual; false = manual only
    poll_interval = 4000, -- ms (backstop / fallback)
    chat_header = true,   -- winbar on the chat window (workspace › agent + status)
    separators = { dotted = true, vert = "┊" }, -- dotted = false keeps solid dividers
  },
  attach = {
    detach_hint = true,
    attach_args = {},        -- e.g. { "--takeover" }
    switch_key = ":",        -- on an EMPTY agent prompt, drops into Neovim
    switch_on_empty = true,  -- set false to always pass the key to the agent
    nav = { enable = true, prefix = "<C-w>", keys = {} }, -- window nav from chat
  },
  keymaps = { prefix = "<leader>h", add="c", send="s", list="l", clear="x",
              pick_agent="a", read="r", dashboard="d", tile="t" },
  -- format = function(batch) return "..." end,
})
```

## How it talks to herdr

- **State:** Unix socket at `$HERDR_SOCKET_PATH` (or
  `~/.config/herdr[/sessions/<name>]/herdr.sock`), NDJSON JSON-RPC. The socket is
  **one-request-per-connection**, so snapshots (`pane.list` / `workspace.list`)
  open a fresh connection each; a separate persistent connection carries
  `events.subscribe` for pushed `pane.agent_status_changed` / `pane.exited`
  (re-subscribes when the pane set changes). No socket → CLI `agent list` poll.
  The header shows `socket ●` (live events), `socket`, or `cli-poll`.
- **Actions:** `herdr agent prompt`, `agent read`, `agent send-keys`.
- **Live panes:** `herdr agent attach <target>` in a `:terminal` split; detach
  with herdr's `ctrl+b q` or just close the split.

## Health check

```
:checkhealth neo-herdr
```

Verifies `herdr` on PATH, dumps raw `agent list`, and reports whether the socket
is present.

> **Field-shape caveat:** herdr's public docs pin down the socket *methods* and
> event shapes but not every field of the agent objects. Normalisation lives in
> `state.lua` (`normalize_agent`) and `herdr.lua` (`extract_agents`); if the
> dashboard mislabels something, check `:checkhealth` output and adjust those.
