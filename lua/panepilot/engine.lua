local config = require('panepilot.config')
local claude = require('panepilot.backend.claude')
local context = require('panepilot.context')
local codex = require('panepilot.backend.codex')
local ghost = require('panepilot.ghost')
local log = require('panepilot.log')
local openai = require('panepilot.backend.openai')
local spinner = require('panepilot.spinner')

local M = {}

local states = {}
local backends = { openai = openai, claude = claude, codex = codex }
local api_backends = { openai = true, claude = true }
local auto_paused = false
local auto_pause_notified = false
local candidate_cache = {}
local cache_clock = 0
local CACHE_LIMIT = 20

local function limit_candidates(candidates, max_lines, max_chars)
  local limited = {}
  for _, original in ipairs(candidates) do
    local candidate = original
    local lines = vim.split(candidate, '\n', { plain = true })
    if #lines > max_lines then
      local kept = {}
      for index = 1, max_lines do
        table.insert(kept, lines[index])
      end
      candidate = table.concat(kept, '\n')
    end
    if vim.fn.strchars(candidate, true) > max_chars then
      candidate = vim.fn.strcharpart(candidate, 0, max_chars, true)
    end
    table.insert(limited, candidate)
  end
  return limited
end

local function is_insert_mode()
  return vim.api.nvim_get_mode().mode:sub(1, 1) == 'i'
end

local function automatic_position_allowed()
  return vim.api.nvim_win_get_cursor(0)[2] > 0
end

local function is_target_buffer(bufnr)
  return vim.env.EDITPROMPT == '1'
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].filetype == 'markdown.editprompt'
end

local function state_for(bufnr)
  return states[bufnr]
end

local function buffer_around_cursor(bufnr, cursor)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row = cursor[1]
  local col = cursor[2]
  local before = {}
  local after = {}

  for index = 1, row - 1 do
    table.insert(before, lines[index])
  end
  table.insert(before, (lines[row] or ''):sub(1, col))

  table.insert(after, (lines[row] or ''):sub(col + 1))
  for index = row + 1, #lines do
    table.insert(after, lines[index])
  end

  return table.concat(before, '\n'), table.concat(after, '\n')
end

