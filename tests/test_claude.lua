local helpers = require('tests.helpers')

local new_set = MiniTest.new_set
local eq = helpers.eq
local claude = require('panepilot.backend.claude')

local T = new_set()

local request = {
  system = 'system prompt',
  context = 'pane output',
  buffer_before = 'draft before',
  buffer_after = 'draft after',
  pane_id = '%4',
  n_candidates = 2,
  max_candidate_lines = 2,
  max_candidate_chars = 80,
}

local opts = {
  model = 'claude-haiku-4-5',
  max_tokens = 400,
  api_key_env = 'PANEPILOT_CLAUDE_TEST_KEY',
  timeout_ms = 10000,
}

local function response_body(candidates)
  return vim.json.encode({
    content = {
      { type = 'text', text = vim.json.encode({ candidates = candidates }) },
    },
    stop_reason = 'end_turn',
  })
end

T['build_payload()'] = new_set()

T['build_payload()']['builds a structured Messages API request for Haiku'] = function()
  local payload = claude.build_payload(request, opts)
  eq(payload.model, 'claude-haiku-4-5')
  eq(payload.max_tokens, 400)
  eq(payload.system, 'system prompt')
  eq(payload.messages, {
    {
      role = 'user',
      content = '<terminal_context>\npane output\n</terminal_context>\n<draft>\ndraft before<cursor/>draft after\n</draft>',
    },
  })
  eq(payload.output_config.format.type, 'json_schema')
  eq(payload.output_config.format.schema.properties.candidates.minItems, 1)
  eq(payload.output_config.format.schema.properties.candidates.maxItems, nil)
  eq(payload.output_config.format.schema.required, { 'candidates' })
  eq(payload.output_config.format.schema.additionalProperties, false)
end

T['parse_response()'] = new_set()

T['parse_response()']['parses the requested number of candidates'] = function()
  local candidates, err = claude.parse_response(response_body({ 'first', 'second' }), 2)
  eq(err, nil)
  eq(candidates, { 'first', 'second' })
end

T['parse_response()']['rejects malformed or missing Messages API output'] = function()
  local candidates, err = claude.parse_response('{', 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'decode Messages API')

  candidates, err = claude.parse_response(vim.json.encode({ content = {} }), 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'did not contain text')

  candidates, err = claude.parse_response(vim.json.encode({ content = { { type = 'text', text = 'not-json' } } }), 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'structured output')
end

T['parse_response()']['rejects wrong counts and non-string candidates'] = function()
  local candidates, err = claude.parse_response(response_body({ 'only one' }), 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'expected 2')

  candidates, err = claude.parse_response(response_body({ 'first', 2 }), 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'must be a string')

  candidates, err = claude.parse_response(response_body({ 'first', '' }), 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'must not be empty')
end

T['parse_response()']['rejects refusals and truncated structured output'] = function()
  local body = vim.json.encode({ stop_reason = 'refusal', content = {} })
  local candidates, err = claude.parse_response(body, 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'refused')

  body = vim.json.encode({ stop_reason = 'max_tokens', content = {} })
  candidates, err = claude.parse_response(body, 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'max_tokens')

  body = vim.json.encode({ stop_reason = 'model_context_window_exceeded', content = {} })
  candidates, err = claude.parse_response(body, 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'context window')
end

T['is_available()'] = new_set()

T['is_available()']['requires the configured key and supported curl'] = function()
  local openai = require('panepilot.backend.openai')
  local original_curl_supported = openai.curl_supported
  local original_key = vim.env[opts.api_key_env]
  openai.curl_supported = function()
    return true
  end

  vim.env[opts.api_key_env] = nil
  eq(claude.is_available(opts), false)
  vim.env[opts.api_key_env] = 'set'
  eq(claude.is_available(opts), true)

  openai.curl_supported = function()
    return false
  end
  eq(claude.is_available(opts), false)
  openai.curl_supported = original_curl_supported
  vim.env[opts.api_key_env] = original_key
end

T['complete()'] = new_set()

T['complete()']['posts through stdin without exposing the API key in arguments'] = function()
  local original_system = vim.system
  local original_key = vim.env[opts.api_key_env]
  local arguments
  local system_opts
  vim.env[opts.api_key_env] = 'claude-test-secret'
  vim.system = function(args, call_opts, on_exit)
    arguments = args
    system_opts = call_opts
    vim.schedule(function()
      on_exit({
        code = 0,
        signal = 0,
        stderr = '',
        stdout = response_body({ 'first', 'second' }) .. '\n__PANEPILOT_HTTP_STATUS__:200',
      })
    end)
    return {
      is_closing = function()
        return true
      end,
    }
  end

  local result
  claude.complete(request, function(value)
    result = value
  end, opts)
  vim.wait(1000, function()
    return result ~= nil
  end)

  vim.system = original_system
  vim.env[opts.api_key_env] = original_key
  eq(result, { ok = true, candidates = { 'first', 'second' } })
  local command = table.concat(arguments, ' ')
  helpers.expect.match(command, 'https://api%.anthropic%.com/v1/messages')
  helpers.expect.match(command, 'anthropic%-version: 2023%-06%-01')
  helpers.expect.match(command, 'x%-api%-key')
  helpers.expect.match(command, 'expand%-header')
  helpers.expect.match(command, '%%PANEPILOT_CLAUDE_TEST_KEY')
  eq(command:find('claude-test-secret', 1, true), nil)
  eq(command:find('pane output', 1, true), nil)
  helpers.expect.match(system_opts.stdin, 'pane output')
  helpers.expect.match(system_opts.stdin, 'panepilot')
  eq(system_opts.timeout, 10000)
