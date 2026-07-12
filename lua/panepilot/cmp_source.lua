local M = {}

local registered = false

local Source = {}
Source.__index = Source

local function label_for(candidate)
  if vim.fn.strchars(candidate) <= 60 then
    return candidate
  end
  return vim.fn.strcharpart(candidate, 0, 60) .. '…'
end

function Source.new()
  return setmetatable({}, Source)
end

function Source:is_available()
  local bufnr = vim.api.nvim_get_current_buf()
  return require('panepilot.config').is_enabled()
    and vim.env.EDITPROMPT == '1'
    and vim.bo[bufnr].filetype == 'markdown.editprompt'
end

function Source:get_keyword_pattern()
  -- Candidates are continuations inserted at the cursor, not replacements for
  -- the keyword before it. A zero-width end-of-input match keeps nvim-cmp's
  -- source offset at the cursor for filtering and confirmation.
  return [[\%$]]
end

function Source:complete(_, callback)
  require('panepilot.engine').complete_cmp(function(candidates)
    local items = {}
    for _, candidate in ipairs(candidates) do
      table.insert(items, {
        label = label_for(candidate),
        documentation = candidate,
        insertText = candidate,
        menu = '[Panepilot]',
      })
    end
    callback({ items = items, isIncomplete = false })
  end)
end

function M.register()
  if registered or not require('panepilot.config').get().cmp.enabled then
    return registered
  end

  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    require('panepilot.log').add('warn', 'nvim-cmp is unavailable; panepilot source was not registered')
    return false
  end

  cmp.register_source('panepilot', Source.new())
  cmp.event:on('menu_opened', function()
    require('panepilot.ghost').dismiss()
  end)
  registered = true
  return true
end

function M.new()
  return Source.new()
end

function M._reset()
  registered = false
end

return M
