local M = {}

local namespace = vim.api.nvim_create_namespace('panepilot_ghost')
local states = {}
local internal_changes = {}
local internal_cursors = {}

local function split_candidate(candidate)
  return vim.split(candidate, '\n', { plain = true })
end

local function extmark_position(bufnr, extmark_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, extmark_id, {})
  return #position > 0 and position or nil
end

local function delete_extmark(bufnr, state)
  if state.extmark_id and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, state.extmark_id)
  end
  state.extmark_id = nil
end

local function render(bufnr, row, col, state)
  local candidate = state.candidates[state.index]
  local parts = split_candidate(candidate)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local suffix = line:sub(col + 1)
  local virt_text = { { parts[1], 'PanepilotGhost' } }
  if suffix ~= '' then
    table.insert(virt_text, { suffix })
  end
  local virt_lines
  if #parts > 1 then
    virt_lines = {}
    for index = 2, #parts do
      table.insert(virt_lines, { { parts[index], 'PanepilotGhost' } })
    end
  end

  state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, row, col, {
    virt_text = virt_text,
    virt_text_pos = 'overlay',
    virt_lines = virt_lines,
    hl_mode = 'combine',
    right_gravity = false,
  })
end

local function set_cursor_after(bufnr, row, col, parts)
  local cursor
  if #parts == 1 then
    cursor = { row + 1, col + #parts[1] }
  else
    cursor = { row + #parts, #parts[#parts] }
  end
  if vim.api.nvim_get_current_buf() == bufnr then
    vim.api.nvim_win_set_cursor(0, cursor)
  end
  internal_cursors[bufnr] = { row = cursor[1] - 1, col = cursor[2] }
  return cursor[1] - 1, cursor[2]
end

local function close_undo_block()
  vim.go.undolevels = vim.go.undolevels
end

local function insert_prefix(bufnr, prefix, remaining)
  local state = states[bufnr]
  if not state or not M.visible(bufnr) then
    M.dismiss(bufnr)
    return false
  end

  local position = assert(extmark_position(bufnr, state.extmark_id))
  delete_extmark(bufnr, state)
  local parts = split_candidate(prefix)
  close_undo_block()
  vim.api.nvim_buf_set_text(bufnr, position[1], position[2], position[1], position[2], parts)
  internal_changes[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
  local row, col = set_cursor_after(bufnr, position[1], position[2], parts)

  if remaining == '' then
    states[bufnr] = nil
  else
    state.candidates = { remaining }
    state.index = 1
    render(bufnr, row, col, state)
  end
  return true
end

local function word_prefix(candidate)
  if candidate:sub(1, 1) == '\n' then
    return '\n'
  end

  local length = vim.fn.strchars(candidate)
  local count = 0
  while count < length do
    local char = vim.fn.strcharpart(candidate, count, 1)
    if char == '\n' or vim.fn.charclass(char) ~= 0 then
      break
    end
    count = count + 1
  end
  if count >= length then
    return candidate
  end

  local first = vim.fn.strcharpart(candidate, count, 1)
  if first == '\n' then
    return vim.fn.strcharpart(candidate, 0, count) .. '\n'
  end
  local class = vim.fn.charclass(first)
  count = count + 1
  while count < length do
    local char = vim.fn.strcharpart(candidate, count, 1)
    if char == '\n' or vim.fn.charclass(char) ~= class then
      break
    end
    count = count + 1
  end

  return vim.fn.strcharpart(candidate, 0, count)
end

local function line_prefix(candidate)
  local first_newline = candidate:find('\n', 1, true)
  if not first_newline then
    return candidate
  end
  if first_newline > 1 then
    return candidate:sub(1, first_newline - 1)
  end

  local second_newline = candidate:find('\n', 2, true)
  return second_newline and candidate:sub(1, second_newline - 1) or candidate
end

function M.show(bufnr, row, col, candidates)
  M.dismiss(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or type(candidates) ~= 'table' or type(candidates[1]) ~= 'string' then
    return
  end

  local state = { candidates = vim.deepcopy(candidates), index = 1 }
  states[bufnr] = state
  render(bufnr, row, col, state)
end

function M.visible(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  local position = state and extmark_position(bufnr, state.extmark_id) or nil
  if not position then
    return false
  end

  if vim.api.nvim_get_current_buf() == bufnr then
    local cursor = vim.api.nvim_win_get_cursor(0)
    if cursor[1] - 1 ~= position[1] or cursor[2] ~= position[2] then
      M.dismiss(bufnr)
      return false
    end
  end

  return true
end

function M.dismiss(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  states[bufnr] = nil
  if state then
    delete_extmark(bufnr, state)
  end
end

function M.accept(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state then
    return false
  end
  local candidate = state.candidates[state.index]
  return insert_prefix(bufnr, candidate, '')
end

function M.accept_word(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state then
    return false
  end
  local candidate = state.candidates[state.index]
  local prefix = word_prefix(candidate)
  return insert_prefix(bufnr, prefix, candidate:sub(#prefix + 1))
end

function M.accept_line(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state then
    return false
  end
  local candidate = state.candidates[state.index]
  local prefix = line_prefix(candidate)
  return insert_prefix(bufnr, prefix, candidate:sub(#prefix + 1))
end

local function cycle(bufnr, offset)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state or #state.candidates <= 1 or not M.visible(bufnr) then
    return false
  end

  local position = assert(extmark_position(bufnr, state.extmark_id))
  delete_extmark(bufnr, state)
  state.index = ((state.index - 1 + offset) % #state.candidates) + 1
  render(bufnr, position[1], position[2], state)
  return true
end

function M.next_candidate(bufnr)
  return cycle(bufnr, 1)
end

function M.prev_candidate(bufnr)
  return cycle(bufnr, -1)
end

function M.consume_internal_change(bufnr)
  local tick = internal_changes[bufnr]
  internal_changes[bufnr] = nil
  return tick ~= nil and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_changedtick(bufnr) == tick
end

function M.consume_internal_cursor(bufnr)
  local expected = internal_cursors[bufnr]
  internal_cursors[bufnr] = nil
  if not expected or vim.api.nvim_get_current_buf() ~= bufnr then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return cursor[1] - 1 == expected.row and cursor[2] == expected.col
end

function M._namespace()
  return namespace
end

return M