end

T['complete()']['reports missing keys and vim.system startup failures'] = function()
  local original_system = vim.system
  local original_key = vim.env[opts.api_key_env]
  vim.env[opts.api_key_env] = nil

  local missing
  claude.complete(request, function(value)
    missing = value
  end, opts)
  vim.wait(1000, function()
    return missing ~= nil
  end)
  eq(missing.kind, 'curl')
  helpers.expect.match(missing.message, opts.api_key_env)

  vim.env[opts.api_key_env] = 'set'
  vim.system = function()
    error('spawn failed')
  end
  local startup
  claude.complete(request, function(value)
    startup = value
  end, opts)
  vim.wait(1000, function()
    return startup ~= nil
  end)

  vim.system = original_system
  vim.env[opts.api_key_env] = original_key
  eq(startup.kind, 'curl')
  helpers.expect.match(startup.message, 'spawn failed')
end

T['complete()']['distinguishes timeout, curl, HTTP, marker, and decode failures'] = function()
  local original_system = vim.system
  local original_key = vim.env[opts.api_key_env]
  vim.env[opts.api_key_env] = 'set'
  local responses = {
    { code = 124, signal = 9, stdout = '', stderr = '' },
    { code = 2, signal = 0, stdout = '', stderr = 'network failed' },
    {
      code = 0,
      signal = 0,
      stdout = vim.json.encode({
        error = { type = 'rate_limit_error', message = 'slow down' },
        request_id = 'req_test',
      }) .. '\n__PANEPILOT_HTTP_STATUS__:429',
      stderr = '',
    },
    { code = 0, signal = 0, stdout = '{}', stderr = '' },
    { code = 0, signal = 0, stdout = '{\n__PANEPILOT_HTTP_STATUS__:200', stderr = '' },
  }
  local invocation = 0
  vim.system = function(_, _, on_exit)
    invocation = invocation + 1
    local response = responses[invocation]
    vim.schedule(function()
      on_exit(response)
    end)
    return {
      is_closing = function()
        return true
      end,
    }
  end

  local results = {}
  for _ = 1, #responses do
    claude.complete(request, function(value)
      table.insert(results, value)
    end, opts)
  end
  vim.wait(1000, function()
    return #results == #responses
  end)

  vim.system = original_system
  vim.env[opts.api_key_env] = original_key
  eq(results[1].kind, 'curl')
  helpers.expect.match(results[1].message, 'timed out')
  eq(results[2], { ok = false, kind = 'curl', message = 'network failed' })
  eq(results[3].kind, 'http')
  eq(results[3].status, 429)
  helpers.expect.match(results[3].message, 'rate_limit_error')
  helpers.expect.match(results[3].message, 'slow down')
  helpers.expect.match(results[3].message, 'req_test')
  eq(results[4].kind, 'decode')
  helpers.expect.match(results[4].message, 'marker')
  eq(results[5].kind, 'decode')
  helpers.expect.match(results[5].message, 'Messages API')
end

T['complete()']['cancels idempotently and calls back once'] = function()
  local original_system = vim.system
  local original_schedule = vim.schedule
  local original_key = vim.env[opts.api_key_env]
  local scheduled = {}
  local kill_count = 0
  local handle = {
    is_closing = function()
      return false
    end,
    kill = function()
      kill_count = kill_count + 1
    end,
  }
  vim.env[opts.api_key_env] = 'set'
  vim.schedule = function(callback)
    table.insert(scheduled, callback)
  end
  vim.system = function()
    return handle
  end

  local results = {}
  local returned = claude.complete(request, function(value)
    table.insert(results, value)
  end, opts)
  claude.cancel(returned)
  claude.cancel(returned)
  for _, callback in ipairs(scheduled) do
    callback()
  end

  vim.system = original_system
  vim.schedule = original_schedule
  vim.env[opts.api_key_env] = original_key
  eq(returned, handle)
  eq(results, { { ok = false, kind = 'cancelled' } })
  eq(kill_count, 1)
end

T['complete()']['lets cancellation override a queued success'] = function()
  local original_system = vim.system
  local original_key = vim.env[opts.api_key_env]
  local on_exit
  local handle = {
    is_closing = function()
      return true
    end,
  }
  vim.env[opts.api_key_env] = 'set'
  vim.system = function(_, _, callback)
    on_exit = callback
    return handle
  end

  local results = {}
  local returned = claude.complete(request, function(value)
    table.insert(results, value)
  end, opts)
  on_exit({
    code = 0,
    signal = 0,
    stderr = '',
    stdout = response_body({ 'first', 'second' }) .. '\n__PANEPILOT_HTTP_STATUS__:200',
  })
  claude.cancel(returned)
  vim.wait(1000, function()
    return #results == 1
  end)

  vim.system = original_system
  vim.env[opts.api_key_env] = original_key
  eq(results, { { ok = false, kind = 'cancelled' } })
end

return T
