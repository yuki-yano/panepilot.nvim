local Helpers = {}

local uv = vim.uv or vim.loop

Helpers.expect = vim.deepcopy(MiniTest.expect)
Helpers.eq = MiniTest.expect.equality

Helpers.expect.match = MiniTest.new_expectation('string matching', function(subject, pattern)
  return type(subject) == 'string' and subject:find(pattern) ~= nil
end, function(subject, pattern)
  return string.format('Pattern: %s\nObserved string: %s', vim.inspect(pattern), vim.inspect(subject))
end)

Helpers.new_temp_dir = function(prefix)
  local path = vim.fn.tempname() .. '-' .. (prefix or 'panepilot')
  assert(uv.fs_mkdir(path, 448))
  return path
end

Helpers.rm_rf = function(path)
  if path and path ~= '' then
    vim.fn.delete(path, 'rf')
  end
end

Helpers.join = function(...)
  return vim.fs.normalize(table.concat({ ... }, '/'))
end

Helpers.write_file = function(path, content)
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, 'p')
  local fd = assert(uv.fs_open(path, 'w', 420))
  assert(uv.fs_write(fd, content, -1))
  assert(uv.fs_close(fd))
end

Helpers.read_file = function(path)
  local fd = uv.fs_open(path, 'r', 438)
  if not fd then
    return nil
  end

  local stat = assert(uv.fs_fstat(fd))
  local data = stat.size > 0 and assert(uv.fs_read(fd, stat.size, 0)) or ''
  assert(uv.fs_close(fd))
  return data
end

Helpers.new_child_neovim = function()
  local child = MiniTest.new_child_neovim()

  child.setup = function()
    child.restart({ '-u', 'scripts/minimal_init.lua' })
    child.lua([[
      for key, _ in pairs(package.loaded) do
        if key == 'panepilot' or vim.startswith(key, 'panepilot.') then
          package.loaded[key] = nil
        end
      end
    ]])
  end

  child.set_lines = function(lines)
    if type(lines) == 'string' then
      lines = vim.split(lines, '\n', { plain = true })
    end
    child.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end

  child.set_cursor = function(row, col)
    child.api.nvim_win_set_cursor(0, { row, col })
  end

  return child
end

return Helpers
