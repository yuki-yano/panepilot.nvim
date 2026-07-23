local helpers = require('tests.helpers')

local new_set = MiniTest.new_set
local eq = helpers.eq
local context = require('panepilot.context')

local T = new_set()

T['parse_target_panes()'] = new_set()

T['parse_target_panes()']['returns the first trimmed pane id'] = function()
  eq(context.parse_target_panes('  %4, %7, %9\n'), '%4')
end

T['parse_target_panes()']['returns nil for missing values'] = function()
  eq(context.parse_target_panes(nil), nil)
  eq(context.parse_target_panes('  ,  '), nil)
end

T['multiplexer()'] = new_set()

T['multiplexer()']['prefers Herdr when Herdr runs inside tmux'] = function()
  local original_herdr = vim.env.HERDR_ENV
  local original_tmux = vim.env.TMUX_PANE
  vim.env.HERDR_ENV = '1'
  vim.env.TMUX_PANE = '%4'

  local multiplexer = context.multiplexer()

  vim.env.HERDR_ENV = original_herdr
  vim.env.TMUX_PANE = original_tmux
  eq(multiplexer, 'herdr')
end

T['multiplexer()']['detects tmux from its pane environment'] = function()
  local original_herdr = vim.env.HERDR_ENV
  local original_tmux = vim.env.TMUX_PANE
  vim.env.HERDR_ENV = nil
  vim.env.TMUX_PANE = '%4'

  local multiplexer = context.multiplexer()

  vim.env.HERDR_ENV = original_herdr
  vim.env.TMUX_PANE = original_tmux
  eq(multiplexer, 'tmux')
end

T['multiplexer()']['detects a Herdr custom command environment'] = function()
  local original_herdr = vim.env.HERDR_ENV
  local original_active = vim.env.HERDR_ACTIVE_PANE_ID
  local original_tmux = vim.env.TMUX_PANE
  vim.env.HERDR_ENV = nil
  vim.env.HERDR_ACTIVE_PANE_ID = 'w1:p2'
  vim.env.TMUX_PANE = '%4'

  local multiplexer = context.multiplexer()

  vim.env.HERDR_ENV = original_herdr
  vim.env.HERDR_ACTIVE_PANE_ID = original_active
  vim.env.TMUX_PANE = original_tmux
  eq(multiplexer, 'herdr')
end

T['resolve_target_pane()'] = new_set()

T['resolve_target_pane()']['resolves a Herdr target from editprompt'] = function()
  local original_herdr = vim.env.HERDR_ENV
  local original_target = vim.env.EDITPROMPT_TARGET_PANE
  vim.env.HERDR_ENV = '1'
  vim.env.EDITPROMPT_TARGET_PANE = ' w1:p2 '

  local result
  context.resolve_target_pane(function(value)
    result = value
  end)
  vim.wait(1000, function()
    return result ~= nil
  end)

  vim.env.HERDR_ENV = original_herdr
  vim.env.EDITPROMPT_TARGET_PANE = original_target
  eq(result, { ok = true, multiplexer = 'herdr', pane_id = 'w1:p2' })
end

T['resolve_target_pane()']['does not use the editor Herdr pane as the target'] = function()
  local original_herdr = vim.env.HERDR_ENV
  local original_target = vim.env.EDITPROMPT_TARGET_PANE
  local original_pane = vim.env.HERDR_PANE_ID
  vim.env.HERDR_ENV = '1'
  vim.env.EDITPROMPT_TARGET_PANE = nil
  vim.env.HERDR_PANE_ID = 'w1:p5'

  local pane_id, message = context.resolve_target_pane_sync()

  vim.env.HERDR_ENV = original_herdr
  vim.env.EDITPROMPT_TARGET_PANE = original_target
  vim.env.HERDR_PANE_ID = original_pane
  eq(pane_id, nil)
  eq(message, 'EDITPROMPT_TARGET_PANE is not set')
end

T['capture_pane()'] = new_set()

T['capture_pane()']['reads recent Herdr output with the configured line count'] = function()
  local original_system = vim.system
  local observed_args
  vim.system = function(args, _, on_exit)
    observed_args = args
    on_exit({ code = 0, stdout = 'pane output', stderr = '' })
    return {}
  end

  local result
  context.capture_pane('herdr', 'w1:p2', 300, function(value)
    result = value
  end)
  vim.wait(1000, function()
    return result ~= nil
  end)
  vim.system = original_system

  eq(observed_args, { 'herdr', 'pane', 'read', 'w1:p2', '--source', 'recent-unwrapped', '--lines', '300' })
  eq(result, { ok = true, content = 'pane output' })
end

T['mask()'] = new_set()

T['mask()']['masks long OpenAI and Anthropic-style tokens but preserves short matches'] = function()
  local long = 'sk-' .. string.rep('a', 20)
  local short = 'sk-' .. string.rep('b', 19)
  local anthropic = 'sk-ant-' .. string.rep('c', 20)
  eq(context.mask(long .. ' ' .. short .. ' ' .. anthropic), '<masked> ' .. short .. ' <masked>')
end

T['mask()']['masks unquoted key values through the next whitespace'] = function()
  eq(
    context.mask('token = abc comment\nAPI-KEY:x,y\napikey = z'),
    'token = <masked> comment\nAPI-KEY:<masked>\napikey = <masked>'
  )
end

T['mask()']['masks secret suffixes in real environment variable names'] = function()
  eq(
    context.mask(
      'OPENAI_API_KEY=one\nAWS_SECRET_ACCESS_KEY=two\nDB_PASSWORD=three\nexport GH_TOKEN=four\nCACHE_CREDENTIAL="five six"'
    ),
    'OPENAI_API_KEY=<masked>\nAWS_SECRET_ACCESS_KEY=<masked>\nDB_PASSWORD=<masked>\nexport GH_TOKEN=<masked>\nCACHE_CREDENTIAL=<masked>'
  )
end

T['mask()']['masks quoted values including quotes and handles missing closing quotes'] = function()
  eq(
    context.mask([[password: "a b"
secret='unfinished value]]),
    [[password: <masked>
secret=<masked>]]
  )
end

T['mask()']['applies custom rules after defaults'] = function()
  local result = context.mask('token=abc project-123', {
    { pattern = 'project%-%d+', replace = 'project-<masked>' },
    function(text)
      return text .. ':done'
    end,
  })
  eq(result, 'token=<masked> project-<masked>:done')
end

T['observe_pane()'] = new_set({
  hooks = {
    pre_case = function()
      context._reset_observations()
    end,
  },
})

T['observe_pane()']['suppresses a changed pane until it stays quiet'] = function()
  eq(context.observe_pane('%4', 'first', 3, 1000), false)
  eq(context.observe_pane('%4', 'second', 3, 2000), false)
  eq(context.observe_pane('%4', 'second', 3, 4000), false)
  eq(context.observe_pane('%4', 'second', 3, 5000), true)
end

T['get()'] = new_set()

T['get()']['cancels its active tmux process idempotently'] = function()
  local original_resolve = context.resolve_target_pane
  local killed = 0
  local process = {
    is_closing = function()
      return false
    end,
    kill = function()
      killed = killed + 1
    end,
  }
  context.resolve_target_pane = function()
    return process
  end

  local results = {}
  local handle = context.get({ lines = 300, mask_patterns = {} }, function(result)
    table.insert(results, result)
  end)
  context.cancel(handle)
  context.cancel(handle)
  vim.wait(1000, function()
    return #results == 1
  end)
  context.resolve_target_pane = original_resolve

  eq(killed, 1)
  eq(results[1].cancelled, true)
end

return T
