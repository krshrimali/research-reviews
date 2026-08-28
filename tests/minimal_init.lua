-- Minimal init for headless tests: put review.nvim + plenary on the rtp.
-- Resolve our own path via debug.getinfo so it is robust to `:cd` in tests.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.runtimepath:append(root)
-- Register absolute Lua search paths so `require` survives cwd changes.
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local lazy = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({ "plenary.nvim", "diffview.nvim" }) do
  local dir = lazy .. "/" .. p
  vim.opt.runtimepath:append(dir)
  package.path = dir .. "/lua/?.lua;" .. dir .. "/lua/?/init.lua;" .. package.path
end

vim.cmd("runtime plugin/plenary.vim")

-- Redirect persisted state to a temp dir (sandbox stdpath('state') is read-only).
vim.env.REVIEW_STATE_DIR = vim.fn.tempname() .. "/review-state"
