local helpers = require('tests.helpers')

local new_set = MiniTest.new_set
local eq = helpers.eq

local T = new_set({
  hooks = {
    pre_case = function()
      require('panepilot.config')._reset()
      require('panepilot.log')._clear()
    end,
    post_case = function()
      require('panepilot.engine')._reset()
      vim.env.EDITPROMPT = nil
    end,
  },
})

T['config'] = new_set()

T['config']['uses Phase 1 defaults'] = function()
  local config = require('panepilot.config')
  eq(config.get().backend, 'openai')
  eq(config.get().openai.timeout_ms, 10000)
  eq(config.get().claude.model, 'claude-haiku-4-5')
  eq(config.get().claude.max_tokens, 400)
  eq(config.get().claude.api_key_env, 'PANEPILOT_API_KEY')
  eq(config.get().claude.timeout_ms, 10000)
  eq(config.get().codex.timeout_ms, 30000)
  eq(config.get().n_candidates, 3)
  eq(config.get().max_candidate_lines, 2)
  eq(config.get().max_candidate_chars, 80)
end

T['config']['accepts custom candidate length limits'] = function()
  local config = require('panepilot.config')
  eq(config.setup({ max_candidate_lines = 4, max_candidate_chars = 160 }), true)
  eq(config.get().max_candidate_lines, 4)
  eq(config.get().max_candidate_chars, 160)
end

T['config']['rejects invalid candidate length limits'] = function()
  local config = require('panepilot.config')
  local original_notify = vim.notify
  vim.notify = function() end

  eq(config.setup({ max_candidate_lines = 0 }), false)
  eq(config.setup({ max_candidate_lines = 1.5 }), false)
  eq(config.setup({ max_candidate_chars = '80' }), false)
  vim.notify = original_notify
end

T['config']['accepts codex after Phase 5'] = function()
  local config = require('panepilot.config')
  eq(config.setup({ backend = 'codex' }), true)
  eq(config.is_enabled(), true)
end

T['config']['accepts the Claude API backend'] = function()
  local config = require('panepilot.config')
  eq(config.setup({ backend = 'claude' }), true)
  eq(config.is_enabled(), true)
end

T['config']['rejects invalid Claude settings'] = function()
  local config = require('panepilot.config')
  local original_notify = vim.notify
  vim.notify = function() end

  eq(config.setup({ claude = 'invalid' }), false)
  eq(config.setup({ claude = { model = '' } }), false)
  eq(config.setup({ claude = { max_tokens = 0 } }), false)
  eq(config.setup({ claude = { api_key_env = '' } }), false)
  eq(config.setup({ claude = { timeout_ms = 1.5 } }), false)
  vim.notify = original_notify
end

T['config']['disables the plugin for an unknown backend and notifies once'] = function()
  local config = require('panepilot.config')
  local original_notify = vim.notify
  local notifications = {}
  vim.notify = function(message, level)
    table.insert(notifications, { message, level })
  end

  config.setup({ backend = 'unknown' })
  config.setup({ backend = 'unknown' })
  vim.notify = original_notify

  eq(config.is_enabled(), false)
  eq(#notifications, 1)
  helpers.expect.match(notifications[1][1], 'not implemented')
  eq(notifications[1][2], vim.log.levels.ERROR)
end

T['config']['rejects malformed masking patterns during setup'] = function()
  local config = require('panepilot.config')
  local original_notify = vim.notify
  vim.notify = function() end

  eq(config.setup({ context = { mask_patterns = { { pattern = '%' } } } }), false)
  eq(config.is_enabled(), false)
  helpers.expect.match(config.error(), 'not a valid Lua pattern')
  vim.notify = original_notify
end

T['candidate limits'] = new_set()

T['candidate limits']['caps lines and visible Unicode characters without changing shorter candidates'] = function()
  local engine = require('panepilot.engine')
  local japanese = string.rep('候', 81)
  local candidates = engine._limit_candidates({ 'short', 'one\ntwo\nthree', japanese }, 2, 80)

  eq(candidates[1], 'short')
  eq(candidates[2], 'one\ntwo')
  eq(candidates[3], string.rep('候', 80))
end

T['candidate limits']['keeps combining characters and ZWJ emoji intact'] = function()
  local engine = require('panepilot.engine')
  local combining = 'é'
  local family = '👨‍👩‍👧‍👦'
  local candidates = engine._limit_candidates({ combining .. 'x', family .. 'x' }, 1, 1)

  eq(candidates, { combining, family })
end

T['candidate limits']['applies the common limits to the Codex backend'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    require('panepilot.config').setup({
      backend = 'codex',
      max_candidate_lines = 1,
      max_candidate_chars = 4,
    })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end

    local engine = require('panepilot.engine')
    engine._set_backend('codex', {
      is_available = function()
        return true
      end,
      complete = function(request, callback)
        _G.codex_request = request
        callback({ ok = true, candidates = { 'あいうえお\nsecond' } })
        return {}
      end,
      cancel = function() end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
  ]])
  child.type_keys('A')
  child.lua([[require('panepilot.engine').trigger()]])
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), true)
  eq(child.lua_get([[_G.codex_request.system:find('最大1行かつ4文字以内', 1, true) ~= nil]]), true)
  child.lua([[require('panepilot.ghost').accept()]])
  eq(child.lua_get([[vim.api.nvim_get_current_line()]]), 'draftあいうえ')
  child.stop()
