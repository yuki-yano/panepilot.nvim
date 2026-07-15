local helpers = require('tests.helpers')

local new_set = MiniTest.new_set
local eq = helpers.eq

local T = new_set({
  hooks = {
    pre_case = function()
      require('panepilot.config')._reset()
      require('panepilot.engine')._reset()
    end,
  },
})

T['engine cache'] = new_set()

T['engine cache']['keys by pane content and the complete draft around the cursor'] = function()
  local config = require('panepilot.config')
  local engine = require('panepilot.engine')
  local opts = config.get()
  local key = engine.cache_key('pane', 'before', 'after', opts, 'prompt')
  eq(engine.cache_key('pane', 'before', 'after', opts, 'prompt'), key)
  eq(engine.cache_key('other pane', 'before', 'after', opts, 'prompt') == key, false)
  eq(engine.cache_key('pane', 'other before', 'after', opts, 'prompt') == key, false)
  eq(engine.cache_key('pane', 'before', 'other after', opts, 'prompt') == key, false)
  eq(engine.cache_key('pane', 'before', 'after', opts, 'other prompt') == key, false)
  eq(pcall(engine.cache_key, 'pane', 'before', 'after', opts, nil), false)
end

T['engine cache']['separates generation settings'] = function()
  local config = require('panepilot.config')
  local engine = require('panepilot.engine')
  local defaults = config.get()
  local default_key = engine.cache_key('pane', 'draft', '', defaults, 'prompt')

  local longer = vim.deepcopy(defaults)
  longer.max_candidate_chars = 160
  eq(engine.cache_key('pane', 'draft', '', longer, 'prompt') == default_key, false)

  local other_model = vim.deepcopy(defaults)
  other_model.openai.model = 'other-model'
  eq(engine.cache_key('pane', 'draft', '', other_model, 'prompt') == default_key, false)

  local codex = vim.deepcopy(defaults)
  codex.backend = 'codex'
  eq(engine.cache_key('pane', 'draft', '', codex, 'prompt') == default_key, false)

  local claude = vim.deepcopy(defaults)
  claude.backend = 'claude'
  local claude_key = engine.cache_key('pane', 'draft', '', claude, 'prompt')
  eq(claude_key == default_key, false)

  local other_claude = vim.deepcopy(claude)
  other_claude.claude.max_tokens = 800
  eq(engine.cache_key('pane', 'draft', '', other_claude, 'prompt') == claude_key, false)
end

T['engine cache']['returns copies of cached candidates'] = function()
  local engine = require('panepilot.engine')
  engine._cache_put('key', { 'first', 'second' })
  local candidates = engine._cache_get('key')
  candidates[1] = 'changed'
  eq(engine._cache_get('key'), { 'first', 'second' })
end

T['engine cache']['evicts the least recently used entry above 20 items'] = function()
  local engine = require('panepilot.engine')
  for index = 1, 20 do
    engine._cache_put('key-' .. index, { tostring(index) })
  end
  engine._cache_get('key-1')
  engine._cache_put('key-21', { '21' })

  eq(engine._cache_size(), 20)
  eq(engine._cache_get('key-1'), { '1' })
  eq(engine._cache_get('key-2'), nil)
  eq(engine._cache_get('key-21'), { '21' })
end

T['cmp source'] = new_set()

