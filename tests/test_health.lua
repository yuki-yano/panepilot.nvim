local helpers = require('tests.helpers')

local new_set = MiniTest.new_set
local eq = helpers.eq

local T = new_set({
  hooks = {
    pre_case = function()
      require('panepilot.config')._reset()
    end,
  },
})

local function check_messages(curl_ok, curl_message)
  local original_health = vim.health
  local original_tmux_pane = vim.env.TMUX_PANE
  local openai = require('panepilot.backend.openai')
  local original_curl_supported = openai.curl_supported
  local messages = {}
  vim.health = {}
  for _, level in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
    vim.health[level] = function(message)
      table.insert(messages, { level = level, message = message })
    end
  end
  openai.curl_supported = function()
    return curl_ok ~= false, curl_message or '8.3.0'
  end
  vim.env.TMUX_PANE = nil
  require('panepilot.health').check()
  vim.env.TMUX_PANE = original_tmux_pane
  openai.curl_supported = original_curl_supported
  vim.health = original_health
  return messages
end

local function find_message(messages, pattern)
  for _, entry in ipairs(messages) do
    if entry.message:find(pattern, 1, true) then
      return entry
    end
  end
end

T['check()'] = new_set()

T['check()']['treats missing curl as optional for the selected Codex backend'] = function()
  require('panepilot.config').setup({ backend = 'codex' })
  local entry = find_message(check_messages(false, 'curl missing'), 'curl missing')

  eq(entry, { level = 'info', message = 'curl missing (optional API backends are inactive)' })
end

T['check()']['warns when the selected Claude backend key is missing'] = function()
  local key_env = 'PANEPILOT_HEALTH_CLAUDE_KEY'
  local original_key = vim.env[key_env]
  vim.env[key_env] = nil
  require('panepilot.config').setup({ backend = 'claude', claude = { api_key_env = key_env } })

  local entry = find_message(check_messages(), key_env)

  vim.env[key_env] = original_key
  eq(entry.level, 'warn')
  helpers.expect.match(entry.message, 'Claude backend is inactive')
end

T['check()']['reports an unselected missing Claude key as optional'] = function()
  local key_env = 'PANEPILOT_HEALTH_OPTIONAL_CLAUDE_KEY'
  local original_key = vim.env[key_env]
  vim.env[key_env] = nil
  require('panepilot.config').setup({ backend = 'openai', claude = { api_key_env = key_env } })

  local entry = find_message(check_messages(), key_env)

  vim.env[key_env] = original_key
  eq(entry.level, 'info')
  helpers.expect.match(entry.message, 'optional Claude backend')
end

T['check()']['uses the configured Claude key environment variable when it is set'] = function()
  local key_env = 'PANEPILOT_HEALTH_SET_CLAUDE_KEY'
  local original_key = vim.env[key_env]
  vim.env[key_env] = 'set'
  require('panepilot.config').setup({ backend = 'claude', claude = { api_key_env = key_env } })

  local entry = find_message(check_messages(), key_env)

  vim.env[key_env] = original_key
  eq(entry, { level = 'ok', message = key_env .. ' is set for the Claude backend' })
end

T['check()']['reports the shared default API key once for the selected backend'] = function()
  local key_env = 'PANEPILOT_API_KEY'
  local original_key = vim.env[key_env]
  vim.env[key_env] = 'set'
  require('panepilot.config').setup({ backend = 'claude' })

  local messages = check_messages()
  local matches = {}
  for _, entry in ipairs(messages) do
    if entry.message:find(key_env, 1, true) then
      table.insert(matches, entry)
    end
  end

  vim.env[key_env] = original_key
  eq(matches, { { level = 'ok', message = key_env .. ' is set for the Claude backend' } })
end

T['check()']['reports the Herdr target pane'] = function()
  local original_herdr = vim.env.HERDR_ENV
  local original_target = vim.env.EDITPROMPT_TARGET_PANE
  vim.env.HERDR_ENV = '1'
  vim.env.EDITPROMPT_TARGET_PANE = 'w1:p2'

  local entry = find_message(check_messages(), 'Target pane:')

  vim.env.HERDR_ENV = original_herdr
  vim.env.EDITPROMPT_TARGET_PANE = original_target
  eq(entry, { level = 'ok', message = 'Target pane: w1:p2' })
end

return T
