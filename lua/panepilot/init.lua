local M = {}

local registered = false

local function open_scratch(kind, lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, ('panepilot://%s/%d'):format(kind, vim.uv.hrtime()))
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_set_current_buf(bufnr)
end

local function show_log()
  local lines = {}
  for _, entry in ipairs(require('panepilot.log').entries()) do
    table.insert(lines, ('[%s] [%s] %s'):format(entry.time, entry.level:upper(), entry.message))
  end
  open_scratch('log', #lines > 0 and lines or { '(no entries)' })
end

local function show_debug_context()
  local opts = require('panepilot.config').get()
  require('panepilot.context').get(opts.context, function(result)
    if not result.ok then
      require('panepilot.log').add('warn', result.message)
      return
    end
    open_scratch('context', vim.split(result.content, '\n', { plain = true }))
  end)
end

local function is_target_buffer(bufnr)
  return vim.env.EDITPROMPT == '1'
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].filetype == 'markdown.editprompt'
end

function M._activate_buffer(bufnr)
  if not require('panepilot.config').is_enabled() or not is_target_buffer(bufnr) then
    return
  end

  local engine = require('panepilot.engine')
  engine.attach(bufnr)
  if vim.b[bufnr].panepilot_initialized then
    return
  end
  vim.b[bufnr].panepilot_initialized = true

  local group = vim.api.nvim_create_augroup('Panepilot', { clear = false })
  vim.api.nvim_create_autocmd({ 'CursorMovedI', 'TextChangedI', 'InsertLeave', 'BufLeave' }, {
    group = group,
    buffer = bufnr,
    callback = function(event)
      local ghost = require('panepilot.ghost')
      if event.event == 'TextChangedI' and ghost.consume_internal_change(bufnr) then
        return
      end
      if event.event == 'CursorMovedI' and ghost.consume_internal_cursor(bufnr) then
        return
      end
      if event.event == 'TextChangedI' then
        require('panepilot.engine').schedule_auto(bufnr)
      else
        require('panepilot.engine').dismiss(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = bufnr,
    callback = function()
      require('panepilot.engine').detach(bufnr)
    end,
  })
end

function M._register()
  if registered then
    return
  end
  registered = true

  vim.api.nvim_set_hl(0, 'PanepilotGhost', { default = true, link = 'Comment' })
  vim.api.nvim_set_hl(0, 'PanepilotSpinner', { default = true, link = 'Special' })
  local group = vim.api.nvim_create_augroup('Panepilot', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'markdown.editprompt',
    callback = function(event)
      M._activate_buffer(event.buf)
    end,
  })
  vim.api.nvim_create_user_command('PanepilotDebugContext', show_debug_context, {})
  vim.api.nvim_create_user_command('PanepilotLog', show_log, {})

  M._activate_buffer(vim.api.nvim_get_current_buf())
end

function M.setup(opts)
  local valid = require('panepilot.config').setup(opts)
  M._register()
  if not valid then
    require('panepilot.engine')._reset()
    return
  end
  require('panepilot.cmp_source').register()
  M._activate_buffer(vim.api.nvim_get_current_buf())
end

function M.trigger()
  require('panepilot.engine').trigger()
end

function M.visible()
  return require('panepilot.ghost').visible()
end

function M.accept()
  return require('panepilot.ghost').accept()
end

function M.dismiss()
  require('panepilot.engine').dismiss()
end

function M.accept_word()
  return require('panepilot.ghost').accept_word()
end

function M.accept_line()
  return require('panepilot.ghost').accept_line()
end

function M.next_candidate()
  return require('panepilot.ghost').next_candidate()
end

function M.prev_candidate()
  return require('panepilot.ghost').prev_candidate()
end

function M.resume_auto()
  require('panepilot.engine').resume_auto()
end

return M