T['cmp source']['formats engine candidates for nvim-cmp'] = function()
  local engine = require('panepilot.engine')
  local original_complete = engine.complete_cmp
  local long = string.rep('候', 61)
  engine.complete_cmp = function(callback)
    callback({ long, 'short' })
  end

  local response
  require('panepilot.cmp_source').new():complete({
    offset = 5,
    context = {
      cursor_before_line = 'draft',
      cursor = { line = 0, character = 5 },
      get_reason = function()
        return 'auto'
      end,
    },
  }, function(value)
    response = value
  end)
  engine.complete_cmp = original_complete

  eq(response.isIncomplete, false)
  eq(#response.items, 2)
  eq(response.items[1].label, string.rep('候', 60) .. '…')
  eq(response.items[1].documentation, long)
  eq(response.items[1].filterText, 't' .. long)
  eq(response.items[1].insertText, long)
  eq(response.items[1].textEdit, {
    newText = long,
    range = {
      start = { line = 0, character = 5 },
      ['end'] = { line = 0, character = 5 },
    },
  })
  eq(response.items[1].menu, '[Panepilot]')
  eq(response.items[2].label, 'short')
end

T['cmp source']['forwards whether nvim-cmp was invoked manually'] = function()
  local engine = require('panepilot.engine')
  local original_complete = engine.complete_cmp
  local observed = {}
  engine.complete_cmp = function(callback, manual)
    table.insert(observed, manual)
    callback({})
  end

  local source = require('panepilot.cmp_source').new()
  local function params(reason)
    return {
      context = {
        get_reason = function()
          return reason
        end,
      },
    }
  end
  source:complete(params('auto'), function() end)
  source:complete(params('manual'), function() end)
  engine.complete_cmp = original_complete

  eq(observed, { false, true })
end

T['cmp source']['is available only in editprompt buffers'] = function()
  local source = require('panepilot.cmp_source').new()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.env.EDITPROMPT = '1'
  vim.bo[bufnr].filetype = 'markdown.editprompt'
  eq(source:is_available(), true)
  vim.bo[bufnr].filetype = 'markdown'
  eq(source:is_available(), false)
  vim.env.EDITPROMPT = nil
end

T['cmp source']['matches the final character so automatic completion requests the source'] = function()
  local source = require('panepilot.cmp_source').new()
  eq(source:get_keyword_pattern(), [[.]])
end

T['engine cache']['removes a repeated current-line prefix from candidates'] = function()
  local engine = require('panepilot.engine')
  eq(
    engine._normalize_candidates({ '前の文。入力中の文を完成', '別案' }, '前の文。入力中の文'),
    { 'を完成', '別案' }
  )
  eq(engine._normalize_candidates({ '  続き' }, '  '), { '  続き' })
  eq(engine._normalize_candidates({ 'draft' }, 'draft'), {})
end

T['engine cache']['removes overlap with text after the cursor'] = function()
  local engine = require('panepilot.engine')
  eq(engine._normalize_candidates({ 'lowとmediumで比較する', '別案' }, 'lunaの', 'で比較する'), {
    'lowとmedium',
    '別案',
  })
  eq(engine._normalize_candidates({ '候補です' }, 'これは', 'ですか'), { '候補' })
  eq(engine._normalize_candidates({ 'で比較する' }, 'lunaの', 'で比較する'), {})
  eq(
    engine._normalize_candidates({ '1行目の続き\n2行目' }, '1行目', 'の末尾\n次の行'),
    { 'の続き\n2行目' }
  )
end

T['cmp source']['dismisses ghost text when the menu opens'] = function()
  local cmp_source = require('panepilot.cmp_source')
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft|' })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  ghost.show(bufnr, 0, 5, { ' candidate' })
  eq(ghost.visible(bufnr), true)

  cmp_source._reset()
  eq(cmp_source.register(), true)
  require('cmp').event:emit('menu_opened')
  eq(ghost.visible(bufnr), false)
end

T['cmp source']['keeps ghost text when configured alongside the menu'] = function()
  local cmp_source = require('panepilot.cmp_source')
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft|' })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  require('panepilot.config').setup({ cmp = { dismiss_ghost_on_menu_open = false } })
  ghost.show(bufnr, 0, 5, { ' candidate' })
  eq(ghost.visible(bufnr), true)

  cmp_source._reset()
  eq(cmp_source.register(), true)
  require('cmp').event:emit('menu_opened')
  eq(ghost.visible(bufnr), true)
end

T['cmp source']['removes its menu listener when reset'] = function()
  local cmp_source = require('panepilot.cmp_source')
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft|' })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })

  cmp_source._reset()
  eq(cmp_source.register(), true)
  cmp_source._reset()
  require('panepilot.config').setup({ cmp = { dismiss_ghost_on_menu_open = false } })
  ghost.show(bufnr, 0, 5, { ' candidate' })
  require('cmp').event:emit('menu_opened')

  eq(ghost.visible(bufnr), true)
end

local child = helpers.new_child_neovim()

T['engine sharing'] = new_set({
  hooks = {
    pre_case = function()
      child.setup()
    end,
    post_once = function()
      child.stop()
    end,
  },
})

T['engine sharing']['keeps the current word when nvim-cmp confirms a continuation'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    require('panepilot.config').setup()
    require('panepilot.engine').complete_cmp = function(callback)
      callback({ ' continuation' })
    end

    local cmp = require('cmp')
    require('panepilot.cmp_source').register()
    cmp.setup({
      sources = { { name = 'panepilot' } },
      completion = { autocomplete = false },
    })
  ]])
  child.type_keys('A')
  child.lua([[
    local cmp = require('cmp')
    cmp.complete()
    vim.wait(1000, function()
      return cmp.visible()
    end)
  ]])

  eq(child.lua_get([[require('cmp').visible()]]), true)
  child.lua([[
    require('cmp').confirm({ select = true })
    vim.wait(1000, function()
      return vim.api.nvim_get_current_line() == 'draft continuation'
    end)
  ]])
  eq(child.lua_get([[vim.api.nvim_get_current_line()]]), 'draft continuation')