end

T['candidate limits']['applies the common limits to the Claude API backend'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
    require('panepilot.config').setup({
      backend = 'claude',
      max_candidate_lines = 1,
      max_candidate_chars = 4,
    })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end

    local engine = require('panepilot.engine')
    engine._set_backend('claude', {
      is_available = function()
        return true
      end,
      complete = function(request, callback)
        _G.claude_request = request
        callback({ ok = true, candidates = { 'あいうえお\nsecond', 'second', 'third' } })
        return {}
      end,
      cancel = function() end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
  ]])
  child.type_keys('A')
  child.lua([[require('panepilot.engine').trigger()]])
  eq(child.lua_get([[_G.claude_request.n_candidates]]), 3)
  eq(child.lua_get([[_G.claude_request.system:find('最大1行かつ4文字以内', 1, true) ~= nil]]), true)
  child.lua([[require('panepilot.ghost').accept()]])
  eq(child.lua_get([[vim.api.nvim_get_current_line()]]), 'draftあいうえ')
  child.stop()
end

T['log'] = new_set()

T['log']['keeps the newest 50 entries and returns a copy'] = function()
  local log = require('panepilot.log')
  for index = 1, 51 do
    log.add('error', tostring(index))
  end

  local entries = log.entries()
  eq(#entries, 50)
  eq(entries[1].message, '2')
  eq(entries[50].message, '51')
  entries[1].message = 'changed'
  eq(log.entries()[1].message, '2')
end

T['log']['shows entries in a scratch buffer'] = function()
  local panepilot = require('panepilot')
  local log = require('panepilot.log')
  panepilot._register()
  log.add('error', 'request failed')
  vim.cmd('PanepilotLog')

  eq(vim.bo.buftype, 'nofile')
  eq(vim.bo.modifiable, false)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  helpers.expect.match(lines[1], '%[ERROR%] request failed')
end

T['log']['shows masked debug context in a scratch buffer'] = function()
  local panepilot = require('panepilot')
  local context = require('panepilot.context')
  local original_get = context.get
  panepilot._register()
  context.get = function(_, callback)
    callback({ ok = true, pane_id = '%4', content = 'token=<masked>\ncontext' })
  end
  vim.cmd('PanepilotDebugContext')
  context.get = original_get

  eq(vim.bo.buftype, 'nofile')
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'token=<masked>', 'context' })
end

T['ghost'] = new_set()

T['ghost']['shows multiline virtual text and accepts it at the extmark'] = function()
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'hello world' })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  local cursor_before = vim.api.nvim_win_get_cursor(0)
  local screen_col_before = vim.fn.wincol()

  ghost.show(bufnr, 0, 5, { ' there\nnext line', 'other' })
  vim.cmd('redraw')
  eq(ghost.visible(bufnr), true)
  eq(vim.api.nvim_win_get_cursor(0), cursor_before)
  eq(vim.fn.wincol(), screen_col_before)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ghost._namespace(), 0, -1, { details = true })
  eq(#marks, 1)
  eq(marks[1][4].virt_text_pos, 'overlay')
  eq(marks[1][4].virt_text, { { ' there', 'PanepilotGhost' }, { ' world' } })
  eq(marks[1][4].virt_lines, { { { 'next line', 'PanepilotGhost' } } })

  eq(ghost.accept(bufnr), true)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'hello there', 'next line world' })
  eq(vim.api.nvim_win_get_cursor(0), { 2, 9 })
  eq(ghost.visible(bufnr), false)
end

T['ghost']['dismisses without changing the buffer'] = function()
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft' })
  ghost.show(bufnr, 0, 5, { ' candidate' })
  ghost.dismiss(bufnr)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'draft' })
  eq(ghost.visible(bufnr), false)
end

T['ghost']['refuses stale suggestions after the cursor moves'] = function()
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'hello' })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  ghost.show(bufnr, 0, 5, { ' world' })

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  eq(ghost.visible(bufnr), false)
  eq(ghost.accept(bufnr), false)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'hello' })
end

