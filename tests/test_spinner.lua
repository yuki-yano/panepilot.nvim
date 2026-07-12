local helpers = require('tests.helpers')

local new_set = MiniTest.new_set
local eq = helpers.eq

local T = new_set({
  hooks = {
    post_case = function()
      require('panepilot.engine')._reset()
      require('panepilot.spinner')._reset()
      vim.env.EDITPROMPT = nil
    end,
  },
})

T['spinner'] = new_set()

T['spinner']['appears after a delay, animates, and keeps the cursor in place'] = function()
  local spinner = require('panepilot.spinner')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'あいう world' })
  vim.api.nvim_win_set_cursor(0, { 1, 9 })
  local cursor_before = vim.api.nvim_win_get_cursor(0)
  local screen_col_before = vim.fn.wincol()

  local handle = spinner.start(bufnr, 0, 9)
  local delay_timer = handle.delay_timer
  eq(spinner.pending(bufnr), true)
  eq(spinner.visible(bufnr), false)
  vim.wait(150, function()
    return false
  end, 10)
  eq(spinner.visible(bufnr), false)
  eq(
    vim.wait(1000, function()
      return spinner.visible(bufnr)
    end, 10),
    true
  )

  vim.cmd('redraw')
  eq(vim.api.nvim_win_get_cursor(0), cursor_before)
  eq(vim.fn.wincol(), screen_col_before)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, spinner._namespace(), 0, -1, { details = true })
  eq(#marks, 1)
  eq({ marks[1][2], marks[1][3] }, { 0, 9 })
  eq(marks[1][4].virt_text_pos, 'overlay')
  eq(marks[1][4].virt_text[1], { ' ' })
  eq(vim.fn.strdisplaywidth(marks[1][4].virt_text[2][1]), 1)
  eq(marks[1][4].virt_text[3], { ' world' })
  local extmark_id = marks[1][1]
  local first_frame = marks[1][4].virt_text[2][1]

  eq(
    vim.wait(1000, function()
      local current = vim.api.nvim_buf_get_extmarks(bufnr, spinner._namespace(), 0, -1, { details = true })
      return current[1] and current[1][4].virt_text[2][1] ~= first_frame
    end, 10),
    true
  )
  marks = vim.api.nvim_buf_get_extmarks(bufnr, spinner._namespace(), 0, -1, { details = true })
  eq(#marks, 1)
  eq(marks[1][1], extmark_id)

  local animation_timer = handle.animation_timer
  eq(spinner.stop(bufnr, handle), true)
  eq(delay_timer:is_closing(), true)
  eq(animation_timer:is_closing(), true)
  eq(spinner.pending(bufnr), false)
  eq(spinner.visible(bufnr), false)
end

T['spinner']['does not appear when stopped during the delay'] = function()
  local spinner = require('panepilot.spinner')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'draft' })

  local handle = spinner.start(bufnr, 0, 5)
  local delay_timer = handle.delay_timer
  eq(spinner.stop(bufnr, handle), true)
  eq(delay_timer:is_closing(), true)
  vim.wait(250, function()
    return false
  end, 10)
  eq(spinner.pending(bufnr), false)
  eq(#vim.api.nvim_buf_get_extmarks(bufnr, spinner._namespace(), 0, -1, {}), 0)
end

T['engine'] = new_set()

T['engine']['shows the spinner only for a manual request and clears it before ghost text'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
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
  ]])
  child.type_keys('A')

  child.lua([[
    require('panepilot.engine').trigger(true)
    vim.wait(250, function()
      return false
    end, 10)
  ]])
  eq(child.lua_get([[require('panepilot.spinner').pending()]]), false)
  eq(child.lua_get([[require('panepilot.spinner').visible()]]), false)

  child.lua([[
    require('panepilot.engine').trigger()
    vim.wait(1000, function()
      return require('panepilot.spinner').visible()
    end, 10)
  ]])
  eq(child.lua_get([[require('panepilot.spinner').visible()]]), true)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), false)

  child.lua([[
    require('panepilot.engine').trigger()
    _G.backend_callbacks[2]({ ok = true, candidates = { ' stale completion' } })
  ]])
  eq(child.lua_get([[require('panepilot.spinner').pending()]]), true)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), false)
  child.lua([[
    vim.wait(1000, function()
      return require('panepilot.spinner').visible()
    end, 10)
    _G.backend_callbacks[3]({ ok = true, candidates = { ' completion' } })
  ]])
  eq(child.lua_get([[require('panepilot.spinner').pending()]]), false)
  eq(child.lua_get([[require('panepilot.spinner').visible()]]), false)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), true)
  child.stop()
