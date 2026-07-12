local openai = require('panepilot.backend.openai')

local M = {}

local HTTP_STATUS_MARKER = '__PANEPILOT_HTTP_STATUS__:'
local handle_states = setmetatable({}, { __mode = 'k' })

local function input_text(request)
  return table.concat({
    '<terminal_context>',
    request.context,
    '</terminal_context>',
    '<draft>',
    request.buffer_before .. '<cursor/>' .. request.buffer_after,
    '</draft>',
  }, '\n')
end

function M.build_payload(request, opts)
  return {
    model = opts.model,
    max_tokens = opts.max_tokens,
    system = request.system,
    messages = {
      { role = 'user', content = input_text(request) },
    },
    output_config = {
      format = {
        type = 'json_schema',
        schema = {
          type = 'object',
          properties = {
            candidates = {
              type = 'array',
              items = { type = 'string' },
              minItems = 1,
            },
          },
          required = { 'candidates' },
          additionalProperties = false,
        },
      },
    },
  }
end

function M.parse_response(body, n_candidates)
  local response_ok, response = pcall(vim.json.decode, body)
  if not response_ok or type(response) ~= 'table' then
    return nil, 'failed to decode Messages API response'
  end
  if response.stop_reason == 'refusal' then
    return nil, 'Claude refused to generate structured output'
  end
  if response.stop_reason == 'max_tokens' then
    return nil, 'Claude reached max_tokens before completing structured output'
  end
  if response.stop_reason == 'model_context_window_exceeded' then
    return nil, 'Claude reached the model context window before completing structured output'
  end

  local output_text
  if type(response.content) == 'table' then
    for _, block in ipairs(response.content) do
      if block.type == 'text' and type(block.text) == 'string' then
        output_text = block.text
        break
      end
    end
  end
  if not output_text then
    return nil, 'Messages API response did not contain text'
  end

  local output_ok, output = pcall(vim.json.decode, output_text)
  if not output_ok or type(output) ~= 'table' or type(output.candidates) ~= 'table' then
    return nil, 'failed to decode structured output'
  end
  if #output.candidates ~= n_candidates then
    return nil, ('structured output returned %d candidates; expected %d'):format(#output.candidates, n_candidates)
  end
  for _, candidate in ipairs(output.candidates) do
    if type(candidate) ~= 'string' then
      return nil, 'structured output candidate must be a string'
    end
    if candidate == '' then
      return nil, 'structured output candidate must not be empty'
    end
  end

  return output.candidates
end

local function parse_http_output(stdout)
  local marker_start = stdout:find('\n' .. HTTP_STATUS_MARKER, 1, true)
  if not marker_start then
    return nil, nil
  end

  local body = stdout:sub(1, marker_start - 1)
  local status = tonumber(stdout:sub(marker_start + #HTTP_STATUS_MARKER + 1))
  return body, status
end

local function http_error_message(body, status)
  local message = 'Claude API returned HTTP ' .. status
  local ok, response = pcall(vim.json.decode, body)
  if not ok or type(response) ~= 'table' or type(response.error) ~= 'table' then
    return message
  end
  if type(response.error.type) == 'string' and response.error.type ~= '' then
    message = message .. ' (' .. response.error.type .. ')'
  end
  if type(response.error.message) == 'string' and response.error.message ~= '' then
    message = message .. ': ' .. response.error.message
  end
  if type(response.request_id) == 'string' and response.request_id ~= '' then
    message = message .. ' [request_id=' .. response.request_id .. ']'
  end
  return message
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

function M.is_available(opts)
  local api_key = vim.env[opts.api_key_env]
  if type(api_key) ~= 'string' or api_key == '' then
    return false
  end
  return openai.curl_supported()
end

function M.complete(request, callback, opts)
  opts = opts or require('panepilot.config').get().claude
  local api_key = vim.env[opts.api_key_env]
  if type(api_key) ~= 'string' or api_key == '' then
    vim.schedule(function()
      callback({ ok = false, kind = 'curl', message = opts.api_key_env .. ' is not set' })
    end)
    return nil
  end

  local body = vim.json.encode(M.build_payload(request, opts))
  local state = { callback = callback, queued = false, called = false, cancelled = false }
  local ok, process = pcall(vim.system, {
    'curl',
    '--silent',
    '--show-error',
    '--request',
    'POST',
    'https://api.anthropic.com/v1/messages',
    '--header',
    'Content-Type: application/json',
    '--header',
    'anthropic-version: 2023-06-01',
    '--variable',
    '%' .. opts.api_key_env,
    '--expand-header',
    'x-api-key: {{' .. opts.api_key_env .. '}}',
    '--data-binary',
    '@-',
    '--write-out',
    '\n' .. HTTP_STATUS_MARKER .. '%{http_code}',
  }, {
    text = true,
    stdin = body,
    timeout = opts.timeout_ms,
  }, function(result)
    if state.cancelled then
      return
    end
    if result.code == 124 then
      finish(state, {
        ok = false,
        kind = 'curl',
        message = ('request timed out after %d ms'):format(opts.timeout_ms),
      })
      return
    end
    if result.code ~= 0 then
      finish(state, {
        ok = false,
        kind = 'curl',
        message = vim.trim(result.stderr or ('curl exited with code ' .. tostring(result.code))),
      })
      return
    end

    local response_body, status = parse_http_output(result.stdout or '')
    if not status then
      finish(state, { ok = false, kind = 'decode', message = 'HTTP status marker was missing' })
      return
    end
    if status < 200 or status >= 300 then
      finish(state, {
        ok = false,
        kind = 'http',
        status = status,
        message = http_error_message(response_body, status),
      })
      return
    end

    local candidates, parse_error = M.parse_response(response_body, request.n_candidates)
    if not candidates then
      finish(state, { ok = false, kind = 'decode', message = parse_error })
      return
    end
    finish(state, { ok = true, candidates = candidates })
  end)

  if not ok then
    vim.schedule(function()
      callback({ ok = false, kind = 'curl', message = tostring(process) })
    end)
    return nil
  end

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