T['ghost']['accepts Japanese-aware word units and keeps only the remainder'] = function()
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft|' })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  ghost.show(bufnr, 0, 5, { '  あいう漢字。', 'other' })

  eq(ghost.accept_word(bufnr), true)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'draft  あいう|' })
  eq(ghost.visible(bufnr), true)
  eq(ghost.next_candidate(bufnr), false)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ghost._namespace(), 0, -1, { details = true })
  eq(marks[1][4].virt_text, { { '漢字。', 'PanepilotGhost' }, { '|' } })

  eq(ghost.accept_word(bufnr), true)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'draft  あいう漢字|' })
end

T['ghost']['accepts lines without the trailing newline, then newline plus the next line'] = function()
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft|' })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  ghost.show(bufnr, 0, 5, { 'first\nsecond\nthird' })

  eq(ghost.accept_line(bufnr), true)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'draftfirst|' })
  eq(ghost.visible(bufnr), true)
  eq(ghost.accept_line(bufnr), true)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'draftfirst', 'second|' })
  eq(ghost.visible(bufnr), true)
  eq(ghost.accept_line(bufnr), true)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'draftfirst', 'second', 'third|' })
  eq(ghost.visible(bufnr), false)
end

T['ghost']['cycles candidates in both directions'] = function()
  local ghost = require('panepilot.ghost')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft|' })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  ghost.show(bufnr, 0, 5, { 'one', 'two', 'three' })

  eq(ghost.next_candidate(bufnr), true)
  eq(ghost.next_candidate(bufnr), true)
  eq(ghost.next_candidate(bufnr), true)
  eq(ghost.prev_candidate(bufnr), true)
  eq(ghost.accept(bufnr), true)
  eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'draftthree|' })
end

T['activation'] = new_set()

T['activation']['attaches only to EDITPROMPT markdown.editprompt buffers'] = function()
  local panepilot = require('panepilot')
  local engine = require('panepilot.engine')
  panepilot._register()

  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(other)
  vim.env.EDITPROMPT = '1'
  vim.bo[other].filetype = 'markdown'
  eq(engine.is_attached(other), false)
  eq(#vim.api.nvim_buf_get_extmarks(other, require('panepilot.ghost')._namespace(), 0, -1, {}), 0)

  local target = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(target)
  vim.bo[target].filetype = 'markdown.editprompt'
  eq(engine.is_attached(target), true)
end

T['activation']['installs cleanup only on the target buffer and detaches on wipeout'] = function()
  local panepilot = require('panepilot')
  local engine = require('panepilot.engine')
  panepilot._register()
  vim.env.EDITPROMPT = '1'

  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(other)
  vim.bo[other].filetype = 'markdown'
  eq(#vim.api.nvim_get_autocmds({ group = 'Panepilot', buffer = other }), 0)

  local target = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(target)
  vim.bo[target].filetype = 'markdown.editprompt'
  local target_autocmds = vim.api.nvim_get_autocmds({ group = 'Panepilot', buffer = target })
  eq(#target_autocmds, 5)
  eq(engine.is_attached(target), true)

  vim.api.nvim_buf_delete(target, { force = true })
  eq(engine.is_attached(target), false)
end

T['automatic completion'] = new_set()

T['automatic completion']['pauses on 429, notifies once, and resumes explicitly'] = function()
  local engine = require('panepilot.engine')
  local original_notify = vim.notify
  local notifications = {}
  vim.notify = function(message, level)
    table.insert(notifications, { message, level })
  end

  local failure = { ok = false, kind = 'http', status = 429, message = 'rate limited' }
  engine._handle_failure(failure)
  engine._handle_failure(failure)
  eq(engine.auto_paused(), true)
  eq(engine._cmp_request_suppressed(), true)
  eq(#notifications, 1)
  eq(notifications[1][2], vim.log.levels.WARN)

  engine.resume_auto()
  eq(engine.auto_paused(), false)
  eq(engine._cmp_request_suppressed(), false)
  engine._handle_failure(failure)
  eq(#notifications, 2)
  vim.notify = original_notify
end

T['automatic completion']['never selects the codex backend'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    require('panepilot.config').setup({ backend = 'codex' })

    _G.codex_calls = 0
    local engine = require('panepilot.engine')
    engine._set_backend('codex', {
      is_available = function()
        return true
      end,
      complete = function()
        _G.codex_calls = _G.codex_calls + 1
        return {}
      end,
      cancel = function() end,
    })
    engine.attach(0)
  ]])
  child.type_keys('i')
  child.lua([[require('panepilot.engine').trigger(true)]])
  eq(child.lua_get('_G.codex_calls'), 0)
  child.stop()
end

T['automatic completion']['supports the Claude API backend'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.bo.filetype = 'markdown.editprompt'
    require('panepilot.config').setup({
      backend = 'claude',
      auto_trigger = { pane_quiet_sec = 0 },
    })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
    end

    _G.claude_calls = 0
    local engine = require('panepilot.engine')
    engine._set_backend('claude', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        _G.claude_calls = _G.claude_calls + 1
        callback({ ok = true, candidates = { ' continuation', 'alternative', 'third' } })
        return {}
      end,
      cancel = function() end,
    })
    engine.attach(0)
  ]])
  child.type_keys('i')
  child.lua([[require('panepilot.engine').trigger(true)]])
  eq(child.lua_get('_G.claude_calls'), 1)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), true)
  child.stop()
