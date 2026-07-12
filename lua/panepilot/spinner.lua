local M = {}

local namespace = vim.api.nvim_create_namespace('panepilot_spinner')
local states = {}
local frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local DELAY_MS = 200
local INTERVAL_MS = 80

local function close_timer(timer)
  if not timer or timer:is_closing() then
    return
  end
  timer:stop()
  timer:close()
end

local function delete_extmark(bufnr, state)
  if state.extmark_id and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, state.extmark_id)
  end
  state.extmark_id = nil
end

local function render(bufnr, state)
  if states[bufnr] ~= state then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.stop(bufnr, state)
    return
  end
  if state.row < 0 or state.row >= vim.api.nvim_buf_line_count(bufnr) then
    M.stop(bufnr, state)
    return
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, state.row, state.row + 1, false)[1] or ''
  if state.col < 0 or state.col > #line then
    M.stop(bufnr, state)
    return
  end

  local suffix = line:sub(state.col + 1)
  local virt_text = { { ' ' }, { frames[state.frame], 'PanepilotSpinner' } }
  if suffix ~= '' then
    table.insert(virt_text, { suffix })
  end

  state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, state.row, state.col, {
    id = state.extmark_id,
    virt_text = virt_text,
    virt_text_pos = 'overlay',
    hl_mode = 'combine',
    right_gravity = false,
  })
end

function M.start(bufnr, row, col)
  M.stop(bufnr)

  local state = { row = row, col = col, frame = 1 }
  states[bufnr] = state
  state.delay_timer = vim.uv.new_timer()
  state.delay_timer:start(
    DELAY_MS,
    0,
    vim.schedule_wrap(function()
      if states[bufnr] ~= state then
        return
      end
      close_timer(state.delay_timer)
      state.delay_timer = nil
      render(bufnr, state)
      if states[bufnr] ~= state then
        return
      end

      state.animation_timer = vim.uv.new_timer()
      state.animation_timer:start(
        INTERVAL_MS,
        INTERVAL_MS,
        vim.schedule_wrap(function()
          if states[bufnr] ~= state then
            return
          end
          state.frame = (state.frame % #frames) + 1
          render(bufnr, state)
        end)
      )
    end)
  )
  return state
end

function M.stop(bufnr, expected)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state or (expected and state ~= expected) then
    return false
  end

  states[bufnr] = nil
  close_timer(state.delay_timer)
  close_timer(state.animation_timer)
  delete_extmark(bufnr, state)
  return true
end

function M.visible(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state or not state.extmark_id or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return #vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, state.extmark_id, {}) > 0
end

function M.pending(bufnr)
  return states[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

function M._namespace()
  return namespace
end

function M._reset()
  for _, bufnr in ipairs(vim.tbl_keys(states)) do
    M.stop(bufnr)
  end
end

return M