end

T['engine']['clears the spinner for every context and backend failure result'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    _G.defer_context = true
    _G.backend_calls = 0
    _G.backend_callbacks = {}
    local context = require('panepilot.context')
    context.get = function(_, callback)
      if _G.defer_context then
        _G.context_callback = callback
      else
        callback({ ok = true, pane_id = '%4', content = 'stable pane' })
      end
      return nil
    end

    local engine = require('panepilot.engine')
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        _G.backend_calls = _G.backend_calls + 1
        table.insert(_G.backend_callbacks, callback)
        return {}
      end,
      cancel = function() end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
  ]])
  child.type_keys('A')

  local function wait_for_spinner()
    child.lua([[
      require('panepilot.engine').trigger()
      vim.wait(1000, function()
        return require('panepilot.spinner').visible()
      end, 10)
    ]])
    eq(child.lua_get([[require('panepilot.spinner').visible()]]), true)
  end

  local function expect_cleared()
    eq(child.lua_get([[require('panepilot.spinner').pending()]]), false)
    eq(child.lua_get([[require('panepilot.spinner').visible()]]), false)
    eq(child.lua_get([[require('panepilot.ghost').visible()]]), false)
  end

  wait_for_spinner()
  child.lua([[_G.context_callback({ cancelled = true })]])
  expect_cleared()
  eq(child.lua_get('_G.backend_calls'), 0)

  wait_for_spinner()
  child.lua([[_G.context_callback({ ok = false, message = 'capture failed' })]])
  expect_cleared()
  eq(child.lua_get('_G.backend_calls'), 0)

  child.lua([[_G.defer_context = false]])
  wait_for_spinner()
  child.lua([[_G.backend_callbacks[1]({ ok = false, kind = 'curl', message = 'request failed' })]])
  expect_cleared()

  wait_for_spinner()
  child.lua([[_G.backend_callbacks[2]({ ok = false, kind = 'cancelled' })]])
  expect_cleared()
  child.stop()
end

T['engine']['does not flash for a fast response or cache hit'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end

    _G.backend_calls = 0
    _G.cancel_calls = 0
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
      cancel = function()
        _G.cancel_calls = _G.cancel_calls + 1
      end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
  ]])
  child.type_keys('A')

  child.lua([[
    require('panepilot.engine').trigger()
    vim.wait(250, function()
      return false
    end, 10)
  ]])
  eq(child.lua_get([[require('panepilot.spinner').pending()]]), false)
  eq(child.lua_get([[require('panepilot.spinner').visible()]]), false)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), true)
  eq(child.lua_get('_G.backend_calls'), 1)

  child.lua([[
    require('panepilot').dismiss()
    require('panepilot.engine').trigger()
    vim.wait(250, function()
      return false
    end, 10)
  ]])
  eq(child.lua_get([[require('panepilot.spinner').pending()]]), false)
  eq(child.lua_get([[require('panepilot.spinner').visible()]]), false)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), true)
  eq(child.lua_get('_G.backend_calls'), 1)
  eq(child.lua_get('_G.cancel_calls'), 0)
  child.stop()
end

T['engine']['never starts the spinner for cmp completion'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      callback({ ok = true, pane_id = '%4', content = 'stable pane' })
    end
    context.observe_pane = function()
      return true, 'hash', 0
    end

    local engine = require('panepilot.engine')
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function(_, callback)
        _G.backend_callback = callback
        return {}
      end,
      cancel = function() end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').complete_cmp(function(candidates)
      _G.cmp_candidates = candidates
    end)
    vim.wait(250, function()
      return false
    end, 10)
  ]])
  eq(child.lua_get([[require('panepilot.spinner').pending()]]), false)
  eq(child.lua_get([[require('panepilot.spinner').visible()]]), false)

  child.lua([[_G.backend_callback({ ok = true, candidates = { ' completion' } })]])
  eq(child.lua_get('_G.cmp_candidates'), { ' completion' })
  child.stop()
end

T['engine']['invalidates a pending manual request when the cursor moves'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      _G.context_callback = callback
      return nil
    end

    _G.backend_calls = 0
    local engine = require('panepilot.engine')
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function()
        _G.backend_calls = _G.backend_calls + 1
        return {}
      end,
      cancel = function() end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').trigger()
    vim.wait(1000, function()
      return require('panepilot.spinner').visible()
    end, 10)
  ]])
  eq(child.lua_get([[require('panepilot.spinner').visible()]]), true)

  child.type_keys('<Left>', '<Right>')
  child.lua([[_G.context_callback({ ok = true, pane_id = '%4', content = 'stale pane' })]])
  eq(child.lua_get([[require('panepilot.spinner').pending()]]), false)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), false)
  eq(child.lua_get('_G.backend_calls'), 0)
  child.stop()
