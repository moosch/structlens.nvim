local M = {}

M.ns = vim.api.nvim_create_namespace("structlens")

---@param bufnr integer
function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

--- Replace every annotation in the buffer in one go. Painting incrementally
--- over a buffer that may still be changing is how wrong numbers get on screen.
---@param bufnr integer
---@param specs table[] output of render.marks
---@param cfg table
function M.apply(bufnr, specs, cfg)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  M.clear(bufnr)
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  for _, spec in ipairs(specs) do
    if spec.row >= 0 and spec.row <= last then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, spec.row, 0, {
        virt_text = spec.virt_text,
        virt_text_pos = spec.virt_text and "eol" or nil,
        virt_lines = spec.virt_lines,
        hl_mode = "combine",
        priority = cfg.priority,
      })
    end
  end
end

return M