end

T['engine sharing']['participates in automatic nvim-cmp completion and inserts at the cursor'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draf' })

    require('panepilot.config').setup()
    require('panepilot.engine').complete_cmp = function(callback)
      callback({ ' continuation' })
    end

    local cmp = require('cmp')
    require('panepilot.cmp_source').register()
    cmp.setup({
      sources = { { name = 'panepilot' } },
      completion = { autocomplete = { require('cmp.types').cmp.TriggerEvent.TextChanged } },
    })
  ]])
  child.type_keys('At')
  child.lua([[
    require('cmp').complete({ reason = require('cmp').ContextReason.Auto })
    vim.wait(1000, function()
      return require('cmp').visible()
    end)
  ]])

  eq(child.lua_get([[require('cmp').visible()]]), true)
  eq(child.lua_get([[require('cmp').get_entries()[1].source.name]]), 'panepilot')
  child.lua([[
    require('cmp').confirm({ select = true })
    vim.wait(1000, function()
      return vim.api.nvim_get_current_line() == 'draft continuation'
    end)
  ]])
  eq(child.lua_get([[vim.api.nvim_get_current_line()]]), 'draft continuation')
end

T['engine sharing']['adds delayed panepilot results to an open menu from another source'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    require('panepilot.config').setup()
    require('panepilot.engine').complete_cmp = function(callback)
      vim.defer_fn(function()
        callback({ ' continuation' })
      end, 800)
    end

    local cmp = require('cmp')
    require('panepilot.cmp_source').register()
    cmp.register_source('fast', {
      get_keyword_pattern = function()
        return '.'
      end,
      complete = function(_, _, callback)
        callback({ { label = 't-fast candidate' } })
      end,
    })
    cmp.setup({
      sources = { { name = 'panepilot' }, { name = 'fast' } },
      completion = { autocomplete = false },
      performance = { fetching_timeout = 500 },
    })
  ]])
  child.type_keys('A')
  child.lua([[
    local cmp = require('cmp')
    cmp.complete()
    vim.wait(500, function()
      return cmp.visible()
    end)
    _G.initial_sources = vim.tbl_map(function(entry)
      return entry.source.name
    end, cmp.get_entries())
    vim.wait(2000, function()
      return vim.tbl_contains(vim.tbl_map(function(entry)
        return entry.source.name
      end, cmp.get_entries()), 'panepilot')
    end)
    _G.final_sources = vim.tbl_map(function(entry)
      return entry.source.name
    end, cmp.get_entries())
  ]])

  eq(child.lua_get('_G.initial_sources'), { 'fast' })
  eq(vim.tbl_contains(child.lua_get('_G.final_sources'), 'panepilot'), true)
end

T['engine sharing']['refreshes an open cmp menu after manual ghost completion'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    require('panepilot.config').setup({
      auto_trigger = { pane_quiet_sec = 0 },
      cmp = { dismiss_ghost_on_menu_open = false },
    })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end

    _G.cmp_refreshes = 0
    package.loaded.cmp = {
      visible = function()
        return true
      end,
      complete = function()
        _G.cmp_refreshes = _G.cmp_refreshes + 1
      end,
    }

    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        callback({ ok = true, candidates = { 'draft continuation' } })
        return {}
      end,
      cancel = function() end,
    })
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').trigger()
    vim.wait(1000, function()
      return _G.cmp_refreshes > 0
    end)
  ]])

  eq(child.lua_get('_G.cmp_refreshes'), 1)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), true)
  eq(
    child.lua_get(
      [[vim.api.nvim_buf_get_extmarks(0, require('panepilot.ghost')._namespace(), 0, -1, { details = true })[1][4].virt_text]]
    ),
    { { ' continuation', 'PanepilotGhost' } }
  )
