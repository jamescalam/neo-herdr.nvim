-- Load guard. Actual commands/keymaps are registered from setup() so they can
-- honour user config. This file just prevents double-loading.
if vim.g.loaded_neo_herdr then
  return
end
vim.g.loaded_neo_herdr = true
