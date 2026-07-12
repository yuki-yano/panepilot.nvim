if vim.g.loaded_panepilot then
  return
end
vim.g.loaded_panepilot = 1

require('panepilot')._register()
