-- Neo-tree is a Neovim plugin to browse the file system
-- https://github.com/nvim-neo-tree/neo-tree.nvim

return {
  'nvim-neo-tree/neo-tree.nvim',
  version = '*',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-tree/nvim-web-devicons', -- not strictly required, but recommended
    'MunifTanjim/nui.nvim',
  },
  cmd = 'Neotree',
  keys = {
    { '\\', ':Neotree reveal<CR>', { desc = 'NeoTree reveal' } },
    { '<F3>', ':Neotree reveal<CR>', { desc = 'NeoTree reveal' } },
    { '<F4>', ':Neotree document_symbols<CR>', { desc = 'NeoTree document_symbols' } },
  },
  opts = {
    sources = {
      "filesystem",
      -- "buffers",
      -- "git_status",
      "document_symbols",
    },
    filesystem = {
      window = {
        mappings = {
          ['\\'] = 'close_window',
          ['<F3>'] = 'close_window',
        },
      },
      follow_current_file = {
        enabled = true, -- This will find and focus the file in the active buffer every time
        --              -- the current file is changed while the tree is open.
        leave_dirs_open = false, -- `false` closes auto expanded dirs, such as with `:Neotree reveal`
      },
    },
    document_symbols = {
      follow_cursor = true,
      window = {
        mappings = {
          ['<F4>'] = 'close_window',
        },
      },
    },
  },
}