end

T['engine sharing']['uses the Claude API backend for nvim-cmp'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    require('panepilot.config').setup({
      backend = 'claude',
      auto_trigger = { pane_quiet_sec = 0 },
      system_prompt = 'custom cmp prompt',
    })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
    end

    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('claude', {
      is_available = function()
        return true
      end,
      complete = function(request, callback)
        _G.claude_cmp_request = request
        callback({ ok = true, candidates = { ' first', ' second', ' third' } })
        return {}
      end,
      cancel = function() end,
    })
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.claude_cmp_candidates = candidates
    end)
  ]])
  eq(child.lua_get('_G.claude_cmp_request.n_candidates'), 3)
  eq(child.lua_get('_G.claude_cmp_request.system'), 'custom cmp prompt')
  eq(child.lua_get('_G.claude_cmp_candidates'), { ' first', ' second', ' third' })
end

T['engine sharing']['resolves a function system prompt once across automatic cmp quiet retries'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    _G.prompt_calls = 0
    _G.observe_calls = 0
    require('panepilot.config').setup({
      auto_trigger = { pane_quiet_sec = 0 },
      system_prompt = function(ctx)
        _G.prompt_calls = _G.prompt_calls + 1
        return ctx.default_prompt
      end,
    })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      _G.observe_calls = _G.observe_calls + 1
      return _G.observe_calls > 1, 'hash', 0
    end

    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        callback({ ok = true, candidates = { ' first', ' second', ' third' } })
        return {}
      end,
      cancel = function() end,
    })
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.retry_candidates = candidates
    end, false)
    vim.wait(1000, function()
      return _G.retry_candidates ~= nil
    end)
  ]])
  eq(child.lua_get('_G.prompt_calls'), 1)
  eq(child.lua_get('_G.observe_calls'), 2)
  eq(child.lua_get('_G.retry_candidates'), { ' first', ' second', ' third' })
end

T['engine sharing']['manual nvim-cmp skips pane quiet waiting'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    require('panepilot.config').setup({ auto_trigger = { pane_quiet_sec = 30 } })

    _G.observe_calls = 0
    _G.backend_calls = 0
    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'changing pane' })
    end
    context.observe_pane = function()
      _G.observe_calls = _G.observe_calls + 1
      return false, 'hash', 30000
    end

    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        _G.backend_calls = _G.backend_calls + 1
        callback({ ok = true, candidates = { ' first', ' second', ' third' } })
        return {}
      end,
      cancel = function() end,
    })
    vim.notify = function() end
    engine._handle_failure({ kind = 'http', status = 429, message = 'rate limited' })
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.manual_candidates = candidates
    end, true)
  ]])

  eq(child.lua_get('_G.manual_candidates'), { ' first', ' second', ' third' })
  eq(child.lua_get('_G.observe_calls'), 0)
  eq(child.lua_get('_G.backend_calls'), 1)
  eq(child.lua_get([[require('panepilot.engine').auto_paused()]]), true)
end

T['engine sharing']['ends cmp completion without a backend request when the prompt function fails'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    require('panepilot.config').setup({
      system_prompt = function()
        error('cmp prompt failed')
      end,
    })

    _G.context_calls = 0
    _G.backend_calls = 0
    local context = require('panepilot.context')
    context.get = function()
      _G.context_calls = _G.context_calls + 1
    end

    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function()
        _G.backend_calls = _G.backend_calls + 1
      end,
      cancel = function() end,
    })
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.failed_prompt_candidates = candidates
    end, true)
  ]])
  eq(child.lua_get('_G.failed_prompt_candidates'), {})
  eq(child.lua_get('_G.context_calls'), 0)
  eq(child.lua_get('_G.backend_calls'), 0)
  helpers.expect.match(child.lua_get([[require('panepilot.log').entries()[1].message]]), 'cmp prompt failed')
end

