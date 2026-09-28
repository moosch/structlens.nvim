local M = {}

-- Linked with default = true so a colorscheme can override any of them, and
-- re-asserted on ColorScheme because `:hi clear` drops links.
local LINKS = {
  StructLensSize = "Comment",
  StructLensOffset = "Comment",
  StructLensPad = "WarningMsg",
  StructLensSlack = "Comment",
  StructLensHole = "DiagnosticVirtualTextWarn",
  StructLensTotal = "Comment",
  StructLensWaste = "DiagnosticVirtualTextError",
}

function M.define()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.setup()
  M.define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    desc = "Re-assert structlens highlight links after a colorscheme change",
    group = vim.api.nvim_create_augroup("structlens-highlight", { clear = true }),
    callback = M.define,
  })
end

return M
