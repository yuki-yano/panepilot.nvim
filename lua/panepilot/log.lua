local M = {}

local MAX_ENTRIES = 50
local entries = {}

function M.add(level, message)
  table.insert(entries, {
    time = os.date('%Y-%m-%d %H:%M:%S'),
    level = level,
    message = message,
  })

  if #entries > MAX_ENTRIES then
    table.remove(entries, 1)
  end
end

function M.entries()
  return vim.deepcopy(entries)
end

function M._clear()
  entries = {}
end

return M
