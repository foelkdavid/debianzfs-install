vim.opt.number = true
vim.opt.relativenumber = true

vim.opt.splitbelow = true
vim.opt.splitright = true

vim.opt.wrap = false

vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4

vim.opt.clipboard = "unnamedplus"

-- Set initial scrolloff value
-- vim.o.scrolloff = 999

-- Keep a scroll margin
vim.opt.scrolloff = 6

-- Allow the cursor to move past the last line
vim.opt.virtualedit = "onemore"

vim.opt.virtualedit = "block"

vim.opt.inccommand = "split"

vim.opt.ignorecase = true

vim.opt.termguicolors = true

vim.g.mapleader = " "

vim.opt.updatetime = 1000

-- setup vimtex
vim.g.vimtex_view_method = "zathura" -- Set your preferred PDF viewer
vim.g.vimtex_auto_compile = 1 -- Enable auto compilation
vim.g.vimtex_fold_enabled = 0 -- Enable folding
vim.g.vimtex_format_enabled = 1

-- change latexmk output dir and link pdf to the root folder
vim.g.vimtex_compiler_latexmk = {
	out_dir = "output",
}

-- disable markdown folding
vim.g.vim_markdown_folding_disabled = 1

-- special options
vim.api.nvim_create_autocmd("FileType", {
	pattern = "c",
	callback = function()
		vim.bo.tabstop = 2 -- Number of spaces per tab
		vim.bo.softtabstop = 2 -- Number of spaces per Tab press
		vim.bo.shiftwidth = 2 -- Number of spaces for auto-indents
		vim.bo.expandtab = true -- Convert tabs to spaces
	end,
})
