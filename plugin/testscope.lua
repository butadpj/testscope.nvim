if vim.g.loaded_testscope then
  return
end
vim.g.loaded_testscope = true

vim.api.nvim_create_user_command("Testscope", function(options)
  require("testscope").open({ focus = options.bang })
end, { bang = true, desc = "Browse tests in the current buffer (! for focus mode)" })

vim.api.nvim_create_user_command("TestscopeClose", function()
  require("testscope").close()
end, { desc = "Close the test browser" })
