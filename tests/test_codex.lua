local helpers = require('tests.helpers')

local new_set = MiniTest.new_set
local eq = helpers.eq
local codex = require('panepilot.backend.codex')

local T = new_set()

local request = {
  system = 'system prompt',
  context = 'secret pane context',
  buffer_before = 'draft before',
  buffer_after = 'draft after',
  pane_id = '%4',
  n_candidates = 1,
}

local opts = {
  model = 'gpt-5.3-codex-spark',
  reasoning_effort = 'low',
  timeout_ms = 30000,
}

T['build_prompt()'] = new_set()

T['build_prompt()']['orders system, pane context, and draft'] = function()
  eq(
    codex.build_prompt(request),
    'system prompt\n\n<terminal_context>\nsecret pane context\n</terminal_context>\n<draft>\ndraft before<cursor/>draft after\n</draft>'
  )
end

T['complete()'] = new_set()

T['complete()']['passes the prompt over stdin and returns one candidate'] = function()
  local original_system = vim.system
  local original_available = codex.is_available
  local arguments
  local options
  codex.is_available = function()
    return true
  end
  vim.system = function(args, system_opts, on_exit)
    arguments = args
    options = system_opts
    vim.schedule(function()
      on_exit({ code = 0, signal = 0, stdout = ' candidate\n\n', stderr = '' })
    end)
    return {
      is_closing = function()
        return true
      end,
    }
  end

  local result
  codex.complete(request, function(value)
    result = value
  end, opts)
  vim.wait(1000, function()
    return result ~= nil
  end)
  vim.system = original_system
  codex.is_available = original_available

  eq(result, { ok = true, candidates = { ' candidate\n' } })
  eq(arguments[#arguments], '-')
  eq(table.concat(arguments, ' '):find('secret pane context', 1, true), nil)
  eq(options.stdin, codex.build_prompt(request))
  eq(options.timeout, 30000)
end

T['complete()']['cancels idempotently and calls back once with cancelled'] = function()
  local original_system = vim.system
  local original_available = codex.is_available
  local original_schedule = vim.schedule
  local kill_count = 0
  local fake_handle = {
    is_closing = function()
      return false
    end,
    kill = function()
      kill_count = kill_count + 1
    end,
  }
  codex.is_available = function()
    return true
  end
  vim.system = function()
    return fake_handle
  end
  local scheduled = {}
  vim.schedule = function(callback)
    table.insert(scheduled, callback)
  end

  local results = {}
  local handle = codex.complete(request, function(result)
    table.insert(results, result)
  end, opts)
  codex.cancel(handle)
  codex.cancel(handle)
  for _, callback in ipairs(scheduled) do
    callback()
  end

  vim.system = original_system
  codex.is_available = original_available
  vim.schedule = original_schedule
  eq(handle, fake_handle)
  eq(results, { { ok = false, kind = 'cancelled' } })
  eq(kill_count, 1)
end

T['complete()']['reports timeout and process failures as curl failures'] = function()
  local original_system = vim.system
  local original_available = codex.is_available
  local invocations = 0
  codex.is_available = function()
    return true
  end
  vim.system = function(_, system_opts, on_exit)
    invocations = invocations + 1
    local result = invocations == 1 and { code = 124, signal = 9, stdout = '', stderr = '' }
      or { code = 1, signal = 0, stdout = '', stderr = 'codex failed' }
    vim.schedule(function()
      on_exit(result)
    end)
    eq(system_opts.timeout, 30000)
    return {
      is_closing = function()
        return true
      end,
    }
  end

  local results = {}
  for _ = 1, 2 do
    codex.complete(request, function(result)
      table.insert(results, result)
    end, opts)
  end
  vim.wait(1000, function()
    return #results == 2
  end)

  vim.system = original_system
  codex.is_available = original_available
  eq(results[1].ok, false)
  eq(results[1].kind, 'curl')
  helpers.expect.match(results[1].message, 'timed out after 30000 ms')
  eq(results[2], { ok = false, kind = 'curl', message = 'codex failed' })
end

T['complete()']['rejects empty output as a decode failure'] = function()
  local original_system = vim.system
  local original_available = codex.is_available
  codex.is_available = function()
    return true
  end
  vim.system = function(_, _, on_exit)
    vim.schedule(function()
      on_exit({ code = 0, signal = 0, stdout = '\r\n', stderr = '' })
    end)
    return {
      is_closing = function()
        return true
      end,
    }
  end

  local result
  codex.complete(request, function(value)
    result = value
  end, opts)
  vim.wait(1000, function()
    return result ~= nil
  end)

  vim.system = original_system
  codex.is_available = original_available
  eq(result, { ok = false, kind = 'decode', message = 'codex returned empty output' })
end

return T
