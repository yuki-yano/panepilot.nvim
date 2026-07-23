local M = {}

function M.check()
  local config = require('panepilot.config')
  local context = require('panepilot.context')
  local health = vim.health
  local openai = require('panepilot.backend.openai')
  local opts = config.get()

  health.start('panepilot.nvim')

  if vim.fn.has('nvim-0.11') == 1 then
    health.ok('Neovim 0.11+ is available')
  else
    health.error('Neovim 0.11+ is required')
  end

  if config.error() then
    health.error('Configuration is invalid: ' .. config.error())
  else
    health.ok('Configuration is valid')
  end

  local curl_ok, curl_message = openai.curl_supported()
  if curl_ok then
    health.ok('curl ' .. curl_message .. ' is available')
  elseif opts.backend == 'openai' or opts.backend == 'claude' then
    health.error(curl_message)
  else
    health.info(curl_message .. ' (optional API backends are inactive)')
  end

  local multiplexer = context.multiplexer()
  if multiplexer then
    if vim.fn.executable(multiplexer) == 1 then
      health.ok(multiplexer .. ' is executable')
    else
      health.error(multiplexer .. ' was not found')
    end
  else
    health.error('tmux or Herdr environment was not detected')
  end

  if vim.env.EDITPROMPT == '1' then
    health.ok('EDITPROMPT=1')
  else
    health.warn('EDITPROMPT is not 1; panepilot is inactive')
  end

  local pane_id, pane_error = context.resolve_target_pane_sync()
  if pane_id then
    health.ok('Target pane: ' .. pane_id)
  else
    health.warn('Target pane is unavailable: ' .. pane_error)
  end

  local openai_config = opts.openai
  local openai_key_env = type(openai_config) == 'table' and openai_config.api_key_env
    or config.defaults.openai.api_key_env
  local claude_config = opts.claude
  local claude_key_env = type(claude_config) == 'table' and claude_config.api_key_env
    or config.defaults.claude.api_key_env

  local function check_api_key(backend, label, key_env)
    if vim.env[key_env] and vim.env[key_env] ~= '' then
      health.ok(key_env .. ' is set for the ' .. label .. ' backend')
    elseif opts.backend == backend then
      health.warn(key_env .. ' is not set; ' .. label .. ' backend is inactive')
    else
      health.info(key_env .. ' is not set (optional ' .. label .. ' backend is inactive)')
    end
  end

  if openai_key_env == claude_key_env then
    if opts.backend == 'openai' then
      check_api_key('openai', 'OpenAI', openai_key_env)
    elseif opts.backend == 'claude' then
      check_api_key('claude', 'Claude', claude_key_env)
    elseif vim.env[openai_key_env] and vim.env[openai_key_env] ~= '' then
      health.ok(openai_key_env .. ' is set for API backends')
    else
      health.info(openai_key_env .. ' is not set (optional API backends are inactive)')
    end
  else
    check_api_key('openai', 'OpenAI', openai_key_env)
    check_api_key('claude', 'Claude', claude_key_env)
  end

  if vim.fn.executable('codex') == 1 then
    health.ok('codex is executable')
  elseif opts.backend == 'codex' then
    health.warn('codex was not found; Codex backend is inactive')
  else
    health.info('codex was not found (optional backend is inactive)')
  end
end

return M
