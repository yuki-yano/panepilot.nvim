vim.o.swapfile = false
vim.o.hidden = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.completeopt = 'menu,menuone,noselect'

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. '/.deps/nvim-cmp')
vim.opt.runtimepath:prepend(root .. '/.deps/mini.nvim')

if #vim.api.nvim_list_uis() == 0 then
  require('mini.test').setup()
end
