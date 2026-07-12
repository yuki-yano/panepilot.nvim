local M = {}

local handle_states = setmetatable({}, { __mode = 'k' })

function M.build_prompt(request)
  return table.concat({
    request.system,
    '',
    '<terminal_context>',
    request.context,
    '</terminal_context>',
    '<draft>',
    request.buffer_before .. '<cursor/>' .. request.buffer_after,
    '</draft>',
  }, '\n')
end

local function finish(state, result, override)
  if state.called or (state.queued and not override) then
    return
  end
  state.result = result
  if state.queued then
    return
  end

  state.queued = true
  vim.schedule(function()
    if state.called then
      return
    end
    state.called = true
    state.callback(state.result)
  end)
end

function M.is_available()
  return vim.fn.executable('codex') == 1
end

function M.complete(request, callback, opts)
  opts = opts or require('panepilot.config').get().codex
  if not M.is_available() then
    vim.schedule(function()
      callback({ ok = false, kind = 'curl', message = 'codex executable was not found' })
    end)
    return nil
  end

  local prompt = M.build_prompt(request)
  local state = { callback = callback, queued = false, called = false, cancelled = false }
  local ok, process = pcall(vim.system, {
    'codex',
    'exec',
    '--skip-git-repo-check',
    '-s',
    'read-only',
    '-m',
    opts.model,
    '-c',
    ('model_reasoning_effort="%s"'):format(opts.reasoning_effort),
    '-',
  }, { text = true, stdin = prompt, timeout = opts.timeout_ms }, function(result)
    if state.cancelled then
      return
    end
    if result.code == 124 then
      finish(state, {
        ok = false,
        kind = 'curl',
        message = ('codex request timed out after %d ms'):format(opts.timeout_ms),
      })
      return
    end
    if result.code ~= 0 then
      finish(state, {
        ok = false,
        kind = 'curl',
        message = vim.trim(result.stderr or ('codex exited with code ' .. tostring(result.code))),
      })
      return
    end

    local candidate = result.stdout or ''
    if candidate:sub(-2) == '\r\n' then
      candidate = candidate:sub(1, -3)
    elseif candidate:sub(-1) == '\n' then
      candidate = candidate:sub(1, -2)
    end
    if candidate == '' then
      finish(state, { ok = false, kind = 'decode', message = 'codex returned empty output' })
      return
    end
    finish(state, { ok = true, candidates = { candidate } })
  end)

  if not ok then
    vim.schedule(function()
      callback({ ok = false, kind = 'curl', message = tostring(process) })
    end)
    return nil
  end

  state.process = process
  handle_states[process] = state
  return process
end

function M.cancel(handle)
  local state = handle_states[handle]
  if not state or state.called or state.cancelled then
    return
  end

  state.cancelled = true
  finish(state, { ok = false, kind = 'cancelled' }, true)
  if not handle:is_closing() then
    pcall(handle.kill, handle, 'sigterm')
  end
end

return M