end

T['engine']['cancels an in-flight context capture and ignores its late result'] = function()
  local child = helpers.new_child_neovim()
  child.setup()
  child.lua([[
    vim.env.EDITPROMPT = '1'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

    local context = require('panepilot.context')
    context.get = function(_, callback)
      _G.context_callback = callback
      return 'context-handle'
    end
    context.cancel = function(handle)
      _G.cancelled_context_handle = handle
    end

    _G.backend_calls = 0
    local engine = require('panepilot.engine')
    engine._set_backend('openai', {
      is_available = function()
        return true
      end,
      complete = function()
        _G.backend_calls = _G.backend_calls + 1
        return {}
      end,
      cancel = function() end,
    })

    require('panepilot')._register()
    vim.bo.filetype = 'markdown.editprompt'
  ]])
  child.type_keys('A')
  child.lua([[
    require('panepilot.engine').trigger()
    vim.wait(1000, function()
      return require('panepilot.spinner').visible()
    end, 10)
    require('panepilot').dismiss()
  ]])

  eq(child.lua_get('_G.cancelled_context_handle'), 'context-handle')
  eq(child.lua_get([[require('panepilot.spinner').pending()]]), false)
  child.lua([[_G.context_callback({ ok = true, pane_id = '%4', content = 'stale pane' })]])
  eq(child.lua_get('_G.backend_calls'), 0)
  eq(child.lua_get([[require('panepilot.ghost').visible()]]), false)
  child.stop()
end

T['engine']['cancels an in-flight manual request for every dismissal event'] = function()
  local cases = {
    {
      name = 'CursorMovedI',
      act = function(child)
        child.type_keys('<Left>')
      end,
    },
    {
      name = 'TextChangedI',
      act = function(child)
        child.type_keys('x')
      end,
    },
    {
      name = 'InsertLeave',
      act = function(child)
        child.type_keys('<Esc>')
      end,
    },
    {
      name = 'BufLeave',
      act = function(child)
        child.lua([[vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))]])
      end,
    },
    {
      name = 'BufWipeout',
      act = function(child)
        child.lua([[vim.api.nvim_buf_delete(_G.target_bufnr, { force = true })]])
      end,
    },
    {
      name = 'dismiss',
      act = function(child)
        child.lua([[require('panepilot').dismiss()]])
      end,
    },
  }

  for _, case in ipairs(cases) do
    local child = helpers.new_child_neovim()
    child.setup()
    child.lua([[
      vim.env.EDITPROMPT = '1'
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })

      local context = require('panepilot.context')
      context.get = function(_, callback)
        callback({ ok = true, pane_id = '%4', content = 'stable pane' })
      end

      _G.backend_callbacks = {}
      _G.cancelled_handles = {}
      local engine = require('panepilot.engine')
      engine._set_backend('openai', {
        is_available = function()
          return true
        end,
        complete = function(_, callback)
          table.insert(_G.backend_callbacks, callback)
          return 'request-' .. #_G.backend_callbacks
        end,
        cancel = function(handle)
          table.insert(_G.cancelled_handles, handle)
        end,
      })

      require('panepilot')._register()
      vim.bo.filetype = 'markdown.editprompt'
      _G.target_bufnr = vim.api.nvim_get_current_buf()
    ]])
    child.type_keys('A')
    child.lua([[
      require('panepilot.engine').trigger()
      vim.wait(1000, function()
        return require('panepilot.spinner').visible(_G.target_bufnr)
      end, 10)
    ]])
    eq(child.lua_get([[require('panepilot.spinner').visible(_G.target_bufnr)]]), true)

    case.act(child)
    eq(child.lua_get([[require('panepilot.spinner').pending(_G.target_bufnr)]]), false, case.name)
    eq(child.lua_get('_G.cancelled_handles'), { 'request-1' }, case.name)
    child.lua([[_G.backend_callbacks[1]({ ok = true, candidates = { ' stale completion' } })]])
    eq(child.lua_get([[require('panepilot.ghost').visible(_G.target_bufnr)]]), false, case.name)
    if case.name == 'BufWipeout' then
      eq(child.lua_get([[require('panepilot.engine').is_attached(_G.target_bufnr)]]), false)
    end
    child.stop()
  end
end

return T
