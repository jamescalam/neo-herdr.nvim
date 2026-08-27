-- neo-herdr: in-memory batch of pending review comments.
-- Mirrors reviewr's model: collect notes, then one "send" delivers the set.

local M = {}

local store = {}

--- comment = { file, s = start_line, e = end_line, snippet = { ... }, note }
function M.add(comment)
  table.insert(store, comment)
  return #store
end

function M.count()
  return #store
end

function M.all()
  return store
end

function M.remove(i)
  return table.remove(store, i)
end

function M.clear()
  store = {}
end

return M
