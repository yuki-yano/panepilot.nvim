local helpers = require('tests.helpers')

local new_set = MiniTest.new_set
local eq = helpers.eq
local openai = require('panepilot.backend.openai')

local T = new_set()

local request = {
  context = 'pane output',
  buffer_before = 'draft before',
  buffer_after = 'draft after',
  pane_id = '%4',
  n_candidates = 2,
  max_candidate_lines = 2,
  max_candidate_chars = 80,
}

local opts = {
  model = 'gpt-5.6-luna',
  reasoning_effort = 'none',
  max_output_tokens = 400,
  api_key_env = 'PANEPILOT_API_KEY',
  timeout_ms = 10000,
}

T['system_prompt()'] = new_set()

T['system_prompt()']['uses the fixed prompt with the requested candidate count'] = function()
  eq(
    openai.system_prompt(2, 2, 80),
    table.concat({
      'あなたは AI コーディングエージェントに送るプロンプトの補完エンジンです。',
      '<terminal_context> はユーザーが操作しているターミナル画面(送信先エージェントの出力)、<draft> はユーザーが書きかけのプロンプト、<cursor/> はカーソル位置を示します。',
      'ターミナルの文脈を踏まえ、<cursor/> の位置から自然に続くテキストを日本語で生成してください。',
      '',
      '- 候補は互いに方向性の異なるものを 2 件生成する',
      '- 各候補は原則1文、1行40文字程度を目安に最大2行かつ80文字以内に収め、先の展開を過剰に先回りしない',
      '- 各候補は <cursor/> の直後に挿入されるテキストそのものだけを含める(前置き・引用符・説明・<draft> 内の既存テキストの繰り返しを含めない)',
      '- 書きかけの文の途中であれば、まずその文を自然に完成させることを優先する',
      '- ターミナル画面でエージェントが質問や確認をしている場合は、それに答える方向の候補を優先する',
    }, '\n')
  )
end

T['parse_curl_version()'] = new_set()

T['parse_curl_version()']['parses the curl banner'] = function()
  eq(openai.parse_curl_version('curl 8.7.1 (arm64-apple-darwin)'), { major = 8, minor = 7, patch = 1 })
  eq(openai.parse_curl_version('unknown'), nil)
end

T['build_payload()'] = new_set()

T['build_payload()']['builds the Responses API request in cache-friendly order'] = function()
  local payload = openai.build_payload(request, opts)
  eq(payload.model, 'gpt-5.6-luna')
  eq(payload.reasoning, { effort = 'none' })
  eq(payload.max_output_tokens, 400)
  eq(payload.prompt_cache_key, 'panepilot:%4')
  eq(payload.instructions, openai.system_prompt(2, 2, 80))
  eq(
    payload.input,
    '<terminal_context>\npane output\n</terminal_context>\n<draft>\ndraft before<cursor/>draft after\n</draft>'
  )
  eq(payload.text.format.name, 'panepilot_candidates')
  eq(payload.text.format.strict, true)
  eq(payload.text.format.schema.properties.candidates.minItems, 2)
  eq(payload.text.format.schema.properties.candidates.maxItems, 2)
  eq(payload.text.format.schema.required, { 'candidates' })
  eq(payload.text.format.schema.additionalProperties, false)
end

T['parse_response()'] = new_set()

local function response_body(output_text)
  return vim.json.encode({
    output = {
      {
        type = 'message',
        content = {
          { type = 'output_text', text = output_text },
        },
      },
    },
  })
end

T['parse_response()']['parses structured candidates from output_text'] = function()
  local candidates, err =
    openai.parse_response(response_body(vim.json.encode({ candidates = { 'first', 'second' } })), 2)
  eq(err, nil)
  eq(candidates, { 'first', 'second' })
end

T['parse_response()']['rejects malformed response JSON'] = function()
  local candidates, err = openai.parse_response('{', 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'decode Responses API')
end

T['parse_response()']['rejects malformed structured output and wrong counts'] = function()
  local candidates, err = openai.parse_response(response_body('not-json'), 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'structured output')

  candidates, err = openai.parse_response(response_body(vim.json.encode({ candidates = { 'only one' } })), 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'expected 2')
end

