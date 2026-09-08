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
- `herdr` on `PATH` (0.8.0+). The plugin starts and stops its own headless
  server (see below); live events ride the socket, with CLI polling as backstop.

## Install (lazy.nvim)

```lua
{
  dir = "~/Documents/aurelio/neo-herdr.nvim",
  name = "neo-herdr",
  lazy = false,
  config = function() require("neo-herdr").setup() end,
}
```

## The herd server (dedicated session)

neo-herdr talks to a **dedicated herdr session** (`server.session`, default
`"nvim"`), so it never fights your own `herdr` TUI over one server. Opening the
herd tab probes `herdr status --json`; if nothing is running it launches a
headless `herdr --session nvim server` and waits for it to answer. Closing the
herd tab (`q`), `:tabclose`, or quitting Neovim applies the stop policy:

- `autostop = "owned"` (default): only stop a server *this* Neovim started.
- `"always"` / `"never"`: stop regardless, or leave it to you.
- `confirm = true`: `herdr server stop` kills every pane process, so you are
  asked first whenever an agent is still `working` or `blocked`.

Commands: `:NeoHerdrServerStart`, `:NeoHerdrServerStop`, `:NeoHerdrServerStatus`.
When the server is down, the nav says so and `S` starts it. To share one herd
between the TUI and Neovim, set `server.session = nil` (herdr's default
session) — or run `herdr --session nvim` in a terminal to see this one.

## The herd workspace

`<leader>hd` (or `:NeoHerdrDashboard`) opens a **dedicated tabpage** — fully
independent of your other tabs — laid out like an IDE: your editor / cursor
window keeps most of the space, with a herd area (chat + nav over a keybinding
bar) alongside.

```
┌ editor / cursor window ───────────┬ agent chat ────────┬ HERDR · socket ● ─┐
│                                   │ (empty —           │ ▾ neo-herdr        │
│  open files here, :Neotree, etc.  │  pick an agent,    │▎● planner          │
│                                   │  <CR>)             │▎  claude · working │
│  ~66% of the tab                  │                    │                    │
│                                   │                    │ ◉ reviewer         │
│                                   │                    │   codex · needs in…│
│                                   │                    │                    │
│                                   │                    │ · terminal         │
│                                   │                    │   shell · tab 3    │
│                                   ├────────────────────┴────────────────────┤
│                                   │ NAV  <CR> open / start  n new chat  x … │
└───────────────────────────────────┴─────────────────────────────────────────┘
                                     └──────────── herd ~34% ─────────────────┘
```

The herd area defaults to ~34% of the tab on the **right** (nav 40% of that);
tune with `dashboard.herd_width`, `dashboard.nav_width`, `dashboard.side`
(`"right"`/`"left"`), and `dashboard.editor = false` to drop the editor pane.
Widths accept a fraction (`0.34`) or absolute columns (`44`).

