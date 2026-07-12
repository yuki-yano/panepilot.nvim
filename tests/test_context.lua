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