T['parse_response()']['rejects empty candidates'] = function()
  local candidates, err = openai.parse_response(response_body(vim.json.encode({ candidates = { 'first', '' } })), 2)
  eq(candidates, nil)
  helpers.expect.match(err, 'must not be empty')
end

T['complete()'] = new_set()

T['complete()']['cancels idempotently and calls back once with cancelled'] = function()
  local original_system = vim.system
  local original_schedule = vim.schedule
  local original_key = vim.env.PANEPILOT_TEST_KEY
  local kill_count = 0
  local fake_handle = {
    is_closing = function()
      return false
    end,
    kill = function()
      kill_count = kill_count + 1
    end,
  }
  vim.system = function()
    return fake_handle
  end
  local scheduled = {}
  vim.schedule = function(callback)
    table.insert(scheduled, callback)
  end
  vim.env.PANEPILOT_TEST_KEY = 'test-key'

  local results = {}
  local test_opts = vim.tbl_extend('force', opts, { api_key_env = 'PANEPILOT_TEST_KEY' })
  local handle = openai.complete(request, function(result)
    table.insert(results, result)
  end, test_opts)
  openai.cancel(handle)
  openai.cancel(handle)
  local observed_kill_count = kill_count
  for _, callback in ipairs(scheduled) do
    callback()
  end

  vim.system = original_system
  vim.schedule = original_schedule
  vim.env.PANEPILOT_TEST_KEY = original_key
  eq(handle, fake_handle)
  eq(results, { { ok = false, kind = 'cancelled' } })
  eq(observed_kill_count, 1)
end

T['complete()']['reports vim.system timeouts as curl failures'] = function()
  local original_system = vim.system
  local original_key = vim.env.PANEPILOT_TEST_KEY
  local captured_arguments
  local captured_options
  local fake_handle = {
    is_closing = function()
      return true
    end,
  }
  vim.system = function(arguments, options, on_exit)
    captured_arguments = arguments
    captured_options = options
    vim.schedule(function()
      on_exit({ code = 124, signal = 9, stdout = '', stderr = '' })
    end)
    return fake_handle
  end
  vim.env.PANEPILOT_TEST_KEY = 'test-key'

  local result
  local test_opts = vim.tbl_extend('force', opts, { api_key_env = 'PANEPILOT_TEST_KEY' })
  openai.complete(request, function(value)
    result = value
  end, test_opts)
  vim.wait(1000, function()
    return result ~= nil
  end)

  vim.system = original_system
  vim.env.PANEPILOT_TEST_KEY = original_key
  eq(result.ok, false)
  eq(result.kind, 'curl')
  helpers.expect.match(result.message, 'timed out after 10000 ms')
  eq(captured_options.timeout, 10000)
  helpers.expect.match(captured_options.stdin, 'panepilot_candidates')
  eq(table.concat(captured_arguments, ' '):find('test%-key'), nil)
  helpers.expect.match(table.concat(captured_arguments, ' '), 'expand%-header')
  helpers.expect.match(table.concat(captured_arguments, ' '), '%%PANEPILOT_TEST_KEY')
end

T['complete()']['lets cancel override a queued callback until it is actually called'] = function()
  local original_system = vim.system
  local original_key = vim.env.PANEPILOT_TEST_KEY
  local on_exit
  local fake_handle = {
    is_closing = function()
      return true
    end,
  }
  vim.system = function(_, _, callback)
    on_exit = callback
    return fake_handle
  end
  vim.env.PANEPILOT_TEST_KEY = 'test-key'

  local results = {}
  local test_opts = vim.tbl_extend('force', opts, { api_key_env = 'PANEPILOT_TEST_KEY' })
  local handle = openai.complete(request, function(result)
    table.insert(results, result)
  end, test_opts)
  local output_text = vim.json.encode({ candidates = { 'first', 'second' } })
  on_exit({
    code = 0,
    signal = 0,
    stderr = '',
    stdout = response_body(output_text) .. '\n__PANEPILOT_HTTP_STATUS__:200',
  })
  openai.cancel(handle)
  vim.wait(1000, function()
    return #results == 1
  end)

  vim.system = original_system
  vim.env.PANEPILOT_TEST_KEY = original_key
  eq(results, { { ok = false, kind = 'cancelled' } })
end

return T
