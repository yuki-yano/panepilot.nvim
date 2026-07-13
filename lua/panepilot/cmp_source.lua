local M = {}

local registered = false
local unsubscribe_menu_opened

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

function Source:complete(params, callback)
  local manual = params.context
    and type(params.context.get_reason) == 'function'
    and params.context:get_reason() == 'manual'
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
  end, manual)
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
  unsubscribe_menu_opened = cmp.event:on('menu_opened', function()
    if require('panepilot.config').get().cmp.dismiss_ghost_on_menu_open then
      require('panepilot.ghost').dismiss()
    end
  end)
  registered = true
  return true
end

function M.new()
  return Source.new()
end

function M._reset()
  if unsubscribe_menu_opened then
    unsubscribe_menu_opened()
    unsubscribe_menu_opened = nil
  end
  registered = false
end

return M
