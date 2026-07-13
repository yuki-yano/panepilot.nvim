local M = {}

local HTTP_STATUS_MARKER = '__PANEPILOT_HTTP_STATUS__:'
local handle_states = setmetatable({}, { __mode = 'k' })
local curl_support

local function system_prompt(n_candidates, max_candidate_lines, max_candidate_chars)
  local chars_per_line = math.ceil(max_candidate_chars / max_candidate_lines)
  return table.concat({
    'あなたは AI コーディングエージェントに送るプロンプトの補完エンジンです。',
    '<terminal_context> はユーザーが操作しているターミナル画面(送信先エージェントの出力)、<draft> はユーザーが書きかけのプロンプト、<cursor/> はカーソル位置を示します。',
    'ターミナルの文脈を踏まえ、<cursor/> の位置から自然に続くテキストを日本語で生成してください。',
    '',
    ('- 候補は互いに方向性の異なるものを %d 件生成する'):format(n_candidates),
    ('- 各候補は原則1文、1行%d文字程度を目安に最大%d行かつ%d文字以内に収め、先の展開を過剰に先回りしない'):format(
      chars_per_line,
      max_candidate_lines,
      max_candidate_chars
    ),
    '- 各候補は <cursor/> の直後に挿入されるテキストそのものだけを含める(前置き・引用符・説明・<draft> 内の既存テキストの繰り返しを含めない)',
    '- 書きかけの文の途中であれば、まずその文を自然に完成させることを優先する',
    '- ターミナル画面でエージェントが質問や確認をしている場合は、それに答える方向の候補を優先する',
  }, '\n')
end

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
  local n_candidates = request.n_candidates
  return {
    model = opts.model,
    reasoning = { effort = opts.reasoning_effort },
    max_output_tokens = opts.max_output_tokens,
    prompt_cache_key = 'panepilot:' .. request.pane_id,
    instructions = request.system,
    input = input_text(request),
    text = {
      format = {
        type = 'json_schema',
        name = 'panepilot_candidates',
        strict = true,
        schema = {
          type = 'object',
          properties = {
            candidates = {
              type = 'array',
              items = { type = 'string' },
              minItems = n_candidates,
              maxItems = n_candidates,
            },
          },
          required = { 'candidates' },
          additionalProperties = false,
        },
      },
    },
  }
end

function M.system_prompt(n_candidates, max_candidate_lines, max_candidate_chars)
  return system_prompt(n_candidates, max_candidate_lines, max_candidate_chars)
end

local function extract_output_text(response)
  if type(response.output) ~= 'table' then
    return nil
  end

  for _, output in ipairs(response.output) do
    if type(output.content) == 'table' then
      for _, content in ipairs(output.content) do
        if content.type == 'output_text' and type(content.text) == 'string' then
          return content.text
        end
      end
    end
  end

  return nil
end

function M.parse_response(body, n_candidates)
  local response_ok, response = pcall(vim.json.decode, body)
  if not response_ok or type(response) ~= 'table' then
    return nil, 'failed to decode Responses API response'
  end

  local output_text = extract_output_text(response)
  if not output_text then
    return nil, 'Responses API response did not contain output_text'
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
  return M.curl_supported()
end

function M.parse_curl_version(output)
  local major, minor, patch = (output or ''):match('curl%s+(%d+)%.(%d+)%.(%d+)')
  if not major then
    return nil
  end
  return { major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch) }
end

function M.curl_supported()
  if curl_support then
    return curl_support.ok, curl_support.message
  end
  if vim.fn.executable('curl') ~= 1 then
    curl_support = { ok = false, message = 'curl was not found' }
    return false, curl_support.message
  end

  local ok, process = pcall(vim.system, { 'curl', '--version' }, { text = true })
  if not ok then
    curl_support = { ok = false, message = tostring(process) }
    return false, curl_support.message
  end
  local result = process:wait()
  local version = result.code == 0 and M.parse_curl_version(result.stdout) or nil
  if not version then
    curl_support = { ok = false, message = 'failed to detect curl version' }
    return false, curl_support.message
  end

  local supported = version.major > 8 or (version.major == 8 and version.minor >= 3)
  local version_text = ('%d.%d.%d'):format(version.major, version.minor, version.patch)
  if not supported then
    curl_support = { ok = false, message = 'curl 8.3+ is required; found ' .. version_text }
    return false, curl_support.message
  end

  curl_support = { ok = true, message = version_text }
  return true, version_text
end

function M.complete(request, callback, opts)
  opts = opts or require('panepilot.config').get().openai
  local api_key = vim.env[opts.api_key_env]
  if type(api_key) ~= 'string' or api_key == '' then
    vim.schedule(function()
      callback({ ok = false, kind = 'curl', message = opts.api_key_env .. ' is not set' })
    end)
    return nil
  end

  local body = vim.json.encode(M.build_payload(request, opts))
  local state = {
    callback = callback,
    queued = false,
    called = false,
    cancelled = false,
    timeout_ms = opts.timeout_ms,
  }
  local ok, process = pcall(vim.system, {
    'curl',
    '--silent',
    '--show-error',
    '--request',
    'POST',
    'https://api.openai.com/v1/responses',
    '--header',
    'Content-Type: application/json',
    '--variable',
    '%' .. opts.api_key_env,
    '--expand-header',
    'Authorization: Bearer {{' .. opts.api_key_env .. '}}',
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
      finish(state, { ok = false, kind = 'http', status = status, message = 'OpenAI API returned HTTP ' .. status })
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