end

T['automatic completion']['suppresses while cmp or skkeleton is active'] = function()
  local engine = require('panepilot.engine')
  local original_cmp = package.loaded.cmp
  package.loaded.cmp = {
    visible = function()
      return true
    end,
  }
  eq(engine._auto_suppressed(), true)
  eq(engine._cmp_request_suppressed(), false)

  package.loaded.cmp = {
    visible = function()
      return false
    end,
  }
  local runtime = helpers.new_temp_dir('skkeleton-runtime')
  helpers.write_file(
    helpers.join(runtime, 'autoload/skkeleton.vim'),
    table.concat({
      'function! skkeleton#is_enabled() abort',
      '  return 1',
      'endfunction',
    }, '\n')
  )
  vim.opt.runtimepath:prepend(runtime)
  eq(engine._auto_suppressed(), true)
  eq(engine._cmp_request_suppressed(), true)
  vim.cmd('delfunction skkeleton#is_enabled')
  vim.opt.runtimepath:remove(runtime)
  helpers.rm_rf(runtime)
  package.loaded.cmp = original_cmp
end

T['automatic completion']['invalidates and cancels immediately when text changes'] = function()
  local engine = require('panepilot.engine')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.env.EDITPROMPT = '1'
  vim.bo[bufnr].filetype = 'markdown.editprompt'
  engine.attach(bufnr)

  local cancelled = 0
  engine._set_in_flight(bufnr, {
    cancel = function(handle)
      eq(handle, 'request-handle')
      cancelled = cancelled + 1
    end,
  }, 'request-handle')
  engine.schedule_auto(bufnr)
  eq(cancelled, 1)
  eq(engine._generation(bufnr), 1)

  engine.schedule_auto(bufnr)
  eq(engine._generation(bufnr), 2)
end

T['automatic completion']['runs debounce, pane quiet retry, backend, and ghost display end to end'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    require('panepilot.config').setup({
      auto_trigger = { debounce_ms = 10, pane_quiet_sec = 0.01 },
    })

    _G.observe_calls = 0
    _G.backend_calls = 0
    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      _G.observe_calls = _G.observe_calls + 1
      if _G.observe_calls == 1 then
        return false, 'hash', 10
      end
      return true, 'hash', 0
    end

    local engine = require('panepilot.engine')
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        _G.backend_calls = _G.backend_calls + 1
        callback({ ok = true, candidates = { ' completion' } })
        return {}
      end,
      cancel = function() end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
  ]])
  child.type_keys('i', 'x')
  child.lua([[
    vim.wait(1000, function()
      return require('panepilot.ghost').visible()
    end)
  ]])

  eq(child.lua_get('_G.observe_calls'), 2)
  eq(child.lua_get('_G.backend_calls'), 1)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), true)
  child.stop()
end

T['automatic completion']['discards responses after cursor move, InsertLeave, or buffer switch'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    local context = require('panepilot.context')
    _G.context_calls = 0
    context.get = function(_, callback)
      _G.context_calls = _G.context_calls + 1
      callback({ ok = true, pane_id = '%4', content = 'stable pane ' .. _G.context_calls })
    end

    _G.backend_callbacks = {}
    local engine = require('panepilot.engine')
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        table.insert(_G.backend_callbacks, callback)
        return {}
      end,
      cancel = function() end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
    _G.target_bufnr = vim.api.nvim_get_current_buf()
  ]])
  child.type_keys('A')

  child.lua([[require('panepilot.engine').trigger()]])
  child.type_keys('<Left>')
  child.lua([[_G.backend_callbacks[1]({ ok = true, candidates = { ' stale cursor' } })]])
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), false)

  child.type_keys('<Right>')
  child.lua([[require('panepilot.engine').trigger()]])
  child.type_keys('<Esc>')
  child.lua([[_G.backend_callbacks[2]({ ok = true, candidates = { ' stale mode' } })]])
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), false)

  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').trigger()
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    _G.backend_callbacks[3]({ ok = true, candidates = { ' stale buffer' } })
  ]])
  eq(
    child.lua_get(
      [[#vim.api.nvim_buf_get_extmarks(_G.target_bufnr, require('panepilot.ghost')._namespace(), 0, -1, {})]]
    ),
    0
  )
  child.stop()
end

return T