T['engine sharing']['requires manual nvim-cmp invocation at an empty draft'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    require('panepilot.config').setup({ auto_trigger = { pane_quiet_sec = 0 } })

    _G.context_calls = 0
    _G.backend_calls = 0
    local context = require('panepilot.context')
    context.get = function(_, callback)
      _G.context_calls = _G.context_calls + 1
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
    end

    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        _G.backend_calls = _G.backend_calls + 1
        callback({ ok = true, candidates = { ' first', ' second', ' third' } })
        return {}
      end,
      cancel = function() end,
    })
  ]])
  child.type_keys('i')
  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.auto_cmp_candidates = candidates
    end, false)
  ]])
  eq(child.lua_get('_G.auto_cmp_candidates'), {})
  eq(child.lua_get('_G.context_calls'), 0)
  eq(child.lua_get('_G.backend_calls'), 0)

  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.manual_cmp_candidates = candidates
    end, true)
  ]])
  eq(child.lua_get('_G.manual_cmp_candidates'), { ' first', ' second', ' third' })
  eq(child.lua_get('_G.context_calls'), 1)
  eq(child.lua_get('_G.backend_calls'), 1)
end

T['engine sharing']['keeps ghost text during a new cmp request when configured'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    require('panepilot.config').setup({
      auto_trigger = { pane_quiet_sec = 0 },
      cmp = { dismiss_ghost_on_menu_open = false },
    })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
    end

    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        callback({ ok = true, candidates = { ' first', ' second', ' third' } })
        return {}
      end,
      cancel = function() end,
    })
  ]])
  child.type_keys('A')
  child.lua([[
    local bufnr = vim.api.nvim_get_current_buf()
    require('panepilot.ghost').show(bufnr, 0, 5, { ' existing ghost' })
    assert(require('panepilot.ghost').visible(bufnr))
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.cmp_candidates = candidates
    end, true)
  ]])
  eq(child.lua_get('_G.cmp_candidates'), { ' first', ' second', ' third' })
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), true)
end

T['engine sharing']['dismisses ghost text during a new cmp request by default'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    require('panepilot.config').setup({ auto_trigger = { pane_quiet_sec = 0 } })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
    end

    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        callback({ ok = true, candidates = { ' first', ' second', 'third' } })
        return {}
      end,
      cancel = function() end,
    })
  ]])
  child.type_keys('A')
  child.lua([[
    local bufnr = vim.api.nvim_get_current_buf()
    require('panepilot.ghost').show(bufnr, 0, 5, { ' existing ghost' })
    assert(require('panepilot.ghost').visible(bufnr))
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.cmp_candidates = candidates
    end, true)
  ]])
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), false)
end

T['engine sharing']['serves cmp while another source has already opened the menu'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    require('panepilot.config').setup({ auto_trigger = { pane_quiet_sec = 0 } })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
    end

    _G.backend_calls = 0
    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        _G.backend_calls = _G.backend_calls + 1
        callback({ ok = true, candidates = { ' continuation' } })
        return {}
      end,
      cancel = function() end,
    })

    require('cmp').visible = function()
      return true
    end
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.cmp_candidates = candidates
    end)
  ]])

  eq(child.lua_get('_G.backend_calls'), 1)
  eq(child.lua_get('_G.cmp_candidates'), { ' continuation' })
end

T['engine sharing']['shares an in-flight ghost request and its cache with cmp'] = function()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    require('panepilot.config').setup({ auto_trigger = { pane_quiet_sec = 0 } })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
    end

    _G.backend_calls = 0
    _G.long_candidate = string.rep('候', 81)
    local backend = {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        _G.backend_calls = _G.backend_calls + 1
        _G.backend_callback = callback
        return {}
      end,
      cancel = function() end,
    }
    local engine = require('panepilot.engine')
    engine.attach(0)
    engine._set_backend('openai', backend)
  ]])
  child.type_keys('A')
  eq(child.lua_get([[vim.api.nvim_get_mode().mode:sub(1, 1)]]), 'i')

  child.lua([[require('panepilot.engine').trigger()]])
  eq(child.lua_get('_G.backend_calls'), 1)
  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.first_cmp_candidates = candidates
    end)
  ]])
  eq(child.lua_get('_G.backend_calls'), 1)

  child.lua([[
    _G.backend_callback({ ok = true, candidates = { _G.long_candidate, 'second', 'third' } })
  ]])
  eq(child.lua_get('_G.first_cmp_candidates'), { string.rep('候', 80), 'second', 'third' })
  eq(child.lua_get('_G.backend_calls'), 1)

  child.lua([[
    require('panepilot.ghost').dismiss()
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.cached_cmp_candidates = candidates
    end)
  ]])
  eq(child.lua_get('_G.cached_cmp_candidates'), { string.rep('候', 80), 'second', 'third' })
  eq(child.lua_get('_G.backend_calls'), 1)
end

return T
