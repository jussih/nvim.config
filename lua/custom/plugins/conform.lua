local util = require 'conform.util'

return {
  {
    'stevearc/conform.nvim',
    opts = {
      formatters = {
        prettier_npx = {
          command = 'npx',
          args = { 'prettier', '--stdin-filepath', '$FILENAME' },
          range_args = function(self, ctx)
            local start_offset, end_offset = util.get_offsets_from_range(ctx.buf, ctx.range)
            local args = { '--stdin-filepath', '$FILENAME' }
            return vim.list_extend(args, { '--range-start=' .. start_offset, '--range-end=' .. end_offset })
          end,
          -- Send file contents to stdin, read new contents from stdout (default true)
          -- When false, will create a temp file (will appear in "$FILENAME" args). The temp
          -- file is assumed to be modified in-place by the format command.
          stdin = true,
          -- A function that calculates the directory to run the command in
          cwd = require('conform.util').root_file { '.editorconfig', 'package.json', '.git' },
          -- When cwd is not found, don't run the formatter (default false)
          require_cwd = false,
          -- When stdin=false, use this template to generate the temporary file that gets formatted
          tmpfile_format = '.conform.$RANDOM.$FILENAME',
          -- Set to false to disable merging the config with the base definition
          inherit = false,
        },
      },
    },
  },
}
