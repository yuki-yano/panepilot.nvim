local M = {}

local pane_observations = {}

local SECRET_SUFFIXES = {
  'key',
  'token',
  'secret',
  'password',
  'passwd',
  'credential',
}

local function schedule(callback, value)
  vim.schedule(function()
    callback(value)
  end)
end

local function run(args, callback)
  local ok, process = pcall(vim.system, args, { text = true }, function(result)
    schedule(callback, result)
  end)

  if not ok then
    schedule(callback, { code = -1, stdout = '', stderr = tostring(process) })
    return nil
  end

  return process
end

local function mask_openai_tokens(text)
  return text:gsub('sk%-[%w_%-]+', function(match)
    return #match >= 23 and '<masked>' or match
  end)
end

local function mask_key_values_in_line(line)
  local search_from = 1

  while search_from <= #line do
    local key_start, separator_end, key, separator = line:find('([%w_%-]+)(%s*[:=]%s*)', search_from)
    if not key_start then
      break
    end

    local value_start = separator_end + 1
    local lower_key = key:lower()
    local secret_key = false
    for _, suffix in ipairs(SECRET_SUFFIXES) do
      if lower_key:sub(-#suffix) == suffix then
        secret_key = true
        break
      end
    end

    if secret_key and value_start <= #line then
      local quote = line:sub(value_start, value_start)
      local value_end

      if quote == '"' or quote == "'" then
        value_end = line:find(quote, value_start + 1, true) or #line
      else
        local whitespace = line:find('%s', value_start)
        value_end = whitespace and (whitespace - 1) or #line
      end

      if value_end >= value_start then
        line = line:sub(1, value_start - 1) .. '<masked>' .. line:sub(value_end + 1)
        search_from = value_start + #'<masked>'
      else
        search_from = separator_end + 1
      end
    else
      search_from = separator_end + 1
    end
  end

  return line
end

local function mask_key_values(text)
  local lines = vim.split(text, '\n', { plain = true })
  for index, line in ipairs(lines) do
    lines[index] = mask_key_values_in_line(line)
  end
  return table.concat(lines, '\n')
end

function M.mask(text, extra_patterns)
  local masked = mask_key_values(mask_openai_tokens(text or ''))

  for _, rule in ipairs(extra_patterns or {}) do
    if type(rule) == 'function' then
      masked = rule(masked)
    else
      masked = masked:gsub(rule.pattern, rule.replace or '<masked>')
    end
  end

  return masked
end

function M.parse_target_panes(value)
  if type(value) ~= 'string' then
    return nil
  end

  for pane_id in value:gmatch('[^,]+') do
    pane_id = vim.trim(pane_id)
    if pane_id ~= '' then
      return pane_id
    end
  end

  return nil
end

function M.hash(content)
  return vim.fn.sha256(content)
end

function M.observe_pane(pane_id, content, quiet_sec, now_ms)
  now_ms = now_ms or (vim.uv.hrtime() / 1000000)
  local hash = M.hash(content)
  local observation = pane_observations[pane_id]
  if not observation then
    pane_observations[pane_id] = { hash = hash, changed_at = now_ms }
    return false, hash, quiet_sec * 1000
  end

  if observation.hash ~= hash then
    observation.hash = hash
    observation.changed_at = now_ms
    return false, hash, quiet_sec * 1000
  end

  local elapsed = observation.changed_at and (now_ms - observation.changed_at) or math.huge
  if elapsed < quiet_sec * 1000 then
    return false, hash, quiet_sec * 1000 - elapsed
  end

  return true, hash, 0
end

function M._reset_observations()
  pane_observations = {}
end

function M.multiplexer()
  if vim.env.HERDR_ENV == '1' or (vim.env.HERDR_ACTIVE_PANE_ID and vim.env.HERDR_ACTIVE_PANE_ID ~= '') then
    return 'herdr'
  end
  if vim.env.TMUX_PANE and vim.env.TMUX_PANE ~= '' then
    return 'tmux'
  end
  return nil
end

local function resolve_herdr_target_pane()
  local pane_id = vim.env.EDITPROMPT_TARGET_PANE
  if not pane_id or vim.trim(pane_id) == '' then
    return nil, 'EDITPROMPT_TARGET_PANE is not set'
  end
  return vim.trim(pane_id)
end

function M.resolve_target_pane(callback)
  local multiplexer = M.multiplexer()
  if not multiplexer then
    schedule(callback, { ok = false, message = 'tmux or Herdr environment was not detected' })
    return nil
  end
  if multiplexer == 'herdr' then
    local pane_id, message = resolve_herdr_target_pane()
    schedule(
      callback,
      pane_id and { ok = true, multiplexer = multiplexer, pane_id = pane_id } or { ok = false, message = message }
    )
    return nil
  end
  local tmux_pane = vim.env.TMUX_PANE

  return run({ 'tmux', 'show', '-pt', tmux_pane, '-v', '@editprompt_target_panes' }, function(result)
    if result.code ~= 0 then
      callback({ ok = false, message = vim.trim(result.stderr or 'tmux show failed') })
      return
    end

    local pane_id = M.parse_target_panes(result.stdout)
    if not pane_id then
      callback({ ok = false, message = '@editprompt_target_panes is not set' })
      return
    end

    callback({ ok = true, multiplexer = multiplexer, pane_id = pane_id })
  end)
end

function M.capture_pane(multiplexer, pane_id, lines, callback)
  local args
  if multiplexer == 'herdr' then
    args = { 'herdr', 'pane', 'read', pane_id, '--source', 'recent-unwrapped', '--lines', tostring(lines) }
  elseif multiplexer == 'tmux' then
    args = { 'tmux', 'capture-pane', '-p', '-t', pane_id, '-S', '-' .. tostring(lines) }
  else
    schedule(callback, { ok = false, message = 'unsupported multiplexer: ' .. tostring(multiplexer) })
    return nil
  end

  return run(args, function(result)
    if result.code ~= 0 then
      local fallback = multiplexer == 'herdr' and 'herdr pane read failed' or 'tmux capture-pane failed'
      local message = vim.trim(result.stderr or '')
      callback({ ok = false, message = message ~= '' and message or fallback })
      return
    end

    callback({ ok = true, content = result.stdout or '' })
  end)
end

function M.get(opts, callback)
  local handle = { done = false, process = nil, callback = callback }

  local function finish(result)
    if handle.done then
      return
    end
    handle.done = true
    callback(result)
  end

  handle.process = M.resolve_target_pane(function(resolved)
    if handle.done then
      return
    end
    if not resolved.ok then
      finish(resolved)
      return
    end

    handle.process = M.capture_pane(resolved.multiplexer, resolved.pane_id, opts.lines, function(captured)
      if handle.done then
        return
      end
      if not captured.ok then
        finish(captured)
        return
      end

      finish({
        ok = true,
        pane_id = resolved.pane_id,
        content = M.mask(captured.content, opts.mask_patterns),
      })
    end)
  end)

  return handle
end

function M.cancel(handle)
  if not handle or handle.done then
    return
  end
  handle.done = true
  local process = handle.process
  if process and not process:is_closing() then
    pcall(process.kill, process, 'sigterm')
  end
  schedule(handle.callback, { ok = false, cancelled = true, message = 'context capture cancelled' })
end

function M.resolve_target_pane_sync()
  local multiplexer = M.multiplexer()
  if not multiplexer then
    return nil, 'tmux or Herdr environment was not detected'
  end
  if multiplexer == 'herdr' then
    return resolve_herdr_target_pane()
  end

  local tmux_pane = vim.env.TMUX_PANE

  local ok, process = pcall(vim.system, {
    'tmux',
    'show',
    '-pt',
    tmux_pane,
    '-v',
    '@editprompt_target_panes',
  }, { text = true })
  if not ok then
    return nil, tostring(process)
  end

  local result = process:wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or 'tmux show failed')
  end

  local pane_id = M.parse_target_panes(result.stdout)
  if not pane_id then
    return nil, '@editprompt_target_panes is not set'
  end

  return pane_id
end

return M
