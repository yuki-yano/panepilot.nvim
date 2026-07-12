local M = {}

M.defaults = {
  backend = 'openai',
  openai = {
    model = 'gpt-5.6-luna',
    reasoning_effort = 'none',
    max_output_tokens = 400,
    api_key_env = 'PANEPILOT_API_KEY',
    timeout_ms = 10000,
  },
  claude = {
    model = 'claude-haiku-4-5',
    max_tokens = 400,
    api_key_env = 'PANEPILOT_API_KEY',
    timeout_ms = 10000,
  },
  codex = {
    model = 'gpt-5.3-codex-spark',
    reasoning_effort = 'low',
    timeout_ms = 30000,
  },
  context = {
    lines = 300,
    mask_patterns = {},
  },
  auto_trigger = {
    enabled = true,
    debounce_ms = 800,
    pane_quiet_sec = 3,
  },
  n_candidates = 3,
  max_candidate_lines = 2,
  max_candidate_chars = 80,
  cmp = { enabled = true },
}

local values = vim.deepcopy(M.defaults)
local error_message
local error_notified = false

local function is_positive_integer(value)
  return type(value) == 'number' and value > 0 and value % 1 == 0
end

local function validate_mask_patterns(patterns)
  if type(patterns) ~= 'table' then
    return false, 'context.mask_patterns must be a table'
  end

  for index, rule in ipairs(patterns) do
    if type(rule) == 'function' then
      -- Valid transformation rule.
    elseif type(rule) == 'table' then
      if type(rule.pattern) ~= 'string' then
        return false, ('context.mask_patterns[%d].pattern must be a string'):format(index)
      end
      local pattern_ok, pattern_error = pcall(string.find, '', rule.pattern)
      if not pattern_ok then
        return false, ('context.mask_patterns[%d].pattern is not a valid Lua pattern: %s'):format(index, pattern_error)
      end
      if rule.replace ~= nil and type(rule.replace) ~= 'string' then
        return false, ('context.mask_patterns[%d].replace must be a string'):format(index)
      end
    else
      return false, ('context.mask_patterns[%d] must be a table or function'):format(index)
    end
  end

  return true
end

local function validate(opts)
  if opts.backend ~= 'openai' and opts.backend ~= 'claude' and opts.backend ~= 'codex' then
    return false, ("backend '%s' is not implemented"):format(tostring(opts.backend))
  end
  if not is_positive_integer(opts.n_candidates) or opts.n_candidates > 3 then
    return false, 'n_candidates must be an integer between 1 and 3'
  end
  if not is_positive_integer(opts.max_candidate_lines) then
    return false, 'max_candidate_lines must be a positive integer'
  end
  if not is_positive_integer(opts.max_candidate_chars) then
    return false, 'max_candidate_chars must be a positive integer'
  end
  if type(opts.openai) ~= 'table' then
    return false, 'openai must be a table'
  end
  if type(opts.openai.model) ~= 'string' or opts.openai.model == '' then
    return false, 'openai.model must be a non-empty string'
  end
  if type(opts.openai.reasoning_effort) ~= 'string' or opts.openai.reasoning_effort == '' then
    return false, 'openai.reasoning_effort must be a non-empty string'
  end
  if not is_positive_integer(opts.openai.max_output_tokens) then
    return false, 'openai.max_output_tokens must be a positive integer'
  end
  if type(opts.openai.api_key_env) ~= 'string' or opts.openai.api_key_env == '' then
    return false, 'openai.api_key_env must be a non-empty string'
  end
  if not is_positive_integer(opts.openai.timeout_ms) then
    return false, 'openai.timeout_ms must be a positive integer'
  end
  if type(opts.claude) ~= 'table' then
    return false, 'claude must be a table'
  end
  if type(opts.claude.model) ~= 'string' or opts.claude.model == '' then
    return false, 'claude.model must be a non-empty string'
  end
  if not is_positive_integer(opts.claude.max_tokens) then
    return false, 'claude.max_tokens must be a positive integer'
  end
  if type(opts.claude.api_key_env) ~= 'string' or opts.claude.api_key_env == '' then
    return false, 'claude.api_key_env must be a non-empty string'
  end
  if not is_positive_integer(opts.claude.timeout_ms) then
    return false, 'claude.timeout_ms must be a positive integer'
  end
  if type(opts.codex) ~= 'table' then
    return false, 'codex must be a table'
  end
  if type(opts.codex.model) ~= 'string' or opts.codex.model == '' then
    return false, 'codex.model must be a non-empty string'
  end
  if type(opts.codex.reasoning_effort) ~= 'string' or opts.codex.reasoning_effort == '' then
    return false, 'codex.reasoning_effort must be a non-empty string'
  end
  if not is_positive_integer(opts.codex.timeout_ms) then
    return false, 'codex.timeout_ms must be a positive integer'
  end
  if type(opts.context) ~= 'table' or not is_positive_integer(opts.context.lines) then
    return false, 'context.lines must be a positive integer'
  end

  local patterns_ok, patterns_error = validate_mask_patterns(opts.context.mask_patterns)
  if not patterns_ok then
    return false, patterns_error
  end
  if type(opts.auto_trigger) ~= 'table' or type(opts.auto_trigger.enabled) ~= 'boolean' then
    return false, 'auto_trigger.enabled must be a boolean'
  end
  if not is_positive_integer(opts.auto_trigger.debounce_ms) then
    return false, 'auto_trigger.debounce_ms must be a positive integer'
  end
  if type(opts.auto_trigger.pane_quiet_sec) ~= 'number' or opts.auto_trigger.pane_quiet_sec < 0 then
    return false, 'auto_trigger.pane_quiet_sec must be a non-negative number'
  end
  if type(opts.cmp) ~= 'table' or type(opts.cmp.enabled) ~= 'boolean' then
    return false, 'cmp.enabled must be a boolean'
  end

  return true
end

function M.setup(opts)
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  local ok, message = validate(merged)
  if not ok then
    values = merged
    error_message = message
    if not error_notified then
      error_notified = true
      vim.notify('panepilot.nvim: ' .. message, vim.log.levels.ERROR)
    end
    return false
  end

  values = merged
  error_message = nil
  return true
end

function M.get()
  return values
end

function M.is_enabled()
  return error_message == nil
end

function M.error()
  return error_message
end

function M._reset()
  values = vim.deepcopy(M.defaults)
  error_message = nil
  error_notified = false
end

return M