**Minimum widths.** `dashboard.nav_min` (default 16, enough for the first ~10
characters of a title) and `dashboard.chat_min` (default 40, enough to keep
terminal output readable) are floors that neo-herdr enforces the way
nvim-tree/neo-tree hold a sidebar: both herd windows are `winfixwidth`, so
`<C-w>=`, `equalalways` and closing windows leave them alone; when the terminal
is resized the configured widths are re-resolved with the floors applied; and a
resize that would push a window under its floor stops at the floor. Dragging
the nav|chat separator redistributes inside the herd column only; dragging the
chat|editor separator, or `:vertical resize` on nav or chat, is honoured with
the sibling held at its floor and the editor absorbing the difference. Anything
wider than a floor is yours and is kept. When the terminal is too narrow for
the floors the editor pane is what gives way (down to Neovim's `winminwidth`),
and if even the herd cannot fit, nav keeps its floor and chat takes the rest.
Nothing is hidden. Note the floors take precedence over the fractions: with the
defaults, chat only reaches 40 columns once the herd is 57 wide, so on a
160-column terminal the herd grows to 57 and nav sits at 16.

**Nav rows** take two lines, like herdr's own sidebar: the status glyph and the
agent's name (its herdr name, else its live terminal title), then a dim line
with the program, its state (`working` / `needs input` / a custom status) and
the tab. Plain shells show as `terminal` with `shell · tab N · pN`. `j`/`k`
move by row. The row whose pane is **open in the chat** is marked with a
`▎` bar in the gutter and a full-row highlight (`NeoHerdrCurrentBar` /
`NeoHerdrCurrent`), independent of where your cursor is.

Glyphs are **colored by state** (like herdr's UI): amber `●` working · grey `○`
idle · red `◉` blocked · green `✓` done · dim `·` shell. The plugin sets
`NeoHerdrWorking/Idle/Blocked/Done/Unknown` on open and re-applies on
`:colorscheme`; override them in a `ColorScheme` autocmd. State is pushed live
over the socket (`events.subscribe`, including `pane.created/closed` so rows
appear and vanish immediately) with a CLI poll as a backstop; the header shows
`socket ●` (live events), `socket`, `cli-poll`, or the server state.

Selecting an agent (`<CR>`) opens its live terminal in the **chat** window
with a header (winbar) showing `workspace › ● agent`. Because herdr can only
attach panes that currently host an agent, `<CR>` on a **terminal** row does
not attach; it offers to **start an agent in that pane** (kind + name, with a
unique name suggested), then opens the chat once herdr reports it ready. `n`
does the same in a fresh tab. Attaches use `--takeover`, so a client left over
from a previous open never blocks you. When the pane behind the chat goes
away (closed with `x`, from herdr, or the agent exits and its shell is
closed), the chat window returns to the placeholder and shows the last output.

A small **notifier** pill floats at the left edge of the chat — a narrow,
non-focusable, transparent rounded outline holding three icons that aggregate
the whole herd's state: top **red** if any agent is blocked, mid **amber** if
any is working, bottom **green** if any is done. Icons are 3x2 block blobs
(filled when on, hollow when off); `dashboard.notifier_size = "small"` uses
single `●`/`○` glyphs instead. The blocked icon flashes slowly while any agent
needs input (`dashboard.notifier_blink` is the ms per phase, default 800;
`false` keeps it steady). Disable the pill with `dashboard.notifier = false`.

**Keybinding bar.** A short window under chat + nav (it spans both, not the
editor) lists the keys for **whichever window is focused**: `NAV` in the nav,
`CHAT · typing` / `CHAT` in the chat depending on mode, `EDITOR` in the editor
pane. Toggle it with `?` or `dashboard.help = false`. It's rendered from the
same tables that bind the keys, so it always matches what's live.

Row actions (cursor on a row in the nav):

| Key   | Action                                                        |
| ----- | ------------------------------------------------------------- |
| `<CR>`| Open the agent's chat, or start an agent in a terminal row    |
| `n`   | New chat — a fresh tab in the row's workspace (creates a workspace in Neovim's cwd if there is none) |
| `w`   | New workspace — pick a directory in the floating picker, then start an agent in it |
| `x`   | Close this chat / terminal (`herdr pane close`, with a confirm) |
| `c`   | Rename this chat (`herdr agent rename`)                       |
| `p`   | Prompt the agent                                              |
| `r`   | Read recent output into a scratch buffer                      |
| `a`   | Send keys (e.g. `enter` to unblock)                           |
| `R`   | Refresh now                                                   |
| `S`   | Start the herdr server (when it's stopped)                    |
| `?`   | Toggle the keybinding bar                                     |
| `q`   | Close the whole herd (the dashboard/tab), then apply autostop |

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

**Mouse select-to-copy.** Dragging (or double-clicking a word) in the chat or
nav window copies the selection to the system clipboard the moment you release
the button, like a regular terminal emulator — no `y` needed. The attach client
normally grabs the mouse (Neovim forwards mouse events to programs that enable
mouse reporting, so nothing would select), so neo-herdr reclaims the left
button in the chat: a press drops out of terminal mode, the drag selects, and
release copies and jumps straight back into the agent — a plain click does the
same, so the keyboard never leaves the agent. Wheel scrolling and other buttons
still reach the program. In the nav the selection stays highlighted until you
press a key or click. Copies are tidied on the way out: trailing padding the
terminal draws to the window edge is dropped, and the indent shared by every
line (Claude's two-space gutter) is removed while relative indentation — code
under a `⏺ Bash(…)` heading, say — is kept; `attach.mouse_copy_clean = false`
copies exactly what is on screen. Needs `'mouse'` enabled (Neovim's default)
and a clipboard provider (`:checkhealth provider`). Set
`attach.mouse_copy = false` to opt out.

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

While a comment is **pending** (added but not yet sent) it persists inline in the
code like a GitHub review comment: a gutter marker, a subtle highlight over the
commented range, and the note shown as virtual lines beneath it. The marker
tracks edits and disappears once the batch is sent (`<leader>hs`) or cleared
(`<leader>hx`). Colors follow `NeoHerdrCommentSign/Head/Body/Line`.

**Works with your diff viewer.** `<leader>hc` reviews best with **diffview.nvim**
(`:DiffviewOpen`): open the diff, then comment on any hunk. It sees through
`diffview://` and `fugitive://` git-object buffers, so you can comment from
*either* pane — the filepath resolves to the real file, and the line/snippet come
from exactly what you're looking at (the revision on the left, the working tree
on the right). `gitsigns` works too (you're always in the real file buffer).

**Directory picker.** `w` (and `:NeoHerdrNewWorkspace` without an argument)
opens a native floating picker: a path prompt over a fuzzy-filtered list of
the directories under it. The prompt holds a path: everything up to its last
`/` is the directory being browsed (relative to Neovim's cwd, or absolute, or
`~/…`), and what follows the last `/` filters the list. So `../` browses the
parent, `../../` its parent, `apps/` a child, `~/code/` anywhere. `<Tab>`,
`<Right>` or `<C-l>` complete the selected row into the prompt and browse into
it (no confirmation); `<CR>` picks the selected row, or the typed path if it
exists; `<BS>` with nothing typed after the last `/` (or `<S-Tab>`) goes up a
directory; `<C-n>`/`<C-p>` or the arrows move; `<Esc>` cancels. The `./` row
picks the browsed directory itself. Tune `dir_picker.depth`, `.hidden`,
`.ignore`, `.root`, or set `dir_picker = false` for a plain input prompt.

Commands: `:NeoHerdrComment` (range-aware), `:NeoHerdrSend`,
`:NeoHerdrMessage [text]`, `:NeoHerdrList`, `:NeoHerdrClear`,
`:NeoHerdrPickAgent`, `:NeoHerdrRead`, `:NeoHerdrDashboard`, `:NeoHerdrChat`,
`:NeoHerdrNewChat`, `:NeoHerdrNewWorkspace [dir]`, `:NeoHerdrAttach [target]`, `:NeoHerdrTile`,
`:NeoHerdrServerStart`, `:NeoHerdrServerStop`, `:NeoHerdrServerStatus`.

## Configuration (defaults)

```lua
require("neo-herdr").setup({
  herdr_cmd = "herdr",
  agent = nil,            -- pin a target (name or pane id)
  prompt = { wait = false, until_states = {}, timeout = nil },
  snippet_max = 40,
  read = { source = "recent-unwrapped", lines = 200 },
  server = {
    session = "nvim",     -- dedicated herdr session; nil = herdr's default one
    autostart = true,     -- start a headless server on open if none is running
    autostop = "owned",   -- "owned" (only one we started) | "always" | "never"
    confirm = true,       -- ask before stopping while agents are working/blocked
    start_timeout = 10000,
  },
  agent_start = {
    timeout = 60000,      -- herdr's readiness wait for `agent start` (>3000)
    busy_retry_ms = 5000, -- retry `agent_pane_busy` on a fresh pane this long
    default_kind = "claude",
  },
  dashboard = {
    side = "right",       -- herd area (chat+nav) on the "right" or "left"
    herd_width = 0.34,    -- herd area as a fraction of the tab (<=1) or columns (>1)
    nav_width = 0.40,     -- nav as a fraction of the herd area (<=1) or columns (>1)
    nav_min = 16,         -- floor for the nav column (~10 title characters)
    chat_min = 40,        -- floor for the chat window, in columns
    editor = true,        -- include an editor/cursor window taking the rest
    hide_tab = true,      -- hide the herd tabpage from the built-in tabline
    help = true,          -- keybinding bar under chat + nav (toggle with ?)
    notifier = true,      -- Opera-GX-style notifier float (blocked/working/done)
    notifier_size = "large", -- "large" (3x2 block icons) | "small" (●/○ glyphs)
    notifier_blink = 800, -- ms per phase of the blocked icon's flash; false = steady
    use_socket = true,    -- prefer socket; false = CLI poll only
    socket_path = nil,    -- override socket path resolution
    auto_refresh = true,  -- timer + manual; false = manual only
    poll_interval = 4000, -- ms (backstop / fallback)
    chat_header = true,   -- winbar on the chat window (workspace › agent + status)
    separators = { dotted = true, vert = "┊" }, -- dotted = false keeps solid dividers
  },
  dir_picker = {          -- floating directory picker for new workspaces; false = plain prompt
    root = nil,           -- starting directory; nil = Neovim's cwd
    depth = 3,            -- how deep below the root to list
    hidden = false,       -- include dot-directories
    ignore = { ".git", "node_modules", ".venv", "venv", "__pycache__", ".cache", "dist", "build", "target" },
    max = 5000,           -- stop listing past this many directories
  },
  attach = {
    detach_hint = true,
    takeover = true,         -- `--takeover`: evict a lingering attach client
    attach_args = {},
    switch_key = ":",        -- on an EMPTY agent prompt, drops into Neovim
    switch_on_empty = true,  -- set false to always pass the key to the agent
    mouse_copy = true,       -- mouse-select in chat/nav copies to the system clipboard
    mouse_copy_clean = true, -- strip shared indent + trailing padding from mouse copies
    nav = { enable = true, prefix = "<C-w>", keys = {} }, -- window nav from chat
  },
  keymaps = { prefix = "<leader>h", add="c", send="s", list="l", clear="x",
              pick_agent="a", read="r", dashboard="d", tile="t", insert="i" },
  -- format = function(batch) return "..." end,
})
```

## How it talks to herdr

- **Session:** every CLI call and attach runs as `herdr --session <name> …`,
  and the socket path resolves to `~/.config/herdr/sessions/<name>/herdr.sock`
  (`$HERDR_SOCKET_PATH` still overrides). With `server.session = nil` it uses
  herdr's default socket, like the TUI.
- **State:** one `session.snapshot` request per refresh (workspaces, tabs,
  panes, agents — agent *names* only exist on the agent list, so they're merged
  by pane id). The socket is **one-request-per-connection**, so each snapshot
  opens a fresh connection; a separate persistent connection carries
  `events.subscribe` for `pane.created/closed/exited/agent_detected` (global)
  plus `pane.agent_status_changed` per pane. herdr probes per-pane
  subscriptions and rejects the whole request if a pane is gone; the plugin
  drops that pane and resubscribes. No socket → `herdr api snapshot` poll.
- **Actions:** `herdr agent prompt`, `agent read`, `agent send-keys`,
  `agent start` (retrying `agent_pane_busy` while a fresh pane's shell settles),
  `tab create`, `pane close`, `agent rename`, `server stop`.
- **Live panes:** `herdr agent attach <pane-id> --takeover` in a `:terminal`.
  Targets are always pane ids (names change on rename / exit). Only panes that
  currently host an agent can be attached — shells get the start-an-agent flow.

## Health check

```
:checkhealth neo-herdr
```

Verifies `herdr` on PATH, shows the session/argv in use, whether the server is
running, dumps raw `agent list`, and reports whether the socket is present.

> **Field-shape caveat:** herdr's public docs pin down the socket *methods* and
> event shapes but not every field of the agent objects. Normalisation lives in
> `state.lua` (`normalize_agent`) and `herdr.lua` (`extract_agents`); if the
> dashboard mislabels something, check `:checkhealth` output and adjust those.
