vim.env.MINITEST = '1'

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

vim.cmd('set rtp^=' .. vim.fn.fnameescape(root))
vim.cmd('set rtp^=' .. vim.fn.fnameescape(root .. '/.deps/nvim-cmp'))
vim.cmd('set rtp^=' .. vim.fn.fnameescape(root .. '/.deps/mini.nvim'))

local MiniTest = require('mini.test')
MiniTest.setup()

local test_files = vim.fn.globpath(root .. '/tests', 'test_*.lua', false, true)
MiniTest.run(test_files)
