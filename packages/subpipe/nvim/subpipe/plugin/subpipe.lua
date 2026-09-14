-- Autoload entry (optional); start() is invoked from subpipe review -c
vim.api.nvim_create_user_command("SubpipeMentor", function()
  require("subpipe.mentor").start()
end, {})