local function cache_signature(opts)
  local backend_opts = opts[opts.backend]
  local request_candidates = opts.backend == 'codex' and 1 or opts.n_candidates
  local values = {
    opts.backend,
    backend_opts.model,
    backend_opts.reasoning_effort or '',
    request_candidates,
    opts.max_candidate_lines,
    opts.max_candidate_chars,
    backend_opts.max_output_tokens or backend_opts.max_tokens or '',
  }
  local parts = {}
  for _, value in ipairs(values) do
    local encoded = tostring(value)
    table.insert(parts, #encoded .. ':' .. encoded)
  end
  return table.concat(parts)
end

local function snapshot_is_current(snapshot)
  if vim.api.nvim_get_current_buf() ~= snapshot.bufnr then
    return false
  end
  if not vim.api.nvim_buf_is_valid(snapshot.bufnr) then
    return false
  end

  local current_state = state_for(snapshot.bufnr)
  if not current_state or current_state.generation ~= snapshot.generation then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  if cursor[1] ~= snapshot.row or cursor[2] ~= snapshot.col then
    return false
  end

  return is_insert_mode()
end

local function cancel_in_flight(bufnr, state)
  spinner.stop(bufnr)
  if state.context_handle then
    context.cancel(state.context_handle)
  end
  state.context_handle = nil
  if state.handle and state.backend then
    state.backend.cancel(state.handle)
  end
  state.handle = nil
  state.backend = nil
  state.request = nil
end

local function notify_waiters(slot, candidates)
  for _, waiter in ipairs(slot.waiters) do
    waiter(candidates or {})
  end
  slot.waiters = {}
end

local function cmp_visible()
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    return false
  end
  local visible_ok, visible = pcall(cmp.visible)
  return visible_ok and visible == true
end

local function skkeleton_enabled()
  local ok, enabled = pcall(vim.fn['skkeleton#is_enabled'])
  return ok and enabled == 1
end

local function auto_suppressed()
  return auto_paused or cmp_visible() or skkeleton_enabled()
end

local function cmp_request_suppressed()
  return auto_paused or skkeleton_enabled()
end

local function handle_failure(result)
  if result.kind == 'cancelled' then
    return
  end
  if result.kind == 'http' and result.status == 429 then
    auto_paused = true
    if not auto_pause_notified then
      auto_pause_notified = true
      vim.notify(
        "panepilot.nvim: automatic completion paused after HTTP 429; call require('panepilot').resume_auto() to resume",
        vim.log.levels.WARN
      )
    end
  end

  local status = result.status and (' (HTTP %d)'):format(result.status) or ''
  log.add('error', result.kind .. status .. ': ' .. (result.message or 'unknown error'))
end

local function cache_put(key, candidates)
  cache_clock = cache_clock + 1
  candidate_cache[key] = { candidates = vim.deepcopy(candidates), used_at = cache_clock }

  if vim.tbl_count(candidate_cache) <= CACHE_LIMIT then
    return
  end
  local oldest_key
  local oldest_used_at = math.huge
  for candidate_key, entry in pairs(candidate_cache) do
    if entry.used_at < oldest_used_at then
      oldest_key = candidate_key
      oldest_used_at = entry.used_at
    end
  end
  candidate_cache[oldest_key] = nil
end

local function cache_get(key)
  local entry = candidate_cache[key]
  if not entry then
    return nil
  end
  cache_clock = cache_clock + 1
  entry.used_at = cache_clock
  return vim.deepcopy(entry.candidates)
end

local function start_auto_timer(bufnr, state, generation, delay_ms)
  if state.timer then
    state.timer:stop()
  else
    state.timer = vim.uv.new_timer()
  end
  state.timer:start(
    math.max(0, math.ceil(delay_ms)),
    0,
    vim.schedule_wrap(function()
      local current_state = state_for(bufnr)
      if
        vim.api.nvim_get_current_buf() == bufnr
        and current_state == state
        and current_state.generation == generation
      then
        M.trigger(true, generation)
      end
    end)
  )
end

function M.attach(bufnr)
  if not config.is_enabled() or not is_target_buffer(bufnr) then
    return false
  end

  states[bufnr] = states[bufnr] or { generation = 0 }
  return true
end

function M.trigger(automatic, scheduled_generation)
  local bufnr = vim.api.nvim_get_current_buf()
  if not M.attach(bufnr) or not is_insert_mode() then
    return
  end

  local opts = config.get()
  if
    automatic
    and (
      not opts.auto_trigger.enabled
      or not api_backends[opts.backend]
      or auto_suppressed()
      or not automatic_position_allowed()
    )
  then
    return
  end

  local backend = backends[opts.backend]
  if not backend or (backend.is_available and not backend.is_available(opts[opts.backend])) then
    return
  end

  local state = state_for(bufnr)
  local generation
  if scheduled_generation then
    if state.generation ~= scheduled_generation then
      return
    end
    generation = scheduled_generation
  else
    cancel_in_flight(bufnr, state)
    ghost.dismiss(bufnr)
    state.generation = state.generation + 1
    generation = state.generation
  end

  local spinner_handle
  if not automatic then
    local cursor = vim.api.nvim_win_get_cursor(0)
    spinner_handle = spinner.start(bufnr, cursor[1] - 1, cursor[2])
  end

  local function stop_spinner()
    if spinner_handle then
      spinner.stop(bufnr, spinner_handle)
    end
  end

  local context_handle
  context_handle = context.get(opts.context, function(context_result)
    state = state_for(bufnr)
    if state and state.context_handle == context_handle then
      state.context_handle = nil
    end
    if not state or state.generation ~= generation then
      stop_spinner()
      return
    end
    if context_result.cancelled then
      stop_spinner()
      return
    end
    if not context_result.ok then
      stop_spinner()
      log.add('warn', context_result.message)
      return
    end
    if vim.api.nvim_get_current_buf() ~= bufnr or not is_insert_mode() then
      stop_spinner()
      return
    end
    if automatic then
      if auto_suppressed() or not automatic_position_allowed() then
        return
      end
      local quiet, _, retry_after_ms =
        context.observe_pane(context_result.pane_id, context_result.content, opts.auto_trigger.pane_quiet_sec)
      if not quiet then
        start_auto_timer(bufnr, state, generation, retry_after_ms)
        return
      end
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local buffer_before, buffer_after = buffer_around_cursor(bufnr, cursor)
    local cache_key = M.cache_key(context_result.content, buffer_before, buffer_after, opts)
    local snapshot = {
      generation = generation,
      bufnr = bufnr,
      row = cursor[1],
      col = cursor[2],
      mode = vim.api.nvim_get_mode().mode,
    }
    local request_candidates = opts.backend == 'codex' and 1 or opts.n_candidates
    local request = {
      system = openai.system_prompt(request_candidates, opts.max_candidate_lines, opts.max_candidate_chars),
      context = context_result.content,
      buffer_before = buffer_before,
      buffer_after = buffer_after,
      pane_id = context_result.pane_id,
      n_candidates = request_candidates,
      max_candidate_lines = opts.max_candidate_lines,
      max_candidate_chars = opts.max_candidate_chars,
    }

    local cached = cache_get(cache_key)
    if cached then
      cached = limit_candidates(cached, opts.max_candidate_lines, opts.max_candidate_chars)
      stop_spinner()
      if snapshot_is_current(snapshot) and (not automatic or not auto_suppressed()) then
        ghost.show(bufnr, snapshot.row - 1, snapshot.col, cached)
      end
      return
    end

    local slot = { key = cache_key, waiters = {} }
    state.request = slot
    state.backend = backend
    local completed = false
    local handle = backend.complete(request, function(result)
      completed = true
      stop_spinner()
      local current_state = state_for(bufnr)
      if current_state and current_state.request == slot then
        current_state.handle = nil
        current_state.backend = nil
        current_state.request = nil
      end

      if not result.ok then
        notify_waiters(slot, {})
        handle_failure(result)
        return
      end
      local candidates = limit_candidates(result.candidates, opts.max_candidate_lines, opts.max_candidate_chars)
      cache_put(cache_key, candidates)
      notify_waiters(slot, candidates)
      if not snapshot_is_current(snapshot) then
        return
      end
      if automatic and auto_suppressed() then
        return
      end

      ghost.show(bufnr, snapshot.row - 1, snapshot.col, candidates)
    end, opts[opts.backend])
    if not completed and state_for(bufnr) == state and state.request == slot then
      state.handle = handle
    end
  end)
  state.context_handle = context_handle
end

function M.schedule_auto(bufnr)
  local state = state_for(bufnr)
  local opts = config.get()
  if not state then
    return
  end

  cancel_in_flight(bufnr, state)
  ghost.dismiss(bufnr)
  state.generation = state.generation + 1
  if
    not opts.auto_trigger.enabled
    or not api_backends[opts.backend]
    or auto_suppressed()
    or not automatic_position_allowed()
  then
    return
  end
  start_auto_timer(bufnr, state, state.generation, opts.auto_trigger.debounce_ms)
end

function M.cache_key(pane_content, buffer_before, buffer_after, opts)
  local draft_hash = context.hash(buffer_before .. '\0' .. buffer_after)
  return context.hash(pane_content) .. '\0' .. draft_hash .. '\0' .. cache_signature(opts)
end

function M.complete_cmp(callback, manual)
  local bufnr = vim.api.nvim_get_current_buf()
  local opts = config.get()
  if not M.attach(bufnr) or not is_insert_mode() or not opts.cmp.enabled or not api_backends[opts.backend] then
    callback({})
    return
  end
  if not manual and not automatic_position_allowed() then
    callback({})
    return
  end

  local backend = backends[opts.backend]
  if not backend or (backend.is_available and not backend.is_available(opts[opts.backend])) then
    callback({})
    return
  end

  local state = state_for(bufnr)
  local observed_generation = state.generation
  local called = false

  local function complete_once(candidates)
    if called then
      return
    end
    called = true
    callback(candidates or {})
  end

  local function attempt()
    if
      vim.api.nvim_get_current_buf() ~= bufnr
      or not is_insert_mode()
      or state_for(bufnr) ~= state
      or state.generation ~= observed_generation
    then
      complete_once({})
      return
    end

    local context_handle
    context_handle = context.get(opts.context, function(context_result)
      if state.context_handle == context_handle then
        state.context_handle = nil
      end
      if state_for(bufnr) ~= state or state.generation ~= observed_generation then
        complete_once({})
        return
      end
      if context_result.cancelled then
        complete_once({})
        return
      end
      if not context_result.ok then
        log.add('warn', context_result.message)
        complete_once({})
        return
      end
      local cursor = vim.api.nvim_win_get_cursor(0)
      local buffer_before, buffer_after = buffer_around_cursor(bufnr, cursor)
      local key = M.cache_key(context_result.content, buffer_before, buffer_after, opts)
      local cached = cache_get(key)
      if cached then
        complete_once(limit_candidates(cached, opts.max_candidate_lines, opts.max_candidate_chars))
        return
      end
      if state.handle and state.request and state.request.key == key then
        table.insert(state.request.waiters, complete_once)
        return
      end
      if cmp_request_suppressed() then
        complete_once({})
        return
      end

      local quiet, _, retry_after_ms =
        context.observe_pane(context_result.pane_id, context_result.content, opts.auto_trigger.pane_quiet_sec)
      if not quiet then
        vim.defer_fn(attempt, math.max(0, math.ceil(retry_after_ms)))
        return
      end

      cancel_in_flight(bufnr, state)
      ghost.dismiss(bufnr)
      state.generation = state.generation + 1
      local generation = state.generation

      local snapshot = {
        generation = generation,
        bufnr = bufnr,
        row = cursor[1],
        col = cursor[2],
        mode = vim.api.nvim_get_mode().mode,
      }
      local request = {
        system = openai.system_prompt(opts.n_candidates, opts.max_candidate_lines, opts.max_candidate_chars),
        context = context_result.content,
        buffer_before = buffer_before,
        buffer_after = buffer_after,
        pane_id = context_result.pane_id,
        n_candidates = opts.n_candidates,
        max_candidate_lines = opts.max_candidate_lines,
        max_candidate_chars = opts.max_candidate_chars,
      }

      local slot = { key = key, waiters = {} }
      state.request = slot
      state.backend = backend
      local completed = false
      local handle = backend.complete(request, function(result)
        completed = true
        local current_state = state_for(bufnr)
        if current_state and current_state.request == slot then
          current_state.handle = nil
          current_state.backend = nil
          current_state.request = nil
        end
        if not result.ok then
          notify_waiters(slot, {})
          handle_failure(result)
          complete_once({})
          return
        end
        if not snapshot_is_current(snapshot) then
          complete_once({})
          return
        end

        local candidates = limit_candidates(result.candidates, opts.max_candidate_lines, opts.max_candidate_chars)
        cache_put(key, candidates)
        notify_waiters(slot, candidates)
        complete_once(candidates)
      end, opts[opts.backend])
      if not completed and state_for(bufnr) == state and state.request == slot then
        state.handle = handle
      end
    end)
    state.context_handle = context_handle
  end

  attempt()
end

function M.resume_auto()
  auto_paused = false
  auto_pause_notified = false
end

function M.dismiss(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = state_for(bufnr)
  if state then
    cancel_in_flight(bufnr, state)
    state.generation = state.generation + 1
  end
  ghost.dismiss(bufnr)
end

function M.auto_paused()
  return auto_paused
end

function M._handle_failure(result)
  handle_failure(result)
end

function M._auto_suppressed()
  return auto_suppressed()
end

function M._cmp_request_suppressed()
  return cmp_request_suppressed()
end

function M._set_backend(name, backend)
  backends[name] = backend
end

function M._generation(bufnr)
  local state = state_for(bufnr)
  return state and state.generation or nil
end

function M._set_in_flight(bufnr, backend, handle)
  local state = assert(state_for(bufnr), 'buffer is not attached')
  state.backend = backend
  state.handle = handle
end

function M._cache_put(key, candidates)
  cache_put(key, candidates)
end

function M._cache_get(key)
  return cache_get(key)
end

function M._cache_size()
  return vim.tbl_count(candidate_cache)
end

function M._limit_candidates(candidates, max_lines, max_chars)
  return limit_candidates(candidates, max_lines, max_chars)
end

function M.is_attached(bufnr)
  return states[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

function M.detach(bufnr)
  local state = states[bufnr]
  if not state then
    return
  end
  cancel_in_flight(bufnr, state)
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
  ghost.dismiss(bufnr)
  states[bufnr] = nil
end

function M._reset()
  local buffers = vim.tbl_keys(states)
  for _, bufnr in ipairs(buffers) do
    M.detach(bufnr)
  end
  backends = { openai = openai, claude = claude, codex = codex }
  auto_paused = false
  auto_pause_notified = false
  candidate_cache = {}
  cache_clock = 0
end

return M
